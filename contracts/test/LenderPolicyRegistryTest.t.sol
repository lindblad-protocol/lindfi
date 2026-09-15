// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Constants} from "../src/Constants.sol";
import {LenderRegistry} from "../src/LenderRegistry.sol";
import {LenderPolicyRegistry, ILenderRegistry} from "../src/LenderPolicyRegistry.sol";

/// @title LenderPolicyRegistryTest
/// @notice Covers every invariant in the approved LenderPolicyRegistry
///         final micro-spec (§10.1 through §10.9).
contract LenderPolicyRegistryTest is Test {
    LenderRegistry internal lenderRegistry;
    LenderPolicyRegistry internal policyRegistry;

    address internal governanceAddr;
    address internal notGovernance = address(0xBAD);
    address internal newGovernance = address(0x1234);

    // Lender signers used across tests
    address internal signerA = address(0xA11CE);
    address internal signerB = address(0xB0B);
    address internal signerC = address(0xC0DE);

    // Convenience state used by many tests
    uint256 internal lenderIdA; // VERIFIED, active
    uint256 internal lenderIdB; // VERIFIED, active (second lender)

    bytes32 internal constant CLASS_GOLD = bytes32(uint256(0x60174));
    bytes32 internal constant CLASS_SILVER = bytes32(uint256(0x5117e7));
    bytes32 internal constant HASH_V1 = keccak256("policy-v1");
    bytes32 internal constant HASH_V2 = keccak256("policy-v2");
    bytes32 internal constant HASH_V3 = keccak256("policy-v3");

    // ─── Local event declarations for vm.expectEmit ────────────────
    // Solidity 0.8.20 does not allow `emit ContractName.EventName(...)`.
    // Redeclaring the events locally is the standard workaround; the
    // event signatures must match LenderPolicyRegistry exactly.

    event PolicyPublished(
        uint256 indexed policyId,
        uint256 indexed lenderId,
        bytes32 indexed assetClass,
        bytes32 policyHash,
        uint256 effectiveFrom,
        uint256 effectiveUntil,
        address publishedBy
    );

    event PolicySuperseded(
        uint256 indexed previousPolicyId, uint256 indexed newPolicyId, uint256 indexed lenderId, bytes32 assetClass
    );

    event PolicyDeprecated(uint256 indexed policyId);

    event PolicyValidityUpdated(uint256 indexed policyId, uint256 newEffectiveUntil);

    event GovernanceTransferInitiated(address indexed previousGovernance, address indexed newGovernance);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    function setUp() public {
        vm.chainId(Constants.CHAIN_ARBITRUM_SEPOLIA);
        governanceAddr = Constants.expectedSafeFor(block.chainid);

        // Deploy LenderRegistry with the same governance
        lenderRegistry = new LenderRegistry(governanceAddr);

        // Deploy LenderPolicyRegistry pointing at that LenderRegistry
        policyRegistry = new LenderPolicyRegistry(governanceAddr, address(lenderRegistry));

        // Register two lenders (both VERIFIED, both active)
        vm.startPrank(governanceAddr);
        lenderIdA = lenderRegistry.registerLender("Alpha Capital", "US-DE", LenderRegistry.KybStatus.VERIFIED, signerA);
        lenderIdB = lenderRegistry.registerLender("Beta Fund", "BO", LenderRegistry.KybStatus.VERIFIED, signerB);
        vm.stopPrank();
    }

    // Common publish helper used across tests
    function _publishAsGovernance(uint256 lenderId, bytes32 assetClass, bytes32 policyHash) internal returns (uint256) {
        vm.prank(governanceAddr);
        return
            policyRegistry.publishPolicy(lenderId, assetClass, policyHash, block.timestamp, block.timestamp + 30 days);
    }

    // ── §10.1 Constructor ─────────────────────────────────────────

    function test_Constructor_RevertsOnZeroGovernance() public {
        vm.expectRevert(LenderPolicyRegistry.ZeroGovernance.selector);
        new LenderPolicyRegistry(address(0), address(lenderRegistry));
    }

    function test_Constructor_RevertsOnZeroLenderRegistry() public {
        vm.expectRevert(LenderPolicyRegistry.ZeroLenderRegistry.selector);
        new LenderPolicyRegistry(governanceAddr, address(0));
    }

    function test_Constructor_RevertsOnGovernanceMismatch() public {
        // Deploy a LenderRegistry with a different governance
        address altGovernance = address(0xC0FFEE);
        LenderRegistry altRegistry = new LenderRegistry(altGovernance);

        vm.expectRevert(
            abi.encodeWithSelector(
                LenderPolicyRegistry.LenderRegistryGovernanceMismatch.selector, altGovernance, governanceAddr
            )
        );
        new LenderPolicyRegistry(governanceAddr, address(altRegistry));
    }

    function test_Constructor_SetsGovernance() public {
        assertEq(policyRegistry.governance(), governanceAddr);
    }

    function test_Constructor_SetsLenderRegistry() public {
        assertEq(policyRegistry.lenderRegistry(), address(lenderRegistry));
    }

    function test_Constructor_PendingGovernanceIsZero() public {
        assertEq(policyRegistry.pendingGovernance(), address(0));
    }

    function test_Constructor_NextPolicyIdStartsAtOne() public {
        uint256 firstId = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        assertEq(firstId, 1);
    }

    // ── §10.2 publishPolicy ───────────────────────────────────────

    function test_PublishPolicy_GovernanceCanPublish() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        assertTrue(policyRegistry.isPolicyActive(id));
    }

    function test_PublishPolicy_LenderSignerCanPublish() public {
        vm.prank(signerA);
        uint256 id =
            policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
        assertTrue(policyRegistry.isPolicyActive(id));
    }

    function test_PublishPolicy_RevertsIfWrongSender() public {
        vm.prank(notGovernance);
        vm.expectRevert(LenderPolicyRegistry.NotAuthorized.selector);
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsIfLenderDoesNotExistGovernancePath() public {
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderDoesNotExist.selector, 999));
        policyRegistry.publishPolicy(999, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsIfLenderDoesNotExistSignerPath() public {
        // signerA is a real signer but we call publishPolicy with an
        // unknown lenderId. The internal helper calls
        // ILenderRegistry(...).getLender(999) which reverts in
        // LenderRegistry itself with LenderDoesNotExist(999).
        vm.prank(signerA);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderDoesNotExist.selector, 999));
        policyRegistry.publishPolicy(999, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsIfLenderInactive_GovernancePath() public {
        vm.prank(governanceAddr);
        lenderRegistry.deactivateLender(lenderIdA);

        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotActive.selector, lenderIdA));
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsIfLenderInactive_SignerPath() public {
        vm.prank(governanceAddr);
        lenderRegistry.deactivateLender(lenderIdA);

        vm.prank(signerA);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotActive.selector, lenderIdA));
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsIfKybNotVerified_Pending() public {
        vm.prank(governanceAddr);
        uint256 pendingLenderId =
            lenderRegistry.registerLender("Pending Lender", "US", LenderRegistry.KybStatus.PENDING, signerC);

        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotVerified.selector, pendingLenderId));
        policyRegistry.publishPolicy(pendingLenderId, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsIfKybRejected() public {
        vm.prank(governanceAddr);
        uint256 rejLenderId =
            lenderRegistry.registerLender("Rejected Lender", "US", LenderRegistry.KybStatus.REJECTED, signerC);

        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotVerified.selector, rejLenderId));
        policyRegistry.publishPolicy(rejLenderId, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsOnZeroAssetClass() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderPolicyRegistry.ZeroAssetClass.selector);
        policyRegistry.publishPolicy(lenderIdA, bytes32(0), HASH_V1, block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsOnZeroPolicyHash() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderPolicyRegistry.ZeroPolicyHash.selector);
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, bytes32(0), block.timestamp, block.timestamp + 30 days);
    }

    function test_PublishPolicy_RevertsIfEffectiveUntilEqualsEffectiveFrom() public {
        uint256 t = block.timestamp;
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.InvalidValidityWindow.selector, t, t));
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t);
    }

    function test_PublishPolicy_RevertsIfEffectiveUntilBeforeEffectiveFrom() public {
        uint256 t = block.timestamp + 100;
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.InvalidValidityWindow.selector, t, t - 1));
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t - 1);
    }

    function test_PublishPolicy_AllowsEffectiveFromInPast() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t - 1000, t + 1000);
        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.effectiveFrom, t - 1000);
        assertEq(p.effectiveUntil, t + 1000);
    }

    function test_PublishPolicy_AllowsEffectiveUntilInPast() public {
        // effectiveUntil > effectiveFrom is the only constraint. Both
        // in the past is allowed.
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t - 1000, t - 500);
        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.effectiveUntil, t - 500);
    }

    function test_PublishPolicy_MonotonicIds() public {
        uint256 id1 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 id2 = _publishAsGovernance(lenderIdB, CLASS_GOLD, HASH_V2);
        uint256 id3 = _publishAsGovernance(lenderIdA, CLASS_SILVER, HASH_V3);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_PublishPolicy_PopulatesFields() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t + 100 days);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.policyId, id);
        assertEq(p.lenderId, lenderIdA);
        assertEq(p.assetClass, CLASS_GOLD);
        assertEq(p.policyHash, HASH_V1);
        assertEq(p.effectiveFrom, t);
        assertEq(p.effectiveUntil, t + 100 days);
        assertTrue(p.active);
        assertEq(p.publishedBy, governanceAddr);
        assertEq(p.recordedAt, t);
    }

    function test_PublishPolicy_PublishedByCarriesLenderSigner() public {
        vm.prank(signerA);
        uint256 id =
            policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);
        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.publishedBy, signerA);
    }

    function test_PublishPolicy_UpdatesActivePolicyOf() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), id);
        assertEq(policyRegistry.getActivePolicyId(lenderIdA, CLASS_GOLD), id);
    }

    function test_PublishPolicy_EmitsPolicyPublished() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.expectEmit(true, true, true, true);
        emit PolicyPublished(1, lenderIdA, CLASS_GOLD, HASH_V1, t, t + 30 days, governanceAddr);
        vm.prank(governanceAddr);
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t + 30 days);
    }

    // ── §10.2 Supersession behavior ───────────────────────────────

    function test_PublishPolicy_AutoSupersedesPrevious() public {
        uint256 v1 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 v2 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V2);

        assertFalse(policyRegistry.isPolicyActive(v1));
        assertTrue(policyRegistry.isPolicyActive(v2));
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), v2);
        // v1 is preserved
        assertTrue(policyRegistry.policyExists(v1));
    }

    function test_PublishPolicy_SupersessionEmitsBothEvents() public {
        uint256 v1 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 t = block.timestamp;

        // Expect PolicyPublished for v2 first, then PolicySuperseded(v1, v2)
        vm.expectEmit(true, true, true, true);
        emit PolicyPublished(v1 + 1, lenderIdA, CLASS_GOLD, HASH_V2, t, t + 30 days, governanceAddr);
        vm.expectEmit(true, true, true, true);
        emit PolicySuperseded(v1, v1 + 1, lenderIdA, CLASS_GOLD);

        vm.prank(governanceAddr);
        policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V2, t, t + 30 days);
    }

    function test_PublishPolicy_ThreeVersionsHistoryPreserved() public {
        uint256 v1 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 v2 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V2);
        uint256 v3 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V3);

        assertFalse(policyRegistry.isPolicyActive(v1));
        assertFalse(policyRegistry.isPolicyActive(v2));
        assertTrue(policyRegistry.isPolicyActive(v3));
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), v3);

        // All three still readable
        assertEq(policyRegistry.getPolicy(v1).policyHash, HASH_V1);
        assertEq(policyRegistry.getPolicy(v2).policyHash, HASH_V2);
        assertEq(policyRegistry.getPolicy(v3).policyHash, HASH_V3);
    }

    function test_PublishPolicy_DifferentAssetClassDoesNotSupersede() public {
        uint256 goldId = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 silverId = _publishAsGovernance(lenderIdA, CLASS_SILVER, HASH_V2);

        assertTrue(policyRegistry.isPolicyActive(goldId));
        assertTrue(policyRegistry.isPolicyActive(silverId));
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), goldId);
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_SILVER), silverId);
    }

    function test_PublishPolicy_DifferentLenderDoesNotSupersede() public {
        uint256 aId = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 bId = _publishAsGovernance(lenderIdB, CLASS_GOLD, HASH_V2);

        assertTrue(policyRegistry.isPolicyActive(aId));
        assertTrue(policyRegistry.isPolicyActive(bId));
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), aId);
        assertEq(policyRegistry.activePolicyOf(lenderIdB, CLASS_GOLD), bId);
    }

    // ── §10.3 deprecatePolicy ─────────────────────────────────────

    function test_DeprecatePolicy_GovernanceCanDeprecate() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.prank(governanceAddr);
        policyRegistry.deprecatePolicy(id);
        assertFalse(policyRegistry.isPolicyActive(id));
    }

    function test_DeprecatePolicy_LenderSignerCanDeprecate() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.prank(signerA);
        policyRegistry.deprecatePolicy(id);
        assertFalse(policyRegistry.isPolicyActive(id));
    }

    function test_DeprecatePolicy_RevertsIfWrongSender() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.prank(notGovernance);
        vm.expectRevert(LenderPolicyRegistry.NotAuthorized.selector);
        policyRegistry.deprecatePolicy(id);
    }

    function test_DeprecatePolicy_RevertsIfPolicyDoesNotExist() public {
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.PolicyDoesNotExist.selector, 999));
        policyRegistry.deprecatePolicy(999);
    }

    function test_DeprecatePolicy_RevertsIfAlreadyInactive() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.startPrank(governanceAddr);
        policyRegistry.deprecatePolicy(id);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.PolicyAlreadyInactive.selector, id));
        policyRegistry.deprecatePolicy(id);
        vm.stopPrank();
    }

    function test_DeprecatePolicy_ClearsActivePolicyOf() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), id);

        vm.prank(governanceAddr);
        policyRegistry.deprecatePolicy(id);

        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), 0);
    }

    function test_DeprecatePolicy_PreservesRecord() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);

        vm.prank(governanceAddr);
        policyRegistry.deprecatePolicy(id);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.policyId, id);
        assertEq(p.lenderId, lenderIdA);
        assertEq(p.assetClass, CLASS_GOLD);
        assertEq(p.policyHash, HASH_V1);
        assertFalse(p.active);
        assertEq(p.publishedBy, governanceAddr);
        assertEq(p.recordedAt, t);
    }

    function test_DeprecatePolicy_AllowedWhenLenderInactive() public {
        // Publish, then deactivate the lender in LenderRegistry.
        // Governance and signer must still be able to deprecate.
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);

        vm.prank(governanceAddr);
        lenderRegistry.deactivateLender(lenderIdA);

        vm.prank(signerA);
        policyRegistry.deprecatePolicy(id);
        assertFalse(policyRegistry.isPolicyActive(id));
    }

    function test_DeprecatePolicy_AllowedWhenLenderNotVerified() public {
        // Register a VERIFIED lender, publish, then downgrade KYB.
        // (Directly setting KYB requires updateLender via governance.)
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);

        vm.prank(governanceAddr);
        lenderRegistry.updateLender(lenderIdA, "Alpha Capital", "US-DE", LenderRegistry.KybStatus.EXPIRED, signerA);

        vm.prank(signerA);
        policyRegistry.deprecatePolicy(id);
        assertFalse(policyRegistry.isPolicyActive(id));
    }

    function test_DeprecatePolicy_EmitsEvent() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.expectEmit(true, false, false, false);
        emit PolicyDeprecated(id);
        vm.prank(governanceAddr);
        policyRegistry.deprecatePolicy(id);
    }

    function test_DeprecatePolicy_PostConditionNewPublishNoSupersession() public {
        // After deprecation, activePolicyOf is 0. Publishing a new
        // policy for the same pair must NOT emit PolicySuperseded.
        uint256 v1 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.prank(governanceAddr);
        policyRegistry.deprecatePolicy(v1);
        assertEq(policyRegistry.activePolicyOf(lenderIdA, CLASS_GOLD), 0);

        // The next publish should emit only PolicyPublished, not
        // PolicySuperseded. We can't easily assert "did NOT emit"
        // directly, but we can assert the new v2 is active and v1
        // remains deprecated.
        uint256 v2 = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V2);
        assertTrue(policyRegistry.isPolicyActive(v2));
        assertFalse(policyRegistry.isPolicyActive(v1));
    }

    // ── §10.4 updatePolicyValidity ────────────────────────────────

    function test_UpdatePolicyValidity_GovernanceCanUpdate() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 t = block.timestamp;

        vm.prank(governanceAddr);
        policyRegistry.updatePolicyValidity(id, t + 90 days);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.effectiveUntil, t + 90 days);
    }

    function test_UpdatePolicyValidity_LenderSignerCanUpdate() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 t = block.timestamp;

        vm.prank(signerA);
        policyRegistry.updatePolicyValidity(id, t + 90 days);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.effectiveUntil, t + 90 days);
    }

    function test_UpdatePolicyValidity_RevertsIfWrongSender() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.prank(notGovernance);
        vm.expectRevert(LenderPolicyRegistry.NotAuthorized.selector);
        policyRegistry.updatePolicyValidity(id, block.timestamp + 90 days);
    }

    function test_UpdatePolicyValidity_RevertsIfPolicyDoesNotExist() public {
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.PolicyDoesNotExist.selector, 999));
        policyRegistry.updatePolicyValidity(999, block.timestamp + 90 days);
    }

    function test_UpdatePolicyValidity_RevertsIfDeprecated() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.startPrank(governanceAddr);
        policyRegistry.deprecatePolicy(id);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.PolicyNotActive.selector, id));
        policyRegistry.updatePolicyValidity(id, block.timestamp + 90 days);
        vm.stopPrank();
    }

    function test_UpdatePolicyValidity_RevertsIfLenderInactive_Governance() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.prank(governanceAddr);
        lenderRegistry.deactivateLender(lenderIdA);

        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotActive.selector, lenderIdA));
        policyRegistry.updatePolicyValidity(id, block.timestamp + 90 days);
    }

    function test_UpdatePolicyValidity_RevertsIfLenderNotVerified() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        vm.prank(governanceAddr);
        lenderRegistry.updateLender(lenderIdA, "Alpha Capital", "US-DE", LenderRegistry.KybStatus.EXPIRED, signerA);

        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotVerified.selector, lenderIdA));
        policyRegistry.updatePolicyValidity(id, block.timestamp + 90 days);
    }

    function test_UpdatePolicyValidity_RevertsIfNewUntilLeqEffectiveFrom() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t + 30 days);

        // Attempt to set newEffectiveUntil == effectiveFrom
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.InvalidValidityWindow.selector, t, t));
        policyRegistry.updatePolicyValidity(id, t);
    }

    function test_UpdatePolicyValidity_CanShorten() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t + 90 days);

        vm.prank(governanceAddr);
        policyRegistry.updatePolicyValidity(id, t + 30 days);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.effectiveUntil, t + 30 days);
    }

    function test_UpdatePolicyValidity_CanExtend() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t + 30 days);

        vm.prank(governanceAddr);
        policyRegistry.updatePolicyValidity(id, t + 365 days);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.effectiveUntil, t + 365 days);
    }

    function test_UpdatePolicyValidity_DoesNotChangeHashOrFrom() public {
        uint256 t = 2_000_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, t, t + 30 days);

        vm.prank(governanceAddr);
        policyRegistry.updatePolicyValidity(id, t + 60 days);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.policyHash, HASH_V1);
        assertEq(p.effectiveFrom, t);
    }

    function test_UpdatePolicyValidity_EmitsEvent() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        uint256 newUntil = block.timestamp + 60 days;
        vm.expectEmit(true, false, false, true);
        emit PolicyValidityUpdated(id, newUntil);
        vm.prank(governanceAddr);
        policyRegistry.updatePolicyValidity(id, newUntil);
    }

    // ── §10.5 Signer rotation ─────────────────────────────────────

    function test_SignerRotation_OldSignerLosesAuthority() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);

        // Rotate signerA → signerC via LenderRegistry.updateLender
        vm.prank(governanceAddr);
        lenderRegistry.updateLender(lenderIdA, "Alpha Capital", "US-DE", LenderRegistry.KybStatus.VERIFIED, signerC);

        // signerA (former signer) can no longer deprecate
        vm.prank(signerA);
        vm.expectRevert(LenderPolicyRegistry.NotAuthorized.selector);
        policyRegistry.deprecatePolicy(id);
    }

    function test_SignerRotation_NewSignerHasAuthority() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);

        vm.prank(governanceAddr);
        lenderRegistry.updateLender(lenderIdA, "Alpha Capital", "US-DE", LenderRegistry.KybStatus.VERIFIED, signerC);

        vm.prank(signerC);
        policyRegistry.deprecatePolicy(id);
        assertFalse(policyRegistry.isPolicyActive(id));
    }

    function test_SignerRotation_PublishedByPreserved() public {
        uint256 id;
        vm.prank(signerA);
        id = policyRegistry.publishPolicy(lenderIdA, CLASS_GOLD, HASH_V1, block.timestamp, block.timestamp + 30 days);

        vm.prank(governanceAddr);
        lenderRegistry.updateLender(lenderIdA, "Alpha Capital", "US-DE", LenderRegistry.KybStatus.VERIFIED, signerC);

        LenderPolicyRegistry.Policy memory p = policyRegistry.getPolicy(id);
        assertEq(p.publishedBy, signerA); // historical trail preserved
    }

    // ── §10.6 Governance transfer ─────────────────────────────────

    function test_TransferGovernance_RevertsIfNotGovernance() public {
        vm.prank(notGovernance);
        vm.expectRevert(LenderPolicyRegistry.NotGovernance.selector);
        policyRegistry.transferGovernance(newGovernance);
    }

    function test_TransferGovernance_RevertsOnZero() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderPolicyRegistry.ZeroGovernance.selector);
        policyRegistry.transferGovernance(address(0));
    }

    function test_TransferGovernance_SetsPendingOnly() public {
        vm.prank(governanceAddr);
        policyRegistry.transferGovernance(newGovernance);
        assertEq(policyRegistry.pendingGovernance(), newGovernance);
        assertEq(policyRegistry.governance(), governanceAddr);
    }

    function test_TransferGovernance_EmitsInitiated() public {
        vm.expectEmit(true, true, false, false);
        emit GovernanceTransferInitiated(governanceAddr, newGovernance);
        vm.prank(governanceAddr);
        policyRegistry.transferGovernance(newGovernance);
    }

    function test_AcceptGovernance_RevertsIfNotPending() public {
        vm.prank(governanceAddr);
        policyRegistry.transferGovernance(newGovernance);
        vm.prank(notGovernance);
        vm.expectRevert(LenderPolicyRegistry.NotPendingGovernance.selector);
        policyRegistry.acceptGovernance();
    }

    function test_AcceptGovernance_RevertsIfNoPending() public {
        vm.prank(newGovernance);
        vm.expectRevert(LenderPolicyRegistry.NotPendingGovernance.selector);
        policyRegistry.acceptGovernance();
    }

    function test_AcceptGovernance_Completes() public {
        vm.prank(governanceAddr);
        policyRegistry.transferGovernance(newGovernance);
        vm.prank(newGovernance);
        policyRegistry.acceptGovernance();

        assertEq(policyRegistry.governance(), newGovernance);
        assertEq(policyRegistry.pendingGovernance(), address(0));
    }

    function test_AcceptGovernance_EmitsTransferred() public {
        vm.prank(governanceAddr);
        policyRegistry.transferGovernance(newGovernance);
        vm.expectEmit(true, true, false, false);
        emit GovernanceTransferred(governanceAddr, newGovernance);
        vm.prank(newGovernance);
        policyRegistry.acceptGovernance();
    }

    function test_TransferGovernance_CanBeOverwritten() public {
        vm.startPrank(governanceAddr);
        policyRegistry.transferGovernance(newGovernance);
        address other = address(0x9999);
        policyRegistry.transferGovernance(other);
        assertEq(policyRegistry.pendingGovernance(), other);
        vm.stopPrank();
    }

    // ── §10.7 Read invariants ─────────────────────────────────────

    function test_GetPolicy_RevertsOnUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.PolicyDoesNotExist.selector, 999));
        policyRegistry.getPolicy(999);
    }

    function test_GetPolicy_RevertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.PolicyDoesNotExist.selector, 0));
        policyRegistry.getPolicy(0);
    }

    function test_PolicyExists_FalseForZero() public {
        assertFalse(policyRegistry.policyExists(0));
    }

    function test_PolicyExists_TrueForActiveAndDeprecated() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        assertTrue(policyRegistry.policyExists(id));

        vm.prank(governanceAddr);
        policyRegistry.deprecatePolicy(id);
        assertTrue(policyRegistry.policyExists(id));
    }

    function test_IsPolicyActive_FalseForUnknown() public {
        assertFalse(policyRegistry.isPolicyActive(999));
    }

    function test_IsPolicyActive_FalseForZero() public {
        assertFalse(policyRegistry.isPolicyActive(0));
    }

    function test_GetActivePolicyId_ZeroForNone() public {
        assertEq(policyRegistry.getActivePolicyId(lenderIdA, CLASS_GOLD), 0);
        assertEq(policyRegistry.getActivePolicyId(999, CLASS_GOLD), 0);
        assertEq(policyRegistry.getActivePolicyId(lenderIdA, bytes32(0)), 0);
    }

    function test_TotalPolicies_ZeroInitially() public {
        assertEq(policyRegistry.totalPolicies(), 0);
    }

    function test_TotalPolicies_IncrementsOnPublish() public {
        _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        assertEq(policyRegistry.totalPolicies(), 1);

        _publishAsGovernance(lenderIdA, CLASS_SILVER, HASH_V2);
        assertEq(policyRegistry.totalPolicies(), 2);
    }

    function test_TotalPolicies_UnaffectedByDeprecateAndUpdate() public {
        uint256 id = _publishAsGovernance(lenderIdA, CLASS_GOLD, HASH_V1);
        assertEq(policyRegistry.totalPolicies(), 1);

        vm.prank(governanceAddr);
        policyRegistry.updatePolicyValidity(id, block.timestamp + 90 days);
        assertEq(policyRegistry.totalPolicies(), 1);

        vm.prank(governanceAddr);
        policyRegistry.deprecatePolicy(id);
        assertEq(policyRegistry.totalPolicies(), 1);
    }

    // ── §10.8 No custody / no funds ───────────────────────────────

    function test_NoCustody_ContractRejectsEthTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(policyRegistry).call{value: 1 ether}("");
        assertFalse(sent);
        assertEq(address(policyRegistry).balance, 0);
    }

    // ── §10.9 Guardrail integration ───────────────────────────────

    function test_Guardrail_ConstantsMatchGovernance() public {
        assertEq(policyRegistry.governance(), Constants.expectedSafeFor(block.chainid));
    }

    function test_Guardrail_LenderRegistryLinked() public {
        assertEq(policyRegistry.lenderRegistry(), address(lenderRegistry));
    }
}
