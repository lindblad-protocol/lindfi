# LindFi Contracts

Financial layer of the Lindblad Protocol, deployed on Arbitrum.

**Current stage:** Deploy guardrail validation.

Before writing production contracts (LenderRegistry,
LenderPolicyRegistry, CollateralPositionAnchor), we are validating
the deploy guardrail specified in
`DEPLOY_GUARDRAIL_SPEC.md` end-to-end with a compliant dummy
contract and an adversarial one. Once the guardrail is
validated, the dummies are removed and the pattern is copied
into the three real contracts.

## Layout

```
lindfi/
├── contracts/
│   ├── src/
│   │   ├── Constants.sol                    ← canonical Safe per network
│   │   ├── GovernanceGuardrailTest.sol      ← compliant two-step dummy
│   │   └── MaliciousGuardrailTest.sol       ← adversarial dummy (TEST 3)
│   ├── test/
│   │   └── GovernanceGuardrailTest.t.sol    ← 3 tests + sanity checks
│   └── script/
│       └── DeployGuardrailTest.s.sol        ← pre-check + banner + deploy + post-check
├── foundry.toml
├── .env.example
└── .gitignore
```

## Guardrail validation plan

| Stage | What runs | Where |
|-------|-----------|-------|
| 1 | `forge test` — HAPPY_PATH, WRONG_ENV, WRONG_ON_CHAIN | local |
| 2 | Real deploy of the compliant dummy | Arbitrum Sepolia |
| 3 | Remove dummies, copy pattern into MVP-03A contracts | this repo |

See:
- `MVP03A_GOVERNANCE_AMENDMENT_01.md`
- `DEPLOY_GUARDRAIL_SPEC.md`

## Quick start (local tests)

```bash
cp .env.example .env
# Fill in DEPLOYER_PRIVATE_KEY and other values

forge install foundry-rs/forge-std --no-commit    # first time
forge build
forge test -vv
```

Expected: all tests pass. If `test_HappyPath...` fails, the
guardrail pattern needs debugging before proceeding.

## Real deploy (Arbitrum Sepolia)

```bash
# .env must be filled with DEPLOYER_PRIVATE_KEY funded on Sepolia
forge script contracts/script/DeployGuardrailTest.s.sol \
    --rpc-url $ARBITRUM_SEPOLIA_RPC \
    --broadcast
```

Expected output: banner with `PRE-CHECK: PASS`, deploy tx,
banner with `POST-CHECK: PASS`, deployed address printed.
