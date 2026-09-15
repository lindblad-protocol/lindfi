# LindFi — Protocol Architecture

This document describes how LindFi is put together and how it
relates to the other layers of the Lindblad Protocol. It is a
conceptual reference intended for developers, integrators,
lender-side readers, and Buildathon reviewers.

The [README](../README.md) is a two-minute overview; this
document is the deeper technical explanation.

Interfaces, storage layout, events, and permissions are not
described here at contract-signature level. The MVP-03A contracts
(`LenderRegistry`, `LenderPolicyRegistry`,
`CollateralPositionAnchor`) are under active implementation.
When each contract lands, this document is updated with a
follow-up commit that adds only the interfaces and behavior that
actually exist in the merged code. Solidity NatSpec on the
contracts themselves is the source of truth for contract-level
detail.

---

## 1. System boundary

```
                     PHYSICAL ASSET
                            │
                            ▼
                       LINDBLAD
             Physical Attestation
     (hardware-rooted attestations of
      physical asset state and events)
                            │
                            ▼
                          LAS
        Lindblad Assurance Standard — evaluates
        physical evidence against the
        applicable assurance standard
                            │
                            ▼
                     Physical NAV
     valuation signal derived from LAS-
       verified physical state
                            │
                            ▼
                        LINDFI
                            │
             ┌──────────────┼──────────────┐
             ▼              ▼              ▼
       LenderRegistry  LenderPolicy   CollateralPosition
                       Registry       Anchor
                            │
                            ▼
                       ARBITRUM
         Settlement, liquidity, integrations
```

Each layer has a distinct responsibility and none of the layers
above LindFi is re-implemented inside LindFi.

- **Lindblad** provides cryptographically verifiable attestations
  of physical asset state and events. It does not extend
  eligibility judgments or policy decisions.
- **LAS (Lindblad Assurance Standard)** evaluates the evidence produced
  by the attestation layer against the applicable assurance
  standard and produces a validated, classified assertion about
  the asset.
- **Physical NAV** represents a financial valuation signal
  associated with LAS-verified physical state. LAS provides the
  verified physical-state input; valuation may also depend on
  applicable market data and valuation methodology.
- **LindFi** consumes Physical NAV and lender policy and
  coordinates the resulting on-chain financial state.
- **Arbitrum** provides execution, settlement, and integrations.

LindFi does not independently prove that a physical asset exists.
That is Lindblad's responsibility. LindFi's job is to make that
verification financially usable under lender-defined policy.

## 2. Layer responsibilities

### 2.1 Lindblad — physical verification

Lindblad produces hardware-rooted cryptographic attestations of
physical asset events. Its role in the stack is to establish
provenance and integrity for physical facts.

Lindblad does not decide whether an asset qualifies as collateral,
what a lender should accept, or how any given policy should be
priced.

### 2.2 LAS — assurance and verification

LAS takes attestations from Lindblad and evaluates them against
the applicable assurance standard for the asset class. Its output
is a validated, classified statement about the asset's condition.

LAS does not decide lender eligibility. A LAS-verified asset can
still be ineligible under a specific lender's policy, and the
inverse is not possible: a policy cannot upgrade an unverified
asset into a verified one.

### 2.3 Physical NAV — valuation signal

Physical NAV represents a financial valuation signal associated
with LAS-verified physical state. LAS provides the verified
physical-state input; valuation may also depend on applicable
market data and valuation methodology.

Physical NAV is a signal, not a policy: it expresses how the
verified state is being valued, not who may borrow against it or
under what terms.

### 2.4 LindFi — collateral and financial coordination

LindFi is the layer this repository implements. It is planned as
three contracts in MVP-03A:

**LenderRegistry**

Records which lenders are recognized by the protocol and their
authorization status. Governance-controlled at the recognition
level. Individual lender business logic is not stored here — the
registry answers the question "is this address a recognized
lender?" and nothing more.

**LenderPolicyRegistry**

Records lender-defined collateral requirements and policy
parameters. Policies remain attributable to the lender that
publishes them. LindFi does not override lender policy: a lender
that requires a stricter condition than the LAS baseline gets to
enforce that stricter condition.

**CollateralPositionAnchor**

Anchors the resulting collateral position on-chain. Links a
LAS-verified asset condition and its Physical NAV signal to the
relevant lender policy, producing an auditable on-chain state
that reflects the collateral relationship.

The exact interfaces, storage layout, events, permissions, and
formulas of these three contracts are described in the frozen
MVP-03A design and are not repeated here at signature level.

### 2.5 Arbitrum — settlement and liquidity

Arbitrum is the execution and settlement rail on which LindFi
runs. It provides programmability, integrations, and liquidity
context. Arbitrum does not verify physical assets. Physical
verification belongs to Lindblad and LAS.

## 3. From physical asset to collateral capacity

The flow from a physical asset to a usable financial position
crosses several layers, each of which contributes something
different.

```
Physical asset
      │
      ▼
Lindblad Physical Attestation
      │  (cryptographic provenance and integrity)
      ▼
LAS validation
      │  (assurance evaluation against a standard)
      ▼
Physical NAV
      │  (valuation signal for the verified state)
      ▼
Lender Policy
      │  (haircuts, eligibility rules,
      │   custody requirements, LTV, etc. —
      │   defined by the lender, not by LindFi)
      ▼
Eligible Collateral Value
      │
      ▼
Credit Capacity
      │
      ▼
On-chain financial state
      (anchored by LindFi on Arbitrum)
```

Two properties of this flow matter:

**LAS verification is not lender eligibility.** LAS answers
whether the asset is verified against its assurance standard.
Eligibility is a separate question, answered by lender policy.
An asset can be LAS-verified and still be ineligible under a
specific lender's policy. Conversely, no lender policy can
declare an unverified asset eligible — the verified state has to
be there first.

**Haircuts, LTV, and eligibility rules are lender-defined.** They
are not universal LindFi constants. Two lenders may accept the
same LAS-verified asset with different eligibility rules and
different credit capacity. LindFi coordinates and anchors the
resulting positions; it does not impose a single set of financial
parameters across lenders.

## 4. Custody

Custody is a condition of the assurance state, not a universal
requirement.

An asset that is LAS-verified may be in any of several custody
conditions. Possible states include (illustrative, not
exhaustive):

- **Owner-site custody** — the asset remains under the owner's
  control at a known location.
- **Independent custody** — the asset is held by an independent
  third party (warehouse, warrantera, custodian).
- **Warehouse or warrantera custody** — a regulated custody
  arrangement typical of commodities.

LAS reports the actual custody condition. It does not require any
one of them to be present.

A lender policy may independently require a specific custody
condition for its collateral eligibility. When it does, the
result is:

```
LAS:           Asset VERIFIED
               Custody = OWNER_SITE

Lender policy: Independent custody required

Result:        LAS status unchanged (VERIFIED).
               Ineligible under this lender's policy.
```

The same asset may be eligible under a lender whose policy
accepts owner-site custody, and ineligible under a lender whose
policy does not. Both outcomes are correct under their respective
policies. This separation between assurance and eligibility is
fundamental to the model.

## 5. Trust model

LindFi does not replace, and does not attempt to replace:

- laboratories that certify material properties
- custodians, warehouses, or warranteras
- insurers
- legal ownership records
- external attestors or regulators

These sources contribute evidence to the assurance process. The
Lindblad physical-attestation layer establishes cryptographic
provenance and integrity for physical events, so that the
evidence flowing into LAS carries verifiable authorship, time,
and place. Provenance and integrity are not the same as legal
title, absence of liens, purity guarantees, or custody
correctness. Those come from the respective external sources.

In practical terms:

- Lindblad's attestations establish *what happened, where, when,
  and from which device*, not *who owns it legally* or *what its
  economic quality is*.
- LAS's assurance evaluation integrates external evidence
  (laboratory results, custody records, ownership documents,
  insurance status, etc.) into a validated statement about the
  asset.
- Lender policy decides which of those validated statements
  qualify as acceptable collateral, and on what terms.
- LindFi anchors the resulting relationship on-chain and
  coordinates the financial state.

Cryptography does not, by itself, prove legal title, absence of
liens, purity, or custody. The trust model is a composition, not
a substitution.

## 6. Governance

LindFi contracts are governance-gated. The governance model is
public and documented in code:

- **Canonical governance per supported network.** The expected
  governance address for each supported network is declared in
  `contracts/src/Constants.sol`. Each network's canonical
  governance is defined explicitly; the governance on one
  network is not assumed to equal the governance on another.
- **Governance supplied at construction.** New governance-gated
  LindFi contracts receive their governance address as a
  constructor argument.
- **Pre-broadcast verification.** Before any deploy is
  broadcast, the intended governance is compared against the
  canonical value from `Constants.sol`. A mismatch aborts the
  deploy before any transaction is sent.
- **Post-deployment `governance()` verification.** After a
  deploy transaction confirms, the deployed contract's
  `governance()` return value is compared on-chain against the
  same canonical value.
- **Fail-fast deployment guardrail.** Each contract is verified
  independently. If any check fails, subsequent contracts in the
  same batch are not deployed. Deployment is fail-fast, not
  atomic — each on-chain transaction remains independent.

The public deployment manifest at
[`deployments/arbitrum-sepolia.json`](../deployments/arbitrum-sepolia.json)
records the guardrail validation deployment on Arbitrum Sepolia.
Anyone can independently verify governance on-chain.

Details that are not part of the public governance model —
individual Safe owners, recovery procedures, key-management
practices, internal operational history — are not published in
this repository and are out of scope for this document.

## 7. Arbitrum

LindFi deploys on Arbitrum and inherits its execution, settlement,
and liquidity properties.

Arbitrum's role in the stack is:

- **Execution rail.** Contract logic runs on Arbitrum's EVM
  execution.
- **Programmable financial state.** On-chain state (positions,
  policies, registry entries) is programmable and composable
  with other Arbitrum protocols.
- **Settlement and integration layer.** Interaction with
  liquidity, stablecoins, and other on-chain protocols happens
  through Arbitrum.

Arbitrum does not verify physical assets. Physical verification
belongs to Lindblad and LAS. This distinction matters when
evaluating trust assumptions: an on-chain state on Arbitrum is
only as trustworthy as the off-chain assurance layer that
produced its inputs.

## 8. Public / proprietary boundary

This document describes the public LindFi integration
architecture at the conceptual level. It intentionally does not
describe:

- production PUF implementation
- Chua-related implementation and parameters
- device key derivation
- production firmware
- anti-tamper mechanisms
- LAS proprietary validation algorithms and classification
  pipelines
- detailed physical evidence pipelines
- private node, backend, or operational infrastructure

Those components exist and are part of the Lindblad system; they
are not part of this repository and are not covered by the
Apache 2.0 license that applies here.

## 9. Current status

### Validated

- Governance deployment guardrail
- 8/8 Foundry tests
- Arbitrum Sepolia end-to-end validation of the guardrail
- Public deployment manifest for the guardrail validation
  deployment

### Under implementation (MVP-03A)

- `LenderRegistry`
- `LenderPolicyRegistry`
- `CollateralPositionAnchor`

MVP-03A is not complete. No production release exists. No real
loans or real collateral positions currently exist on-chain
against this codebase. Deployments referenced in this repository
are testnet validation deployments unless a specific deployment is
labeled otherwise.

## 10. Buildathon transparency

Parts of the Lindblad Protocol and its LindFi vertical predate the
Arbitrum Open House Singapore Online Buildathon (September 14 –
October 4, 2026). The physical-attestation work, LAS, and prior
Arbitrum deployments were built before the Buildathon window
opened. This document reflects that pre-existing architecture at
the conceptual level.

Work produced during the Buildathon window is recorded in this
repository as such. This includes the repository itself, the
governance deployment guardrail, the guardrail test suite, the
public deployment manifest, this architecture document, and the
MVP-03A implementation work that will land in subsequent commits.

## 11. Where to look next

- [`README.md`](../README.md) — project overview
- [`SECURITY.md`](../SECURITY.md) — security policy
- [`contracts/src/Constants.sol`](../contracts/src/Constants.sol) —
  canonical governance per network
- [`contracts/script/DeployGuardrailTest.s.sol`](../contracts/script/DeployGuardrailTest.s.sol) —
  reference deployment script implementing the guardrail
- [`deployments/arbitrum-sepolia.json`](../deployments/arbitrum-sepolia.json) —
  public deployment record

As MVP-03A contracts land, sections of this document that
currently describe planned responsibilities at the conceptual
level will be extended to reference the interfaces and NatSpec of
the merged code.
