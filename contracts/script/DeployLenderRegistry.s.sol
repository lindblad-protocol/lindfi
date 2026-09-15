// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Constants} from "../src/Constants.sol";
import {LenderRegistry} from "../src/LenderRegistry.sol";

/// @title DeployLenderRegistry
/// @notice Deploys LenderRegistry using the two-part deployment
///         guardrail described in DEPLOY_GUARDRAIL_SPEC.md:
///           - pre-broadcast: .env EXPECTED_SAFE_ADDRESS ==
///             Constants.expectedSafeFor(block.chainid)
///           - constructor: contract receives canonical governance
///             (not the .env value)
///           - post-broadcast: deployed.governance() == canonical
///         Fail-fast: aborts before broadcast on pre-check failure;
///         reverts after broadcast on post-check failure.
contract DeployLenderRegistry is Script {
    function run() external returns (LenderRegistry deployed) {
        // ─── 1. Load values ─────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address envSafe = vm.envAddress("EXPECTED_SAFE_ADDRESS");
        address canonicalSafe = Constants.expectedSafeFor(block.chainid);

        // ─── 2. Pre-broadcast check ─────────────────────────────
        bool preCheckPass = (envSafe == canonicalSafe);

        // ─── 3. Banner ──────────────────────────────────────────
        console2.log("=====================================================");
        console2.log("Lindblad Contract Deployment");
        console2.log("-----------------------------------------------------");
        console2.log("Contract:       LenderRegistry");
        console2.log("Network:        Arbitrum Sepolia (or configured)");
        console2.log("Chain ID:       ", block.chainid);
        console2.log("Deployer:       ", vm.addr(deployerKey));
        console2.log("env Safe:       ", envSafe);
        console2.log("Canonical Safe: ", canonicalSafe);
        if (preCheckPass) {
            console2.log("PRE-CHECK:      PASS");
        } else {
            console2.log("PRE-CHECK:      FAIL");
            console2.log("-----------------------------------------------------");
            console2.log("ABORT: .env EXPECTED_SAFE_ADDRESS does not match");
            console2.log("       Constants.expectedSafeFor(chainid).");
            console2.log("       No broadcast will occur.");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: env != canonical");
        }
        console2.log("-----------------------------------------------------");
        console2.log("Proceeding to broadcast.");
        console2.log("=====================================================");

        // ─── 4. Broadcast the deploy with governance = canonical ─
        vm.startBroadcast(deployerKey);
        deployed = new LenderRegistry(canonicalSafe);
        vm.stopBroadcast();

        // ─── 5. Post-broadcast check ─────────────────────────────
        address onChainGovernance = deployed.governance();
        bool postCheckPass = (onChainGovernance == canonicalSafe);

        console2.log("");
        console2.log("=====================================================");
        console2.log("POST-BROADCAST CHECK");
        console2.log("-----------------------------------------------------");
        console2.log("Deployed at:      ", address(deployed));
        console2.log("governance():     ", onChainGovernance);
        console2.log("Canonical Safe:   ", canonicalSafe);
        if (postCheckPass) {
            console2.log("POST-CHECK:       PASS");
            console2.log("-----------------------------------------------------");
            console2.log("Deployment complete and verified.");
        } else {
            console2.log("POST-CHECK:       FAIL");
            console2.log("-----------------------------------------------------");
            console2.log("ALERT: deployed contract's governance does NOT match");
            console2.log("       the canonical Safe. Contract is deployed but");
            console2.log("       marked NOT VERIFIED. Do not proceed with the");
            console2.log("       batch. Manual review required.");
            console2.log("=====================================================");
            revert("POST-CHECK failed: on-chain governance != canonical");
        }
        console2.log("=====================================================");
    }
}
