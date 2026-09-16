# Lindblad MVP-03A Collateral Assessment Pipeline

Off-chain deterministic pipeline that consumes a Physical NAV + LAS
+ Lender Policy + Asset Metadata and produces a canonical Assessment
JSON with a protocol-relevant SHA-256 hash, plus a proposed
`AnchorInput` for `CollateralPositionAnchor.anchorAssessment(...)`.

**This iteration is preview-only.** No `--broadcast` flag. Structurally
incapable of transacting.

## Design principles

- **Asset-agnostic core.** The evaluator does not know or infer what
  a lithium carbonate asset is, what gold is, etc. `assetSubtype` and
  `assetJurisdiction` are supplied by upstream metadata files. To
  process a new asset kind, add its metadata fixture; the pipeline
  logic does not change.
- **Float-free financial arithmetic.** NAV amounts are parsed as
  `Decimal` from the exact JSON textual representation. Conversion to
  integer minor units is exact and rejects excessive precision as a
  hard error. All subsequent arithmetic is integer.
- **NAV raw bytes are inviolable.** `navHash` is SHA-256 of the raw
  NAV bytes, computed before any parsing. Parsing never affects the
  hash.
- **Jurisdiction distinction.** Lender jurisdiction and asset
  jurisdiction are separate dimensions. Only asset jurisdiction drives
  the E6 eligibility rule. Lender jurisdiction is metadata for audit.

## Files

```
pipeline/
├── collateral_pipeline.py               # CLI + assessment construction
├── collateral_policy_evaluator.py       # E1-E8 rules (pure, asset-agnostic)
├── test_collateral_pipeline.py          # 37 deterministic tests
├── fixtures/
│   ├── asset-LICO-0001.json             # asset metadata (subtype + jurisdiction)
│   ├── asset-tGOLD-0001.json            # asset metadata for the demo gold asset
│   ├── policy-1-demo-v1.json            # DEMO lender policy
│   └── lender-1-info.json               # lender metadata (jurisdiction, notice)
└── out/                                 # ASMT-*.json outputs (generated)
```

## Usage

```bash
# LICO-0001 preview (reads real MVP-02E NAV/LAS if present in default paths)
python3 collateral_pipeline.py LICO-0001 1

# tGOLD-0001 preview (proves asset-agnostic design)
python3 collateral_pipeline.py tGOLD-0001 1

# Offline mode (no advisory RPC checks)
python3 collateral_pipeline.py LICO-0001 1 --no-rpc-checks

# Explicit paths
python3 collateral_pipeline.py LICO-0001 1 \
    --nav-path /path/to/NAV-LICO-0001-*.json \
    --las-path /path/to/LAS-LICO-0001-*.json \
    --policy fixtures/policy-1-demo-v1.json \
    --asset-metadata fixtures/asset-LICO-0001.json \
    --performed-at 1789317549
```

Default input search paths:
- NAV: `~/Lindblad/04-lindfi/pipeline/out/NAV-<assetId>-*.json`
- LAS: `~/Lindblad/04-lindfi/pipeline/out/LAS-<assetId>-*.json`
- Policy: `fixtures/policy-<lenderId>-demo-v1.json`
- Asset metadata: `fixtures/asset-<assetId>.json`
- Lender info: `fixtures/lender-<lenderId>-info.json`

Output goes to `pipeline/out/ASMT-<assetId>-<lenderId>-<performedAt>.json`.

## Eligibility rules (frozen for MVP-03A)

Applied in strict order. First failure short-circuits to `INELIGIBLE`.

| # | Rule | Data source |
|---|---|---|
| E1 | `LAS.status == "VERIFIED"` | LAS |
| E2 | `LAS` freshness against `policy.lasMaxAgeSeconds` | LAS + policy |
| E3 | `NAV` freshness against `policy.navMaxAgeSeconds` | NAV + policy |
| E4 | `NAV.lasReference.lasHash == SHA-256(raw LAS bytes)` | NAV + LAS |
| E5 | Currency in `policy.allowedCurrencies` | NAV + policy |
| E6 | `assetJurisdiction` in `policy.allowedJurisdictions` | asset metadata + policy |
| E7 | DEMO acceptance | NAV + policy |
| E8 | `assetSubtype` in `policy.allowedSubtypes` | asset metadata + policy |

**E6 uses asset jurisdiction, NOT lender jurisdiction.** The lender's
own jurisdiction is separate metadata that does not drive eligibility.

**E8 uses asset subtype from explicit metadata, NOT derived from
`assetId` prefix.** The evaluator does not know that "LICO" means
lithium carbonate or that "tGOLD" means gold — that mapping lives in
the asset metadata file.

## Tests

```bash
python3 -m unittest test_collateral_pipeline
```

Expected: **37 tests PASS**.

Coverage includes:
- E1-E8 behavior with asset-agnostic inputs
- Explicit `asset_subtype` and `asset_jurisdiction`
- Lender jurisdiction != asset jurisdiction (both pass and fail cases)
- LICO happy path
- tGOLD happy path through the same engine
- Structural verification that no asset-prefix mapping exists in source
- Structural verification that the evaluator no longer accepts a `lender=` param
- Exact `Decimal` → minor-unit conversion
- Excessive precision rejection (`PrecisionError`)
- Binary-float artifact rejection (e.g. `0.1 + 0.2`)
- Integer haircut / max LTV / truncation
- Deterministic pretty JSON serialization
- Deterministic `assessmentHash`
- `navHash` remains hash of raw NAV bytes (unchanged by parsing)
- `AnchorInput` field mapping
- No `--broadcast` capability, no `web3`/`eth_account` imports

## Preview output structure

```json
{
  "schemaVersion": "1.0",
  "assessmentId": "ASMT-LICO-0001-1-1789317549",
  "assetId": "LICO-0001",
  "assetSubtype": "LI2CO3-COMMODITY",
  "assetJurisdiction": "BO",
  "lenderId": 1,
  "lenderJurisdiction": "US-DE",
  ...
  "navReference": {
    "navHash": "0x...",
    "sourceAmount": "22500.0",
    "currency": "USD",
    ...
  },
  "calculation": {
    "currencyDecimals": 6,
    "navUnits": 22500000000,
    "haircutBps": 2000,
    "maxLTVBps": 5000,
    "eligibleValueUnits": 18000000000,
    "creditCapacityUnits": 9000000000,
    "eligibleValueDisplay": "18,000.00 USD",
    "creditCapacityDisplay": "9,000.00 USD"
  },
  "eligibility": {
    "verdict": "ELIGIBLE",
    "verdictCode": 0,
    ...
  },
  ...
}
```

## What this pipeline does NOT do

- Broadcast transactions (no `--broadcast` flag)
- Modify the frozen MVP-02E NAV production system
- Modify deployed contracts (`LenderRegistry`, `LenderPolicyRegistry`, `CollateralPositionAnchor`)
- Register lenders on-chain
- Publish policies on-chain
- Call `anchorAssessment()`
- Import `web3` or `eth_account`
- Require any private key
- Access the internet outside of optional read-only `cast call` advisory checks

## Related documents

- `docs/LINDFI_COLLATERAL_PIPELINE_IMPLEMENTATION_SPEC.md` — full spec
- `docs/MVP03A_ONCHAIN_DEPLOYMENT_COMPLETE.md` — deployed contract addresses
- `docs/LINDBLAD_NODE_OPERATIONS_HANDBOOK.md` — operational context
