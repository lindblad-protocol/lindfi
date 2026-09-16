# LINDFI MVP-03B — Execution Record

**Status:** 📋 **FINAL — VERIFIED 42/42. Not committed. Awaiting Jorge's formal `MVP-03B — CLOSED` declaration.**
**Execution date:** 2026-09-16
**Network:** Arbitrum Sepolia (chainId `421614`), testnet
**Governing spec:** `LINDFI_MVP03B_FIRST_LIVE_COLLATERAL_SPEC.md` (🔒 PROTOCOL SPEC: FROZEN)
**Code baseline:** `lindblad-protocol/lindfi` @ `b88f061b6228259a842071f5e76c3589bb3775f7`. The working tree was clean before, during and after execution. No Solidity, pipeline or spec modification.

> **Scope of this record.** This record covers the on-chain protocol execution of MVP-03B (Tx 1 → Tx 2 → Tx 3) and the publication of its canonical artifacts. B4 (Explorer / Terminal UI) is **PENDING REPOSITORY AUDIT** and is **outside** this protocol closure.

---

## 1. Summary

MVP-03B demonstrated on-chain, with public verifiable artifacts:

```
Tx 1  governance (Safe 2-of-3)  → LenderRegistry.registerLender        → lender 1
Tx 2  lender signer (EOA)       → LenderPolicyRegistry.publishPolicy   → policy 1
Tx 3  governance (Safe 2-of-3)  → CollateralPositionAnchor.anchorAssessment → anchor 1
```

This produced a complete, cross-referenced chain:
- **Governance** registered a lender.
- **That lender, through its own authorized signer**, published its policy.
- **Governance** anchored a canonical, reproducible collateral assessment that references that exact policy and the physical NAV.

Every hash anchored on-chain matches a publicly served artifact byte for byte.

---

## 2. Important limitations (read first)

| # | Limitation |
|---|---|
| L-1 | **`kybStatus = VERIFIED` for "Lindblad Demo Lender" is a demo/testnet attestation only.** No real KYB process was performed (P-6 acknowledged by Jorge). |
| L-2 | **`creditCapacity` is an assessment output, NOT a credit commitment, loan offer or lender obligation.** CPA records a collateral evaluation; it does not originate or commit credit. |
| L-3 | **The anchor expires.** `state()` returns ACTIVE only for `performedAt ≤ t ≤ validUntil`. After **`validUntil = 1792162800` (2026-10-16 15:00:00 UTC)** the anchor is **EXPIRED**. Any demo after that date shows it as expired unless a new assessment is anchored. |
| L-4 | **Demo asset.** `LICO-0001` is a demonstration asset; the NAV notice is `DEMO / TESTNET - NO PHYSICAL BACKING` and `demoAtAnchoring = true`. |
| L-5 | Testnet only. No mainnet state was touched. |
| L-6 | Amounts use the fixed **10⁶ scale** (not 18 decimals): `18000000000` = 18,000.00 USD. |

---

## 3. Contracts, chain and authorities

### 3.1 Contracts

| Component | Address |
|---|---|
| LenderRegistry (LR) | `0xf55D941bb4FF692B8F0553fA2Fc0350452fA88F7` |
| LenderPolicyRegistry (LPR) | `0xC33bDd53D53eBE675dDd165e3FD2f98227B36398` |
| CollateralPositionAnchor (CPA) | `0xB489376bB9f0455f917D82Cc806DEC51392051DA` |

Verified wiring:
- `LR.governance = LPR.governance = CPA.governance = Safe`
- `LPR.lenderRegistry = CPA.lenderRegistry = LR`
- `CPA.lenderPolicyRegistry = LPR`

### 3.2 Governance Safe

| Field | Value |
|---|---|
| Address | `0x87039DF20338A876FB3b4dbd787816D42eecbACa` |
| Version | `1.4.1`, L2 variant (emits `SafeMultiSigTransaction`) |
| Threshold / owners | 2-of-3 |
| Owner A (signed Tx 1, Tx 3) | `0xB99784A7B5Ff659F9d5FED46f2AdFCb3Bd63Ecb0` |
| Owner B (signed Tx 1, Tx 3) | `0x32a372CA8136484D60730a0cB7C0495b70BF6125` |
| Owner C (not used) | `0x386e5501Ba104dD640baa8FCD4Ae5fADa117D301` |

### 3.3 Other accounts

| Role | Address |
|---|---|
| Lender signer (B5, dedicated fresh EOA) | `0x4B432A562F71929925093896d67B355e1A3d7ceB`; Foundry encrypted keystore `lindfi-demo-lender-signer` |
| Relayer / gas payer for Tx 1 and Tx 3; funder of signer | `0xE647Be12719cCD2A0AFb5836e134a859BCa7a7A3` (MVP-03A deployer). Relayer identity does not affect state: `msg.sender` seen by LR/CPA is the Safe. |

### 3.4 Authorization model exercised

| Tx | On-chain `msg.sender` to target | Authorization rule (source) | Negative control |
|---|---|---|---|
| Tx 1 | Safe | `LR.registerLender` is `onlyGovernance` | n/a |
| Tx 2 | lender signer | `LPR.publishPolicy`: governance OR current lender signer; lender must be active + VERIFIED | deployer EOA → revert `NotAuthorized()` `0xea8e4eb5` |
| Tx 3 | Safe | `CPA.anchorAssessment` is `onlyGovernance` | lender signer → revert `NotGovernance()` `0xb56f932c` |

No AccessControl roles and no role-grant transaction. `writerRole` is metadata only.

---

## 4. Canonical values (frozen)

### 4.1 Artifacts and hashes

| Artifact | Local canonical path | Size | SHA-256 (on-chain / E4 value) |
|---|---|---|---|
| NAV | `$HOME/Lindblad/04-lindfi/pipeline/out/NAV-LICO-0001-1789231149.json` | — | `0x5fc893094562213420b2f34d700042f65edaff3de501a7bdfb53eadcf322bf3d` |
| LAS | `$HOME/Lindblad/04-lindfi/pipeline/out/LAS-LICO-0001-1789094130.json` | — | `0x9c12810196af15f8d455a2be2b669147ebb5c7e4ef62a3715db6ee9f7f35d9e8` |
| Policy | `pipeline/fixtures/policy-1-demo-v1.json` @ `b88f061` | 545 bytes | `0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2` |
| Assessment | `$HOME/Lindblad/04-lindfi/pipeline/out/mvp-03b/ASMT-LICO-0001-1-1789570800.json` | 1715 bytes | `0x097eb0b6c000a45669558e48cdd7182625affe46f772c9e8e1071b6c77fdc4e7` |

Hashing convention (spec §6, BLK-B):
- **Artifact hashes:** SHA-256 over the exact file bytes.
- **Identifiers:** keccak256 over UTF-8 (`assetId`, `assetClass`, `writerRole`), or ASCII right-padded bytes32 (`currencyCode`).

### 4.2 Public artifact URLs

| Artifact | URL | Served-bytes verification in this execution |
|---|---|---|
| NAV | `https://pub-5b1e7b456c174e028ef9a87abb10345d.r2.dev/mvp-02a/NAV-LICO-0001-1789231149.json` | ✅ SHA-256 `0x5fc8…bf3d` |
| LAS | `https://pub-5b1e7b456c174e028ef9a87abb10345d.r2.dev/mvp-02a/LAS-LICO-0001-1789094130.json` | ✅ SHA-256 `0x9c12…d9e8` (check R-LAS, §10) |
| Policy | `https://pub-5b1e7b456c174e028ef9a87abb10345d.r2.dev/mvp-03b/policy-1-demo-v1.json` | ✅ P-7 (§6) |
| Assessment | `https://pub-5b1e7b456c174e028ef9a87abb10345d.r2.dev/mvp-03b/ASMT-LICO-0001-1-1789570800.json` | ✅ §7 |

R2 bucket `lindblad-storage`, public dev URL `pub-5b1e7b456c174e028ef9a87abb10345d.r2.dev`. **Do not overwrite** `mvp-03b/policy-1-demo-v1.json` or `mvp-03b/ASMT-LICO-0001-1-1789570800.json`.

### 4.3 Identifiers

| Identifier | Value | Derivation |
|---|---|---|
| assetId | `0x132b640977a078ed75c0a08f32d241ec1c1b023cb8cf51f3985c3065a3c36c25` | keccak256("LICO-0001") |
| assetClass | `0x6d8b595792555d4b18e727ffa23c7b8afd9e5fc9cc1ae10905609c1f4711b127` | keccak256("LI2CO3-COMMODITY") |
| writerRole | `0x1f1d9701f35d6935b4679cc9951a94636b9fbc5ce50a6123e1758063d1461560` | keccak256("PIPELINE-ANALYST") |
| currencyCode | `0x5553440000000000000000000000000000000000000000000000000000000000` | bytes32("USD") |

### 4.4 Timestamps

| Value | Integer | UTC | Origin |
|---|---|---|---|
| LAS performedAt | `1789094130` | 2026-09-11 02:35:30 | LAS artifact |
| NAV performedAt | `1789231149` | 2026-09-12 16:39:09 | NAV artifact |
| **Assessment performedAt** | **`1789570800`** | 2026-09-16 15:00:00 | frozen (P-9) |
| Policy effectiveFrom | `1789567200` | 2026-09-16 14:00:00 | performedAt − 3600 |
| Policy effectiveUntil | `1821103200` | 2027-09-16 14:00:00 | effectiveFrom + 31536000 |
| Lender addedAt | `1789578611` | 2026-09-16 17:10:11 | Tx 1 block |
| Policy recordedAt | `1789579501` | 2026-09-16 17:25:01 | Tx 2 block |
| Anchor anchoredAt | `1789586290` | 2026-09-16 19:18:10 | Tx 3 block |
| **Anchor validUntil** | **`1792162800`** | **2026-10-16 15:00:00** | performedAt + 2592000 |

### 4.5 Canonical calldata hashes

| Tx | Function / selector | SHA-256(calldata) | Safe nonce | safeTxHash |
|---|---|---|---|---|
| Tx 1 | `registerLender` `0x97f75d02` | `0xa380c644fdcae6bee35e3f068afc6792ab3baa7c0dfa96c3f3f7a76311579dd2` | 5 | `0x32d0fa9ea8b6bb2d8c7dbde93b92465dd1a7aebe2d47fbc68ebeef92f50e4454` |
| Tx 2 | `publishPolicy` `0x1559bd80` | `0xa670a78a7ef0c123fc658d590f924e0c3d18265e62d9428f1020f448e9b8a6f7` | n/a (EOA, signer nonce 0) | n/a |
| Tx 3 | `anchorAssessment` `0x81a07052` | `0x6489abfb626dcf9e9b9d8797b583c238b2f6e79c41147477f01e960f1bfd295c` | 6 | `0x06b49ea9f31ef45d57b416c12335459f7a28f14e8138865894f4befa27f98206` |

Both safeTxHashes were computed locally (EIP-712, Safe 1.4.1) and **matched `Safe.getTransactionHash(...)` on-chain** before signing.

---

## 5. Transactions

| # | transactionHash | Block | from → to | gasUsed | Status |
|---|---|---|---|---|---|
| Funding (P-2) | `0xbae4094dd45c40e118cce22c5bae77722e96f44827a783df8a75525a072c6867` | 309540611 | `0xE647…a7A3` → signer `0x4B43…7ceB` (value 0.002 ETH) | 21175 | 1 |
| **Tx 1** | `0x5fea579233706fa61c33b5f05f9366946d05b74572e696c4c10ce5c299c2881e` | 309560693 | `0xE647…a7A3` → Safe (`execTransaction`, nonce 5) | 219595 | 1 |
| **Tx 2** | `0xa47ef82a912b76ce64879a016af4d50f7a4e48e1bf756269e123e5e38693bfa3` | 309564255 | signer `0x4B43…7ceB` → LPR | 252971 | 1 |
| **Tx 3** | `0x78ab79ccd8f03ce00f4618bb9ac230f8c1f185ac3d81178988512f163e67ee63` | 309591443 | `0xE647…a7A3` → Safe (`execTransaction`, nonce 6) | 448520 | 1 |

### 5.1 Tx 1 — registerLender (Safe)

- **Parameters:** `("Lindblad Demo Lender", "US-DE", 2 /*VERIFIED, demo*/, 0x4B432A562F71929925093896d67B355e1A3d7ceB)`
- **Signatures:** Owner A + Owner B, `eth_sign` scheme over safeTxHash, v adjusted 27/28 → 31/32, sorted by owner address. Pre-validated with `checkSignatures` (pass) and simulated with `execTransaction` via `eth_call` (`true`).
- **Events:**
  - Safe `SafeMultiSigTransaction` `0x66753cd2356569ee081232e3be8909b950e0a76c1f8460c3a5e3c2be32b11bed`
  - LR `LenderRegistered` `0x6072d57bd6936f3f5e1623aa6fd735e76796b38e2866a106bc518b4e7aa8d9ef`
  - Safe `ExecutionSuccess` `0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e`
- **Safe nonce:** 5 → 6.
- **Result:** `lenderId = 1`.

### 5.2 Tx 2 — publishPolicy (lender signer)

- **Parameters:** `(1, 0x6d8b…b127, 0xc147…bae2, 1789567200, 1821103200)`
- **Signed with:** Foundry keystore `lindfi-demo-lender-signer` (`--from` guardrail).
- **Input verification:** SHA-256 of the on-chain transaction input = `0xa670a78a…a6f7` (canonical).
- **Events:** LPR `PolicyPublished` `0x70cc77a92825ac0897027612fbb6fddb50348c5134d6f76187a53c776deb5820`. No `PolicySuperseded`, since this was the first policy for (lender 1, assetClass).
- **Signer nonce:** 0 → 1. Safe nonce unchanged (6).
- **Result:** `policyId = 1`, `publishedBy = 0x4B432A562F71929925093896d67B355e1A3d7ceB`.

### 5.3 Tx 3 — anchorAssessment (Safe)

- **AnchorInput:** 15/15 canonical, see §8.3.
- **Signatures:** Owner A + Owner B, same scheme as Tx 1. `checkSignatures` passed; `execTransaction` simulation returned `true`; direct simulation as Safe returned `anchorId = 1`.
- **Events:**
  - Safe `SafeMultiSigTransaction` `0x66753cd2…1bed`
  - CPA `AssessmentAnchored` `0xcaed51792f2ee040bd8f3d36d2ae9047e33a505b4103ef7dd5fec44af69be64c`
  - CPA `AssessmentHashes` `0x298e00964ae4e99a353efd00b8cf16742d8287314496f4f577d5be7ea494ad37`
  - CPA `AssessmentAmounts` `0x3541ff0ff56c3ef5ef16d69875af17c64f2584e9191af51f7485241d8dceceb6`
  - Safe `ExecutionSuccess` `0x442e715f…556e`, whose topic1 is the safeTxHash `0x06b49ea9…f98206`
  - No `ExecutionFailure`.
- **Safe nonce:** 6 → 7.
- **Result:** `anchorId = 1`.

---

## 6. Execution prerequisites P-1 … P-10

| ID | Prerequisite | Evidence | Result |
|---|---|---|---|
| P-1 | Dedicated lender signer EOA, key never exposed | `0x4B432A562F71929925093896d67B355e1A3d7ceB` (EIP-55 valid). Encrypted Foundry keystore `~/.foundry/keystores/lindfi-demo-lender-signer`, perms `-rw-------`, decrypt check returned the same address, not tracked by git. `LR.signerToLender = 0` before Tx 1. | ✅ |
| P-2 | Signer funded for Tx 2 gas | Funding tx `0xbae4…6867`: 0.002 ETH from `0xE647…a7A3` | ✅ |
| P-3 | NAV/LAS freshness at performedAt | NAV age 339,651 s ≤ 15,552,000; LAS age 476,670 s ≤ 31,536,000; E1–E8 8/8 passed | ✅ |
| P-4 | Read-only pre-checks / empty-registry STOP rule | governance ×3 = Safe; wiring correct; `totalLenders/totalPolicies/totalAnchors = 0/0/0`; repeated immediately before Tx 1 | ✅ |
| P-5 | Safe 2-of-3 available | Acknowledged by Jorge; threshold 2, owners 3; Owner A + B signed Tx 1 and Tx 3 | ✅ |
| P-6 | VERIFIED = demo attestation | Acknowledged by Jorge (see L-1) | ✅ |
| P-7 | Policy published byte-identical to R2 | local = git object `b88f061` = served = bucket: SHA-256 `0xc147…bae2`; 545 bytes; `cmp` identical; ETag = MD5 `e4aa8deb463a9f1daaa7a1c2c6acd067`; no Content-Encoding; destination was 404 before upload | ✅ |
| P-8 | Canonical pinned pipeline run | inputs pinned via `--nav-path`/`--las-path`; verdict ELIGIBLE; assessmentHash `0x097e…c4e7`; reproduced 3× (canonical run, second deterministic run, independent sandbox reconstruction); printed hash = file SHA-256 | ✅ |
| P-9 | performedAt frozen, Tx 2 window derived | `performedAt = 1789570800` frozen before the run and unchanged; `effectiveFrom/Until = 1789567200 / 1821103200` | ✅ |
| P-10 | Tx 3 anchored before validUntil | `anchoredAt 1789586290 < validUntil 1792162800` (margin 2,576,510 s ≈ 29.8 days) | ✅ |

Supporting pre-execution evidence:
- Integrity check at `b88f061` with a clean tree: NAV/LAS/policy SHA-256 matched.
- Sandbox `forge test` 265/265 and `pytest` 37/37 at `b88f061`.
- Local rehearsal of the Safe signing procedure on an anvil replica (chainId 421614, same addresses, nonce 5), including negative tests (wrong order, unadjusted v, replay → `GS026`).

---

## 7. Assessment artifact publication (post-Tx 3)

| Check | Result |
|---|---|
| Local before upload | 1715 bytes, SHA-256 `0x097e…c4e7`, MD5 `2a69e90c233c1365e424f5944726336e` |
| Destination before upload | HTTP 404 (no overwrite) |
| Upload | wrangler 4.131.1, `Resource location: remote`, `Upload complete` |
| Served headers | HTTP 200, `Content-Type: application/json`, `Content-Length: 1715`, no Content-Encoding, ETag `2a69e90c233c1365e424f5944726336e` (= local MD5) |
| Served bytes (identity) | 1715 bytes, SHA-256 `0x097e…c4e7`, MD5 `2a69…336e` |
| `cmp` local vs served | BYTES_IDENTICAL |
| Served with `--compressed` | SHA-256 `0x097e…c4e7` |
| Bucket object (API) | SHA-256 `0x097e…c4e7` |
| Local after upload | SHA-256 `0x097e…c4e7` (unchanged) |

Result: **PASS**. The anchored `assessmentHash` is now publicly verifiable.

---

## 8. Final on-chain state

### 8.1 LenderRegistry

`totalLenders = 1`

`getLender(1)` = `(1, "Lindblad Demo Lender", "US-DE", 2, 0x4B432A562F71929925093896d67B355e1A3d7ceB, true, 1789578611)`

- `isActive(1) = true`
- `signerToLender(0x4B43…7ceB) = 1`

### 8.2 LenderPolicyRegistry

`totalPolicies = 1`

- `getActivePolicyId(1, 0x6d8b…b127) = 1`
- `isPolicyActive(1) = true`

`getPolicy(1)` = `(1, 1, 0x6d8b595792555d4b18e727ffa23c7b8afd9e5fc9cc1ae10905609c1f4711b127, 0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2, 1789567200, 1821103200, true, 0x4B432A562F71929925093896d67B355e1A3d7ceB, 1789579501)`

### 8.3 CollateralPositionAnchor

`totalAnchors = 1`, `historyLength(assetId, 1) = 1`

`latest(assetId, 1)`:

| # | Field | Value |
|---|---|---|
| 1 | assetId | `0x132b640977a078ed75c0a08f32d241ec1c1b023cb8cf51f3985c3065a3c36c25` |
| 2 | assessmentHash | `0x097eb0b6c000a45669558e48cdd7182625affe46f772c9e8e1071b6c77fdc4e7` |
| 3 | navHash | `0x5fc893094562213420b2f34d700042f65edaff3de501a7bdfb53eadcf322bf3d` |
| 4 | policyHash | `0xc1470124db6303aa6216e83cd68861dd26893d3edff201e04ccff4d218ccbae2` |
| 5 | lenderId | `1` |
| 6 | haircutBps | `2000` |
| 7 | maxLTVBps | `5000` |
| 8 | eligibleValue | `18000000000` (18,000.00 USD @ 10⁶) |
| 9 | creditCapacity | `9000000000` (9,000.00 USD @ 10⁶); assessment output, not a commitment |
| 10 | currencyCode | `0x5553440000000000000000000000000000000000000000000000000000000000` |
| 11 | verdict | `0` (ELIGIBLE) |
| — | writer (contract-set) | `0x87039DF20338A876FB3b4dbd787816D42eecbACa` (Safe) |
| 12 | writerRole | `0x1f1d9701f35d6935b4679cc9951a94636b9fbc5ce50a6123e1758063d1461560` |
| 13 | performedAt | `1789570800` |
| — | anchoredAt (contract-set) | `1789586290` |
| 14 | validUntil | `1792162800` |
| 15 | demoAtAnchoring | `true` |

`state(assetId, 1, t)`:

| t | Value |
|---|---|
| `1789570799` (before performedAt) | `0` UNKNOWN |
| `1789570800` (performedAt) | `1` ACTIVE |
| `1792162800` (validUntil) | `1` ACTIVE |
| `1792162801` (after validUntil) | `2` EXPIRED |

### 8.4 Safe

Nonce `7`: 5 consumed by Tx 1, 6 consumed by Tx 3.

---

## 9. Cross-verification

| Link | Evidence | Result |
|---|---|---|
| Anchor → lender | `anchor.lenderId = 1` = lender of Tx 1 (active, VERIFIED demo) | ✅ |
| Lender → policy | `policy(1).lenderId = 1`; `policy(1).publishedBy` = lender 1 signer | ✅ |
| Anchor → policy | `anchor.policyHash = policy(1).policyHash = 0xc147…bae2` | ✅ |
| Policy → public artifact | served `mvp-03b/policy-1-demo-v1.json` SHA-256 = `0xc147…bae2` | ✅ |
| Policy → code baseline | same bytes as `pipeline/fixtures/policy-1-demo-v1.json` @ `b88f061` | ✅ |
| Anchor → assessment | `anchor.assessmentHash` = SHA-256 of canonical file = served `mvp-03b/ASMT-…json` | ✅ |
| Anchor → NAV | `anchor.navHash` = SHA-256 of canonical NAV = served `mvp-02a/NAV-…json` | ✅ |
| NAV → LAS | `NAV.lasReference.lasHash = 0x9c12…d9e8` = SHA-256 of canonical LAS (E4) | ✅ |
| Assessment inside policy window | `1789567200 ≤ performedAt 1789570800 ≤ 1821103200` | ✅ |
| On-chain ordering | lender addedAt `1789578611` < policy recordedAt `1789579501` < anchoredAt `1789586290` | ✅ |
| Anchored before expiry | `anchoredAt 1789586290 < validUntil 1792162800` | ✅ |
| Amounts | 22,500 × (1 − 0.20) = 18,000; × 0.50 = 9,000 (USD, 10⁶ scale) | ✅ |
| Separation of authority | Tx 1/Tx 3 writer = Safe; Tx 2 publishedBy = lender signer; negative controls reverted | ✅ |

---

## 10. Final review (performed on this document)

Checked against the evidence produced during execution:
- Every 32-byte value in this document was matched against the canonical set.
- Calldata SHA-256s and safeTxHashes were recomputed locally from frozen values (EIP-712, Safe 1.4.1).
- Identifiers were recomputed with keccak256.
- Timestamps and derived windows were recomputed arithmetically.

**On-chain and artifact re-verification.** Jorge ran `mvp03b_verify_record.sh` (read-only, SHA-256 `95420c8bdd53ecdeb505436804647472250290ef25e8615a6a86b76ce350dba3`, stored outside the repo in `~/Lindblad/04-lindfi/ops/`) on 2026-09-16. It re-checks every claim in this record:
- chain, Safe version/threshold/nonce and contract wiring;
- lender 1, policy 1, anchor 1 (all 15 fields) and the four `state()` values;
- receipts of all four transactions (status, block, from, to, event topics) and the Tx 2 input SHA-256;
- served bytes of NAV, LAS (**R-LAS**), policy and assessment, plus policy/assessment sizes;
- local canonical files, repo HEAD `b88f061` and a clean tree.

Result:

```
RESULT: 42 passed, 0 failed
MVP-03B RECORD VERIFIED
```

---

## 11. Procedural deviations and operational observations

| ID | Type | Description | Impact |
|---|---|---|---|
| D-1 | Deviation | Owner A's signature for Tx 1 was generated **before** the explicit `GO Tx 1`. | None: one signature cannot execute a 2-of-3 Safe; signature bound to nonce 5 / exact tx. GO was given before Owner B signed. |
| D-2 | Deviation | Tx 2 was **broadcast without an explicit `GO Tx 2`** in the conversation. | None on outcome: on-chain input SHA-256 = canonical `0xa670…a6f7`; state identical to the approved package. Not repeated in Tx 3. |
| O-1 | Observation | Tx 1 and Tx 3 receipts contain an additional Safe log `SafeMultiSigTransaction` (`0x66753cd2…`), not included in the pre-broadcast expected log list. | None: expected for the SafeL2 1.4.1 variant; confirms deployed singleton type. |
| O-2 | Observation | Several guidance commands contained placeholder markers (e.g. `<TX_HASH>`, `PEGAR_…`) that failed in zsh. The expected `DATA` length was stated as 650 instead of the correct 522. | None: failures occurred before any signing/broadcast or on read-only calls; `DATA` was verified by SHA-256. |
| O-3 | Observation | Tx 3 had no procedural deviations (explicit `GO Tx 3`, STOP after simulation). | — |

Operational constraint carried forward: see L-3 (anchor EXPIRED after 2026-10-16 15:00:00 UTC).

---

## 12. Not changed by MVP-03B execution

- Solidity contracts: unchanged (deployed MVP-03A).
- Collateral pipeline behavior: unchanged (`b88f061`).
- `LINDFI_MVP03B_FIRST_LIVE_COLLATERAL_SPEC.md`: unchanged (FROZEN).
- Canonical artifacts (NAV, LAS, policy, assessment): unchanged; R2 objects must not be overwritten.
- Repository: no commit or push during execution. Helper `assemble_safe_sigs.py` (SHA-256 `a29c8f4815e239d516b3f478b799ac51b449f8b40d25ebee976fb58c70232a9c`) lives outside the repo in `~/Lindblad/04-lindfi/ops/`.
- No private keys, seeds or signatures recorded in this document.

---

## 13. B4 — Explorer / Terminal

**Status: PENDING REPOSITORY AUDIT. Outside the MVP-03B protocol closure.**

Preserved design:
- **Lindblad Explorer:** physical verification (LAS / NAV / evidence).
- **LindFi Terminal:** financial usage (collateral, lender policy, eligible value, credit capacity).
- **Bidirectional provenance** between the two.

UI consumers must use the 10⁶ scale and SHA-256-over-served-bytes verification (spec §6), and must render L-1 … L-4.

---

## 14. Closure status

| Item | Status |
|---|---|
| Tx 1 | CLOSED |
| Tx 2 | CLOSED |
| Tx 3 | CLOSED |
| Policy artifact published (P-7) | PASS |
| Assessment artifact published | PASS |
| Cross-verification | PASS |
| R-LAS served-bytes check | PASS |
| Record re-verification (`mvp03b_verify_record.sh`) | PASS — 42/42 |
| B4 | PENDING REPOSITORY AUDIT (out of scope) |
| **MVP-03B** | **Awaiting Jorge's final review and formal `MVP-03B — CLOSED` declaration** |
