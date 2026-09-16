// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Constants} from "../src/Constants.sol";
import {LenderRegistry} from "../src/LenderRegistry.sol";
import {LenderPolicyRegistry} from "../src/LenderPolicyRegistry.sol";
import {CollateralPositionAnchor} from "../src/CollateralPositionAnchor.sol";

/// @title Mvp03aIntegrationTest
/// @notice Integration tests proving that LenderRegistry (LR),
///         LenderPolicyRegistry (LPR), and CollateralPositionAnchor
///         (CPA) operate correctly as one compositional system.
/// @dev Implements the frozen
///      LINDFI_MVP03A_INTEGRATION_TEST_SPEC_FINAL.md test inventory.
///      45 tests across 11 scenario groups (A-K). Every test is
///      compositional (requires at least two contracts to reason
///      about correctly). No mocks of the three MVP-03A contracts.
///      Time discipline: deterministic t0-based timestamps per §21.6.
contract Mvp03aIntegrationTest is Test {
    // ─── Contracts (real, not mocked) ─────────────────────────────
    LenderRegistry internal lr;
    LenderPolicyRegistry internal lpr;
    CollateralPositionAnchor internal cpa;

    // ─── Actors ────────────────────────────────────────────────────
    address internal governanceAddr;
    address internal notGovernance = address(0xBAD);
    address internal newGovernance = address(0x1234);
    address internal signerA = address(0xA11CE);
    address internal signerB = address(0xB0B);
    address internal signerC = address(0xC0DE);

    // ─── Common state populated in setUp ──────────────────────────
    uint256 internal lenderIdA_u256;
    uint256 internal lenderIdB_u256;
    uint32 internal lenderIdA;
    uint32 internal lenderIdB;

    // ─── Fixture literals ──────────────────────────────────────────
    bytes32 internal constant ASSET_1 = bytes32(uint256(0xa55e71));
    bytes32 internal constant ASSET_2 = bytes32(uint256(0xa55e72));
    bytes32 internal constant ASSET_CLASS_GOLD = bytes32("GOLD");
    bytes32 internal constant ASSET_CLASS_SILVER = bytes32("SILVER");
    bytes32 internal constant NAV_H = keccak256("nav-1");
    bytes32 internal constant POLICY_H_V1 = keccak256("policy-v1");
    bytes32 internal constant POLICY_H_V2 = keccak256("policy-v2");
    bytes32 internal constant POLICY_H_V3 = keccak256("policy-v3");
    bytes32 internal constant POLICY_H_A = keccak256("policy-lender-A");
    bytes32 internal constant POLICY_H_B = keccak256("policy-lender-B");
    bytes32 internal constant CURRENCY_USD = bytes32("USD");
    bytes32 internal constant ROLE_ANALYST = bytes32("ANALYST");

    // Deterministic t0 for all timing-sensitive tests (§21.6)
    uint64 internal constant T0 = 2_000_000_000;

    // ─── setUp — deploy real fixture (§5, §7) ─────────────────────
    function setUp() public {
        vm.chainId(Constants.CHAIN_ARBITRUM_SEPOLIA);
        governanceAddr = Constants.expectedSafeFor(block.chainid);

        lr = new LenderRegistry(governanceAddr);
        lpr = new LenderPolicyRegistry(governanceAddr, address(lr));
        cpa = new CollateralPositionAnchor(governanceAddr, address(lr), address(lpr));

        vm.startPrank(governanceAddr);
        lenderIdA_u256 = lr.registerLender("Alpha Capital", "US-DE", LenderRegistry.KybStatus.VERIFIED, signerA);
        lenderIdB_u256 = lr.registerLender("Beta Fund", "BO", LenderRegistry.KybStatus.VERIFIED, signerB);
        vm.stopPrank();

        lenderIdA = uint32(lenderIdA_u256);
        lenderIdB = uint32(lenderIdB_u256);

        // Deterministic t0 (§21.6)
        vm.warp(T0);
    }

    // ─── Helpers (§5) — APPROVED per §21.2 ─────────────────────────

    function _publishPolicyAsGovernance(
        uint256 lenderId,
        bytes32 assetClass,
        bytes32 policyHash,
        uint256 effectiveFrom,
        uint256 effectiveUntil
    ) internal returns (uint256) {
        vm.prank(governanceAddr);
        return lpr.publishPolicy(lenderId, assetClass, policyHash, effectiveFrom, effectiveUntil);
    }

    function _buildAssessment(bytes32 assetId, uint32 lenderId, bytes32 policyHash)
        internal
        view
        returns (CollateralPositionAnchor.AnchorInput memory)
    {
        return CollateralPositionAnchor.AnchorInput({
            assetId: assetId,
            assessmentHash: keccak256(abi.encodePacked("assessment", assetId, lenderId, block.timestamp)),
            navHash: NAV_H,
            policyHash: policyHash,
            lenderId: lenderId,
            haircutBps: 2000,
            maxLTVBps: 5000,
            eligibleValue: 100 ether,
            creditCapacity: 40 ether,
            currencyCode: CURRENCY_USD,
            verdict: 0,
            writerRole: ROLE_ANALYST,
            performedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 30 days),
            demoAtAnchoring: true
        });
    }

    function _anchorAsGovernance(CollateralPositionAnchor.AnchorInput memory input) internal returns (uint256) {
        vm.prank(governanceAddr);
        return cpa.anchorAssessment(input);
    }

    // ══════════════════════════════════════════════════════════════
    // A — HAPPY PATH (3 tests)
    // ══════════════════════════════════════════════════════════════

    function test_HappyPath_FullLifecycle_RegisterPublishAnchor() public {
        // 1. Lender A already VERIFIED + active from setUp; re-assert.
        assertTrue(lr.lenderExists(lenderIdA_u256));
        assertTrue(lr.isActive(lenderIdA_u256));
        assertEq(uint8(lr.getLender(lenderIdA_u256).kybStatus), uint8(LenderRegistry.KybStatus.VERIFIED));

        // 2. Publish policy V1 as governance.
        uint256 policyId = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        // 3. LPR state assertions
        assertEq(policyId, 1);
        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), 1);
        assertEq(lpr.getPolicy(1).policyHash, POLICY_H_V1);
        assertTrue(lpr.getPolicy(1).active);
        assertEq(lpr.totalPolicies(), 1);

        // 4-5. Build and anchor assessment referencing POLICY_H_V1
        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1);
        uint256 anchorId = _anchorAsGovernance(input);

        // 6. CPA state assertions
        assertEq(anchorId, 1);
        CollateralPositionAnchor.AnchorRecord memory r = cpa.latest(ASSET_1, lenderIdA);
        assertEq(r.policyHash, POLICY_H_V1);
        assertEq(r.writer, governanceAddr);
        assertEq(r.anchoredAt, T0);
        assertEq(cpa.latest(ASSET_1).policyHash, POLICY_H_V1);
        assertEq(cpa.historyLength(ASSET_1), 1);
        assertEq(cpa.historyLength(ASSET_1, lenderIdA), 1);
        assertEq(cpa.getAssessment(ASSET_1, 0).policyHash, POLICY_H_V1);
        assertEq(uint8(cpa.state(ASSET_1, lenderIdA, T0)), uint8(CollateralPositionAnchor.State.ACTIVE));
        assertEq(cpa.totalAnchors(), 1);

        // 7. Cross-contract state remained coherent
        assertEq(uint8(lr.getLender(lenderIdA_u256).kybStatus), uint8(LenderRegistry.KybStatus.VERIFIED));
        assertTrue(lr.isActive(lenderIdA_u256));
        assertTrue(lpr.getPolicy(1).active);
        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), 1);
    }

    function test_HappyPath_MultipleSequentialAnchorsForSamePair() public {
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        uint256 id1 = _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));
        vm.warp(T0 + 1);
        uint256 id2 = _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));
        vm.warp(T0 + 2);
        uint256 id3 = _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(cpa.historyLength(ASSET_1, lenderIdA), 3);
        assertEq(cpa.totalAnchors(), 3);
    }

    function test_HappyPath_CrossContractStateCoherentAfterCycle() public {
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        // After full cycle, every contract's state matches what setUp promised
        assertEq(lr.governance(), governanceAddr);
        assertEq(lpr.governance(), governanceAddr);
        assertEq(cpa.governance(), governanceAddr);
        assertEq(lpr.lenderRegistry(), address(lr));
        assertEq(cpa.lenderRegistry(), address(lr));
        assertEq(cpa.lenderPolicyRegistry(), address(lpr));
    }

    // ══════════════════════════════════════════════════════════════
    // B — LENDER NOT VERIFIED (6 tests)
    // ══════════════════════════════════════════════════════════════

    function _registerLenderWithKyb(LenderRegistry.KybStatus status) internal returns (uint256) {
        vm.prank(governanceAddr);
        return lr.registerLender("Test Lender", "US", status, signerC);
    }

    function test_Pending_LprRejectsPublish() public {
        uint256 id = _registerLenderWithKyb(LenderRegistry.KybStatus.PENDING);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotVerified.selector, id));
        lpr.publishPolicy(id, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
    }

    function test_Pending_CpaRejectsAnchor() public {
        uint256 id = _registerLenderWithKyb(LenderRegistry.KybStatus.PENDING);
        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, uint32(id), POLICY_H_V1);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotVerified.selector, uint32(id)));
        cpa.anchorAssessment(input);
    }

    function test_Rejected_LprRejectsPublish() public {
        uint256 id = _registerLenderWithKyb(LenderRegistry.KybStatus.REJECTED);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotVerified.selector, id));
        lpr.publishPolicy(id, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
    }

    function test_Rejected_CpaRejectsAnchor() public {
        uint256 id = _registerLenderWithKyb(LenderRegistry.KybStatus.REJECTED);
        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, uint32(id), POLICY_H_V1);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotVerified.selector, uint32(id)));
        cpa.anchorAssessment(input);
    }

    function test_Expired_LprRejectsPublish() public {
        uint256 id = _registerLenderWithKyb(LenderRegistry.KybStatus.EXPIRED);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotVerified.selector, id));
        lpr.publishPolicy(id, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
    }

    function test_Expired_CpaRejectsAnchor() public {
        uint256 id = _registerLenderWithKyb(LenderRegistry.KybStatus.EXPIRED);
        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, uint32(id), POLICY_H_V1);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotVerified.selector, uint32(id)));
        cpa.anchorAssessment(input);
    }

    // ══════════════════════════════════════════════════════════════
    // C — LENDER DEACTIVATION (7 tests)
    // ══════════════════════════════════════════════════════════════

    function _setupWithPolicyAndAnchor() internal returns (uint256 policyId, uint256 anchorId) {
        policyId = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        anchorId = _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));
    }

    function test_Deactivation_HistoricalAnchorImmutable() public {
        (, uint256 anchorId) = _setupWithPolicyAndAnchor();
        CollateralPositionAnchor.AnchorRecord memory before = cpa.getAssessment(ASSET_1, 0);

        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        CollateralPositionAnchor.AnchorRecord memory afterR = cpa.getAssessment(ASSET_1, 0);
        // Every field byte-for-byte identical
        assertEq(afterR.assetId, before.assetId);
        assertEq(afterR.assessmentHash, before.assessmentHash);
        assertEq(afterR.policyHash, before.policyHash);
        assertEq(afterR.lenderId, before.lenderId);
        assertEq(afterR.writer, before.writer);
        assertEq(afterR.anchoredAt, before.anchoredAt);
        assertEq(afterR.validUntil, before.validUntil);
        assertEq(cpa.totalAnchors(), 1);
        (anchorId); // used already
    }

    function test_Deactivation_HistoricalAnchorAllFieldsPreserved() public {
        _setupWithPolicyAndAnchor();
        CollateralPositionAnchor.AnchorRecord memory before = cpa.latest(ASSET_1, lenderIdA);

        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        CollateralPositionAnchor.AnchorRecord memory afterR = cpa.latest(ASSET_1, lenderIdA);
        assertEq(afterR.haircutBps, before.haircutBps);
        assertEq(afterR.maxLTVBps, before.maxLTVBps);
        assertEq(afterR.eligibleValue, before.eligibleValue);
        assertEq(afterR.creditCapacity, before.creditCapacity);
        assertEq(afterR.currencyCode, before.currencyCode);
        assertEq(afterR.verdict, before.verdict);
        assertEq(afterR.writerRole, before.writerRole);
        assertEq(afterR.performedAt, before.performedAt);
        assertEq(afterR.demoAtAnchoring, before.demoAtAnchoring);
        assertEq(afterR.navHash, before.navHash);
    }

    function test_Deactivation_NewAnchorReverts() public {
        _setupWithPolicyAndAnchor();
        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotActive.selector, lenderIdA));
        cpa.anchorAssessment(input);
    }

    function test_Deactivation_ExistingPolicyUnchanged() public {
        (uint256 policyId,) = _setupWithPolicyAndAnchor();

        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), policyId);
        assertTrue(lpr.getPolicy(policyId).active);
        assertEq(lpr.getPolicy(policyId).policyHash, POLICY_H_V1);
    }

    function test_Deactivation_NewPublishReverts() public {
        _setupWithPolicyAndAnchor();
        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotActive.selector, lenderIdA_u256));
        lpr.publishPolicy(lenderIdA_u256, ASSET_CLASS_SILVER, POLICY_H_V2, T0, T0 + 30 days);
    }

    function test_Deactivation_DeprecateStillWorks() public {
        (uint256 policyId,) = _setupWithPolicyAndAnchor();
        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        // Deprecate still works (relaxed auth per LPR spec §H.11)
        vm.prank(governanceAddr);
        lpr.deprecatePolicy(policyId);

        assertFalse(lpr.getPolicy(policyId).active);
        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), 0);
    }

    function test_Deactivation_StateDoesNotConsultLenderRegistry() public {
        _setupWithPolicyAndAnchor();
        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        // state() still returns ACTIVE because it evaluates the anchor's
        // window, not the lender's status
        assertEq(uint8(cpa.state(ASSET_1, lenderIdA, T0 + 5 days)), uint8(CollateralPositionAnchor.State.ACTIVE));
    }

    // ══════════════════════════════════════════════════════════════
    // D — LENDER REACTIVATION (4 tests)
    // ══════════════════════════════════════════════════════════════

    function test_Reactivation_LprPublishSucceedsAgain() public {
        _setupWithPolicyAndAnchor();

        vm.startPrank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);
        lr.reactivateLender(lenderIdA_u256);
        vm.stopPrank();

        // Publish should now succeed (both active + VERIFIED conditions met)
        vm.prank(governanceAddr);
        uint256 newPolicyId = lpr.publishPolicy(lenderIdA_u256, ASSET_CLASS_SILVER, POLICY_H_V2, T0, T0 + 30 days);
        assertTrue(newPolicyId > 0);
        assertTrue(lpr.getPolicy(newPolicyId).active);
    }

    function test_Reactivation_CpaAnchorSucceedsAgain() public {
        _setupWithPolicyAndAnchor();

        vm.startPrank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);
        lr.reactivateLender(lenderIdA_u256);
        vm.stopPrank();

        uint256 newAnchorId = _anchorAsGovernance(_buildAssessment(ASSET_2, lenderIdA, POLICY_H_V1));
        assertEq(newAnchorId, 2); // first anchor was id=1
    }

    function test_Reactivation_DoesNotRestoreKyb() public {
        // Documents §24.2: reactivate restores active=true but does NOT
        // touch kybStatus. If KYB was downgraded while deactivated,
        // reactivation leaves the lender in (active, downgraded_kyb).
        _setupWithPolicyAndAnchor();

        vm.startPrank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);
        // Downgrade KYB while inactive
        lr.updateLender(lenderIdA_u256, "Alpha Capital", "US-DE", LenderRegistry.KybStatus.EXPIRED, signerA);
        lr.reactivateLender(lenderIdA_u256);
        vm.stopPrank();

        // Now active but KYB is EXPIRED
        assertTrue(lr.isActive(lenderIdA_u256));
        assertEq(uint8(lr.getLender(lenderIdA_u256).kybStatus), uint8(LenderRegistry.KybStatus.EXPIRED));

        // Publish and anchor should still fail because KYB is not VERIFIED
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderPolicyRegistry.LenderNotVerified.selector, lenderIdA_u256));
        lpr.publishPolicy(lenderIdA_u256, ASSET_CLASS_SILVER, POLICY_H_V2, T0, T0 + 30 days);

        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_2, lenderIdA, POLICY_H_V1);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotVerified.selector, lenderIdA));
        cpa.anchorAssessment(input);
    }

    function test_Reactivation_HistoricalAnchorStillImmutable() public {
        _setupWithPolicyAndAnchor();
        CollateralPositionAnchor.AnchorRecord memory before = cpa.getAssessment(ASSET_1, 0);

        vm.startPrank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);
        lr.reactivateLender(lenderIdA_u256);
        vm.stopPrank();

        CollateralPositionAnchor.AnchorRecord memory afterR = cpa.getAssessment(ASSET_1, 0);
        assertEq(afterR.assessmentHash, before.assessmentHash);
        assertEq(afterR.policyHash, before.policyHash);
        assertEq(afterR.anchoredAt, before.anchoredAt);
        assertEq(afterR.creditCapacity, before.creditCapacity);
    }

    // ══════════════════════════════════════════════════════════════
    // E — POLICY VERSIONING (5 tests)
    // ══════════════════════════════════════════════════════════════

    function test_Versioning_AutoSupersedeCouplesToNewHash() public {
        uint256 v1 = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        vm.warp(T0 + 5 days);
        uint256 v2 =
            _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V2, T0 + 5 days, T0 + 60 days);

        assertFalse(lpr.getPolicy(v1).active);
        assertEq(lpr.getPolicy(v1).policyHash, POLICY_H_V1);
        assertTrue(lpr.getPolicy(v2).active);
        assertEq(lpr.getPolicy(v2).policyHash, POLICY_H_V2);
        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), v2);
        assertEq(lpr.totalPolicies(), 2);
    }

    function test_Versioning_HistoricalAnchorStaysWithV1Hash() public {
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        vm.warp(T0 + 5 days);
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V2, T0 + 5 days, T0 + 60 days);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V2));

        // Historical anchor at index 0 still references V1 hash
        assertEq(cpa.getAssessment(ASSET_1, 0).policyHash, POLICY_H_V1);
        assertEq(cpa.getAssessment(ASSET_1, 1).policyHash, POLICY_H_V2);
        assertEq(cpa.historyLength(ASSET_1, lenderIdA), 2);
        assertEq(cpa.latest(ASSET_1, lenderIdA).policyHash, POLICY_H_V2);
    }

    function test_Versioning_ExplicitDeprecationEmitsNoSupersede() public {
        uint256 v1 = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        vm.prank(governanceAddr);
        lpr.deprecatePolicy(v1);

        // activePolicyOf cleared to 0
        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), 0);

        // Publish V2: no PolicySuperseded event because activePolicyOf was 0
        // (verified by absence of event; we assert the state instead)
        uint256 v2 = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V2, T0, T0 + 30 days);

        // V1 remains deprecated (not superseded), V2 is new active
        assertFalse(lpr.getPolicy(v1).active);
        assertTrue(lpr.getPolicy(v2).active);
        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), v2);
    }

    function test_Versioning_UpdatePolicyValidityDoesNotChangeAnchor() public {
        uint256 v1 = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        bytes32 anchorPolicyHashBefore = cpa.getAssessment(ASSET_1, 0).policyHash;
        uint64 anchorValidUntilBefore = cpa.getAssessment(ASSET_1, 0).validUntil;

        // Update LPR policy's effectiveUntil
        vm.prank(governanceAddr);
        lpr.updatePolicyValidity(v1, T0 + 90 days);

        // LPR policyHash unchanged
        assertEq(lpr.getPolicy(v1).policyHash, POLICY_H_V1);
        assertEq(lpr.getPolicy(v1).effectiveUntil, T0 + 90 days);

        // Anchor's policyHash and validUntil unchanged
        assertEq(cpa.getAssessment(ASSET_1, 0).policyHash, anchorPolicyHashBefore);
        assertEq(cpa.getAssessment(ASSET_1, 0).validUntil, anchorValidUntilBefore);
    }

    function test_Versioning_ThreeVersionsAllReadable() public {
        uint256 v1 = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        vm.warp(T0 + 10 days);
        uint256 v2 =
            _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V2, T0 + 10 days, T0 + 40 days);
        vm.warp(T0 + 20 days);
        uint256 v3 =
            _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V3, T0 + 20 days, T0 + 50 days);

        assertFalse(lpr.getPolicy(v1).active);
        assertFalse(lpr.getPolicy(v2).active);
        assertTrue(lpr.getPolicy(v3).active);
        assertEq(lpr.getPolicy(v1).policyHash, POLICY_H_V1);
        assertEq(lpr.getPolicy(v2).policyHash, POLICY_H_V2);
        assertEq(lpr.getPolicy(v3).policyHash, POLICY_H_V3);
        assertEq(lpr.totalPolicies(), 3);
        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), v3);
    }

    // ══════════════════════════════════════════════════════════════
    // F — MULTI-LENDER / SAME ASSET (5 tests)
    // ══════════════════════════════════════════════════════════════

    function _setupTwoLenderPolicies() internal {
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_A, T0, T0 + 30 days);
        _publishPolicyAsGovernance(lenderIdB_u256, ASSET_CLASS_GOLD, POLICY_H_B, T0, T0 + 30 days);
    }

    function test_MultiLender_TwoIndependentPoliciesForSameAssetClass() public {
        _setupTwoLenderPolicies();

        assertEq(lpr.getActivePolicyId(lenderIdA_u256, ASSET_CLASS_GOLD), 1);
        assertEq(lpr.getActivePolicyId(lenderIdB_u256, ASSET_CLASS_GOLD), 2);
        assertEq(lpr.getPolicy(1).policyHash, POLICY_H_A);
        assertEq(lpr.getPolicy(2).policyHash, POLICY_H_B);
    }

    function test_MultiLender_TwoIndependentAssessmentsForSameAsset() public {
        _setupTwoLenderPolicies();

        // Lender A's assessment
        CollateralPositionAnchor.AnchorInput memory inputA = _buildAssessment(ASSET_1, lenderIdA, POLICY_H_A);
        inputA.haircutBps = 2000;
        inputA.maxLTVBps = 5000;
        inputA.creditCapacity = 40 ether;
        uint256 idA = _anchorAsGovernance(inputA);

        // Lender B's assessment
        vm.warp(T0 + 1);
        CollateralPositionAnchor.AnchorInput memory inputB = _buildAssessment(ASSET_1, lenderIdB, POLICY_H_B);
        inputB.haircutBps = 3000;
        inputB.maxLTVBps = 4000;
        inputB.creditCapacity = 28 ether;
        uint256 idB = _anchorAsGovernance(inputB);

        assertTrue(idA != idB);
        assertEq(cpa.latest(ASSET_1, lenderIdA).policyHash, POLICY_H_A);
        assertEq(cpa.latest(ASSET_1, lenderIdB).policyHash, POLICY_H_B);
    }

    function test_MultiLender_PerLenderIndicesDoNotCrossContaminate() public {
        _setupTwoLenderPolicies();

        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_A));
        vm.warp(T0 + 1);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_A));
        vm.warp(T0 + 2);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdB, POLICY_H_B));

        assertEq(cpa.historyLength(ASSET_1), 3);
        assertEq(cpa.historyLength(ASSET_1, lenderIdA), 2);
        assertEq(cpa.historyLength(ASSET_1, lenderIdB), 1);
    }

    function test_MultiLender_LatestAssetReturnsMostRecentAcrossLenders() public {
        _setupTwoLenderPolicies();

        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_A));
        vm.warp(T0 + 1);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdB, POLICY_H_B));
        vm.warp(T0 + 2);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_A));

        // Most recent write was lender A's second anchor
        assertEq(cpa.latest(ASSET_1).lenderId, lenderIdA);
    }

    function test_MultiLender_FieldVarianceAcrossLenderPolicies() public {
        _setupTwoLenderPolicies();

        CollateralPositionAnchor.AnchorInput memory inputA = _buildAssessment(ASSET_1, lenderIdA, POLICY_H_A);
        inputA.haircutBps = 1500;
        inputA.maxLTVBps = 7000;
        inputA.eligibleValue = 100 ether;
        inputA.creditCapacity = 70 ether;
        inputA.verdict = 0; // ELIGIBLE
        _anchorAsGovernance(inputA);

        vm.warp(T0 + 1);
        CollateralPositionAnchor.AnchorInput memory inputB = _buildAssessment(ASSET_1, lenderIdB, POLICY_H_B);
        inputB.haircutBps = 4000;
        inputB.maxLTVBps = 3000;
        inputB.eligibleValue = 100 ether;
        inputB.creditCapacity = 18 ether;
        inputB.verdict = 0;
        _anchorAsGovernance(inputB);

        CollateralPositionAnchor.AnchorRecord memory rA = cpa.latest(ASSET_1, lenderIdA);
        CollateralPositionAnchor.AnchorRecord memory rB = cpa.latest(ASSET_1, lenderIdB);

        assertTrue(rA.haircutBps != rB.haircutBps);
        assertTrue(rA.maxLTVBps != rB.maxLTVBps);
        assertTrue(rA.creditCapacity != rB.creditCapacity);
        assertTrue(rA.policyHash != rB.policyHash);
    }

    // ══════════════════════════════════════════════════════════════
    // G — POLICY / ANCHOR BOUNDARY (3 tests)
    // ══════════════════════════════════════════════════════════════

    function test_Boundary_AnchorAcceptsPolicyHashWithoutLprRecord() public {
        // This is the approved MVP-03A boundary per
        // LINDFI_COLLATERAL_POSITION_ANCHOR_MICROSPEC_FINAL.md §11.8.
        // Off-chain pipeline is responsible for policyHash
        // correspondence to a real lender policy. Do NOT modify this
        // behavior in-contract.

        // Deliberately do NOT publish any policy
        assertEq(lpr.totalPolicies(), 0);

        bytes32 arbitraryHash = keccak256("hash-never-seen-by-lpr");
        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, lenderIdA, arbitraryHash);

        uint256 anchorId = _anchorAsGovernance(input);

        assertEq(anchorId, 1);
        assertEq(cpa.getAssessment(ASSET_1, 0).policyHash, arbitraryHash);
        assertEq(lpr.totalPolicies(), 0); // Still 0, CPA did not consult LPR
    }

    function test_Boundary_AnchorAcceptsPolicyHashAfterDeprecation() public {
        // Same approved boundary: deprecated status in LPR does NOT
        // block the anchor. Do NOT modify this behavior in-contract.
        uint256 v1 = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        vm.prank(governanceAddr);
        lpr.deprecatePolicy(v1);

        // Anchor with the deprecated policyHash still succeeds
        uint256 anchorId = _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        assertEq(anchorId, 1);
        assertEq(cpa.getAssessment(ASSET_1, 0).policyHash, POLICY_H_V1);
        assertFalse(lpr.getPolicy(v1).active); // LPR reports deprecated
    }

    function test_Boundary_AnchorAcceptsArbitraryPolicyHashWhenLpArgumentDiffers() public {
        // Same approved boundary: CPA does not verify that policyHash
        // matches the active LPR policy for (lender, assetClass).
        // Do NOT modify this behavior in-contract.
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        // Anchor with a completely different hash than the active policy
        bytes32 unrelatedHash = keccak256("unrelated-hash");
        uint256 anchorId = _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, unrelatedHash));

        assertEq(anchorId, 1);
        assertEq(cpa.getAssessment(ASSET_1, 0).policyHash, unrelatedHash);
        // LPR active policy is still V1, unrelated to what got anchored
        assertEq(lpr.getPolicy(1).policyHash, POLICY_H_V1);
    }

    // ══════════════════════════════════════════════════════════════
    // H — SNAPSHOT STATE SEMANTICS (3 tests)
    // ══════════════════════════════════════════════════════════════

    function test_State_MultiRecord_LatestOnly() public {
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        // v1 covers [T0, T0+30d]
        CollateralPositionAnchor.AnchorInput memory input1 = _buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1);
        input1.performedAt = T0;
        input1.validUntil = T0 + 30 days;
        _anchorAsGovernance(input1);

        // v2 at T0+15d covers [T0+15d, T0+60d]
        vm.warp(T0 + 15 days);
        CollateralPositionAnchor.AnchorInput memory input2 = _buildAssessment(ASSET_1, lenderIdA, POLICY_H_V2);
        input2.performedAt = T0 + 15 days;
        input2.validUntil = T0 + 60 days;
        _anchorAsGovernance(input2);

        // At T0+5d: latest=v2, v2.performedAt = T0+15d, 5d<15d → UNKNOWN.
        // If historical time-travel existed, v1 would say ACTIVE.
        assertEq(uint8(cpa.state(ASSET_1, lenderIdA, T0 + 5 days)), uint8(CollateralPositionAnchor.State.UNKNOWN));
        // At T0+20d: within v2's window → ACTIVE
        assertEq(uint8(cpa.state(ASSET_1, lenderIdA, T0 + 20 days)), uint8(CollateralPositionAnchor.State.ACTIVE));
        // At T0+70d: past v2.validUntil → EXPIRED
        assertEq(uint8(cpa.state(ASSET_1, lenderIdA, T0 + 70 days)), uint8(CollateralPositionAnchor.State.EXPIRED));
    }

    function test_State_DoesNotDependOnLenderStatus() public {
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        vm.prank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);

        // state() still ACTIVE because it doesn't consult LR
        assertEq(uint8(cpa.state(ASSET_1, lenderIdA, T0 + 5 days)), uint8(CollateralPositionAnchor.State.ACTIVE));
    }

    function test_State_DoesNotDependOnPolicyStatus() public {
        uint256 v1 = _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        vm.prank(governanceAddr);
        lpr.deprecatePolicy(v1);

        // state() still ACTIVE because it doesn't consult LPR
        assertEq(uint8(cpa.state(ASSET_1, lenderIdA, T0 + 5 days)), uint8(CollateralPositionAnchor.State.ACTIVE));
    }

    // ══════════════════════════════════════════════════════════════
    // I — GOVERNANCE COMPOSITION (4 tests)
    // ══════════════════════════════════════════════════════════════

    function test_Governance_InitialParity() public {
        assertEq(lr.governance(), governanceAddr);
        assertEq(lpr.governance(), governanceAddr);
        assertEq(cpa.governance(), governanceAddr);
    }

    function test_Governance_SplitIsOperationallyPossible() public {
        // Transfer only LR governance
        vm.prank(governanceAddr);
        lr.transferGovernance(newGovernance);
        vm.prank(newGovernance);
        lr.acceptGovernance();

        // LR governance changed, LPR and CPA unchanged (SPLIT)
        assertEq(lr.governance(), newGovernance);
        assertEq(lpr.governance(), governanceAddr);
        assertEq(cpa.governance(), governanceAddr);

        // §21.8: CPA can still read LR via view calls
        assertEq(cpa.lenderRegistry(), address(lr));

        // Register a new lender via LR as newGovernance
        vm.prank(newGovernance);
        uint256 newLenderId = lr.registerLender("Gamma Fund", "AR", LenderRegistry.KybStatus.VERIFIED, signerC);

        // Anchor for that lender via CPA as governanceAddr (CPA's gov unchanged)
        // The CPA calls LR.getLender() as a view - not governance-gated
        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, uint32(newLenderId), POLICY_H_V1);
        vm.prank(governanceAddr);
        uint256 anchorId = cpa.anchorAssessment(input);
        assertEq(anchorId, 1);

        // Publish via LPR as governanceAddr still works (LPR gov unchanged)
        vm.prank(governanceAddr);
        lpr.publishPolicy(newLenderId, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        // But governanceAddr CANNOT register a new lender in LR
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.NotGovernance.selector);
        lr.registerLender("Delta Fund", "US", LenderRegistry.KybStatus.VERIFIED, address(0xDEAD));
    }

    function test_Governance_FullSyncTransfer() public {
        // Transfer all three contracts in sequence
        vm.startPrank(governanceAddr);
        lr.transferGovernance(newGovernance);
        lpr.transferGovernance(newGovernance);
        cpa.transferGovernance(newGovernance);
        vm.stopPrank();

        vm.startPrank(newGovernance);
        lr.acceptGovernance();
        lpr.acceptGovernance();
        cpa.acceptGovernance();
        vm.stopPrank();

        // All three now under newGovernance
        assertEq(lr.governance(), newGovernance);
        assertEq(lpr.governance(), newGovernance);
        assertEq(cpa.governance(), newGovernance);

        // Full operational cycle as newGovernance
        vm.startPrank(newGovernance);
        uint256 lId = lr.registerLender("Epsilon Fund", "SG", LenderRegistry.KybStatus.VERIFIED, signerC);
        lpr.publishPolicy(lId, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        vm.stopPrank();

        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, uint32(lId), POLICY_H_V1);
        vm.prank(newGovernance);
        uint256 aId = cpa.anchorAssessment(input);
        assertEq(aId, 1);
    }

    function test_Governance_TransferOnlyLpr_BreaksPublishFromOldGovernance() public {
        // Transfer only LPR governance
        vm.prank(governanceAddr);
        lpr.transferGovernance(newGovernance);
        vm.prank(newGovernance);
        lpr.acceptGovernance();

        assertEq(lpr.governance(), newGovernance);
        assertEq(lr.governance(), governanceAddr);
        assertEq(cpa.governance(), governanceAddr);

        // Old governanceAddr cannot publish as governance path (fails NotAuthorized:
        // msg.sender is neither LPR's new governance nor the lender's signer)
        vm.prank(governanceAddr);
        vm.expectRevert(LenderPolicyRegistry.NotAuthorized.selector);
        lpr.publishPolicy(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        // But the lender's signer can still publish (signer path)
        vm.prank(signerA);
        uint256 policyId = lpr.publishPolicy(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        assertTrue(policyId > 0);

        // Anchor still works as governanceAddr (CPA gov unchanged)
        uint256 aId = _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));
        assertEq(aId, 1);
    }

    // ══════════════════════════════════════════════════════════════
    // J — CONSTRUCTOR TRIANGULATION (2 tests)
    // ══════════════════════════════════════════════════════════════

    function test_Triangulation_InitialWiringConsistent() public {
        // Wiring
        assertEq(lpr.lenderRegistry(), address(lr));
        assertEq(cpa.lenderRegistry(), address(lr));
        assertEq(cpa.lenderPolicyRegistry(), address(lpr));

        // Initial governance parity
        assertEq(lr.governance(), governanceAddr);
        assertEq(lpr.governance(), governanceAddr);
        assertEq(cpa.governance(), governanceAddr);
    }

    function test_Triangulation_ImmutabilityAcrossStateChanges() public {
        // Snapshot immutable references
        address lprLR = lpr.lenderRegistry();
        address cpaLR = cpa.lenderRegistry();
        address cpaLPR = cpa.lenderPolicyRegistry();

        // Execute compositional cycle
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));

        vm.startPrank(governanceAddr);
        lr.deactivateLender(lenderIdA_u256);
        lr.reactivateLender(lenderIdA_u256);
        vm.stopPrank();

        // Transfer governance on one contract
        vm.prank(governanceAddr);
        lr.transferGovernance(newGovernance);
        vm.prank(newGovernance);
        lr.acceptGovernance();

        // Transfer governance on the remaining two
        vm.startPrank(governanceAddr);
        lpr.transferGovernance(newGovernance);
        cpa.transferGovernance(newGovernance);
        vm.stopPrank();
        vm.startPrank(newGovernance);
        lpr.acceptGovernance();
        cpa.acceptGovernance();
        vm.stopPrank();

        // After all state changes, immutable refs unchanged byte-for-byte
        assertEq(lpr.lenderRegistry(), lprLR);
        assertEq(cpa.lenderRegistry(), cpaLR);
        assertEq(cpa.lenderPolicyRegistry(), cpaLPR);
    }

    // ══════════════════════════════════════════════════════════════
    // K — NO CUSTODY (3 tests)
    // ══════════════════════════════════════════════════════════════

    function test_NoCustody_AllThreeContractsRejectEth() public {
        vm.deal(address(this), 3 ether);

        (bool sent1,) = address(lr).call{value: 1 ether}("");
        assertFalse(sent1);
        assertEq(address(lr).balance, 0);

        (bool sent2,) = address(lpr).call{value: 1 ether}("");
        assertFalse(sent2);
        assertEq(address(lpr).balance, 0);

        (bool sent3,) = address(cpa).call{value: 1 ether}("");
        assertFalse(sent3);
        assertEq(address(cpa).balance, 0);
    }

    function test_NoCustody_BalancesStayZeroAcrossFullLifecycle() public {
        assertEq(address(lr).balance, 0);
        assertEq(address(lpr).balance, 0);
        assertEq(address(cpa).balance, 0);

        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);
        assertEq(address(lr).balance, 0);
        assertEq(address(lpr).balance, 0);
        assertEq(address(cpa).balance, 0);

        _anchorAsGovernance(_buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1));
        assertEq(address(lr).balance, 0);
        assertEq(address(lpr).balance, 0);
        assertEq(address(cpa).balance, 0);
    }

    function test_NoFinancialCalculation_AnchorStoresInputVerbatim() public {
        _publishPolicyAsGovernance(lenderIdA_u256, ASSET_CLASS_GOLD, POLICY_H_V1, T0, T0 + 30 days);

        CollateralPositionAnchor.AnchorInput memory input = _buildAssessment(ASSET_1, lenderIdA, POLICY_H_V1);
        input.eligibleValue = 100 ether;
        input.creditCapacity = 40 ether;
        input.haircutBps = 2000;
        input.maxLTVBps = 5000;

        _anchorAsGovernance(input);

        // Verify stored verbatim - NOT re-derived
        CollateralPositionAnchor.AnchorRecord memory r = cpa.latest(ASSET_1, lenderIdA);
        assertEq(r.eligibleValue, 100 ether);
        assertEq(r.creditCapacity, 40 ether);
        assertEq(r.haircutBps, 2000);
        assertEq(r.maxLTVBps, 5000);

        // Contract did NOT re-derive creditCapacity = 100 * 5000 / 10000 = 50 ether
        // Stored 40 as written
        assertTrue(r.creditCapacity != 50 ether);
    }
}
