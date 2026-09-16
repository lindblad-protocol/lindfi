#!/usr/bin/env python3
"""
Lindblad MVP-03A Collateral Assessment Pipeline
================================================

Deterministic off-chain pipeline that consumes Physical NAV + LAS
+ Lender Policy + Asset Metadata and produces a canonical Assessment
JSON with a protocol-relevant SHA-256 hash, plus a proposed
AnchorInput for CollateralPositionAnchor.

Design principles (post-correction pass):
- Asset-agnostic core: assetSubtype and assetJurisdiction come from
  upstream asset metadata; no assetId-prefix mapping anywhere.
- Financial core is float-free: NAV amount parsed as Decimal from
  raw JSON text (parse_float=Decimal), converted to integer minor
  units without float multiplication.
- Excessive-precision inputs are rejected deterministically.
- NAV raw bytes are never mutated: navHash = SHA-256(raw NAV bytes).
- Assessment JSON is deterministic pretty-serialized; hash =
  SHA-256(pretty Assessment bytes).
- Lender jurisdiction is NOT asset jurisdiction. Both are stored in
  the Assessment for audit, but only assetJurisdiction drives E6.
- Preview by default. No --broadcast flag. No web3/eth_account.

Usage:
    python3 collateral_pipeline.py LICO-0001 1
    python3 collateral_pipeline.py tGOLD-0001 1
    python3 collateral_pipeline.py LICO-0001 1 --performed-at 1789317549
    python3 collateral_pipeline.py LICO-0001 1 --no-rpc-checks
"""

from __future__ import annotations
import argparse
import hashlib
import json
import os
import sys
import time
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Optional

from collateral_policy_evaluator import (
    VERDICT_ELIGIBLE,
    VERDICT_INELIGIBLE,
    VERDICT_POLICY_MISSING,
    evaluate_eligibility,
    EligibilityResult,
)


# ── Constants ────────────────────────────────────────────────
SCHEMA_VERSION = "1.0"
RECORD_HASH_ALGORITHM = "SHA-256"

# Currency minor-unit decimals — matches MVP-02E convention.
CURRENCY_DECIMALS = {"USD": 6, "EUR": 6, "BOB": 6, "GBP": 6, "JPY": 6}
DEFAULT_CURRENCY_DECIMALS = 6

# Bp scale
BPS_SCALE = 10_000

# Default writer role (labels only)
DEFAULT_WRITER_ROLE = "PIPELINE-ANALYST"

# Deployed CPA/LR/LPR addresses on Arbitrum Sepolia (frozen at HEAD 9192f1a).
# Only used for advisory RPC cross-checks. Never in code paths that mutate
# on-chain state.
DEPLOYED_CONTRACTS = {
    "chainId": 421614,
    "lenderRegistry": "0xf55D941bb4FF692B8F0553fA2Fc0350452fA88F7",
    "lenderPolicyRegistry": "0xC33bDd53D53eBE675dDd165e3FD2f98227B36398",
    "collateralPositionAnchor": "0xB489376bB9f0455f917D82Cc806DEC51392051DA",
    "canonicalSafe": "0x87039DF20338A876FB3b4dbd787816D42eecbACa",
    "rpcUrl": "https://sepolia-rollup.arbitrum.io/rpc",
}

# Default input search paths (match MVP-02E convention).
DEFAULT_NAV_DIR = Path.home() / "Lindblad" / "04-lindfi" / "pipeline" / "out"
DEFAULT_LAS_DIR = Path.home() / "Lindblad" / "04-lindfi" / "pipeline" / "out"
DEFAULT_FIXTURE_DIR = Path(__file__).parent / "fixtures"

# Pretty serialization convention (SPEC §E, unchanged per C5).
PRETTY_KWARGS = dict(
    indent=2,
    ensure_ascii=False,
    sort_keys=False,
    separators=(",", ": "),
)


# ── Hashing (matches MVP-02E convention: 0x + lowercase hex) ─
def sha256_hex(b: bytes) -> str:
    return "0x" + hashlib.sha256(b).hexdigest()


def pretty_bytes(record: dict) -> bytes:
    """
    Deterministic pretty JSON serialization.
    The SHA-256 of these bytes is the protocol-relevant hash.

    Uses default=str for Decimal — Decimals are serialized as their
    exact textual representation (e.g. Decimal("22500.0") -> "22500.0").
    Assessment records constructed by this pipeline contain no Decimals
    (all numeric fields are int or str-of-Decimal); the default is
    defensive.
    """
    return json.dumps(record, default=str, **PRETTY_KWARGS).encode("utf-8")


def canonical_compact_bytes(record: dict) -> bytes:
    """
    Compact canonical serialization. DIAGNOSTIC ONLY.
    NEVER used as navHash, assessmentHash, or policyHash.
    NEVER placed in AnchorInput.
    """
    return json.dumps(
        record, default=str, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


# ── Errors ───────────────────────────────────────────────────
class PipelineError(Exception):
    """Structural / input failure (exit code 2)."""


class PrecisionError(PipelineError):
    """NAV amount has more precision than the currency supports."""


# ── I/O ──────────────────────────────────────────────────────
def _load_json_file(path: Path, parse_numbers_as_decimal: bool = False) -> tuple[Any, bytes]:
    """
    Load JSON file, return (parsed value, raw bytes).

    If parse_numbers_as_decimal=True, all JSON numeric literals are parsed
    as Decimal (using the exact textual representation from the file).
    This preserves precision beyond IEEE-754 float capability.
    """
    if not path.exists():
        raise PipelineError(f"file not found: {path}")
    try:
        raw = path.read_bytes()
        if parse_numbers_as_decimal:
            parsed = json.loads(raw, parse_float=Decimal, parse_int=int)
        else:
            parsed = json.loads(raw)
        return parsed, raw
    except json.JSONDecodeError as e:
        raise PipelineError(f"malformed JSON in {path}: {e}") from e
    except InvalidOperation as e:
        raise PipelineError(f"invalid numeric literal in {path}: {e}") from e


def find_latest_by_prefix(directory: Path, prefix: str) -> Optional[Path]:
    """Find the file matching prefix with the largest suffix (timestamp)."""
    if not directory.exists():
        return None
    candidates = sorted(directory.glob(f"{prefix}*.json"))
    return candidates[-1] if candidates else None


def load_nav_json(asset_id: str, nav_dir: Path) -> tuple[dict, bytes, Path]:
    path = find_latest_by_prefix(nav_dir, f"NAV-{asset_id}-")
    if path is None:
        raise PipelineError(
            f"no NAV-{asset_id}-* JSON found in {nav_dir}. "
            f"Run MVP-02E nav_pipeline.py first, or pass --nav-path <file>."
        )
    # Parse with parse_float=Decimal for exact numeric handling in the
    # financial core. Raw bytes are also returned so navHash is unaffected.
    parsed, raw = _load_json_file(path, parse_numbers_as_decimal=True)
    return parsed, raw, path


def load_las_json(asset_id: str, las_dir: Path) -> tuple[dict, bytes, Path]:
    path = find_latest_by_prefix(las_dir, f"LAS-{asset_id}-")
    if path is None:
        raise PipelineError(
            f"no LAS-{asset_id}-* JSON found in {las_dir}. "
            f"Run MVP-02C las_pipeline.py first, or pass --las-path <file>."
        )
    parsed, raw = _load_json_file(path)
    return parsed, raw, path


def load_policy_json(policy_path: Path) -> tuple[dict, bytes, Path]:
    if not policy_path.exists():
        raise PipelineError(f"policy file not found: {policy_path}")
    parsed, raw = _load_json_file(policy_path)
    return parsed, raw, policy_path


def load_asset_metadata(asset_id: str, path: Optional[Path]) -> tuple[dict, Optional[bytes], Optional[Path]]:
    """
    Load asset metadata (assetSubtype, assetJurisdiction).

    Attempts, in order:
      1. Explicit --asset-metadata path if provided.
      2. Default fixture: fixtures/asset-<assetId>.json.

    If none found, raises PipelineError. For MVP-03A, asset metadata
    is required — the pipeline is asset-agnostic, so upstream MUST
    provide these fields explicitly.
    """
    if path is None:
        path = DEFAULT_FIXTURE_DIR / f"asset-{asset_id}.json"
    if not path.exists():
        raise PipelineError(
            f"asset metadata not found: {path}. "
            f"The pipeline is asset-agnostic and requires an explicit "
            f"asset metadata file. Create fixtures/asset-{asset_id}.json "
            f"with {{assetId, assetSubtype, assetJurisdiction}} or pass "
            f"--asset-metadata <path>."
        )
    parsed, raw = _load_json_file(path)
    return parsed, raw, path


# ── Optional RPC advisory checks ─────────────────────────────
def optional_rpc_advisory(lender_id: int, verbose: bool = True) -> dict:
    """
    Best-effort read-only advisory checks against Arbitrum Sepolia.
    NEVER blocks the assessment. NEVER modifies on-chain state.
    Returns a dict of observations; empty on failure.
    """
    observations = {}
    try:
        import subprocess

        rpc = DEPLOYED_CONTRACTS["rpcUrl"]
        lr = DEPLOYED_CONTRACTS["lenderRegistry"]
        lpr = DEPLOYED_CONTRACTS["lenderPolicyRegistry"]
        cpa = DEPLOYED_CONTRACTS["collateralPositionAnchor"]

        def _cast_call(addr: str, sig: str, *args: str) -> str:
            cmd = ["cast", "call", addr, sig, *args, "--rpc-url", rpc]
            return subprocess.check_output(cmd, text=True, timeout=15).strip()

        observations["lr_governance"] = _cast_call(lr, "governance()(address)")
        observations["lpr_governance"] = _cast_call(lpr, "governance()(address)")
        observations["cpa_governance"] = _cast_call(cpa, "governance()(address)")
        observations["lpr_lenderRegistry"] = _cast_call(lpr, "lenderRegistry()(address)")
        observations["cpa_lenderRegistry"] = _cast_call(cpa, "lenderRegistry()(address)")
        observations["cpa_lenderPolicyRegistry"] = _cast_call(cpa, "lenderPolicyRegistry()(address)")
        observations["lender_exists"] = _cast_call(
            lr, "lenderExists(uint256)(bool)", str(lender_id)
        )
        observations["total_anchors"] = _cast_call(cpa, "totalAnchors()(uint256)")

    except Exception as e:  # noqa: BLE001
        if verbose:
            print(f"  [advisory rpc check skipped: {type(e).__name__}]", file=sys.stderr)
        observations["error"] = f"{type(e).__name__}: {e}"

    return observations


# ── Currency helpers ─────────────────────────────────────────
def currency_decimals(code: str) -> int:
    return CURRENCY_DECIMALS.get(code.upper(), DEFAULT_CURRENCY_DECIMALS)


def to_minor_units_strict(amount: Any, currency: str) -> int:
    """
    Convert amount to integer minor units for the given currency.

    Rules (per Jorge's C3 correction):
    - Input may be Decimal (preferred), int, or str.
    - If input is float, we convert via str() first (safe for well-behaved
      values like 22500.0 but still rejected if precision would be lost).
    - Result must be exactly representable in the currency's decimal
      precision; otherwise PrecisionError is raised.
    - No float multiplication in this function.
    - Truncation is EXPLICITLY forbidden; if the caller wants to truncate,
      they must do so before calling.
    """
    if amount is None:
        raise PipelineError("amount is None")
    if isinstance(amount, Decimal):
        d = amount
    elif isinstance(amount, int) and not isinstance(amount, bool):
        d = Decimal(amount)
    elif isinstance(amount, str):
        try:
            d = Decimal(amount)
        except InvalidOperation as e:
            raise PipelineError(f"invalid numeric string: {amount!r}: {e}") from e
    elif isinstance(amount, float):
        # str(float) uses Python's shortest-round-trip representation.
        # For "well-behaved" values like 22500.0 this is exact.
        # For values like 0.1, this preserves the source intent but
        # will be caught by the precision check if it exceeds currency decimals.
        try:
            d = Decimal(str(amount))
        except InvalidOperation as e:
            raise PipelineError(f"invalid float: {amount!r}: {e}") from e
    else:
        raise PipelineError(f"unsupported amount type: {type(amount).__name__}")

    decimals = currency_decimals(currency)
    scale_factor = Decimal(10) ** decimals
    scaled = d * scale_factor
    # Precision guard: scaled must be an integer
    if scaled != scaled.to_integral_value():
        raise PrecisionError(
            f"amount {d} exceeds {decimals}-decimal precision for {currency} "
            f"(scaled = {scaled}); pipeline requires exact conversion."
        )
    return int(scaled)


def display_amount(units: int, code: str) -> str:
    decimals = currency_decimals(code)
    whole, frac = divmod(units, 10 ** decimals)
    # Two-decimal display, matches MVP-02E format_money.
    frac_2 = frac // (10 ** (decimals - 2)) if decimals >= 2 else frac
    return f"{whole:,}.{frac_2:02d} {code}"


# ── Assessment construction ──────────────────────────────────
def build_assessment(
    *,
    asset_id: str,
    asset_subtype: str,
    asset_jurisdiction: str,
    lender_id: int,
    lender_jurisdiction: Optional[str],
    policy: dict,
    policy_pretty_hash: str,
    nav: dict,
    nav_pretty_hash: str,
    las: dict,
    las_pretty_hash: str,
    performed_at: int,
    eligibility: EligibilityResult,
) -> dict:
    """
    Construct the Assessment record in the frozen field order.

    Asset-agnostic: asset_subtype and asset_jurisdiction are provided
    by the caller, not derived from asset_id.
    """
    # ── Financial calculation (integer only, Decimal-based) ──
    currency = nav.get("priceSource", {}).get("currency", "USD")
    decimals = currency_decimals(currency)

    nav_amount_raw = nav.get("valuation", {}).get("finalPhysicalNAV", 0)
    nav_units = to_minor_units_strict(nav_amount_raw, currency)

    haircut_bps = int(policy.get("haircutBps", 0))
    max_ltv_bps = int(policy.get("maxLTVBps", 0))
    if not (0 <= haircut_bps <= BPS_SCALE):
        raise PipelineError(f"haircutBps out of range: {haircut_bps}")
    if not (0 <= max_ltv_bps <= BPS_SCALE):
        raise PipelineError(f"maxLTVBps out of range: {max_ltv_bps}")

    # Fixed order: (A * B) // BPS_SCALE. Never (A // BPS_SCALE) * B.
    eligible_value_units = nav_units * (BPS_SCALE - haircut_bps) // BPS_SCALE
    credit_capacity_units = eligible_value_units * max_ltv_bps // BPS_SCALE

    validity_seconds = int(policy.get("validitySeconds", 0))
    valid_until = performed_at + validity_seconds

    is_demo = "DEMO" in (nav.get("notice", "") or "").upper()

    assessment_id = f"ASMT-{asset_id}-{lender_id}-{performed_at}"

    # Source amount stored as string for exact audit representation.
    # Never a float in the Assessment JSON.
    source_amount_str = str(nav_amount_raw) if not isinstance(nav_amount_raw, Decimal) else str(nav_amount_raw)

    record = {
        "schemaVersion": SCHEMA_VERSION,
        "assessmentId": assessment_id,
        "assetId": asset_id,
        "assetSubtype": asset_subtype,
        "assetJurisdiction": asset_jurisdiction,
        "lenderId": lender_id,
        "lenderJurisdiction": lender_jurisdiction or "",
        "policyReference": {
            "policyHash": policy_pretty_hash,
            "haircutBps": haircut_bps,
            "maxLTVBps": max_ltv_bps,
            "acceptsDemoAssets": bool(policy.get("acceptsDemoAssets", False)),
            "validitySeconds": validity_seconds,
            "policyVersionLabel": policy.get("policyVersionLabel", "unlabeled"),
        },
        "lasReference": {
            "lasHash": las_pretty_hash,
            "status": las.get("status", "UNKNOWN"),
            "performedAt": las.get("performedAt", 0),
        },
        "navReference": {
            "navHash": nav_pretty_hash,
            "sourceAmount": source_amount_str,
            "currency": currency,
            "performedAt": nav.get("performedAt", 0),
        },
        "calculation": {
            "currencyDecimals": decimals,
            "navUnits": nav_units,
            "haircutBps": haircut_bps,
            "maxLTVBps": max_ltv_bps,
            "eligibleValueUnits": eligible_value_units,
            "creditCapacityUnits": credit_capacity_units,
            "eligibleValueDisplay": display_amount(eligible_value_units, currency),
            "creditCapacityDisplay": display_amount(credit_capacity_units, currency),
        },
        "eligibility": {
            "verdict": eligibility.verdict_label,
            "verdictCode": eligibility.verdict,
            "rulesApplied": eligibility.rules_applied,
            "rulesPassed": eligibility.rules_passed,
            "rulesFailed": eligibility.rules_failed,
            "firstFailReason": eligibility.first_fail_reason,
        },
        "writerRole": DEFAULT_WRITER_ROLE,
        "performedAt": performed_at,
        "validUntil": valid_until,
        "demoAtAnchoring": is_demo,
        "recordHashAlgorithm": RECORD_HASH_ALGORITHM,
        "notice": "DEMO / TESTNET - NO PHYSICAL BACKING" if is_demo else "TESTNET",
    }
    return record


# ── AnchorInput mapping ──────────────────────────────────────
def _keccak256_hex(text: str) -> str:
    """
    keccak256 (Ethereum, pre-NIST-SHA3). Cascades: cast -> pysha3 ->
    pycryptodome -> pure-Python fallback.
    """
    try:
        import subprocess
        out = subprocess.check_output(
            ["cast", "keccak", text], text=True, timeout=5
        ).strip().lower()
        return out
    except Exception:
        pass
    try:
        import sha3  # type: ignore
        k = sha3.keccak_256()
        k.update(text.encode("utf-8"))
        return "0x" + k.hexdigest()
    except Exception:
        pass
    try:
        from Crypto.Hash import keccak  # type: ignore
        k = keccak.new(digest_bits=256)
        k.update(text.encode("utf-8"))
        return "0x" + k.hexdigest()
    except Exception:
        pass
    return "0x" + _pure_python_keccak256(text.encode("utf-8")).hex()


def _pure_python_keccak256(data: bytes) -> bytes:
    """Pure-Python keccak-256. Deterministic. Matches Solidity."""
    RATE_BYTES = 136
    ROUNDS = 24
    RC = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    R = [
        [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
    ]
    MASK = (1 << 64) - 1

    def rotl(x, n):
        n %= 64
        return ((x << n) | (x >> (64 - n))) & MASK

    def keccak_f(state):
        for rnd in range(ROUNDS):
            C = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
            D = [C[(x - 1) % 5] ^ rotl(C[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    state[x][y] ^= D[x]
            B = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2 * x + 3 * y) % 5] = rotl(state[x][y], R[x][y])
            for x in range(5):
                for y in range(5):
                    state[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y]) & MASK
            state[0][0] ^= RC[rnd]
        return state

    padded = bytearray(data) + b"\x01"
    while len(padded) % RATE_BYTES != (RATE_BYTES - 1):
        padded.append(0x00)
    padded.append(0x80)

    state = [[0] * 5 for _ in range(5)]
    for block_start in range(0, len(padded), RATE_BYTES):
        block = padded[block_start:block_start + RATE_BYTES]
        for i in range(RATE_BYTES // 8):
            lane = int.from_bytes(block[i * 8:(i + 1) * 8], "little")
            state[i % 5][i // 5] ^= lane
        state = keccak_f(state)

    out = bytearray()
    for i in range(4):
        lane = state[i % 5][i // 5]
        out.extend(lane.to_bytes(8, "little"))
    return bytes(out[:32])


def _bytes32_ascii_right_padded(text: str) -> str:
    """Encode short ASCII string as bytes32 padded right with 0x00."""
    encoded = text.upper().encode("utf-8")
    if len(encoded) > 32:
        raise PipelineError(f"currency code too long for bytes32: {text}")
    padded = encoded + b"\x00" * (32 - len(encoded))
    return "0x" + padded.hex()


def build_anchor_input(record: dict, assessment_hash: str) -> dict:
    """
    Build the AnchorInput dict for CollateralPositionAnchor.anchorAssessment(...).
    """
    return {
        "assetId": _keccak256_hex(record["assetId"]),
        "assessmentHash": assessment_hash,
        "navHash": record["navReference"]["navHash"],
        "policyHash": record["policyReference"]["policyHash"],
        "lenderId": record["lenderId"],
        "haircutBps": record["policyReference"]["haircutBps"],
        "maxLTVBps": record["policyReference"]["maxLTVBps"],
        "eligibleValue": record["calculation"]["eligibleValueUnits"],
        "creditCapacity": record["calculation"]["creditCapacityUnits"],
        "currencyCode": _bytes32_ascii_right_padded(record["navReference"]["currency"]),
        "verdict": record["eligibility"]["verdictCode"],
        "writerRole": _keccak256_hex(record["writerRole"]),
        "performedAt": record["performedAt"],
        "validUntil": record["validUntil"],
        "demoAtAnchoring": record["demoAtAnchoring"],
    }


# ── CLI ──────────────────────────────────────────────────────
def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="collateral_pipeline",
        description="Lindblad MVP-03A deterministic collateral assessment pipeline.",
    )
    p.add_argument("asset_id", help="Asset identifier, e.g. LICO-0001 or tGOLD-0001")
    p.add_argument("lender_id", type=int, help="Lender identifier (positive integer)")
    p.add_argument(
        "--policy",
        type=Path,
        default=None,
        help="Path to lender policy JSON. Defaults to fixtures/policy-<lenderId>-demo-v1.json",
    )
    p.add_argument(
        "--asset-metadata",
        type=Path,
        default=None,
        help="Path to asset metadata JSON (assetSubtype, assetJurisdiction). "
        "Defaults to fixtures/asset-<assetId>.json",
    )
    p.add_argument("--nav-path", type=Path, default=None)
    p.add_argument("--las-path", type=Path, default=None)
    p.add_argument("--nav-dir", type=Path, default=DEFAULT_NAV_DIR)
    p.add_argument("--las-dir", type=Path, default=DEFAULT_LAS_DIR)
    p.add_argument(
        "--performed-at",
        type=int,
        default=None,
        help="Unix seconds; default = now",
    )
    p.add_argument(
        "--lender-info-json",
        type=Path,
        default=None,
        help="Optional lender info JSON (default: fixtures/lender-<id>-info.json)",
    )
    p.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).parent / "out",
        help="Directory to write Assessment JSON",
    )
    p.add_argument(
        "--no-rpc-checks",
        action="store_true",
        help="Skip advisory RPC checks (offline mode)",
    )
    p.add_argument(
        "--quiet",
        action="store_true",
        help="Print only the assessment output path and hash",
    )
    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = _build_arg_parser()
    args = parser.parse_args(argv)

    asset_id = args.asset_id
    lender_id = args.lender_id
    if lender_id <= 0:
        print(f"error: lender_id must be positive, got {lender_id}", file=sys.stderr)
        return 2

    now_ts = args.performed_at if args.performed_at is not None else int(time.time())

    # Resolve policy path
    if args.policy is None:
        policy_path = DEFAULT_FIXTURE_DIR / f"policy-{lender_id}-demo-v1.json"
    else:
        policy_path = args.policy

    if not args.quiet:
        print("=" * 68)
        print(f"  Lindblad MVP-03A Collateral Assessment")
        print(f"  Asset: {asset_id}    Lender: {lender_id}    now: {now_ts}")
        print("=" * 68)

    try:
        # Load NAV (with parse_float=Decimal for float-free financial core)
        if args.nav_path:
            nav, nav_raw = _load_json_file(args.nav_path, parse_numbers_as_decimal=True)
            nav_path = args.nav_path
        else:
            nav, nav_raw, nav_path = load_nav_json(asset_id, args.nav_dir)
        nav_pretty_hash = sha256_hex(nav_raw)  # Matches R2 convention

        # Load LAS
        if args.las_path:
            las, las_raw = _load_json_file(args.las_path)
            las_path = args.las_path
        else:
            las, las_raw, las_path = load_las_json(asset_id, args.las_dir)
        las_pretty_hash = sha256_hex(las_raw)

        # Load asset metadata (asset-agnostic pipeline REQUIRES this)
        asset_meta, asset_meta_raw, asset_meta_path = load_asset_metadata(
            asset_id, args.asset_metadata
        )
        asset_subtype = asset_meta.get("assetSubtype", "")
        asset_jurisdiction = asset_meta.get("assetJurisdiction", "")
        if not asset_subtype:
            raise PipelineError(f"asset metadata missing 'assetSubtype': {asset_meta_path}")
        if not asset_jurisdiction:
            raise PipelineError(f"asset metadata missing 'assetJurisdiction': {asset_meta_path}")

        # Load policy (may fail -> POLICY_MISSING verdict, not exit 2)
        policy: Optional[dict] = None
        policy_pretty_hash: Optional[str] = None
        policy_load_error: Optional[str] = None
        try:
            policy, policy_raw, policy_path = load_policy_json(policy_path)
            policy_pretty_hash = sha256_hex(policy_raw)
        except PipelineError as pe:
            policy_load_error = str(pe)

        # Lender info (jurisdiction is metadata only, does NOT drive E6)
        if args.lender_info_json:
            lender_info_path = args.lender_info_json
        else:
            lender_info_path = DEFAULT_FIXTURE_DIR / f"lender-{lender_id}-info.json"
        try:
            lender, _ = _load_json_file(lender_info_path)
        except PipelineError:
            lender = {"lenderId": lender_id, "jurisdiction": ""}
        lender_jurisdiction = lender.get("jurisdiction", "")

        # Advisory RPC checks (optional, non-blocking)
        rpc_observations: dict = {}
        if not args.no_rpc_checks and not args.quiet:
            print("[1] Advisory RPC checks (read-only, no state change):")
            rpc_observations = optional_rpc_advisory(lender_id, verbose=not args.quiet)
            for k, v in rpc_observations.items():
                if k != "error":
                    print(f"      {k}: {v}")

        if not args.quiet:
            print()
            print(f"[2] NAV loaded:            {nav_path}")
            print(f"      navHash:             {nav_pretty_hash}")
            print(f"[3] LAS loaded:            {las_path}")
            print(f"      lasHash:             {las_pretty_hash}")
            print(f"[4] Asset metadata:        {asset_meta_path}")
            print(f"      assetSubtype:        {asset_subtype}")
            print(f"      assetJurisdiction:   {asset_jurisdiction}")
            print(f"[5] Lender jurisdiction:   {lender_jurisdiction or '(unset)'}  (metadata only; not used for E6)")
            if policy_pretty_hash:
                print(f"[6] Policy loaded:         {policy_path}")
                print(f"      policyHash:          {policy_pretty_hash}")
            else:
                print(f"[6] Policy MISSING:        {policy_load_error}")

        # Pass computed LAS hash into NAV dict so evaluator can check E4.
        nav["__computedLasHash"] = las_pretty_hash

        # Evaluate eligibility (asset-agnostic; explicit subtype+jurisdiction)
        result = evaluate_eligibility(
            nav=nav,
            las=las,
            policy=policy,
            asset_subtype=asset_subtype,
            asset_jurisdiction=asset_jurisdiction,
            now_ts=now_ts,
        )

        # Build assessment record
        if policy is None:
            record = _build_policy_missing_record(
                asset_id=asset_id,
                asset_subtype=asset_subtype,
                asset_jurisdiction=asset_jurisdiction,
                lender_id=lender_id,
                lender_jurisdiction=lender_jurisdiction,
                nav=nav,
                nav_pretty_hash=nav_pretty_hash,
                las=las,
                las_pretty_hash=las_pretty_hash,
                performed_at=now_ts,
                policy_load_error=policy_load_error,
            )
        else:
            assert policy_pretty_hash is not None
            record = build_assessment(
                asset_id=asset_id,
                asset_subtype=asset_subtype,
                asset_jurisdiction=asset_jurisdiction,
                lender_id=lender_id,
                lender_jurisdiction=lender_jurisdiction,
                policy=policy,
                policy_pretty_hash=policy_pretty_hash,
                nav=nav,
                nav_pretty_hash=nav_pretty_hash,
                las=las,
                las_pretty_hash=las_pretty_hash,
                performed_at=now_ts,
                eligibility=result,
            )

        # Serialize + hash
        pretty = pretty_bytes(record)
        assessment_hash = sha256_hex(pretty)
        compact_diagnostic = sha256_hex(canonical_compact_bytes(record))

        # Write output
        out_dir = args.output_dir
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / f"ASMT-{asset_id}-{lender_id}-{now_ts}.json"
        out_path.write_bytes(pretty)

        # Build AnchorInput
        anchor_input = build_anchor_input(record, assessment_hash)

        # Report
        if args.quiet:
            print(str(out_path))
            print(assessment_hash)
            return 0

        print()
        print("[7] Eligibility result:")
        print(f"      verdict:              {record['eligibility']['verdict']} ({record['eligibility']['verdictCode']})")
        if record["eligibility"]["firstFailReason"]:
            print(f"      firstFailReason:      {record['eligibility']['firstFailReason']}")
        print(f"      rulesApplied:         {record['eligibility']['rulesApplied']}")
        print(f"      rulesPassed:          {record['eligibility']['rulesPassed']}")
        print(f"      rulesFailed:          {record['eligibility']['rulesFailed']}")

        if policy is not None:
            print()
            print("[8] Financial calculation (Decimal-exact, integer minor units):")
            calc = record["calculation"]
            print(f"      sourceAmount (str):   {record['navReference']['sourceAmount']}")
            print(f"      currencyDecimals:     {calc['currencyDecimals']}")
            print(f"      navUnits:             {calc['navUnits']}")
            print(f"      haircutBps:           {calc['haircutBps']}")
            print(f"      maxLTVBps:            {calc['maxLTVBps']}")
            print(f"      eligibleValueUnits:   {calc['eligibleValueUnits']}   ({calc['eligibleValueDisplay']})")
            print(f"      creditCapacityUnits:  {calc['creditCapacityUnits']}   ({calc['creditCapacityDisplay']})")

        print()
        print("[9] Assessment output:")
        print(f"      path:                 {out_path}")
        print(f"      assessmentHash:       {assessment_hash}")
        print(f"      (diagnostic compact): {compact_diagnostic}")
        print(f"      pretty bytes length:  {len(pretty)}")

        print()
        print("[10] Proposed AnchorInput (SAFE PREVIEW — NOT BROADCAST):")
        for k, v in anchor_input.items():
            print(f"      {k}: {v}")

        print()
        print("=" * 68)
        if record["eligibility"]["verdictCode"] == VERDICT_ELIGIBLE:
            print("  VERDICT: ELIGIBLE")
            print("  This preview is deterministic. No transaction was sent.")
        elif record["eligibility"]["verdictCode"] == VERDICT_INELIGIBLE:
            print(f"  VERDICT: INELIGIBLE  ({record['eligibility']['firstFailReason']})")
            print("  No transaction was sent.")
        else:
            print("  VERDICT: POLICY_MISSING")
            print("  No transaction was sent.")
        print("=" * 68)
        return 0

    except PipelineError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except Exception as e:  # noqa: BLE001
        print(f"unexpected error: {type(e).__name__}: {e}", file=sys.stderr)
        return 3


def _build_policy_missing_record(
    *,
    asset_id: str,
    asset_subtype: str,
    asset_jurisdiction: str,
    lender_id: int,
    lender_jurisdiction: Optional[str],
    nav: dict,
    nav_pretty_hash: str,
    las: dict,
    las_pretty_hash: str,
    performed_at: int,
    policy_load_error: Optional[str],
) -> dict:
    """POLICY_MISSING record: verdict=2, no policyReference substance, no calc."""
    currency = nav.get("priceSource", {}).get("currency", "USD")
    is_demo = "DEMO" in (nav.get("notice", "") or "").upper()
    nav_amount_raw = nav.get("valuation", {}).get("finalPhysicalNAV", 0)
    source_amount_str = str(nav_amount_raw)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "assessmentId": f"ASMT-{asset_id}-{lender_id}-{performed_at}",
        "assetId": asset_id,
        "assetSubtype": asset_subtype,
        "assetJurisdiction": asset_jurisdiction,
        "lenderId": lender_id,
        "lenderJurisdiction": lender_jurisdiction or "",
        "policyReference": {
            "policyHash": "0x" + "00" * 32,
            "haircutBps": 0,
            "maxLTVBps": 0,
            "acceptsDemoAssets": False,
            "validitySeconds": 0,
            "policyVersionLabel": "policy-missing",
        },
        "lasReference": {
            "lasHash": las_pretty_hash,
            "status": las.get("status", "UNKNOWN"),
            "performedAt": las.get("performedAt", 0),
        },
        "navReference": {
            "navHash": nav_pretty_hash,
            "sourceAmount": source_amount_str,
            "currency": currency,
            "performedAt": nav.get("performedAt", 0),
        },
        "calculation": {
            "currencyDecimals": currency_decimals(currency),
            "navUnits": 0,
            "haircutBps": 0,
            "maxLTVBps": 0,
            "eligibleValueUnits": 0,
            "creditCapacityUnits": 0,
            "eligibleValueDisplay": f"0.00 {currency}",
            "creditCapacityDisplay": f"0.00 {currency}",
        },
        "eligibility": {
            "verdict": "POLICY_MISSING",
            "verdictCode": VERDICT_POLICY_MISSING,
            "rulesApplied": [],
            "rulesPassed": [],
            "rulesFailed": [],
            "firstFailReason": None,
        },
        "writerRole": DEFAULT_WRITER_ROLE,
        "performedAt": performed_at,
        "validUntil": performed_at,
        "demoAtAnchoring": is_demo,
        "recordHashAlgorithm": RECORD_HASH_ALGORITHM,
        "notice": (
            "POLICY_MISSING — policy JSON could not be loaded. "
            + (policy_load_error or "")
        ).strip(),
    }


if __name__ == "__main__":
    sys.exit(main())
