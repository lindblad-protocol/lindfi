// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Constants} from "../src/Constants.sol";
import {LenderPolicyRegistry, ILenderRegistry} from "../src/LenderPolicyRegistry.sol";

/// @title DeployLenderPolicyRegistry
/// @notice Deploys LenderPolicyRegistry using the two-part deployment
///         guardrail described in DEPLOY_GUARDRAIL_SPEC.md, extended
///         with cross-registry pairing:
///           - pre-broadcast: .env EXPECTED_SAFE_ADDRESS ==
///             Constants.expectedSafeFor(block.chainid)
///           - pre-broadcast: LENDER_REGISTRY_ADDRESS is non-zero and
///             its governance() equals the canonical Safe (observability)
///           - constructor: contract receives canonical governance and
///             the LenderRegistry address; the contract itself reverts
///             on any cross-registry governance mismatch
///           - post-broadcast: deployed.governance() == canonical AND
///             deployed.lenderRegistry() == expected LenderRegistry
///         Fail-fast: aborts before broadcast on pre-check failure;
///         reverts after broadcast on post-check failure.
contract DeployLenderPolicyRegistry is Script {
    function run() external returns (LenderPolicyRegistry deployed) {
        // ─── 1. Load values ─────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address envSafe = vm.envAddress("EXPECTED_SAFE_ADDRESS");
        address envLenderRegistry = vm.envAddress("LENDER_REGISTRY_ADDRESS");
        address canonicalSafe = Constants.expectedSafeFor(block.chainid);

        // ─── 2. Pre-broadcast checks ─────────────────────────────
        bool preCheckSafePass = (envSafe == canonicalSafe);
        bool preCheckRegistryNonZero = (envLenderRegistry != address(0));

        // Read the LenderRegistry's governance for observability. The
        // constructor of LenderPolicyRegistry enforces this equality
        // on-chain and reverts on mismatch.
        address registryGovernance = address(0);
        if (preCheckRegistryNonZero) {
            registryGovernance = ILenderRegistry(envLenderRegistry).governance();
        }
        bool preCheckRegistryGovernance = (registryGovernance == canonicalSafe);

        // ─── 3. Banner ──────────────────────────────────────────
        console2.log("=====================================================");
        console2.log("Lindblad Contract Deployment");
        console2.log("-----------------------------------------------------");
        console2.log("Contract:              LenderPolicyRegistry");
        console2.log("Network:               Arbitrum Sepolia (or configured)");
        console2.log("Chain ID:              ", block.chainid);
        console2.log("Deployer:              ", vm.addr(deployerKey));
        console2.log("env Safe:              ", envSafe);
        console2.log("Canonical Safe:        ", canonicalSafe);
        console2.log("env LenderRegistry:    ", envLenderRegistry);
        console2.log("Registry governance:   ", registryGovernance);

        if (!preCheckSafePass) {
            console2.log("PRE-CHECK (safe):      FAIL");
            console2.log("-----------------------------------------------------");
            console2.log("ABORT: .env EXPECTED_SAFE_ADDRESS does not match");
            console2.log("       Constants.expectedSafeFor(chainid).");
            console2.log("       No broadcast will occur.");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: env != canonical");
        }
        if (!preCheckRegistryNonZero) {
            console2.log("PRE-CHECK (reg):       FAIL");
            console2.log("-----------------------------------------------------");
            console2.log("ABORT: LENDER_REGISTRY_ADDRESS is zero.");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LENDER_REGISTRY_ADDRESS is zero");
        }
        if (!preCheckRegistryGovernance) {
            console2.log("PRE-CHECK (reg gov):   FAIL");
            console2.log("-----------------------------------------------------");
            console2.log("ABORT: LenderRegistry.governance() does not match");
            console2.log("       the canonical Safe. Cross-registry pairing");
            console2.log("       would fail on-chain in the constructor.");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: registry governance != canonical");
        }

        console2.log("PRE-CHECK (safe):      PASS");
        console2.log("PRE-CHECK (reg):       PASS");
        console2.log("PRE-CHECK (reg gov):   PASS");
        console2.log("-----------------------------------------------------");
        console2.log("Proceeding to broadcast.");
        console2.log("=====================================================");

        // ─── 4. Broadcast ────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        deployed = new LenderPolicyRegistry(canonicalSafe, envLenderRegistry);
        vm.stopBroadcast();

        // ─── 5. Post-broadcast checks ────────────────────────────
        address onChainGovernance = deployed.governance();
        address onChainLenderRegistry = deployed.lenderRegistry();
        bool postCheckGov = (onChainGovernance == canonicalSafe);
        bool postCheckReg = (onChainLenderRegistry == envLenderRegistry);

        console2.log("");
        console2.log("=====================================================");
        console2.log("POST-BROADCAST CHECK");
        console2.log("-----------------------------------------------------");
        console2.log("Deployed at:              ", address(deployed));
        console2.log("governance():             ", onChainGovernance);
        console2.log("lenderRegistry():         ", onChainLenderRegistry);
        console2.log("Canonical Safe:           ", canonicalSafe);
        console2.log("Expected LenderRegistry:  ", envLenderRegistry);

        if (postCheckGov && postCheckReg) {
            console2.log("POST-CHECK (gov):         PASS");
            console2.log("POST-CHECK (reg):         PASS");
            console2.log("-----------------------------------------------------");
            console2.log("Deployment complete and verified.");
        } else {
            if (!postCheckGov) {
                console2.log("POST-CHECK (gov):         FAIL");
            }
            if (!postCheckReg) {
                console2.log("POST-CHECK (reg):         FAIL");
            }
            console2.log("-----------------------------------------------------");
            console2.log("ALERT: deployed contract's on-chain state does NOT");
            console2.log("       match the expected values. Contract is");
            console2.log("       deployed but marked NOT VERIFIED. Do not");
            console2.log("       proceed with the batch. Manual review");
            console2.log("       required.");
            console2.log("=====================================================");
            revert("POST-CHECK failed: on-chain state mismatch");
        }
        console2.log("=====================================================");
    }
}
