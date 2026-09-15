// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Constants} from "../src/Constants.sol";
import {GovernanceGuardrailTest} from "../test/fixtures/GovernanceGuardrailTest.sol";

/// @title DeployGuardrailTest
/// @notice Reference implementation of the deploy guardrail specified in
///         DEPLOY_GUARDRAIL_SPEC.md. This script:
///           1. Loads EXPECTED_SAFE_ADDRESS from .env
///           2. Reads the canonical Safe from Constants.sol per chainid
///           3. Executes the PRE-BROADCAST check
///           4. Prints the banner
///           5. Broadcasts the deploy with governance = canonical
///           6. Executes the POST-BROADCAST check
///           7. Prints confirmation or aborts with a clear error
/// @dev The pattern here is what LenderRegistry, LenderPolicyRegistry, and
///      CollateralPositionAnchor deploy scripts MUST follow (with
///      fail-fast between them per DEPLOY_GUARDRAIL_SPEC.md §5).
contract DeployGuardrailTest is Script {
    function run() external returns (GovernanceGuardrailTest deployed) {
        // ------------------------------------------------------------------
        // 1. Load values
        // ------------------------------------------------------------------
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address envSafe      = vm.envAddress("EXPECTED_SAFE_ADDRESS");
        address canonicalSafe = Constants.expectedSafeFor(block.chainid);

        // ------------------------------------------------------------------
        // 2. PRE-BROADCAST check
        //    .env value MUST equal the canonical Safe from Constants.sol.
        //    If they differ, ABORT before any broadcast.
        // ------------------------------------------------------------------
        bool preCheckPass = (envSafe == canonicalSafe);

        // ------------------------------------------------------------------
        // 3. Banner (required output per DEPLOY_GUARDRAIL_SPEC §4)
        // ------------------------------------------------------------------
        console2.log("=====================================================");
        console2.log("Lindblad Contract Deployment");
        console2.log("-----------------------------------------------------");
        console2.log("Contract:       GovernanceGuardrailTest");
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

        // ------------------------------------------------------------------
        // 4. Broadcast the deploy with governance = canonical
        //    Note: the contract is passed the CANONICAL address, not the
        //    .env value. Even though they matched, we prefer the source
        //    of truth. This is the point of decoupling from .env.
        // ------------------------------------------------------------------
        vm.startBroadcast(deployerKey);
        deployed = new GovernanceGuardrailTest(canonicalSafe);
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // 5. POST-BROADCAST check
        //    Query the deployed contract and confirm its on-chain
        //    governance equals the canonical Safe.
        // ------------------------------------------------------------------
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
