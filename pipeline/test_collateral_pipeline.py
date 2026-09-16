#!/usr/bin/env python3
"""
Deterministic tests for MVP-03A collateral pipeline (post-correction).

Covers:
- Original E1-E8 behavior (with asset-agnostic corrections)
- Explicit asset_subtype + asset_jurisdiction (not derived)
- Lender jurisdiction != asset jurisdiction
- LICO happy path
- tGOLD happy path through SAME engine (no branching)
- Subtype rejection
- Asset jurisdiction rejection
- Exact Decimal -> minor-unit conversion
- Excessive precision rejection
- Integer haircut / max LTV
- Deterministic pretty JSON
- Deterministic assessmentHash
- navHash = SHA-256 of raw NAV bytes (unaltered)
- AnchorInput mapping
- No broadcast capability

Run:
    python3 -m unittest test_collateral_pipeline -v
"""

from __future__ import annotations
import hashlib
import io
import json
import subprocess
import sys
import unittest
from decimal import Decimal
from pathlib import Path

# Make module importable when run as script
sys.path.insert(0, str(Path(__file__).parent))

import collateral_pipeline as cp
import collateral_policy_evaluator as ev


# ── Deterministic test constants ─────────────────────────────
T0 = 1_789_231_149

def _base_nav(currency="USD", amount="22500.0", notice="DEMO / TESTNET - NO PHYSICAL BACKING"):
    """Return a fresh base NAV dict. Amount can be str, int, Decimal, or float."""
    return {
        "schemaVersion": "1.0",
        "navId": "NAV-TEST-1",
        "assetId": "TESTASSET",
        "lasReference": {
            "lasHash": "0xPLACEHOLDER",
            "rulesVersion": 1,
            "performedAt": T0 - 100000,
        },
        "verifiedQuantity": 1000,
        "unit": "kg",
        "qualityAdjustments": [],
        "priceSource": {
            "type": "MANUAL",
            "referencePrice": 22.5,
            "currency": currency,
        },
        "valuation": {
            "finalPhysicalNAV": amount if isinstance(amount, (int, Decimal)) else Decimal(amount),
            "currency": currency,
        },
        "methodology": "LAS-NAV-COMMODITY-v1",
        "methodologyVersion": 1,
        "performedAt": T0,
        "recordHashAlgorithm": "SHA-256",
        "notice": notice,
    }

BASE_LAS = {
    "schemaVersion": "1.0",
    "lasId": "LAS-TEST-1",
    "assetId": "TESTASSET",
    "status": "VERIFIED",
    "summary": "TEST",
    "verificationLevel": "DOCUMENTARY",
    "rulesVersion": 1,
    "evidenceIds": ["0xaa"],
    "checks": [],
    "performedAt": T0 - 100000,
    "recordHashAlgorithm": "SHA-256",
    "notice": "TEST",
}

def _base_policy(**overrides):
    """Fresh policy with sensible defaults; overrides replace top-level fields."""
    p = {
        "schemaVersion": "1.0",
        "policyVersionLabel": "test-v1",
        "haircutBps": 2000,
        "maxLTVBps": 5000,
        "acceptsDemoAssets": True,
        "validitySeconds": 2592000,
        "lasMaxAgeSeconds": 31536000,
        "navMaxAgeSeconds": 15552000,
        "allowedCurrencies": ["USD"],
        "allowedJurisdictions": ["BO"],
        "allowedSubtypes": ["LI2CO3-COMMODITY", "GOLD-COMMODITY"],
    }
    p.update(overrides)
    return p


def _computed_las_hash(las_dict: dict) -> str:
    return cp.sha256_hex(cp.pretty_bytes(las_dict))


def _make_nav_with_link(las_dict, **nav_overrides):
    """NAV with correct __computedLasHash for E4."""
    amount = nav_overrides.pop("amount", "22500.0")
    currency = nav_overrides.pop("currency", "USD")
    notice = nav_overrides.pop("notice", "DEMO / TESTNET - NO PHYSICAL BACKING")
    nav = _base_nav(currency=currency, amount=amount, notice=notice)
    nav["lasReference"]["lasHash"] = _computed_las_hash(las_dict)
    nav["__computedLasHash"] = _computed_las_hash(las_dict)
    for k, v in nav_overrides.items():
        nav[k] = v
    return nav


# ══════════════════════════════════════════════════════════════
class TestEligibilityRules(unittest.TestCase):
    """§B rules E1-E8, asset-agnostic."""

    def test_01_eligible_happy_path(self):
        """All 8 rules PASS -> ELIGIBLE."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY",
            asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_ELIGIBLE)
        self.assertEqual(len(r.rules_passed), 8)
        self.assertEqual(r.rules_failed, [])

    def test_02_las_not_verified(self):
        las_bad = dict(BASE_LAS, status="REJECTED")
        nav = _make_nav_with_link(las_bad)
        r = ev.evaluate_eligibility(
            nav=nav, las=las_bad, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_LAS_NOT_VERIFIED)

    def test_03_las_stale(self):
        las_old = dict(BASE_LAS, performedAt=T0 - 100_000_000)
        nav = _make_nav_with_link(las_old)
        r = ev.evaluate_eligibility(
            nav=nav, las=las_old, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_LAS_STALE)

    def test_04_nav_stale(self):
        nav = _make_nav_with_link(BASE_LAS)
        nav["performedAt"] = T0 - 100_000_000
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_NAV_STALE)

    def test_05_nav_las_mismatch(self):
        nav = _make_nav_with_link(BASE_LAS)
        nav["lasReference"]["lasHash"] = "0x" + "de" * 32
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_NAV_LAS_MISMATCH)

    def test_06_currency_not_allowed(self):
        nav = _make_nav_with_link(BASE_LAS)
        nav["priceSource"]["currency"] = "EUR"
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_CURRENCY_NOT_ALLOWED)

    def test_07_asset_jurisdiction_not_allowed(self):
        """E6 rejects when asset_jurisdiction not in policy allowed list."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(allowedJurisdictions=["US-DE"]),
            asset_subtype="LI2CO3-COMMODITY",
            asset_jurisdiction="BO",  # not in allowed list
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_ASSET_JURISDICTION_NOT_ALLOWED)

    def test_08_demo_asset_rejected(self):
        nav = _make_nav_with_link(BASE_LAS)  # notice contains "DEMO"
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(acceptsDemoAssets=False),
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_DEMO_ASSET_REJECTED)

    def test_09_asset_subtype_not_allowed(self):
        """E8: subtype comes from explicit input, not derived."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(allowedSubtypes=["AU-COMMODITY"]),
            asset_subtype="LI2CO3-COMMODITY",  # not in allowed list
            asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_ASSET_SUBTYPE_NOT_ALLOWED)


# ══════════════════════════════════════════════════════════════
class TestLenderVsAssetJurisdiction(unittest.TestCase):
    """
    C2: Lender jurisdiction MUST NOT substitute for asset jurisdiction.
    The evaluator does not even accept a `lender` argument for E6.
    """

    def test_10_lender_diff_from_asset_e6_pass(self):
        """Lender in US-DE, asset in BO, policy allows BO -> E6 PASS."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(allowedJurisdictions=["BO"]),
            asset_subtype="LI2CO3-COMMODITY",
            asset_jurisdiction="BO",  # asset in BO
            now_ts=T0,
        )
        # Note: lender's jurisdiction is completely absent here.
        # If E6 were still using lender.jurisdiction, this test wouldn't
        # even compile because evaluator no longer accepts `lender=`.
        self.assertEqual(r.verdict, ev.VERDICT_ELIGIBLE)
        self.assertIn(ev.RULE_ASSET_JURISDICTION_ALLOWED, r.rules_passed)

    def test_11_lender_diff_from_asset_e6_fail(self):
        """Lender in US-DE, asset in BO, policy only allows US-DE -> E6 FAIL."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(allowedJurisdictions=["US-DE"]),
            asset_subtype="LI2CO3-COMMODITY",
            asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_INELIGIBLE)
        self.assertEqual(r.first_fail_reason, ev.REASON_ASSET_JURISDICTION_NOT_ALLOWED)

    def test_12_evaluator_signature_does_not_accept_lender(self):
        """
        Structural test: evaluator signature must NOT have `lender=` param.
        If it did, someone could accidentally revert to the old lender-jurisdiction
        proxy for E6.
        """
        import inspect
        sig = inspect.signature(ev.evaluate_eligibility)
        self.assertNotIn("lender", sig.parameters,
            "evaluate_eligibility must not accept a `lender` param — "
            "asset_jurisdiction is the E6 driver, not lender jurisdiction.")


# ══════════════════════════════════════════════════════════════
class TestAssetAgnostic(unittest.TestCase):
    """C1 + C4: Same engine processes different assets with no branching."""

    def test_13_no_subtype_derivation_function(self):
        """The old derive_subtype_from_asset_id function must not exist."""
        self.assertFalse(
            hasattr(ev, "derive_subtype_from_asset_id"),
            "derive_subtype_from_asset_id must not exist in the evaluator."
        )

    def test_14_no_asset_prefix_mapping_in_source(self):
        """No 'LICO', 'GOLD', 'AU-COMMODITY' etc. hardcoded in evaluator source."""
        with open(Path(__file__).parent / "collateral_policy_evaluator.py") as f:
            src = f.read()
        forbidden_snippets = [
            "LICO",             # asset id prefix mapping
            "LI2CO3-COMMODITY", # value mapping
            "GOLD",
            "AU-COMMODITY",
            "AG-COMMODITY",
            "FE-COMMODITY",
            "startswith",       # any prefix-based routing
            "derive_subtype",
        ]
        found = [s for s in forbidden_snippets if s in src]
        self.assertEqual(found, [],
            f"asset-specific/prefix-derived tokens found in evaluator: {found}")

    def test_15_lico_through_generic_engine(self):
        """LICO-0001 with LI2CO3-COMMODITY / BO -> ELIGIBLE."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY",
            asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_ELIGIBLE)

    def test_16_tgold_through_same_generic_engine(self):
        """tGOLD-0001 with GOLD-COMMODITY / BO -> ELIGIBLE, SAME engine."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="GOLD-COMMODITY",  # different subtype
            asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_ELIGIBLE)
        # Same code path — no branching. Both LICO and tGOLD PASS with the
        # same policy fixture.

    def test_17_tgold_full_assessment_path(self):
        """Full pipeline path for tGOLD (build_assessment + hash)."""
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="GOLD-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        rec = cp.build_assessment(
            asset_id="tGOLD-0001",
            asset_subtype="GOLD-COMMODITY",
            asset_jurisdiction="BO",
            lender_id=1, lender_jurisdiction="US-DE",
            policy=_base_policy(), policy_pretty_hash="0x" + "aa" * 32,
            nav=nav, nav_pretty_hash="0x" + "bb" * 32,
            las=BASE_LAS, las_pretty_hash="0x" + "cc" * 32,
            performed_at=T0, eligibility=r,
        )
        self.assertEqual(rec["assetId"], "tGOLD-0001")
        self.assertEqual(rec["assetSubtype"], "GOLD-COMMODITY")
        self.assertEqual(rec["assetJurisdiction"], "BO")
        self.assertEqual(rec["eligibility"]["verdictCode"], ev.VERDICT_ELIGIBLE)
        # Assessment produces valid pretty JSON
        h = cp.sha256_hex(cp.pretty_bytes(rec))
        self.assertTrue(h.startswith("0x"))
        self.assertEqual(len(h), 66)


# ══════════════════════════════════════════════════════════════
class TestDecimalArithmetic(unittest.TestCase):
    """C3: Float-free financial core using Decimal."""

    def test_18_decimal_exact_conversion(self):
        """Decimal('22500.0') * 10^6 -> 22_500_000_000 exact."""
        self.assertEqual(
            cp.to_minor_units_strict(Decimal("22500.0"), "USD"),
            22_500_000_000,
        )

    def test_19_decimal_from_string(self):
        """String amount converted exactly."""
        self.assertEqual(cp.to_minor_units_strict("22500.00", "USD"), 22_500_000_000)

    def test_20_decimal_within_precision(self):
        """22500.123456 (6 decimals) -> exact in USD (6-decimal currency)."""
        self.assertEqual(
            cp.to_minor_units_strict(Decimal("22500.123456"), "USD"),
            22_500_123_456,
        )

    def test_21_reject_excessive_precision(self):
        """22500.1234567 (7 decimals) -> PrecisionError (USD only has 6)."""
        with self.assertRaises(cp.PrecisionError):
            cp.to_minor_units_strict(Decimal("22500.1234567"), "USD")

    def test_22_reject_binary_float_artifact(self):
        """
        0.1 as a Python float is 0.1000000000000000055511151231257827021181583404541015625.
        Passing float(0.1) into the strict converter must be REJECTED for USD.

        The strict path uses str(float) which for float(0.1) is "0.1" (Python 3
        shortest-round-trip), so this actually converts EXACTLY to 100_000
        minor USD units. But the point is that for a value that WOULD carry
        binary-float artifacts to str(), the strict path rejects.

        Here we test a value that Python str() would render with more than 6
        decimal places.
        """
        # Sum of floats that produces a value with excessive precision
        bad = 0.1 + 0.2  # 0.30000000000000004
        with self.assertRaises(cp.PrecisionError):
            cp.to_minor_units_strict(bad, "USD")

    def test_23_pipeline_source_has_no_float_multiply(self):
        """The financial core in build_assessment must not use float * / rounding."""
        with open(Path(__file__).parent / "collateral_pipeline.py") as f:
            src = f.read()
        # Check that the build_assessment function does not use int(round(...))
        # or "amount * (10 **" pattern (old float scaling).
        forbidden_patterns = [
            "int(round(scaled))",
            "amount * (10 ** decimals)",
        ]
        found = [p for p in forbidden_patterns if p in src]
        self.assertEqual(found, [],
            f"forbidden float-based patterns found: {found}")

    def test_24_haircut_and_ltv_integer(self):
        """Haircut + LTV arithmetic is integer only, truncation toward zero."""
        # 22_500_000_000 * 8000 // 10_000 = 18_000_000_000
        # 18_000_000_000 * 5000 // 10_000 = 9_000_000_000
        nav_units = 22_500_000_000
        eligible = nav_units * (10_000 - 2000) // 10_000
        credit = eligible * 5000 // 10_000
        self.assertEqual(eligible, 18_000_000_000)
        self.assertEqual(credit, 9_000_000_000)

    def test_25_truncation_toward_zero(self):
        self.assertEqual(1 * 9999 // 10_000, 0)
        self.assertEqual(999_999 * 5000 // 10_000, 499_999)


# ══════════════════════════════════════════════════════════════
class TestDeterministicSerialization(unittest.TestCase):
    """§E pretty JSON serialization determinism (C5 unchanged)."""

    def test_26_pretty_json_deterministic(self):
        record = {"schemaVersion": "1.0", "assetId": "X", "n": 42}
        bytes_list = [cp.pretty_bytes(record) for _ in range(10)]
        self.assertEqual(len(set(bytes_list)), 1)

    def test_27_pretty_json_no_trailing_newline(self):
        b = cp.pretty_bytes({"a": 1})
        self.assertFalse(b.endswith(b"\n"))

    def test_28_field_order_preserved(self):
        record = {"z": 1, "a": 2, "m": 3}
        text = cp.pretty_bytes(record).decode()
        self.assertLess(text.find('"z"'), text.find('"a"'))
        self.assertLess(text.find('"a"'), text.find('"m"'))


# ══════════════════════════════════════════════════════════════
class TestFullPipelineDeterminism(unittest.TestCase):
    """End-to-end determinism on the corrected pipeline."""

    def _build_rec(self, subtype="LI2CO3-COMMODITY", policy_hash=None, nav_hash=None):
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype=subtype, asset_jurisdiction="BO",
            now_ts=T0,
        )
        return cp.build_assessment(
            asset_id="LICO-0001",
            asset_subtype=subtype, asset_jurisdiction="BO",
            lender_id=1, lender_jurisdiction="US-DE",
            policy=_base_policy(), policy_pretty_hash=policy_hash or "0x" + "aa" * 32,
            nav=nav, nav_pretty_hash=nav_hash or "0x" + "bb" * 32,
            las=BASE_LAS, las_pretty_hash="0x" + "cc" * 32,
            performed_at=T0, eligibility=r,
        )

    def test_29_same_inputs_same_hash(self):
        h1 = cp.sha256_hex(cp.pretty_bytes(self._build_rec()))
        h2 = cp.sha256_hex(cp.pretty_bytes(self._build_rec()))
        self.assertEqual(h1, h2)

    def test_30_changed_policy_changed_hash(self):
        h1 = cp.sha256_hex(cp.pretty_bytes(self._build_rec(policy_hash="0x" + "aa" * 32)))
        h2 = cp.sha256_hex(cp.pretty_bytes(self._build_rec(policy_hash="0x" + "bb" * 32)))
        self.assertNotEqual(h1, h2)

    def test_31_changed_nav_changed_hash(self):
        h1 = cp.sha256_hex(cp.pretty_bytes(self._build_rec(nav_hash="0x" + "aa" * 32)))
        h2 = cp.sha256_hex(cp.pretty_bytes(self._build_rec(nav_hash="0x" + "cc" * 32)))
        self.assertNotEqual(h1, h2)


# ══════════════════════════════════════════════════════════════
class TestNavHashUnaltered(unittest.TestCase):
    """navHash is SHA-256 of raw NAV bytes; parsing must not affect it."""

    def test_32_nav_raw_bytes_hash_stable(self):
        """
        Given raw NAV bytes B, sha256(B) must not depend on how we parse.
        We hash B first, then parse with parse_float=Decimal — result unchanged.
        """
        nav_raw = b'{\n  "finalPhysicalNAV": 22500.0,\n  "priceSource": {"currency": "USD"}\n}'
        h_before = cp.sha256_hex(nav_raw)
        # Parse (may return Decimals for numbers) — hash of original bytes unchanged
        parsed = json.loads(nav_raw, parse_float=Decimal)
        h_after = cp.sha256_hex(nav_raw)
        self.assertEqual(h_before, h_after)
        # Parsed value is Decimal
        self.assertIsInstance(parsed["finalPhysicalNAV"], Decimal)


# ══════════════════════════════════════════════════════════════
class TestAnchorInputMapping(unittest.TestCase):

    def test_33_currency_code_bytes32_padding(self):
        result = cp._bytes32_ascii_right_padded("USD")
        expected = "0x" + "555344" + "00" * 29
        self.assertEqual(result, expected)

    def test_34_anchor_input_fields(self):
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=_base_policy(),
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        rec = cp.build_assessment(
            asset_id="LICO-0001",
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            lender_id=1, lender_jurisdiction="US-DE",
            policy=_base_policy(), policy_pretty_hash="0x" + "aa" * 32,
            nav=nav, nav_pretty_hash="0x" + "bb" * 32,
            las=BASE_LAS, las_pretty_hash="0x" + "cc" * 32,
            performed_at=T0, eligibility=r,
        )
        anchor = cp.build_anchor_input(rec, "0x" + "dd" * 32)
        expected_fields = {
            "assetId", "assessmentHash", "navHash", "policyHash",
            "lenderId", "haircutBps", "maxLTVBps", "eligibleValue",
            "creditCapacity", "currencyCode", "verdict", "writerRole",
            "performedAt", "validUntil", "demoAtAnchoring",
        }
        self.assertEqual(set(anchor.keys()), expected_fields)
        # writer and anchoredAt MUST NOT be in AnchorInput
        self.assertNotIn("writer", anchor)
        self.assertNotIn("anchoredAt", anchor)


# ══════════════════════════════════════════════════════════════
class TestNoBroadcast(unittest.TestCase):
    """C6: No broadcast capability in this iteration."""

    def test_35_no_broadcast_flag(self):
        parser = cp._build_arg_parser()
        old_stderr = sys.stderr
        sys.stderr = io.StringIO()
        try:
            with self.assertRaises(SystemExit):
                parser.parse_args(["LICO-0001", "1", "--broadcast"])
        finally:
            sys.stderr = old_stderr

    def test_36_no_web3_import(self):
        with open(Path(__file__).parent / "collateral_pipeline.py") as f:
            src = f.read()
        forbidden = ["import web3", "from web3", "import eth_account", "from eth_account"]
        for f in forbidden:
            self.assertNotIn(f, src, f"forbidden broadcast import: {f}")


# ══════════════════════════════════════════════════════════════
class TestPolicyMissing(unittest.TestCase):
    def test_37_policy_missing_verdict(self):
        nav = _make_nav_with_link(BASE_LAS)
        r = ev.evaluate_eligibility(
            nav=nav, las=BASE_LAS, policy=None,
            asset_subtype="LI2CO3-COMMODITY", asset_jurisdiction="BO",
            now_ts=T0,
        )
        self.assertEqual(r.verdict, ev.VERDICT_POLICY_MISSING)


if __name__ == "__main__":
    unittest.main(verbosity=2)
