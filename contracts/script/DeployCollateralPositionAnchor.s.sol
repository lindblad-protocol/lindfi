// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Constants} from "../src/Constants.sol";
import {CollateralPositionAnchor, ILenderRegistry, ILenderPolicyRegistry} from "../src/CollateralPositionAnchor.sol";

/// @title DeployCollateralPositionAnchor
/// @notice Deploys CollateralPositionAnchor using the two-part
///         deployment guardrail described in DEPLOY_GUARDRAIL_SPEC.md,
///         extended with cross-dependency triangulation over both
///         LenderRegistry and LenderPolicyRegistry.
///
///         Pre-broadcast:
///           - .env EXPECTED_SAFE_ADDRESS == Constants.expectedSafeFor(chainid)
///           - LENDER_REGISTRY_ADDRESS non-zero and LR.governance() == canonical
///           - LENDER_POLICY_REGISTRY_ADDRESS non-zero and LPR.governance() == canonical
///           - LPR.lenderRegistry() == LENDER_REGISTRY_ADDRESS
///
///         Broadcast:
///           - Constructor receives canonicalSafe, LR_address, LPR_address.
///             The contract independently enforces internal consistency
///             between the supplied governance, LenderRegistry, and
///             LenderPolicyRegistry. Canonical Safe enforcement remains
///             the responsibility of this deploy script and
///             Constants.expectedSafeFor(block.chainid).
///
///         Post-broadcast:
///           - deployed.governance() == canonical
///           - deployed.lenderRegistry() == LENDER_REGISTRY_ADDRESS
///           - deployed.lenderPolicyRegistry() == LENDER_POLICY_REGISTRY_ADDRESS
contract DeployCollateralPositionAnchor is Script {
    function run() external returns (CollateralPositionAnchor deployed) {
        // Load and check first. Helpers keep the run() stack shallow.
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address canonicalSafe = Constants.expectedSafeFor(block.chainid);
        address envLenderRegistry = vm.envAddress("LENDER_REGISTRY_ADDRESS");
        address envPolicyRegistry = vm.envAddress("LENDER_POLICY_REGISTRY_ADDRESS");

        _preCheck(canonicalSafe, envLenderRegistry, envPolicyRegistry, deployerKey);

        // Broadcast
        vm.startBroadcast(deployerKey);
        deployed = new CollateralPositionAnchor(canonicalSafe, envLenderRegistry, envPolicyRegistry);
        vm.stopBroadcast();

        _postCheck(deployed, canonicalSafe, envLenderRegistry, envPolicyRegistry);
    }

    /// @dev Pre-broadcast validation and banner. Reverts before broadcast
    ///      on any failure. Extracted to keep run()'s stack shallow.
    function _preCheck(address canonicalSafe, address envLenderRegistry, address envPolicyRegistry, uint256 deployerKey)
        private
        view
    {
        address envSafe = vm.envAddress("EXPECTED_SAFE_ADDRESS");

        console2.log("=====================================================");
        console2.log("Lindblad Contract Deployment");
        console2.log("-----------------------------------------------------");
        console2.log("Contract:                CollateralPositionAnchor");
        console2.log("Chain ID:                ", block.chainid);
        console2.log("Deployer:                ", vm.addr(deployerKey));
        console2.log("env Safe:                ", envSafe);
        console2.log("Canonical Safe:          ", canonicalSafe);
        console2.log("env LenderRegistry:      ", envLenderRegistry);
        console2.log("env PolicyRegistry:      ", envPolicyRegistry);

        if (envSafe != canonicalSafe) {
            console2.log("PRE-CHECK (safe):        FAIL");
            console2.log("ABORT: .env EXPECTED_SAFE_ADDRESS != canonical");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: env != canonical");
        }
        if (envLenderRegistry == address(0)) {
            console2.log("PRE-CHECK (LR):          FAIL");
            console2.log("ABORT: LENDER_REGISTRY_ADDRESS is zero");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LENDER_REGISTRY_ADDRESS is zero");
        }
        if (envPolicyRegistry == address(0)) {
            console2.log("PRE-CHECK (LPR):         FAIL");
            console2.log("ABORT: LENDER_POLICY_REGISTRY_ADDRESS is zero");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LENDER_POLICY_REGISTRY_ADDRESS is zero");
        }

        _preCheckDependencies(canonicalSafe, envLenderRegistry, envPolicyRegistry);

        console2.log("PRE-CHECK (safe):        PASS");
        console2.log("PRE-CHECK (LR):          PASS");
        console2.log("PRE-CHECK (LPR):         PASS");
        console2.log("PRE-CHECK (LR gov):      PASS");
        console2.log("PRE-CHECK (LPR gov):     PASS");
        console2.log("PRE-CHECK (LPR reg):     PASS");
        console2.log("-----------------------------------------------------");
        console2.log("Proceeding to broadcast.");
        console2.log("=====================================================");
    }

    /// @dev Observability checks against the two dependency contracts.
    ///      Their on-chain enforcement in the anchor's constructor is
    ///      the authoritative guard; these checks fail-fast before
    ///      broadcast for a better developer experience.
    function _preCheckDependencies(address canonicalSafe, address envLenderRegistry, address envPolicyRegistry)
        private
        view
    {
        address lrGov = ILenderRegistry(envLenderRegistry).governance();
        console2.log("LR governance:           ", lrGov);
        if (lrGov != canonicalSafe) {
            console2.log("PRE-CHECK (LR gov):      FAIL");
            console2.log("ABORT: LenderRegistry.governance() != canonical");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LR governance != canonical");
        }

        address lprGov = ILenderPolicyRegistry(envPolicyRegistry).governance();
        console2.log("LPR governance:          ", lprGov);
        if (lprGov != canonicalSafe) {
            console2.log("PRE-CHECK (LPR gov):     FAIL");
            console2.log("ABORT: LenderPolicyRegistry.governance() != canonical");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LPR governance != canonical");
        }

        address lprLR = ILenderPolicyRegistry(envPolicyRegistry).lenderRegistry();
        console2.log("LPR.lenderRegistry():    ", lprLR);
        if (lprLR != envLenderRegistry) {
            console2.log("PRE-CHECK (LPR reg):     FAIL");
            console2.log("ABORT: LPR.lenderRegistry() != LENDER_REGISTRY_ADDRESS");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LPR.lenderRegistry() != LR");
        }
    }

    /// @dev Post-broadcast verification. Reads the deployed contract's
    ///      on-chain state and confirms it matches expected values.
    ///      Reverts on any mismatch.
    function _postCheck(
        CollateralPositionAnchor deployed,
        address canonicalSafe,
        address envLenderRegistry,
        address envPolicyRegistry
    ) private view {
        address onChainGovernance = deployed.governance();
        address onChainLR = deployed.lenderRegistry();
        address onChainLPR = deployed.lenderPolicyRegistry();

        console2.log("");
        console2.log("=====================================================");
        console2.log("POST-BROADCAST CHECK");
        console2.log("-----------------------------------------------------");
        console2.log("Deployed at:                ", address(deployed));
        console2.log("governance():               ", onChainGovernance);
        console2.log("lenderRegistry():           ", onChainLR);
        console2.log("lenderPolicyRegistry():     ", onChainLPR);
        console2.log("Canonical Safe:             ", canonicalSafe);

        if (onChainGovernance != canonicalSafe) {
            console2.log("POST-CHECK (gov):           FAIL");
            console2.log("ALERT: on-chain governance != canonical.");
            console2.log("=====================================================");
            revert("POST-CHECK failed: governance mismatch");
        }
        if (onChainLR != envLenderRegistry) {
            console2.log("POST-CHECK (LR):            FAIL");
            console2.log("ALERT: on-chain lenderRegistry mismatch.");
            console2.log("=====================================================");
            revert("POST-CHECK failed: lenderRegistry mismatch");
        }
        if (onChainLPR != envPolicyRegistry) {
            console2.log("POST-CHECK (LPR):           FAIL");
            console2.log("ALERT: on-chain lenderPolicyRegistry mismatch.");
            console2.log("=====================================================");
            revert("POST-CHECK failed: lenderPolicyRegistry mismatch");
        }

        console2.log("POST-CHECK (gov):           PASS");
        console2.log("POST-CHECK (LR):            PASS");
        console2.log("POST-CHECK (LPR):           PASS");
        console2.log("-----------------------------------------------------");
        console2.log("Deployment complete and verified.");
        console2.log("=====================================================");
    }
}
