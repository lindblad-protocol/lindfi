#!/usr/bin/env python3
"""
Lindblad MVP-03A Collateral Policy Evaluator
============================================

Evaluates eligibility rules E1-E8 for a collateral assessment.

Asset-agnostic by construction: the evaluator does not know or infer
what a lithium carbonate asset is, what gold is, etc. It receives
`asset_subtype` and `asset_jurisdiction` as explicit inputs from
upstream metadata (NAV or DEMO asset adapter) and compares them
against the lender's policy allowlists.

This module is pure and deterministic:
- No I/O beyond reading its input dicts
- No RPC calls
- No time-dependent behavior beyond the `now` argument passed in
- No random numbers, no discretionary scoring
- No hardcoded asset-type mappings (per Jorge's C1 correction)
- Same inputs -> same output

Rules are gate-only. There is no credit judgment. The verdict is
purely "does this asset satisfy the frozen MVP-03A gate conditions
against this lender's policy at this timestamp?"

Verdict encoding matches CollateralPositionAnchor:
    0 = ELIGIBLE
    1 = INELIGIBLE
    2 = POLICY_MISSING
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional


# ── Verdict constants (match CPA on-chain encoding) ──────────
VERDICT_ELIGIBLE = 0
VERDICT_INELIGIBLE = 1
VERDICT_POLICY_MISSING = 2


# ── Rule identifiers ─────────────────────────────────────────
RULE_LAS_VERIFIED = "E1"
RULE_LAS_FRESHNESS = "E2"
RULE_NAV_FRESHNESS = "E3"
RULE_LAS_NAV_LINK = "E4"
RULE_CURRENCY_ALLOWED = "E5"
RULE_ASSET_JURISDICTION_ALLOWED = "E6"
RULE_DEMO_ACCEPTANCE = "E7"
RULE_ASSET_SUBTYPE_ALLOWED = "E8"

ALL_RULES = [
    RULE_LAS_VERIFIED,
    RULE_LAS_FRESHNESS,
    RULE_NAV_FRESHNESS,
    RULE_LAS_NAV_LINK,
    RULE_CURRENCY_ALLOWED,
    RULE_ASSET_JURISDICTION_ALLOWED,
    RULE_DEMO_ACCEPTANCE,
    RULE_ASSET_SUBTYPE_ALLOWED,
]


# ── Reason codes (canonical strings for firstFailReason) ─────
REASON_LAS_NOT_VERIFIED = "las-not-verified"
REASON_LAS_STALE = "las-stale"
REASON_NAV_STALE = "nav-stale"
REASON_NAV_LAS_MISMATCH = "nav-las-mismatch"
REASON_CURRENCY_NOT_ALLOWED = "currency-not-allowed"
REASON_ASSET_JURISDICTION_NOT_ALLOWED = "asset-jurisdiction-not-allowed"
REASON_DEMO_ASSET_REJECTED = "demo-asset-rejected"
REASON_ASSET_SUBTYPE_NOT_ALLOWED = "asset-subtype-not-allowed"


@dataclass
class EligibilityResult:
    verdict: int
    verdict_label: str
    rules_applied: list[str] = field(default_factory=list)
    rules_passed: list[str] = field(default_factory=list)
    rules_failed: list[str] = field(default_factory=list)
    first_fail_reason: Optional[str] = None
    first_fail_rule: Optional[str] = None
    diagnostic: dict = field(default_factory=dict)


def _label(verdict: int) -> str:
    if verdict == VERDICT_ELIGIBLE:
        return "ELIGIBLE"
    if verdict == VERDICT_INELIGIBLE:
        return "INELIGIBLE"
    if verdict == VERDICT_POLICY_MISSING:
        return "POLICY_MISSING"
    return "UNKNOWN"


def evaluate_eligibility(
    *,
    nav: dict,
    las: dict,
    policy: Optional[dict],
    asset_subtype: str,
    asset_jurisdiction: str,
    now_ts: int,
) -> EligibilityResult:
    """
    Evaluate rules E1-E8 in strict order. First failure short-circuits.

    Asset-agnostic: `asset_subtype` and `asset_jurisdiction` are provided
    by upstream (NAV/LAS metadata or DEMO adapter). The evaluator does NOT
    derive them from `assetId` or any other identity field.

    Note: `lender.jurisdiction` is NOT used for eligibility. Asset
    jurisdiction and lender jurisdiction are different dimensions.

    Arguments (all keyword-only for callsite clarity):
        nav:                 loaded NAV JSON (dict)
        las:                 loaded LAS JSON (dict)
        policy:              loaded lender policy JSON (dict) or None
        asset_subtype:       category string from upstream (opaque to evaluator)
        asset_jurisdiction:  jurisdiction string from upstream (opaque to evaluator)
        now_ts:              integer Unix seconds — the assessment anchor

    Returns:
        EligibilityResult with verdict in {ELIGIBLE, INELIGIBLE, POLICY_MISSING}
    """

    # POLICY_MISSING short-circuit
    if policy is None:
        return EligibilityResult(
            verdict=VERDICT_POLICY_MISSING,
            verdict_label=_label(VERDICT_POLICY_MISSING),
            rules_applied=[],
            rules_passed=[],
            rules_failed=[],
            first_fail_reason=None,
            first_fail_rule=None,
            diagnostic={"note": "no policy JSON was loadable"},
        )

    applied: list[str] = []
    passed: list[str] = []
    failed: list[str] = []
    diagnostic: dict = {}

    def _fail(rule: str, reason: str, extra: Optional[dict] = None) -> EligibilityResult:
        applied.append(rule)
        failed.append(rule)
        if extra:
            diagnostic.update(extra)
        return EligibilityResult(
            verdict=VERDICT_INELIGIBLE,
            verdict_label=_label(VERDICT_INELIGIBLE),
            rules_applied=applied,
            rules_passed=passed,
            rules_failed=failed,
            first_fail_reason=reason,
            first_fail_rule=rule,
            diagnostic=diagnostic,
        )

    def _ok(rule: str, extra: Optional[dict] = None) -> None:
        applied.append(rule)
        passed.append(rule)
        if extra:
            diagnostic.update(extra)

    # ── E1: LAS.status == "VERIFIED" ─────────────────────────
    las_status = las.get("status")
    if las_status != "VERIFIED":
        return _fail(
            RULE_LAS_VERIFIED,
            REASON_LAS_NOT_VERIFIED,
            {"lasStatus": las_status},
        )
    _ok(RULE_LAS_VERIFIED, {"lasStatus": las_status})

    # ── E2: LAS freshness ────────────────────────────────────
    las_max_age = policy.get("lasMaxAgeSeconds")
    las_performed_at = las.get("performedAt")
    if not isinstance(las_max_age, int) or not isinstance(las_performed_at, int):
        return _fail(
            RULE_LAS_FRESHNESS,
            REASON_LAS_STALE,
            {"reason": "missing_or_invalid_fields"},
        )
    las_age = now_ts - las_performed_at
    if las_age > las_max_age:
        return _fail(
            RULE_LAS_FRESHNESS,
            REASON_LAS_STALE,
            {"lasAgeSeconds": las_age, "lasMaxAgeSeconds": las_max_age},
        )
    _ok(RULE_LAS_FRESHNESS, {"lasAgeSeconds": las_age})

    # ── E3: NAV freshness ────────────────────────────────────
    nav_max_age = policy.get("navMaxAgeSeconds")
    nav_performed_at = nav.get("performedAt")
    if not isinstance(nav_max_age, int) or not isinstance(nav_performed_at, int):
        return _fail(
            RULE_NAV_FRESHNESS,
            REASON_NAV_STALE,
            {"reason": "missing_or_invalid_fields"},
        )
    nav_age = now_ts - nav_performed_at
    if nav_age > nav_max_age:
        return _fail(
            RULE_NAV_FRESHNESS,
            REASON_NAV_STALE,
            {"navAgeSeconds": nav_age, "navMaxAgeSeconds": nav_max_age},
        )
    _ok(RULE_NAV_FRESHNESS, {"navAgeSeconds": nav_age})

    # ── E4: NAV.lasReference.lasHash matches published LAS hash ──
    nav_las_hash_declared = nav.get("lasReference", {}).get("lasHash")
    las_hash_computed = nav.get("__computedLasHash")
    if not nav_las_hash_declared or not las_hash_computed:
        return _fail(
            RULE_LAS_NAV_LINK,
            REASON_NAV_LAS_MISMATCH,
            {"reason": "missing_hash_input"},
        )
    if nav_las_hash_declared.lower() != las_hash_computed.lower():
        return _fail(
            RULE_LAS_NAV_LINK,
            REASON_NAV_LAS_MISMATCH,
            {
                "navDeclaredLasHash": nav_las_hash_declared,
                "computedLasHash": las_hash_computed,
            },
        )
    _ok(RULE_LAS_NAV_LINK)

    # ── E5: Currency allowed ─────────────────────────────────
    currency = nav.get("priceSource", {}).get("currency")
    allowed_currencies = policy.get("allowedCurrencies")
    if not isinstance(allowed_currencies, list) or not currency:
        return _fail(
            RULE_CURRENCY_ALLOWED,
            REASON_CURRENCY_NOT_ALLOWED,
            {"reason": "missing_or_invalid_fields"},
        )
    if currency not in allowed_currencies:
        return _fail(
            RULE_CURRENCY_ALLOWED,
            REASON_CURRENCY_NOT_ALLOWED,
            {"currency": currency, "allowedCurrencies": allowed_currencies},
        )
    _ok(RULE_CURRENCY_ALLOWED, {"currency": currency})

    # ── E6: ASSET jurisdiction allowed ───────────────────────
    # NOT lender jurisdiction. Asset jurisdiction is a separate dimension.
    allowed_jurisdictions = policy.get("allowedJurisdictions")
    if not isinstance(allowed_jurisdictions, list) or not asset_jurisdiction:
        return _fail(
            RULE_ASSET_JURISDICTION_ALLOWED,
            REASON_ASSET_JURISDICTION_NOT_ALLOWED,
            {"reason": "missing_or_invalid_fields"},
        )
    if asset_jurisdiction not in allowed_jurisdictions:
        return _fail(
            RULE_ASSET_JURISDICTION_ALLOWED,
            REASON_ASSET_JURISDICTION_NOT_ALLOWED,
            {
                "assetJurisdiction": asset_jurisdiction,
                "allowedJurisdictions": allowed_jurisdictions,
            },
        )
    _ok(RULE_ASSET_JURISDICTION_ALLOWED, {"assetJurisdiction": asset_jurisdiction})

    # ── E7: Demo acceptance ──────────────────────────────────
    accepts_demo = bool(policy.get("acceptsDemoAssets", False))
    nav_notice = nav.get("notice", "") or ""
    is_demo_asset = "DEMO" in nav_notice.upper()
    if is_demo_asset and not accepts_demo:
        return _fail(
            RULE_DEMO_ACCEPTANCE,
            REASON_DEMO_ASSET_REJECTED,
            {"isDemoAsset": True, "policyAcceptsDemo": False},
        )
    _ok(RULE_DEMO_ACCEPTANCE, {"isDemoAsset": is_demo_asset, "policyAcceptsDemo": accepts_demo})

    # ── E8: Asset subtype allowed ────────────────────────────
    # Subtype comes from upstream, NOT derived from assetId prefix.
    allowed_subtypes = policy.get("allowedSubtypes")
    if not isinstance(allowed_subtypes, list) or not asset_subtype:
        return _fail(
            RULE_ASSET_SUBTYPE_ALLOWED,
            REASON_ASSET_SUBTYPE_NOT_ALLOWED,
            {"reason": "missing_or_invalid_fields"},
        )
    if asset_subtype not in allowed_subtypes:
        return _fail(
            RULE_ASSET_SUBTYPE_ALLOWED,
            REASON_ASSET_SUBTYPE_NOT_ALLOWED,
            {"assetSubtype": asset_subtype, "allowedSubtypes": allowed_subtypes},
        )
    _ok(RULE_ASSET_SUBTYPE_ALLOWED, {"assetSubtype": asset_subtype})

    # All 8 rules PASS -> ELIGIBLE
    return EligibilityResult(
        verdict=VERDICT_ELIGIBLE,
        verdict_label=_label(VERDICT_ELIGIBLE),
        rules_applied=applied,
        rules_passed=passed,
        rules_failed=failed,
        first_fail_reason=None,
        first_fail_rule=None,
        diagnostic=diagnostic,
    )
