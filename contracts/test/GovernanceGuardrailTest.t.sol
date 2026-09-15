// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Constants} from "../src/Constants.sol";
import {GovernanceGuardrailTest} from "../src/GovernanceGuardrailTest.sol";
import {MaliciousGuardrailTest} from "../src/MaliciousGuardrailTest.sol";
import {ConstantsRevertsHelper} from "./ConstantsRevertsHelper.sol";

/// @title GovernanceGuardrailTest_T
/// @notice Validates the deploy guardrail's three cases as specified in
///         DEPLOY_GUARDRAIL_SPEC.md:
///           TEST 1 — HAPPY_PATH: pre-check PASS, deploy, post-check PASS
///           TEST 2 — WRONG_ENV: pre-check FAIL, no broadcast
///           TEST 3 — WRONG_ON_CHAIN: pre-check PASS, deploy adversarial
///                     contract, post-check FAIL
/// @dev Each test simulates the same logic the deploy script runs, in
///      isolation, without needing an RPC. `chainid` is set to
///      Arbitrum Sepolia so Constants.expectedSafeFor returns the
///      canonical Safe.
contract GovernanceGuardrailTest_T is Test {
    address constant SAFE = 0x87039DF20338A876FB3b4dbd787816D42eecbACa;
    address constant WRONG = 0x1111111111111111111111111111111111111111;

    /// @notice Anchor the tests to Arbitrum Sepolia so the resolver
    ///         returns the canonical Safe.
    function setUp() public {
        vm.chainId(Constants.CHAIN_ARBITRUM_SEPOLIA);
    }

    // ------------------------------------------------------------------
    // Sanity: Constants.sol resolves as documented
    // ------------------------------------------------------------------

    function test_ConstantsResolvesArbitrumSepoliaSafe() public {
        assertEq(
            Constants.expectedSafeFor(Constants.CHAIN_ARBITRUM_SEPOLIA),
            SAFE,
            "Constants must return the frozen Sepolia Safe address"
        );
    }

    function test_ConstantsRevertsOnUnsupportedChain() public {
        ConstantsRevertsHelper helper = new ConstantsRevertsHelper();
        vm.expectRevert("Constants: unsupported chain id");
        helper.resolve(1); // Ethereum mainnet — not defined
    }

    function test_ConstantsRevertsOnArbitrumOneUntilDefined() public {
        ConstantsRevertsHelper helper = new ConstantsRevertsHelper();
        vm.expectRevert("Constants: Arbitrum One Safe not yet defined");
        helper.resolve(Constants.CHAIN_ARBITRUM_ONE);
    }

    // ------------------------------------------------------------------
    // TEST 1 — HAPPY_PATH
    // ------------------------------------------------------------------

    /// @notice Full guardrail on a compliant contract: pre-check equal,
    ///         deploy, post-check equal, both PASS.
    function test_HappyPath_PreCheckAndPostCheckBothPass() public {
        // Simulate .env value that the operator claims
        address envSafe = SAFE;
        address canonical = Constants.expectedSafeFor(block.chainid);

        // PRE-CHECK
        assertEq(envSafe, canonical, "PRE-CHECK: env must equal canonical");

        // DEPLOY (compliant dummy)
        GovernanceGuardrailTest deployed =
            new GovernanceGuardrailTest(canonical);

        // POST-CHECK
        assertEq(
            deployed.governance(),
            canonical,
            "POST-CHECK: on-chain governance must equal canonical"
        );
    }

    // ------------------------------------------------------------------
    // TEST 2 — WRONG_ENV
    // ------------------------------------------------------------------

    /// @notice Pre-check fails when the .env value diverges from
    ///         Constants. No deploy is attempted.
    /// @dev We assert the mismatch here; in the deploy script this is
    ///      the branch that calls `revert()` / `vm.stopBroadcast()` and
    ///      exits with code 1 before any broadcast.
    function test_WrongEnv_PreCheckFails_NoDeploy() public {
        address envSafe = WRONG;
        address canonical = Constants.expectedSafeFor(block.chainid);

        assertTrue(
            envSafe != canonical,
            "TEST 2: env deliberately diverges from canonical"
        );

        // In the deploy script, this branch aborts. Here we just
        // assert we would abort — no `new` call happens.
        // The test PASSES precisely because we did NOT deploy.
    }

    // ------------------------------------------------------------------
    // TEST 3 — WRONG_ON_CHAIN
    // ------------------------------------------------------------------

    /// @notice Pre-check passes (env == canonical), but the deployed
    ///         contract's actual on-chain governance diverges from the
    ///         canonical Safe. Post-check MUST fail.
    function test_WrongOnChain_PostCheckFails_AdversarialContract() public {
        address envSafe = SAFE;
        address canonical = Constants.expectedSafeFor(block.chainid);

        // PRE-CHECK passes — env matches canonical
        assertEq(envSafe, canonical, "PRE-CHECK: env must equal canonical");

        // DEPLOY (adversarial dummy). Same constructor signature; the
        // pre-check cannot distinguish this from the compliant one.
        MaliciousGuardrailTest deployed =
            new MaliciousGuardrailTest(canonical);

        // POST-CHECK must FAIL
        address onChainGovernance = deployed.governance();
        assertTrue(
            onChainGovernance != canonical,
            "POST-CHECK: adversarial contract must expose divergence"
        );
        assertEq(
            onChainGovernance,
            deployed.ATTACKER(),
            "Adversarial contract stored ATTACKER instead of canonical"
        );
    }

    // ------------------------------------------------------------------
    // Compliance dummy: constructor rejects zero
    // ------------------------------------------------------------------

    function test_CompliantContract_RejectsZeroGovernance() public {
        vm.expectRevert(GovernanceGuardrailTest.ZeroGovernance.selector);
        new GovernanceGuardrailTest(address(0));
    }

    // ------------------------------------------------------------------
    // Compliance dummy: two-step transfer works (documented interface)
    // ------------------------------------------------------------------

    function test_CompliantContract_TwoStepTransferWorks() public {
        address canonical = Constants.expectedSafeFor(block.chainid);
        GovernanceGuardrailTest deployed =
            new GovernanceGuardrailTest(canonical);

        address newGov = address(0xBEEF);

        // Only current governance can initiate
        vm.prank(canonical);
        deployed.transferGovernance(newGov);
        assertEq(deployed.pendingGovernance(), newGov);
        assertEq(deployed.governance(), canonical); // unchanged — critical

        // Only the pending address can accept
        vm.prank(newGov);
        deployed.acceptGovernance();
        assertEq(deployed.governance(), newGov);
        assertEq(deployed.pendingGovernance(), address(0));
    }
}
