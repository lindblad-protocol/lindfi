# LindFi

**Financial layer for verified physical assets on Arbitrum.**

LindFi is the financial coordination layer of the Lindblad Protocol.
It exists so that physical assets whose real-world state has been
cryptographically verified can be used as programmable collateral
on-chain, under lender-defined policy.

---

## How it fits together

```
                PHYSICAL WORLD
                      │
                      ▼
                  LINDBLAD
       Physical verification and assurance
       (hardware-rooted attestations of
        physical asset state and events)
                      │
                      ▼
                     LAS
        Lindblad Asset Standard — validation
      and classification of attested physical
                  asset state
                      │
                      ▼
                 Physical NAV
                      │
                      ▼
                   LINDFI
        Collateral and financial coordination
     (lender registry, lender policy, collateral
              position anchoring)
                      │
                      ▼
                  ARBITRUM
    Programmable settlement and liquidity rail
```

- **Lindblad** verifies physical assets. It produces hardware-rooted
  cryptographic attestations of physical asset events.
- **LAS (Lindblad Asset Standard)** takes those attestations and
  turns them into a validated, classified assertion about the
  asset's state. Physical NAV is derived from LAS-validated state,
  not directly from raw attestations.
- **LindFi** makes verified physical value financially usable. It
  translates Physical NAV into lender-defined collateral capacity,
  under the policies each lender publishes on-chain.
- **Arbitrum** provides the programmable settlement and liquidity
  rail on which LindFi runs.

## Problem

Physical inventory contains real economic value, but using it as
digital collateral has historically required trusting off-chain
records about the underlying asset. LindFi is being designed around
verified physical state and Physical NAV rather than around token
ownership alone. The physical verification is produced by Lindblad;
LindFi's job is to make that verification usable inside a financial
protocol.

## Architecture

Three layers, each with a separate responsibility.

**Lindblad — physical verification and assurance layer.** Produces
hardware-rooted cryptographic attestations of physical asset events.
Above the attestation layer, the Lindblad Asset Standard (LAS)
validates and classifies attested state and is the layer from which
Physical NAV is derived. The internal mechanisms that produce
attestations and drive LAS validation (device-level security, key
derivation, physical evidence pipelines, proprietary validation
algorithms) are not part of this repository.

**LindFi — collateral policy and financial coordination layer.**
This is the layer this repository contains. It defines who can act
as a recognized lender, what policies each lender publishes, and how
verified physical value is anchored into a collateral position.

**Arbitrum — programmable settlement and liquidity layer.** LindFi
contracts deploy on Arbitrum and inherit its execution, settlement,
and liquidity characteristics.

## Scope of this repository

**Open-source, in this repository (Apache License 2.0):**

- LindFi smart contracts
- Lender and collateral interfaces
- Deployment guardrails
- Test suite and validation fixtures
- Public deployment records
- Integration documentation

**Not part of this repository:**

- Lindblad production firmware
- Proprietary physical-attestation implementation
- Hardware security internals
- Proprietary LAS validation logic and classification pipelines
- Private operational infrastructure

Apache License 2.0 applies to the contents of this repository. It
does not extend to any Lindblad component that is not published here.

## Current status

**LindFi MVP-03A — implementation stage.**

Completed:

- Governance deployment guardrail
- 8/8 Foundry tests passing
- Arbitrum Sepolia end-to-end validation
- Pre-broadcast governance verification
- Constructor governance assignment
- On-chain post-deployment verification

Next:

- LenderRegistry
- LenderPolicyRegistry
- CollateralPositionAnchor

MVP-03A is not complete. This README will be updated as each of the
three contracts above lands.

## Governance Deployment Guardrail — VALIDATED

Every governance-gated LindFi contract must pass a two-part
verification at deploy time. Both parts are enforced by the deploy
script:

1. **Pre-broadcast check.** The intended governance address is
   verified against the canonical Safe address defined in
   `Constants.sol` for the target chain. If the value in the
   deployer's configuration diverges from the canonical value, the
   deploy aborts before any transaction is broadcast.
2. **Post-broadcast check.** After the deploy transaction confirms,
   the freshly deployed contract's `governance()` function is called
   on-chain and its return value is compared against the canonical
   Safe. If they diverge, post-deployment verification fails and the
   deployment batch stops.

The guardrail was validated end-to-end on Arbitrum Sepolia against
both a compliant and an adversarial contract.

| Field | Value |
|---|---|
| Network | Arbitrum Sepolia |
| Chain ID | 421614 |
| Validation deployment | [`0x155931f63859edF2c426080BBf70e10db5406bf1`](https://sepolia.arbiscan.io/address/0x155931f63859edF2c426080BBf70e10db5406bf1) |
| Deployment transaction | [`0xeb2570d284fee9d97bc465bc3104d4f04ab49b590e88e70a6416ca407a837067`](https://sepolia.arbiscan.io/tx/0xeb2570d284fee9d97bc465bc3104d4f04ab49b590e88e70a6416ca407a837067) |
| Block | 309206489 |

Anyone can verify the guardrail's on-chain state independently:

```bash
cast call 0x155931f63859edF2c426080BBf70e10db5406bf1 \
    "governance()(address)" \
    --rpc-url https://sepolia-rollup.arbitrum.io/rpc
```

The returned address is the canonical Safe declared in
`contracts/src/Constants.sol` for chain 421614.

## Repository structure

```
lindfi/
├── contracts/
│   ├── script/
│   │   └── DeployGuardrailTest.s.sol       # deploy script with pre-check + banner + post-check
│   ├── src/
│   │   └── Constants.sol                   # canonical governance Safe per network
│   └── test/
│       ├── GovernanceGuardrailTest.t.sol   # 8 tests covering the guardrail
│       └── fixtures/
│           ├── ConstantsRevertsHelper.sol
│           ├── GovernanceGuardrailTest.sol
│           └── MaliciousGuardrailTest.sol
├── foundry.toml
├── foundry.lock
├── .env.example
├── LICENSE
├── NOTICE
└── README.md
```

`contracts/src/` currently contains only `Constants.sol`. The three
MVP-03A production contracts will land there as they are written.

`contracts/test/fixtures/` contains validation and test scaffolding
only. Its contents are not part of the LindFi production protocol.

## Quickstart

**Never commit `.env`, private keys, keystores, or production
credentials to this repository or any fork of it. Use a dedicated
testnet deployer for Sepolia validation — not a wallet that holds
real value or mainnet governance rights.**

```bash
git clone --recursive https://github.com/lindblad-protocol/lindfi
cd lindfi
cp .env.example .env
# Fill in the values required by .env.example

forge build
forge test -vv
```

Expected: 8/8 tests pass.

To reproduce the guardrail deploy on Arbitrum Sepolia (requires a
funded deployer key in `.env`):

```bash
forge script contracts/script/DeployGuardrailTest.s.sol:DeployGuardrailTest \
    --rpc-url $ARBITRUM_SEPOLIA_RPC \
    --broadcast
```

Expected output: banner with `PRE-CHECK: PASS`, deploy transaction,
banner with `POST-CHECK: PASS`, deployed address printed.

## Buildathon context

Portions of the Lindblad Protocol and its LindFi vertical predate
the Arbitrum Open House Singapore Online Buildathon (September 14 –
October 4, 2026). The Physical Attestation work, LAS, and prior
Arbitrum deployments were built before the Buildathon window opened.

The following was produced during the Buildathon window and is
recorded here as such: this repository itself, the governance
deployment guardrail, the guardrail test suite, and the MVP-03A
implementation work that will land in subsequent commits.

This README is factual. It does not describe LindFi as
production-ready. It does not claim real loans or real assets
backing on-chain positions. Test deployments are labeled as such.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
