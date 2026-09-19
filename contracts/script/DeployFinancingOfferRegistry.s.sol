// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Constants} from "../src/Constants.sol";
import {
    FinancingOfferRegistry,
    ILenderRegistry,
    ILenderPolicyRegistry,
    ICollateralPositionAnchor
} from "../src/FinancingOfferRegistry.sol";

/// @title DeployFinancingOfferRegistry
/// @notice Deploys the single B5 contract using the same two-part deployment guardrail as
///         DeployCollateralPositionAnchor, extended to triangulate all THREE B4 dependencies and to
///         assert their deployed runtime code identities before broadcasting.
///
///         Pre-broadcast:
///           - chainid is the expected network and .env EXPECTED_SAFE_ADDRESS == Constants.expectedSafeFor(chainid)
///           - LR / LPR / CPA addresses are non-zero and match the .env values
///           - each dependency's runtime keccak256 matches its frozen CFG-0 identity
///           - LR.governance() == LPR.governance() == CPA.governance() == canonical Safe
///           - LPR.lenderRegistry() == LR, CPA.lenderRegistry() == LR, CPA.lenderPolicyRegistry() == LPR
///
///         Broadcast:
///           - exactly one FinancingOfferRegistry is created. The constructor re-enforces the whole
///             triangulation on-chain; this script fails fast for a better operator experience.
///
///         Post-broadcast:
///           - governance / lenderRegistry / lenderPolicyRegistry / collateralPositionAnchor read back
///           - EIP-712 domain separator recomputed off the deployed address and compared
///           - runtime code present, and its length matches the compiled artifact
///           - the registry holds no balance
contract DeployFinancingOfferRegistry is Script {
    // Frozen CFG-0 runtime identities of the B4 dependencies (Arbitrum Sepolia, chainId 421614).
    bytes32 constant LR_RUNTIME_KECCAK = 0xc4bdd05bde25804f591547202181e3c0b849895f68823d69f8a72545ae4ba65f;
    bytes32 constant LPR_RUNTIME_KECCAK = 0x9517a266431f40a32fb059dfda8e1e107b3db3aa8a8985865b8787ebac66e6a2;
    bytes32 constant CPA_RUNTIME_KECCAK = 0x36bf1414d0d8b30a691bd51b869f6a304b5162520cd2807d0c282dac32ed4a9b;
    uint256 constant EXPECTED_CHAIN_ID = 421614;
    uint256 constant EXPECTED_RUNTIME_LENGTH = 15252;

    function run() external returns (FinancingOfferRegistry deployed) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address canonicalSafe = Constants.expectedSafeFor(block.chainid);
        address envLr = vm.envAddress("LENDER_REGISTRY_ADDRESS");
        address envLpr = vm.envAddress("LENDER_POLICY_REGISTRY_ADDRESS");
        address envCpa = vm.envAddress("COLLATERAL_POSITION_ANCHOR_ADDRESS");

        _preCheck(canonicalSafe, envLr, envLpr, envCpa, deployerKey);

        vm.startBroadcast(deployerKey);
        deployed = new FinancingOfferRegistry(canonicalSafe, envLr, envLpr, envCpa);
        vm.stopBroadcast();

        _postCheck(deployed, canonicalSafe, envLr, envLpr, envCpa);
    }

    function _preCheck(address canonicalSafe, address envLr, address envLpr, address envCpa, uint256 deployerKey)
        private
        view
    {
        address envSafe = vm.envAddress("EXPECTED_SAFE_ADDRESS");

        console2.log("=====================================================");
        console2.log("Lindblad Contract Deployment");
        console2.log("-----------------------------------------------------");
        console2.log("Contract:                FinancingOfferRegistry (B5)");
        console2.log("Chain ID:                ", block.chainid);
        console2.log("Deployer:                ", vm.addr(deployerKey));
        console2.log("env Safe:                ", envSafe);
        console2.log("Canonical Safe:          ", canonicalSafe);
        console2.log("env LenderRegistry:      ", envLr);
        console2.log("env PolicyRegistry:      ", envLpr);
        console2.log("env PositionAnchor:      ", envCpa);

        if (block.chainid != EXPECTED_CHAIN_ID) {
            console2.log("PRE-CHECK (chain):       FAIL");
            console2.log("ABORT: unexpected chain id");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: unexpected chain id");
        }
        if (envSafe != canonicalSafe) {
            console2.log("PRE-CHECK (safe):        FAIL");
            console2.log("ABORT: .env EXPECTED_SAFE_ADDRESS != canonical");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: env != canonical");
        }
        if (envLr == address(0) || envLpr == address(0) || envCpa == address(0)) {
            console2.log("PRE-CHECK (deps):        FAIL");
            console2.log("ABORT: a dependency address is zero");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: zero dependency address");
        }

        _preCheckRuntimeIdentities(envLr, envLpr, envCpa);
        _preCheckDependencies(canonicalSafe, envLr, envLpr, envCpa);

        console2.log("PRE-CHECK (chain):       PASS");
        console2.log("PRE-CHECK (safe):        PASS");
        console2.log("PRE-CHECK (LR code):     PASS");
        console2.log("PRE-CHECK (LPR code):    PASS");
        console2.log("PRE-CHECK (CPA code):    PASS");
        console2.log("PRE-CHECK (governance):  PASS");
        console2.log("PRE-CHECK (wiring):      PASS");
        console2.log("-----------------------------------------------------");
        console2.log("Proceeding to broadcast.");
        console2.log("=====================================================");
    }

    /// @dev The deployed dependencies must be the exact contracts B5 was specified against.
    function _preCheckRuntimeIdentities(address envLr, address envLpr, address envCpa) private view {
        if (keccak256(envLr.code) != LR_RUNTIME_KECCAK) {
            console2.log("PRE-CHECK (LR code):     FAIL");
            console2.log("ABORT: LenderRegistry runtime code identity mismatch");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LR runtime code mismatch");
        }
        if (keccak256(envLpr.code) != LPR_RUNTIME_KECCAK) {
            console2.log("PRE-CHECK (LPR code):    FAIL");
            console2.log("ABORT: LenderPolicyRegistry runtime code identity mismatch");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: LPR runtime code mismatch");
        }
        if (keccak256(envCpa.code) != CPA_RUNTIME_KECCAK) {
            console2.log("PRE-CHECK (CPA code):    FAIL");
            console2.log("ABORT: CollateralPositionAnchor runtime code identity mismatch");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: CPA runtime code mismatch");
        }
    }

    function _preCheckDependencies(address canonicalSafe, address envLr, address envLpr, address envCpa)
        private
        view
    {
        address lrGov = ILenderRegistry(envLr).governance();
        address lprGov = ILenderPolicyRegistry(envLpr).governance();
        address cpaGov = ICollateralPositionAnchor(envCpa).governance();
        console2.log("LR governance:           ", lrGov);
        console2.log("LPR governance:          ", lprGov);
        console2.log("CPA governance:          ", cpaGov);
        if (lrGov != canonicalSafe || lprGov != canonicalSafe || cpaGov != canonicalSafe) {
            console2.log("PRE-CHECK (governance):  FAIL");
            console2.log("ABORT: a dependency governance != canonical Safe");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: dependency governance mismatch");
        }

        address lprLr = ILenderPolicyRegistry(envLpr).lenderRegistry();
        address cpaLr = ICollateralPositionAnchor(envCpa).lenderRegistry();
        address cpaLpr = ICollateralPositionAnchor(envCpa).lenderPolicyRegistry();
        console2.log("LPR.lenderRegistry():    ", lprLr);
        console2.log("CPA.lenderRegistry():    ", cpaLr);
        console2.log("CPA.lenderPolicyRegistry():", cpaLpr);
        if (lprLr != envLr || cpaLr != envLr || cpaLpr != envLpr) {
            console2.log("PRE-CHECK (wiring):      FAIL");
            console2.log("ABORT: dependency wiring mismatch");
            console2.log("=====================================================");
            revert("PRE-CHECK failed: dependency wiring mismatch");
        }
    }

    function _postCheck(
        FinancingOfferRegistry deployed,
        address canonicalSafe,
        address envLr,
        address envLpr,
        address envCpa
    ) private view {
        address a = address(deployed);
        console2.log("");
        console2.log("=====================================================");
        console2.log("POST-BROADCAST CHECK");
        console2.log("-----------------------------------------------------");
        console2.log("Deployed at:                ", a);
        console2.log("governance():               ", deployed.governance());
        console2.log("lenderRegistry():           ", deployed.lenderRegistry());
        console2.log("lenderPolicyRegistry():     ", deployed.lenderPolicyRegistry());
        console2.log("collateralPositionAnchor(): ", deployed.collateralPositionAnchor());
        console2.log("runtime code length:        ", a.code.length);
        console2.logBytes32(keccak256(a.code));

        if (a == address(0) || a.code.length == 0) revert("POST-CHECK failed: no runtime code");
        if (a.code.length != EXPECTED_RUNTIME_LENGTH) revert("POST-CHECK failed: runtime length mismatch");
        if (deployed.governance() != canonicalSafe) revert("POST-CHECK failed: governance mismatch");
        if (deployed.lenderRegistry() != envLr) revert("POST-CHECK failed: lenderRegistry mismatch");
        if (deployed.lenderPolicyRegistry() != envLpr) revert("POST-CHECK failed: lenderPolicyRegistry mismatch");
        if (deployed.collateralPositionAnchor() != envCpa) revert("POST-CHECK failed: anchor mismatch");
        if (a.balance != 0) revert("POST-CHECK failed: unexpected balance");

        // EIP-712 domain must bind THIS chain and THIS address.
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LindFi FinancingOfferRegistry"),
                keccak256("1"),
                block.chainid,
                a
            )
        );
        if (deployed.domainSeparator() != expectedDomain) revert("POST-CHECK failed: EIP-712 domain mismatch");

        console2.log("POST-CHECK (code):          PASS");
        console2.log("POST-CHECK (governance):    PASS");
        console2.log("POST-CHECK (dependencies):  PASS");
        console2.log("POST-CHECK (EIP-712):       PASS");
        console2.log("POST-CHECK (zero balance):  PASS");
        console2.log("-----------------------------------------------------");
        console2.log("Deployment complete and verified.");
        console2.log("=====================================================");
    }
}
