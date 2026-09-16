# LINDFI MVP-03B — First Live Collateral Assessment Spec

**Status:** 🔒 **PROTOCOL SPEC: FROZEN** (September 16, 2026)
**UI implementation (B4):** PENDING REPOSITORY AUDIT — outside the frozen scope
**Date:** September 16, 2026
**Audited baseline:** `lindblad-protocol/lindfi` @ `b88f061b6228259a842071f5e76c3589bb3775f7`
**Supersedes:** all previous MVP-03B drafts. This revision closes B5/B6/B7 and BLK-A/B/C and freezes the protocol portion. The canonical NAV/LAS inputs were verified by Jorge on his Mac.

**Frozen scope:** the protocol definitions in this document are frozen: §1–§3, the §4 transaction structure and rules, §6 hashing/identifiers, §8 invariants. Per-run values are NOT frozen constants: `performedAt`, `assessmentHash`, `eligibleValue`, `creditCapacity`, `validUntil`, and the integer `effectiveFrom`/`effectiveUntil` derived from them. They become canonical only when produced by the §4 Tx 3 pinned run at the frozen `performedAt`. `<LENDER_SIGNER_ADDRESS>` remains a placeholder.

**Sources of truth (precedence):**
1. `contracts/src/LenderRegistry.sol` at `b88f061` (deployed to Arbitrum Sepolia at `0xf55D941bb4FF692B8F0553fA2Fc0350452fA88F7`)
2. `contracts/src/LenderPolicyRegistry.sol` at `b88f061` (deployed at `0xC33bDd53D53eBE675dDd165e3FD2f98227B36398`)
3. `contracts/src/CollateralPositionAnchor.sol` at `b88f061` (deployed at `0xB489376bB9f0455f917D82Cc806DEC51392051DA`)
4. `LINDFI_MVP03A_DESIGN.md` (frozen; not in the repo and not re-audited in this pass)
5. `LINDFI_MVP03A_GOVERNANCE_AMENDMENT_01.md` (frozen; not in the repo and not re-audited in this pass)
6. MVP-03A pipeline (`pipeline/collateral_pipeline.py`, `pipeline/collateral_policy_evaluator.py` at `b88f061`), the off-chain assessment producer

Contract source is unchanged since deployment source commit `9adebb5`. Verified with `git diff --stat 9adebb5 b88f061 -- contracts` (empty).

**Composability invariants:**
- **P1 asset-agnostic.** Nothing in the engine hardcodes LI2CO3, GOLD or any subtype. `LICO-0001` and `tGOLD-0001` are demonstration assets only. The architecture is not limited to lithium or gold. Future LAS-verified assets may include iron, copper, silver, energy and other physical asset classes.
  - Future LAS-verified asset classes may include `IRON-COMMODITY`, `COPPER-COMMODITY`, `SILVER-COMMODITY`, energy and other physical assets.
  - Adding a new asset class requires only configuration and policy (asset metadata with `assetSubtype`/`assetJurisdiction`, a policy listing the subtype, an LPR publication under its `assetClass`) plus upstream LAS/NAV support.
  - It never requires modifying the generic LindFi collateral engine.
  - Audit at `b88f061`: asset names appear only in usage examples, CLI help text and a docstring, never in executable logic. Enforced by pipeline tests 13–17.
- **P2 financing-instrument-agnostic.** CPA remains the collateral primitive. No loan, credit facility, escrow, USDC/USDT settlement, repayment, trade finance, inventory finance or DeFi adapter is implemented in MVP-03B.

---

## Section 0 — Changes vs previous draft

| # | Previous draft said | Source at `b88f061` shows | Action |
|---|---|---|---|
| C-1 | §6: hash is "sha256 OR keccak256"; "the pipeline currently emits keccak256 for on-chain hashes, which is what LPR and CPA compare against" | navHash, policyHash and assessmentHash are **SHA-256**. keccak256 is used only for bytes32 identifiers. LPR and CPA **do not compare** any hash; they store what they receive. | Ambiguity removed (§6) |
| C-2 | §4 Tx 2: policyHash is the "frozen pretty-JSON hash" of the policy file. §6: browser verification re-serializes with `json.dumps(indent=2, …)` | policyHash = SHA-256 of the **raw file bytes**. Value `0xc147…bae2` is correct. Re-serializing the policy gives `0x58de…9aef`, which would **fail** browser verification. | Wording and verification recipe corrected (§6.2) |
| C-3 | §3.6: `eligibleValue`/`creditCapacity` "18-decimal-scaled" | Pipeline scale is **10⁶** (`CURRENCY_DECIMALS` = 6). Reading them as 18 decimals is off by 10¹². | Corrected (§3.7) |
| C-4 | §3.6: struct PENDING; `verdict` "uint8 or enum Verdict" | Struct extracted verbatim; `verdict` is `uint8` | B7 closed (§3.6) |
| C-5 | §3.1: `anchorAssessment` at line 284 | Line 278 | Fixed |
| C-6 | §2.6: B6 open; §9 step 3: "single-subtype version" of the policy | Jorge's decision: no split. Publish `keccak256("LI2CO3-COMMODITY")` only. | B6 closed (§2.6, §9) |
| C-7 | §5 B5: signer "largely ceremonial"; Tx 2 caller Safe OR signer | Jorge's decision: fresh EOA = operational lender identity for LPR | B5 closed; Tx 2 caller = signer (§4) |
| C-8 | §2.7: `effectiveFrom = <block.timestamp at publication> - 3600` | Calldata cannot reference `block.timestamp`; the value must be a concrete integer fixed before signing | Rule frozen: `effectiveFrom = performedAt − 3600`, `effectiveUntil = effectiveFrom + 31536000` (§2.7). Integers derived only after `performedAt` is frozen. |
| C-9 | §4: postconditions assume `lenderId = 1`, `policyId = 1`, `anchorId = 1` | True only if the deployed registries are empty; not observable from the sandbox | Read-only pre-checks with a STOP rule added (§4.0) |
| C-10 | §4 Tx 3: `navHash = 0x5fc89309…` | **The draft was correct.** Jorge verified locally: `NAV-LICO-0001-1789231149.json` → `0x5fc89309…2bf3d`. The `0x9c128101…` value the previous revision attributed to the NAV is the **LAS** artifact hash (`LAS-LICO-0001-1789094130.json`). That attribution came from a transcript summary and was wrong. | BLK-A closed; canonical inputs pinned (§6.5) |
| C-11 | §7: tests PENDING (expected counts) | Both suites run in sandbox | Verified counts (§7) |

---

## Section 1 — B1 RESOLUTION (LenderRegistry, from real source)

**Correction carried from previous draft:** the invented lifecycle states (`REGISTERED`, `KYB_VERIFIED`, `ACTIVE`) and fields (`notice`, `isDemo`) do not exist. They are removed.

### 1.1 Real types (verbatim from source)

```solidity
enum KybStatus {
    NONE,      // 0 — sentinel, not accepted by register/update
    PENDING,   // 1
    VERIFIED,  // 2
    REJECTED,  // 3
    EXPIRED    // 4
}

struct Lender {
    uint256 lenderId;
    string  name;
    string  jurisdiction;
    KybStatus kybStatus;
    address signerAddress;
    bool    active;
    uint256 addedAt;
}
```

### 1.2 Real `registerLender` ABI

```solidity
function registerLender(
    string calldata name,
    string calldata jurisdiction,
    KybStatus kybStatus,
    address signerAddress
) external onlyGovernance returns (uint256 lenderId);
```

ABI signature: `registerLender(string,string,uint8,address)` → selector `0x97f75d02` (compiled `methodIdentifiers`, cross-checked with `cast sig`).

### 1.3 Authorization

`onlyGovernance` (`msg.sender == governance`). On this deployment `governance == 0x87039DF20338A876FB3b4dbd787816D42eecbACa` (canonical Safe, 2-of-3).

### 1.4 Rejects (from source)

- `signerAddress == address(0)` → `ZeroSignerAddress()`
- `bytes(name).length == 0` → `EmptyName()`
- `bytes(jurisdiction).length == 0` → `EmptyJurisdiction()`
- `kybStatus == KybStatus.NONE` → `InvalidKybStatus()`
- `signerToLender[signerAddress] != 0` → `SignerAlreadyAssigned(signerAddress, existingLenderId)`

### 1.5 State on success

- `_nextLenderId` increments monotonically (starts at 1).
- `_lenders[lenderId]` is populated with `active = true` and `addedAt = block.timestamp`.
- `signerToLender[signerAddress] = lenderId`. The reservation persists across deactivation.
- `LenderRegistered` is emitted.

### 1.6 Exact transition to `active == true AND kybStatus == VERIFIED`

It takes a single transaction: `registerLender(..., KybStatus.VERIFIED, ...)`. There is no PENDING→VERIFIED workflow. Later status changes go through `updateLender` (also `onlyGovernance`, rejects `NONE`).

**Acknowledgment required (P-6):** `VERIFIED` for "Lindblad Demo Lender" is a testnet demo attestation, not the result of a real KYB process.

---

## Section 2 — B2 RESOLUTION (LenderPolicyRegistry, from real source)

LPR takes a **single `bytes32 assetClass`** per publication. The policy JSON's `allowedSubtypes` array is not mapped on-chain.

### 2.1 Real `publishPolicy` ABI

```solidity
function publishPolicy(
    uint256 lenderId,
    bytes32 assetClass,
    bytes32 policyHash,
    uint256 effectiveFrom,
    uint256 effectiveUntil
) external returns (uint256 policyId);
```

ABI signature: `publishPolicy(uint256,bytes32,bytes32,uint256,uint256)` → selector `0x1559bd80`.

### 2.2 Real authorization

The caller must be `governance` OR `LR.getLender(lenderId).signerAddress`. **Regardless of path:** the lender must exist, be active and have `kybStatus == VERIFIED`. Governance does NOT bypass this gate. Tx 1 is therefore a hard precondition for Tx 2.

### 2.3 Real frozen validations

- `assetClass != bytes32(0)` → else `ZeroAssetClass()`
- `policyHash != bytes32(0)` → else `ZeroPolicyHash()`
- `effectiveUntil > effectiveFrom` → else `InvalidValidityWindow(effectiveFrom, effectiveUntil)`
- Both values MAY be in the past. LPR does not compare them to `block.timestamp`.

### 2.4 Real on-chain policy fields

```solidity
struct Policy {
    uint256 policyId;
    uint256 lenderId;
    bytes32 assetClass;
    bytes32 policyHash;
    uint256 effectiveFrom;
    uint256 effectiveUntil;
    bool    active;
    address publishedBy;    // == msg.sender at publication
    uint256 recordedAt;     // == block.timestamp at publication
}
```

No haircut, maxLTV, jurisdiction allowlist, subtype list or NAV pointer is stored on-chain. Those live in the hashed JSON.

### 2.5 Auto-supersession

Publishing for the same `(lenderId, assetClass)` pair deactivates the previous active policy. It emits `PolicySuperseded(previousId, newId, lenderId, assetClass)` alongside `PolicyPublished`.

### 2.6 B6 — assetClass encoding — ✅ RESOLVED

**Decision (Jorge):** for the first MVP-03B live publication:

```
assetClass = keccak256(bytes("LI2CO3-COMMODITY"))
           = 0x6d8b595792555d4b18e727ffa23c7b8afd9e5fc9cc1ae10905609c1f4711b127
```

- `policy-1-demo-v1.json` is **NOT split or modified**. It keeps `allowedSubtypes: ["LI2CO3-COMMODITY", "GOLD-COMMODITY"]` and its existing policyHash `0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2`. The sandbox recomputation from the repo file matches the value in the previous draft.
- Previous options (a) and (c) are rejected; (b) with encoding (b.1) is adopted.

**Definitions:**
- **`LPR.assetClass`** is the deterministic on-chain routing/index key for the asset class under which the policy is published. It keys `activePolicyOf[lenderId][assetClass]`.
- **`policyHash`** is the commitment to the complete off-chain policy document.

Therefore:
- One policy document MAY contain multiple allowed subtypes.
- The same policyHash MAY later be published under another applicable assetClass. LPR has no uniqueness constraint on policyHash; each pair has its own slot and supersession chain.
- MVP-03B publishes ONLY `keccak256("LI2CO3-COMMODITY")`.
- A future GOLD publication may use `keccak256("GOLD-COMMODITY") = 0xc04372f88c0be747700b49bc3229a6abfc832f79e5c731fc75f5728970f50cc1` without modifying the collateral engine.

The pipeline at `b88f061` does not compute assetClass. The value is spec-defined and used only in Tx 2. Solidity integration tests use `bytes32("GOLD")` ASCII placeholders; those are illustrative test values, not the live convention.

### 2.7 Effective window — 🔒 FROZEN RULE (BLK-C resolved)

The **rule** is frozen, not any specific timestamp:

```
effectiveFrom  = performedAt − 3600
effectiveUntil = effectiveFrom + 31536000      # 365 days
```

`performedAt` is the value of the canonical live assessment anchored in Tx 3.

Consequences:
- `effectiveFrom ≤ performedAt` holds by construction, so the anchored assessment falls inside its policy window. CPA does not enforce this; the spec does.
- `effectiveUntil > effectiveFrom` holds by construction, satisfying LPR `InvalidValidityWindow`.
- The definitive integers are derived **only after** `performedAt` is frozen for the canonical run (P-9), and before Tx 2 is signed.

**Worked example only (NOT protocol constants):** for the example `performedAt = 1789562182`, the rule gives `effectiveFrom = 1789558582` and `effectiveUntil = 1821094582`. These values are illustrative and MUST NOT be reused unless that exact `performedAt` is the one frozen.

---

## Section 3 — B3 / B7 RESOLUTION (CollateralPositionAnchor, from real source)

**Correction carried from previous draft:** there is no `PIPELINE-ANALYST` role and no AccessControl. The role-grant assumption stays removed.

### 3.1 Verified from source at `b88f061`

- `function anchorAssessment(AnchorInput calldata input) external onlyGovernance returns (uint256 anchorId)` is at **line 278**.
- Governance uses the same two-step transfer as LR/LPR.
- Read functions:
  - `latest(bytes32,uint32)`
  - `latest(bytes32)`
  - `historyLength(bytes32)`
  - `historyLength(bytes32,uint32)`
  - `getAssessment(bytes32,uint256)`
  - `state(bytes32,uint32,uint64)`
  - `totalAnchors()`

### 3.2 Access model

`anchorAssessment` is **governance-only**. The Safe is the sole authorized caller. There is no role grant, no grant holder and no AccessControl.

### 3.3 `writerRole` is metadata, not access-gating

`keccak256("PIPELINE-ANALYST") = 0x1f1d9701f35d6935b4679cc9951a94636b9fbc5ce50a6123e1758063d1461560`. CPA only checks that it is non-zero (`ZeroWriterRole`).

### 3.4 `writer` field in AnchorRecord

`writer` is set from `msg.sender`, which is the Safe for every anchor on this deployment.

### 3.5 `lenderId` width

LR and LPR use `uint256 lenderId`; CPA uses `uint32`. CPA calls `getLender(uint256(input.lenderId))`. This has no impact for small IDs. Encode as `uint32` in CPA calldata.

### 3.6 B7 — AnchorInput struct — ✅ RESOLVED (verbatim from source)

```solidity
struct AnchorInput {
    bytes32 assetId;
    bytes32 assessmentHash;
    bytes32 navHash;
    bytes32 policyHash;
    uint32 lenderId;
    uint16 haircutBps;
    uint16 maxLTVBps;
    uint256 eligibleValue;
    uint256 creditCapacity;
    bytes32 currencyCode;
    uint8 verdict;
    bytes32 writerRole;
    uint64 performedAt;
    uint64 validUntil;
    bool demoAtAnchoring;
}
```

ABI signature: `anchorAssessment((bytes32,bytes32,bytes32,bytes32,uint32,uint16,uint16,uint256,uint256,bytes32,uint8,bytes32,uint64,uint64,bool))` → selector `0x81a07052`.

**Compatibility with `build_anchor_input()`: 15/15 PASS.**

Method:
- Parsed the struct from source.
- Built an assessment with the real policy fixture and LICO-0001 metadata, using synthetic NAV/LAS from the test helpers.
- Checked key order, Python type and Solidity range for every field.
- ABI-encoded locally with `cast calldata` (succeeds, selector `0x81a07052`).

| # | Field | Solidity | Pipeline source | Guarantee | Result |
|---|---|---|---|---|---|
| 1 | assetId | bytes32 | keccak256(UTF-8 assetId) | 0x + 64 hex | PASS |
| 2 | assessmentHash | bytes32 | SHA-256(pretty_bytes(record)) | 0x + 64 hex | PASS |
| 3 | navHash | bytes32 | SHA-256(raw NAV bytes) | 0x + 64 hex | PASS |
| 4 | policyHash | bytes32 | SHA-256(raw policy bytes) | 0x + 64 hex | PASS |
| 5 | lenderId | uint32 | CLI int | > 0 checked (no explicit upper bound) | PASS |
| 6 | haircutBps | uint16 | policy | 0..10000 checked | PASS |
| 7 | maxLTVBps | uint16 | policy | 0..10000 checked | PASS |
| 8 | eligibleValue | uint256 | integer minor units | ≥ 0, integer math | PASS |
| 9 | creditCapacity | uint256 | integer minor units | ≤ eligibleValue | PASS |
| 10 | currencyCode | bytes32 | ASCII right-padded | = Solidity `bytes32("USD")` | PASS |
| 11 | verdict | uint8 | 0/1/2 | CPA rejects > 2 | PASS |
| 12 | writerRole | bytes32 | keccak256("PIPELINE-ANALYST") | non-zero | PASS |
| 13 | performedAt | uint64 | CLI / time | int seconds | PASS |
| 14 | validUntil | uint64 | performedAt + validitySeconds | > performedAt | PASS |
| 15 | demoAtAnchoring | bool | NAV notice contains "DEMO" | bool | PASS |

Field order is identical and there are no extra or missing fields. The verdict encoding `0=ELIGIBLE, 1=INELIGIBLE, 2=POLICY_MISSING` matches CPA.

### 3.7 Currency minor-unit convention (corrects previous "18-decimal")

- Pipeline: fixed **10⁶** scale for every currency (`CURRENCY_DECIMALS` USD/EUR/BOB/GBP/JPY = 6, default 6). This is inherited from MVP-02E. It is not ISO-4217 minor units.
- CPA stores raw `uint256` with no decimals field. Solidity tests use `100 ether` only as illustrative magnitudes.
- The scale is an **off-chain convention**. It is recorded as `calculation.currencyDecimals = 6` inside the Assessment JSON committed by `assessmentHash`.
- **Rule for Explorer/Terminal:** `displayAmount = value / 10^6` of `currencyCode`. Never assume 18 decimals.

### 3.8 Non-anchorable POLICY_MISSING records (informational)

A POLICY_MISSING assessment carries `policyHash = 0x00…00` (CPA reverts `ZeroPolicyHash`) and `validUntil == performedAt` (reverts `InvalidValidityWindow`). MVP-03B anchors only ELIGIBLE records.

---

## Section 4 — TRANSACTION SEQUENCE (three transactions, none broadcast)

Every function below exists on the deployed contracts. **There is no Tx 0 and no role grant.** Nothing is broadcast without a separate explicit GO from Jorge.

### 4.0 Read-only pre-checks (STOP rule)

```bash
RPC=https://sepolia-rollup.arbitrum.io/rpc
SAFE=0x87039DF20338A876FB3b4dbd787816D42eecbACa
LR=0xf55D941bb4FF692B8F0553fA2Fc0350452fA88F7
LPR=0xC33bDd53D53eBE675dDd165e3FD2f98227B36398
CPA=0xB489376bB9f0455f917D82Cc806DEC51392051DA
ASSET_CLASS=0x6d8b595792555d4b18e727ffa23c7b8afd9e5fc9cc1ae10905609c1f4711b127

cast call $LR  "governance()(address)" --rpc-url $RPC            # == SAFE
cast call $LPR "governance()(address)" --rpc-url $RPC            # == SAFE
cast call $CPA "governance()(address)" --rpc-url $RPC            # == SAFE
cast call $LPR "lenderRegistry()(address)" --rpc-url $RPC        # == LR
cast call $CPA "lenderRegistry()(address)" --rpc-url $RPC        # == LR
cast call $CPA "lenderPolicyRegistry()(address)" --rpc-url $RPC  # == LPR
cast call $LR  "totalLenders()(uint256)" --rpc-url $RPC          # == 0
cast call $LPR "totalPolicies()(uint256)" --rpc-url $RPC         # == 0
cast call $CPA "totalAnchors()(uint256)" --rpc-url $RPC          # == 0
cast call $LR  "signerToLender(address)(uint256)" <LENDER_SIGNER_ADDRESS> --rpc-url $RPC  # == 0
cast balance <LENDER_SIGNER_ADDRESS> --rpc-url $RPC              # > 0 (Tx 2 gas)
```

**STOP rule:** if any of `totalLenders`, `totalPolicies` or `totalAnchors` is non-zero, STOP. The hardcoded IDs below (`lenderId = 1`, `policyId = 1`, `anchorId = 1`) and the pipeline default fixture `lender-1-info.json` would no longer hold, and the spec must be revised.

### Tx 1 — Register the demo lender directly to `active + VERIFIED`

| Item | Value |
|---|---|
| Caller | Safe `0x87039DF20338A876FB3b4dbd787816D42eecbACa` |
| Target | LR `0xf55D941bb4FF692B8F0553fA2Fc0350452fA88F7` |
| Function | `registerLender(string,string,uint8,address)` — `0x97f75d02` |
| `name` | `"Lindblad Demo Lender"` |
| `jurisdiction` | `"US-DE"` (equals `lender-1-info.json`, which the pipeline copies into the Assessment as `lenderJurisdiction`) |
| `kybStatus` | `2` (VERIFIED) — see P-6 |
| `signerAddress` | `<LENDER_SIGNER_ADDRESS>` (B5) |

**Postconditions:**
- `LR.totalLenders() == 1`
- `LR.getLender(1)` = `{1, "Lindblad Demo Lender", "US-DE", 2, <LENDER_SIGNER_ADDRESS>, true, <block.timestamp>}`
- `LR.signerToLender(<LENDER_SIGNER_ADDRESS>) == 1`
- `LR.isActive(1) == true`

```bash
cast calldata "registerLender(string,string,uint8,address)" \
  "Lindblad Demo Lender" "US-DE" 2 <LENDER_SIGNER_ADDRESS>
```

### Tx 2 — Publish the first demo policy

| Item | Value |
|---|---|
| Caller | `<LENDER_SIGNER_ADDRESS>` (B5: operational lender identity for LPR) |
| Target | LPR `0xC33bDd53D53eBE675dDd165e3FD2f98227B36398` |
| Function | `publishPolicy(uint256,bytes32,bytes32,uint256,uint256)` — `0x1559bd80` |
| `lenderId` | `1` |
| `assetClass` | `0x6d8b595792555d4b18e727ffa23c7b8afd9e5fc9cc1ae10905609c1f4711b127` |
| `policyHash` | `0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2` (SHA-256 of the raw 545-byte policy file) |
| `effectiveFrom` | `<PERFORMED_AT> − 3600` (frozen rule §2.7) |
| `effectiveUntil` | `<PERFORMED_AT> − 3600 + 31536000` (frozen rule §2.7) |

**Preconditions:**
- Tx 1 postconditions hold.
- `LPR.activePolicyOf(1, ASSET_CLASS) == 0`.
- Policy file published byte-identical to R2 (§6.3, P-7).

**Postconditions:**
- `LPR.totalPolicies() == 1`
- `LPR.getActivePolicyId(1, ASSET_CLASS) == 1`
- `LPR.getPolicy(1).active == true`
- `LPR.getPolicy(1).publishedBy == <LENDER_SIGNER_ADDRESS>`

Tx 2 is signed only through Jorge's secure key handling. The private key never enters the repo, `.env`, `.env.example`, JSON, docs, shell history or logs.

```bash
PERFORMED_AT=<FROZEN_PERFORMED_AT>   # same value used by the Tx 3 canonical run
cast calldata "publishPolicy(uint256,bytes32,bytes32,uint256,uint256)" \
  1 \
  0x6d8b595792555d4b18e727ffa23c7b8afd9e5fc9cc1ae10905609c1f4711b127 \
  0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2 \
  $((PERFORMED_AT - 3600)) $((PERFORMED_AT - 3600 + 31536000))
```

### Tx 3 — Anchor the LICO-0001 assessment

| Item | Value |
|---|---|
| Caller | Safe (CPA `onlyGovernance`) |
| Target | CPA `0xB489376bB9f0455f917D82Cc806DEC51392051DA` |
| Function | `anchorAssessment((bytes32,bytes32,bytes32,bytes32,uint32,uint16,uint16,uint256,uint256,bytes32,uint8,bytes32,uint64,uint64,bool))` — `0x81a07052` |
| Argument | the 15-field tuple printed by pipeline step `[10] Proposed AnchorInput`, copied without edits |

**Canonical pipeline invocation (preview only, pinned inputs).** The canonical run MUST pin the §6.5 files with `--nav-path` and `--las-path`. Automatic latest-file selection (`--nav-dir`/`--las-dir` defaults) is **forbidden** for the canonical run, because it picks the lexicographically latest file.

```bash
cd ~/Lindblad/lindfi
PERFORMED_AT=<FROZEN_PERFORMED_AT>

python3 pipeline/collateral_pipeline.py LICO-0001 1 \
  --policy    pipeline/fixtures/policy-1-demo-v1.json \
  --nav-path  "$HOME/Lindblad/04-lindfi/pipeline/out/NAV-LICO-0001-1789231149.json" \
  --las-path  "$HOME/Lindblad/04-lindfi/pipeline/out/LAS-LICO-0001-1789094130.json" \
  --performed-at "$PERFORMED_AT"
```

Use `$HOME`, not a quoted `~`. The pipeline does not expand `~`; a quoted `~` fails with "file not found" (exit 2). That failure is safe but blocks the run.

The run's `[2]` and `[3]` lines MUST print `navHash 0x5fc89309…2bf3d` and `lasHash 0x9c128101…35d9e8`. Otherwise STOP.

**AnchorInput values:**

| Field | Value | Status |
|---|---|---|
| assetId | `0x132b640977a078ed75c0a08f32d241ec1c1b023cb8cf51f3985c3065a3c36c25` (keccak256("LICO-0001")) | verified |
| assessmentHash | produced by the canonical pinned run at the frozen `performedAt`. The earlier draft value `0x017e7a7f…118f10` is **NOT canonical** unless reproduced from the §6.5 files at that exact `performedAt`. | per canonical run (P-8) |
| navHash | `0x5fc893094562213420b2f34d700042f65edaff3de501a7bdfb53eadcf322bf3d` | **canonical** (verified by Jorge, §6.5) |
| policyHash | `0xc1470124…bae2` | verified (repo bytes) |
| lenderId | `1` (uint32) | subject to §4.0 STOP rule |
| haircutBps | `2000` | verified (policy) |
| maxLTVBps | `5000` | verified (policy) |
| eligibleValue / creditCapacity | pipeline output, scale 10⁶ | depends on NAV |
| currencyCode | `0x5553440000000000000000000000000000000000000000000000000000000000` | verified if NAV currency is USD |
| verdict | must be `0`, otherwise STOP | depends on E1–E8 at performedAt (incl. E4: `NAV.lasReference.lasHash == 0x9c128101…35d9e8`) |
| writerRole | `0x1f1d9701…d1461560` | verified |
| performedAt | `<FROZEN_PERFORMED_AT>` | frozen before Tx 2 (P-9) |
| validUntil | `performedAt + 2592000` (policy `validitySeconds`) | derived |
| demoAtAnchoring | expected `true` | depends on NAV notice |

**Postconditions:**
- `CPA.totalAnchors() == 1`
- `CPA.latest(assetId, uint32(1))` returns the anchored record
- `AnchorRecord.writer == Safe`
- `CPA.state(assetId, 1, <FROZEN_PERFORMED_AT>) == ACTIVE (1)`

### 4.4 Ordering

- Tx 1 before Tx 2 and Tx 3 is **enforced on-chain** (lender exists, active, VERIFIED).
- Tx 2 before Tx 3 is **procedural only.** CPA performs no runtime policyHash check against LPR. The spec mandates Tx 2 → Tx 3.

---

## Section 5 — BLOCKERS

### Closed

- ~~B1~~ LR lifecycle → §1
- ~~B2~~ LPR authorization and encoding → §2
- ~~B3~~ CPA access model → §3
- ~~B5~~ Signer → **Option A**, fresh dedicated EOA, placeholder `<LENDER_SIGNER_ADDRESS>`. Operational lender identity for LPR. CPA stays governance-only via the Safe. Key never generated, requested, printed or stored in repo, JSON, `.env` examples, docs or logs.
- ~~B6~~ assetClass → `keccak256("LI2CO3-COMMODITY")`, policy unchanged → §2.6
- ~~B7~~ AnchorInput → exact struct, 15/15 PASS → §3.6

### B4 — Terminal + Explorer (STILL OPEN, independent)

**UI implementation: PENDING REPOSITORY AUDIT.** The repositories were not available in this pass.

Preserved:
- **Lindblad Explorer = physical verification layer** (evidence, LAS, NAV; asset side).
- **LindFi Terminal = financial usage layer** (collateral, future financing modules; lender/borrower side).
- **Bidirectional provenance:** Terminal links back to the Explorer NAV/LAS view, and the Explorer links forward to the CPA anchor view.

Constraints already fixed for the UIs: amounts use scale 10⁶ (§3.7). Artifact hashes are SHA-256 over published bytes; identifiers are keccak256 (§6).

B4 does not block the CONTRACT/PROTOCOL freeze.

### Freeze blockers — all closed

| ID | Resolution |
|---|---|
| ~~BLK-A~~ | **Resolved.** Canonical NAV = `NAV-LICO-0001-1789231149.json` → `0x5fc89309…2bf3d`. Canonical LAS = `LAS-LICO-0001-1789094130.json` → `0x9c128101…35d9e8`. `0x9c128101…` is the LAS hash, not the NAV hash. Canonical run pins both paths (§4 Tx 3, §6.5). |
| ~~BLK-B~~ | **Approved by Jorge.** Hashing definitions in §6.1 frozen. |
| ~~BLK-C~~ | **Approved by Jorge.** Rule frozen (§2.7); integers derived after `performedAt` is frozen. |

### Execution prerequisites (do not affect the freeze)

| ID | Item |
|---|---|
| P-1 | Jorge generates the signer EOA securely and supplies only the public `<LENDER_SIGNER_ADDRESS>` |
| P-2 | Signer funded with Arbitrum Sepolia ETH for Tx 2 gas (operational transfer, not a protocol transaction) |
| P-3 | Freshness at `performedAt`: `performedAt − NAV.performedAt ≤ 15552000` and `performedAt − LAS.performedAt ≤ 31536000`. **If** the internal `performedAt` fields equal the filename suffixes, the binding bound is NAV: `performedAt ≤ 1804783149` (2027-03-11 16:39:09 UTC). Otherwise INELIGIBLE → STOP. |
| P-4 | §4.0 pre-checks pass (STOP rule) |
| P-5 | Safe 2-of-3 signatures available for Tx 1 and Tx 3 |
| P-6 | Acknowledgment that `VERIFIED` for the demo lender is a demo attestation, not a real KYB result |
| P-7 | Policy file uploaded byte-identical to `mvp-03b/policy-1-demo-v1.json` in R2; SHA-256 of served bytes = `0xc147…bae2` before Tx 2 |
| P-8 | Canonical pinned pipeline run: prints navHash `0x5fc8…` and lasHash `0x9c12…`, verdict ELIGIBLE; `assessmentHash` and amounts recorded from this run only |
| P-9 | Freeze `<FROZEN_PERFORMED_AT>`, then derive the Tx 2 integers with the §2.7 rule before signing Tx 2 |
| P-10 | Tx 3 broadcast while the assessment is valid (`block.timestamp ≤ validUntil = performedAt + 2592000`). CPA does not reject late anchoring, but a late anchor would be born EXPIRED. |

---

## Section 6 — HASHING, IDENTIFIERS AND R2 NAMESPACE

### 6.1 Artifact hashes vs bytes32 identifiers — 🔒 FROZEN (BLK-B approved by Jorge)

The previous "sha256 OR keccak256" language is removed. MVP-03B does **not** change navHash, policyHash or assessmentHash algorithms.

| Field | Category | Exact algorithm | Source | Fixed value |
|---|---|---|---|---|
| navHash | JSON artifact hash | SHA-256 over the exact raw NAV file bytes; no re-serialization | `main()`: `sha256_hex(nav_raw)` | `0x5fc893094562213420b2f34d700042f65edaff3de501a7bdfb53eadcf322bf3d` |
| policyHash | JSON artifact hash | SHA-256 over the raw policy file bytes as read from disk; no re-serialization | `main()`: `sha256_hex(policy_raw)` | `0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2` |
| assessmentHash | JSON artifact hash | SHA-256 over the exact deterministic Assessment file bytes produced by the pipeline: `json.dumps(record, default=str, indent=2, ensure_ascii=False, sort_keys=False, separators=(",", ": ")).encode("utf-8")`, no trailing newline; the same bytes are written to the ASMT file | `pretty_bytes()` | per run |
| lasHash (context; not in AnchorInput; checked by E4) | JSON artifact hash | SHA-256 over the exact raw LAS file bytes | `main()`: `sha256_hex(las_raw)` | `0x9c12810196af15f8d455a2be2b669147ebb5c7e4ef62a3715db6ee9f7f35d9e8` |
| assetId | bytes32 identifier | keccak256 over UTF-8 assetId string. Backend order: `cast keccak` → pysha3 → pycryptodome → pure-Python; all agree. | `build_anchor_input()` | LICO-0001 → `0x132b6409…a3c36c25` |
| assetClass | bytes32 identifier | keccak256 over UTF-8 asset subtype string; **spec-defined, not computed by pipeline** | §2.6 | `0x6d8b5957…4711b127` |
| writerRole | bytes32 identifier | keccak256 over UTF-8 `"PIPELINE-ANALYST"` | `build_anchor_input()` | `0x1f1d9701…d1461560` |
| currencyCode | bytes32 identifier | not hashed; uppercase ASCII right-padded with 0x00 | `_bytes32_ascii_right_padded()` | `0x5553440000…` |

Artifact hashes are SHA-256 commitments to documents. Identifiers are keccak256 or ASCII-padded keys. They MUST NOT be confused. LPR and CPA store both kinds verbatim and compare neither.

### 6.2 Browser verification recipe (corrected)

- **policy / NAV / LAS:** download the file from R2 and SHA-256 the **downloaded bytes as-is**.
  - Do NOT parse and re-serialize.
  - Re-serializing the policy gives `0x58de1d3c82b5f1b2913e8d1247136c3715a6d86890a1fdf46623bb35afb69aef`, which does not equal the on-chain `0xc147…bae2`.
- **assessment:** SHA-256 of the downloaded ASMT file bytes as-is. They equal `pretty_bytes(record)` by construction.

Browser code must use `crypto.subtle.digest("SHA-256", arrayBuffer)` on the fetched `ArrayBuffer`, not on `JSON.stringify(...)` output.

### 6.3 R2 namespace

```
https://pub-5b1e7b456c174e028ef9a87abb10345d.r2.dev/mvp-03b/
```

This value is frozen from the earlier draft. Uploads must preserve exact bytes: no reformatting, no line-ending conversion, no BOM, no content-encoding transform that changes the served bytes. The policy object is `mvp-03b/policy-1-demo-v1.json` = the 545-byte file at `b88f061` (trailing LF included).

### 6.4 Identifier encoding constraint

`cast keccak` treats `0x`-prefixed input as hex bytes, while the Python fallbacks hash it as text (`"0x1234"`: `0x56570de2…` vs `0x1ac7d1b8…`). Asset IDs, subtypes and role labels MUST NOT begin with `0x`. All current values comply.

### 6.5 Canonical MVP-03B inputs — 🔒 FROZEN

Verified by Jorge on his Mac against the original frozen MVP-02E outputs.

| Artifact | Canonical path | SHA-256 (= on-chain / E4 value) |
|---|---|---|
| NAV | `~/Lindblad/04-lindfi/pipeline/out/NAV-LICO-0001-1789231149.json` | `0x5fc893094562213420b2f34d700042f65edaff3de501a7bdfb53eadcf322bf3d` |
| LAS | `~/Lindblad/04-lindfi/pipeline/out/LAS-LICO-0001-1789094130.json` | `0x9c12810196af15f8d455a2be2b669147ebb5c7e4ef62a3715db6ee9f7f35d9e8` |
| Policy | `pipeline/fixtures/policy-1-demo-v1.json` @ `b88f061` (545 bytes) | `0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2` |
| Asset metadata | `pipeline/fixtures/asset-LICO-0001.json` @ `b88f061` | not anchored (supplies `assetSubtype = LI2CO3-COMMODITY`, `assetJurisdiction = BO`) |
| Lender info | `pipeline/fixtures/lender-1-info.json` @ `b88f061` | not anchored (supplies `lenderJurisdiction = US-DE`, included in the Assessment) |

Integrity re-check before the canonical run:

```bash
shasum -a 256 \
  "$HOME/Lindblad/04-lindfi/pipeline/out/NAV-LICO-0001-1789231149.json" \
  "$HOME/Lindblad/04-lindfi/pipeline/out/LAS-LICO-0001-1789094130.json" \
  pipeline/fixtures/policy-1-demo-v1.json
```

Any mismatch → STOP.

---

## Section 7 — VALIDATION STATUS

**Tests: VERIFIED IN SANDBOX this pass** at `b88f061`, clean tree.

| Suite | Command | Result |
|---|---|---|
| Solidity | `forge test` | **265 passed, 0 failed, 0 skipped** (5 suites) |
| Python | `python3 -m pytest pipeline/test_collateral_pipeline.py -v` | **37 passed** |

Environment:
- forge 1.5.1-stable (`b0a9dd9`)
- solc 0.8.20+commit.a1b79de6 (official GitHub release)
- forge-std `bf647bd` = `foundry.lock` v1.16.2
- Python 3.12.3, pytest 9.1.1

These are sandbox results. Jorge's local run remains the reference for GO/NO-GO:

```bash
cd ~/Lindblad/lindfi
forge test
python3 -m pytest pipeline/test_collateral_pipeline.py -v
```

**Local sequence simulation** (throwaway copy, repo untouched): fresh LR/LPR/CPA with Safe governance. Tx 1 (Safe) → Tx 2 (placeholder signer) → Tx 3 (Safe) with `build_anchor_input()` output: **2/2 PASS**. It confirmed:
- Solidity `keccak256(bytes(...))` equals the pipeline identifiers.
- `bytes32("USD")` equals the pipeline currencyCode.
- `state()` returns ACTIVE.
- The signer is rejected by CPA and LR (`NotGovernance`).
- Tx 2 reverts `LenderNotVerified` for a PENDING lender.

**Verified by Jorge locally (this pass):** SHA-256 of canonical NAV and LAS files (§6.5).

**Not verified (execution-time, not freeze-blocking):**
- Canonical pinned pipeline run and resulting `assessmentHash` (P-8)
- NAV/LAS internal `performedAt` values and the E4 link (checked by that run)
- Any deployed on-chain state (§4.0, no RPC access from sandbox)

---

## Section 8 — FUTURE COMPOSABILITY BOUNDARIES

Reaffirmed. CPA remains the collateral primitive consumed by future modules:

- Loans (borrowing against anchored collateral)
- Credit facilities (revolving lines against anchored collateral)
- Escrow (multi-party lockups referencing anchored assessments)
- USDC / USDT settlement (stablecoin rails on top of CPA state)
- Repayment tracking
- Trade finance
- Inventory finance
- External DeFi adapters

**None of these are implemented in MVP-03B.** MVP-03B ends at the anchored assessment. Every future module reads CPA state; CPA reads nothing back. This one-way flow is the composability invariant.

**Multi-asset invariant (frozen).**
- `LICO-0001` and `tGOLD-0001` are demonstration assets only. The architecture is NOT limited to lithium or gold.
- Future LAS-verified asset classes may include `IRON-COMMODITY`, `COPPER-COMMODITY`, `SILVER-COMMODITY`, energy and other physical assets.
- Adding an asset requires upstream LAS/NAV support plus configuration/policy, and an LPR publication under `keccak256(UTF-8 <SUBTYPE>)`. It never requires modifying the generic LindFi collateral engine.

---

## Section 9 — WHAT COMES AFTER FREEZE

The protocol portion is FROZEN. Execution order (each broadcast needs its own explicit GO):

1. Resolve P-1, P-2, P-5, P-6. Freeze `<FROZEN_PERFORMED_AT>` (P-9) and run the §6.5 integrity check.
2. Upload `policy-1-demo-v1.json` **unchanged** (545 bytes) to `mvp-03b/policy-1-demo-v1.json` in R2 and verify the SHA-256 of the served bytes = `0xc147…bae2`.
3. Run §4.0 pre-checks. Apply the STOP rule.
4. Broadcast Tx 1 (register lender). Verify postconditions.
5. Broadcast Tx 2 (publish policy, signer EOA). Verify postconditions.
6. Run the canonical pinned pipeline preview (§4 Tx 3) at the frozen `performedAt`. Confirm navHash/lasHash, verdict ELIGIBLE, and record `assessmentHash` and the AnchorInput (P-8). In practice this run can happen before Tx 2 (the pipeline is read-only), which also confirms P-3 before any broadcast.
7. Broadcast Tx 3 (anchor assessment). Verify postconditions.
8. After B4 repository audit: author the Terminal collateral view (`CPA.latest(assetId, 1)`, amounts at 10⁶ scale) and the bidirectional Explorer ↔ Terminal links.
9. End-to-end demo: pipeline → Terminal → Explorer → back to Terminal.
10. Commit Terminal and Explorer changes separately from the on-chain steps. Optionally annotate `deployments/arbitrum-sepolia.json` with the canonical demo state.

Each broadcast requires its own explicit GO. **None of the above is executed in this pass.**

---

## Summary

- **Frozen:**
  - B1–B3 contract facts
  - B5 (fresh EOA signer), B6 (`keccak256("LI2CO3-COMMODITY")`, policy unchanged), B7 (15/15 PASS)
  - §6 hashing/identifier table (BLK-B)
  - §2.7 effective-window rule (BLK-C)
  - canonical NAV/LAS inputs (BLK-A, §6.5)
  - three-transaction structure with STOP rules
  - multi-asset invariant
- **Not constants:** `performedAt`, `assessmentHash`, amounts, `validUntil`, Tx 2 integers — produced at execution by the canonical pinned run.
- **Open independently:** B4 — PENDING REPOSITORY AUDIT (not part of the frozen protocol scope).
- **Tests:** verified in sandbox (265 / 37).
- **Not done:** no broadcast, no registration, no publication, no anchoring, no key generation, no Solidity or pipeline modification, no commit, no push.

**Verdict: MVP-03B PROTOCOL SPEC FROZEN**

---

**End of spec.**
