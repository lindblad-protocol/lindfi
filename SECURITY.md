# Security Policy

Lindblad Protocol Inc. takes security reports regarding LindFi
seriously and encourages responsible disclosure of vulnerabilities
that could affect the integrity, authorization, accounting, or
behavior of the LindFi protocol.

## Scope

This policy covers the LindFi code, deployment tooling, and related
materials published in this repository.

**In scope:**

- LindFi smart contracts published in this repository
- Deployment scripts and governance guardrails
- Contract authorization and access-control issues
- Collateral-policy logic and lender-facing logic once implemented
- Any vulnerability that could affect the integrity, authorization,
  accounting, or expected behavior of the protocol

**Out of scope for this repository:**

- Lindblad production firmware
- Physical Attestation implementation
- Hardware security internals
- LAS proprietary infrastructure
- Private Lindblad operational infrastructure

Reports concerning components outside the scope of this repository
are not handled through this policy.

## Supported Versions

LindFi is under active development and has not yet reached a
production release. Security fixes currently target the latest
version of the `master` branch of this repository.

Formal version-support guarantees do not exist yet and will only be
introduced once LindFi reaches a stable release.

## Reporting a Vulnerability

Please do not report security vulnerabilities through public
GitHub Issues, pull requests, or public discussion channels.

Use GitHub's private vulnerability reporting feature for this
repository:

**Security → Advisories → Report a vulnerability**

This allows vulnerability details to be shared privately with the
LindFi maintainers.

## What to Include

Where possible, please include:

- affected component (contract name, script, or file)
- description of the vulnerability
- reproduction steps or a proof of concept
- potential impact
- relevant transaction hash, contract address, or network
- suggested remediation, if you have one

Please do **not** include in your report:

- private keys
- seed phrases
- credentials or access tokens (yours or third-party)
- unnecessary personal data

If a vulnerability's reproduction inherently requires such
material, describe how it is derived rather than attaching it.

## Responsible Disclosure

We ask that reporters:

- give the maintainers a reasonable window to investigate and
  remediate before any public disclosure
- avoid exploiting a vulnerability beyond what is necessary to
  demonstrate it
- avoid accessing, modifying, or destroying data that does not
  belong to them
- avoid public disclosure before coordination when the issue could
  put users, assets, or infrastructure at risk

## Response

We will make a reasonable effort to acknowledge, investigate, and
coordinate valid security reports as promptly as is practical for
the stage of development LindFi is currently in.

No specific response time is guaranteed at this stage, and no bug
bounty program is offered for this repository.

## Development and Testnet Notice

LindFi is currently under active development.

Deployments referenced in this repository are **testnet validation
deployments** unless a specific deployment is explicitly labeled
otherwise. The repository should not be interpreted, at this stage,
as a production-ready financial protocol.

Contributors, integrators, and reviewers should treat any address,
transaction, or state referenced here accordingly.
