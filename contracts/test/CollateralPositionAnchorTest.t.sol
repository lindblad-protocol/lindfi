// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Constants} from "../src/Constants.sol";
import {LenderRegistry} from "../src/LenderRegistry.sol";
import {LenderPolicyRegistry} from "../src/LenderPolicyRegistry.sol";
import {CollateralPositionAnchor, ILenderRegistry, ILenderPolicyRegistry} from "../src/CollateralPositionAnchor.sol";

/// @title CollateralPositionAnchorTest
/// @notice Covers every invariant in the approved
///         CollateralPositionAnchor micro-spec (§12.1 through §12.14).
///         Uses AnchorInput calldata DTO throughout (per FINAL spec).
contract CollateralPositionAnchorTest is Test {
    LenderRegistry internal lenderRegistry;
    LenderPolicyRegistry internal lenderPolicyRegistry;
    CollateralPositionAnchor internal anchor;

    address internal governanceAddr;
    address internal notGovernance = address(0xBAD);
    address internal newGovernance = address(0x1234);

    address internal signerA = address(0xA11CE);
    address internal signerB = address(0xB0B);

    uint256 internal lenderIdA_u256;
    uint256 internal lenderIdB_u256;
    uint32 internal lenderIdA;
    uint32 internal lenderIdB;

    bytes32 internal constant ASSET_1 = bytes32(uint256(0xa55e71));
    bytes32 internal constant ASSET_2 = bytes32(uint256(0xa55e72));
    bytes32 internal constant ASSESSMENT_H = keccak256("assessment-1");
    bytes32 internal constant NAV_H = keccak256("nav-1");
    bytes32 internal constant POLICY_H = keccak256("policy-1");
    bytes32 internal constant CURRENCY_USD = bytes32("USD");
    bytes32 internal constant ROLE_ANALYST = bytes32("ANALYST");

    // ─── Local event declarations for vm.expectEmit ────────────────

    event AssessmentAnchored(
        uint256 indexed anchorId,
        bytes32 indexed assetId,
        uint32 indexed lenderId,
        uint8 verdict,
        address writer,
        bytes32 writerRole,
        uint64 anchoredAt,
        uint64 validUntil
    );

    event AssessmentHashes(uint256 indexed anchorId, bytes32 assessmentHash, bytes32 navHash, bytes32 policyHash);

    event AssessmentAmounts(
        uint256 indexed anchorId,
        uint16 haircutBps,
        uint16 maxLTVBps,
        uint256 eligibleValue,
        uint256 creditCapacity,
        bytes32 currencyCode,
        uint64 performedAt,
        bool demoAtAnchoring
    );

    event GovernanceTransferInitiated(address indexed previousGovernance, address indexed newGovernance);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    function setUp() public {
        vm.chainId(Constants.CHAIN_ARBITRUM_SEPOLIA);
        governanceAddr = Constants.expectedSafeFor(block.chainid);

        lenderRegistry = new LenderRegistry(governanceAddr);
        lenderPolicyRegistry = new LenderPolicyRegistry(governanceAddr, address(lenderRegistry));
        anchor = new CollateralPositionAnchor(governanceAddr, address(lenderRegistry), address(lenderPolicyRegistry));

        vm.startPrank(governanceAddr);
        lenderIdA_u256 =
            lenderRegistry.registerLender("Alpha Capital", "US-DE", LenderRegistry.KybStatus.VERIFIED, signerA);
        lenderIdB_u256 = lenderRegistry.registerLender("Beta Fund", "BO", LenderRegistry.KybStatus.VERIFIED, signerB);
        vm.stopPrank();

        lenderIdA = uint32(lenderIdA_u256);
        lenderIdB = uint32(lenderIdB_u256);
    }

    // ─── Test helpers ──────────────────────────────────────────────

    /// @dev Build a default valid input for the given asset/lender.
    function _validInput(bytes32 assetId, uint32 lenderId)
        internal
        view
        returns (CollateralPositionAnchor.AnchorInput memory)
    {
        return CollateralPositionAnchor.AnchorInput({
            assetId: assetId,
            assessmentHash: ASSESSMENT_H,
            navHash: NAV_H,
            policyHash: POLICY_H,
            lenderId: lenderId,
            haircutBps: 2000,
            maxLTVBps: 5000,
            eligibleValue: 100 ether,
            creditCapacity: 50 ether,
            currencyCode: CURRENCY_USD,
            verdict: 0,
            writerRole: ROLE_ANALYST,
            performedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 30 days),
            demoAtAnchoring: true
        });
    }

    /// @dev Anchor a default record for the pair.
    function _anchor(bytes32 assetId, uint32 lenderId) internal returns (uint256) {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(assetId, lenderId);
        vm.prank(governanceAddr);
        return anchor.anchorAssessment(input);
    }

    /// @dev Anchor with specific assessmentHash, verdict, performedAt, validUntil.
    function _anchorFull(
        bytes32 assetId,
        bytes32 assessmentHash,
        uint32 lenderId,
        uint8 verdict,
        uint64 performedAt,
        uint64 validUntil
    ) internal returns (uint256) {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(assetId, lenderId);
        input.assessmentHash = assessmentHash;
        input.verdict = verdict;
        input.performedAt = performedAt;
        input.validUntil = validUntil;
        vm.prank(governanceAddr);
        return anchor.anchorAssessment(input);
    }

    // ── §12.1 Constructor ─────────────────────────────────────────

    function test_Constructor_RevertsOnZeroGovernance() public {
        vm.expectRevert(CollateralPositionAnchor.ZeroGovernance.selector);
        new CollateralPositionAnchor(address(0), address(lenderRegistry), address(lenderPolicyRegistry));
    }

    function test_Constructor_RevertsOnZeroLenderRegistry() public {
        vm.expectRevert(CollateralPositionAnchor.ZeroLenderRegistry.selector);
        new CollateralPositionAnchor(governanceAddr, address(0), address(lenderPolicyRegistry));
    }

    function test_Constructor_RevertsOnZeroLenderPolicyRegistry() public {
        vm.expectRevert(CollateralPositionAnchor.ZeroLenderPolicyRegistry.selector);
        new CollateralPositionAnchor(governanceAddr, address(lenderRegistry), address(0));
    }

    function test_Constructor_RevertsOnLenderRegistryGovernanceMismatch() public {
        address altGov = address(0xC0FFEE);
        LenderRegistry altLR = new LenderRegistry(altGov);
        LenderPolicyRegistry altLPR = new LenderPolicyRegistry(altGov, address(altLR));

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralPositionAnchor.LenderRegistryGovernanceMismatch.selector, altGov, governanceAddr
            )
        );
        new CollateralPositionAnchor(governanceAddr, address(altLR), address(altLPR));
    }

    function test_Constructor_RevertsOnLenderPolicyRegistryGovernanceMismatch() public {
        address altGov = address(0xC0FFEE);
        LenderRegistry altLR = new LenderRegistry(altGov);
        LenderPolicyRegistry altLPR = new LenderPolicyRegistry(altGov, address(altLR));

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralPositionAnchor.LenderPolicyRegistryGovernanceMismatch.selector, altGov, governanceAddr
            )
        );
        new CollateralPositionAnchor(governanceAddr, address(lenderRegistry), address(altLPR));
    }

    function test_Constructor_RevertsOnLenderPolicyRegistryRegistryMismatch() public {
        LenderRegistry otherLR = new LenderRegistry(governanceAddr);
        LenderPolicyRegistry otherLPR = new LenderPolicyRegistry(governanceAddr, address(otherLR));

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralPositionAnchor.LenderPolicyRegistryRegistryMismatch.selector,
                address(otherLR),
                address(lenderRegistry)
            )
        );
        new CollateralPositionAnchor(governanceAddr, address(lenderRegistry), address(otherLPR));
    }

    function test_Constructor_SetsAllReferences() public {
        assertEq(anchor.governance(), governanceAddr);
        assertEq(anchor.lenderRegistry(), address(lenderRegistry));
        assertEq(anchor.lenderPolicyRegistry(), address(lenderPolicyRegistry));
    }

    function test_Constructor_PendingGovernanceIsZero() public {
        assertEq(anchor.pendingGovernance(), address(0));
    }

    function test_Constructor_NextAnchorIdStartsAtOne() public {
        uint256 first = _anchor(ASSET_1, lenderIdA);
        assertEq(first, 1);
    }

    // ── §12.2 anchorAssessment authorization ──────────────────────

    function test_AnchorAssessment_RevertsIfNotGovernance() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        vm.prank(notGovernance);
        vm.expectRevert(CollateralPositionAnchor.NotGovernance.selector);
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_LenderSignerCannotWrite() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        vm.prank(signerA);
        vm.expectRevert(CollateralPositionAnchor.NotGovernance.selector);
        anchor.anchorAssessment(input);
    }

    // ── §12.3 anchorAssessment frozen validations ─────────────────

    function test_AnchorAssessment_RevertsOnZeroAssessmentHash() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.assessmentHash = bytes32(0);
        vm.prank(governanceAddr);
        vm.expectRevert(CollateralPositionAnchor.ZeroAssessmentHash.selector);
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnZeroNavHash() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.navHash = bytes32(0);
        vm.prank(governanceAddr);
        vm.expectRevert(CollateralPositionAnchor.ZeroNavHash.selector);
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnZeroPolicyHash() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.policyHash = bytes32(0);
        vm.prank(governanceAddr);
        vm.expectRevert(CollateralPositionAnchor.ZeroPolicyHash.selector);
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnZeroCurrencyCode() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.currencyCode = bytes32(0);
        vm.prank(governanceAddr);
        vm.expectRevert(CollateralPositionAnchor.ZeroCurrencyCode.selector);
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsIfValidUntilEqualsPerformedAt() public {
        uint64 t = uint64(block.timestamp);
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.performedAt = t;
        input.validUntil = t;
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.InvalidValidityWindow.selector, t, t));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsIfValidUntilBeforePerformedAt() public {
        uint64 t = uint64(block.timestamp + 100);
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.performedAt = t;
        input.validUntil = t - 1;
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.InvalidValidityWindow.selector, t, t - 1));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsIfCreditCapacityExceedsEligibleValue() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.eligibleValue = 100 ether;
        input.creditCapacity = 100 ether + 1;
        vm.prank(governanceAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralPositionAnchor.CreditCapacityExceedsEligibleValue.selector, 100 ether + 1, 100 ether
            )
        );
        anchor.anchorAssessment(input);
    }

    // ── §12.4 anchorAssessment approved validations ───────────────

    function test_AnchorAssessment_RevertsOnInvalidVerdict() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.verdict = 3;
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.InvalidVerdict.selector, 3));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnInvalidHaircutBps() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.haircutBps = 10_001;
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.InvalidHaircutBps.selector, 10_001));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnInvalidMaxLTVBps() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.maxLTVBps = 10_001;
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.InvalidMaxLTVBps.selector, 10_001));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_AllowsBpsAt10_000() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.haircutBps = 10_000;
        input.maxLTVBps = 10_000;
        vm.prank(governanceAddr);
        uint256 id = anchor.anchorAssessment(input);
        assertEq(id, 1);
    }

    function test_AnchorAssessment_RevertsOnZeroWriterRole() public {
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.writerRole = bytes32(0);
        vm.prank(governanceAddr);
        vm.expectRevert(CollateralPositionAnchor.ZeroWriterRole.selector);
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_AcceptsAllValidVerdicts() public {
        for (uint8 v = 0; v <= 2; v++) {
            _anchorFull(
                ASSET_1,
                keccak256(abi.encodePacked("v", v)),
                lenderIdA,
                v,
                uint64(block.timestamp),
                uint64(block.timestamp + 30 days)
            );
            CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1, lenderIdA);
            assertEq(r.verdict, v);
        }
    }

    // ── §12.5 anchorAssessment lender dependency ──────────────────

    function test_AnchorAssessment_RevertsOnUnknownLender() public {
        uint32 unknown = 9999;
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, unknown);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderDoesNotExist.selector, uint256(unknown)));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnInactiveLender() public {
        vm.prank(governanceAddr);
        lenderRegistry.deactivateLender(lenderIdA_u256);

        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotActive.selector, lenderIdA));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnLenderPending() public {
        vm.prank(governanceAddr);
        uint256 pendingId =
            lenderRegistry.registerLender("Pending", "US", LenderRegistry.KybStatus.PENDING, address(0xDEAD));

        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, uint32(pendingId));
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotVerified.selector, uint32(pendingId)));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnLenderRejected() public {
        vm.prank(governanceAddr);
        uint256 rejId = lenderRegistry.registerLender("Rej", "US", LenderRegistry.KybStatus.REJECTED, address(0xDEAD));

        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, uint32(rejId));
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotVerified.selector, uint32(rejId)));
        anchor.anchorAssessment(input);
    }

    function test_AnchorAssessment_RevertsOnLenderExpired() public {
        vm.prank(governanceAddr);
        uint256 expId = lenderRegistry.registerLender("Exp", "US", LenderRegistry.KybStatus.EXPIRED, address(0xDEAD));

        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, uint32(expId));
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.LenderNotVerified.selector, uint32(expId)));
        anchor.anchorAssessment(input);
    }

    // ── §12.6 anchorAssessment storage effects ────────────────────

    function test_AnchorAssessment_MonotonicIds() public {
        uint256 id1 = _anchor(ASSET_1, lenderIdA);
        uint256 id2 = _anchor(ASSET_1, lenderIdA);
        uint256 id3 = _anchor(ASSET_2, lenderIdB);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_AnchorAssessment_PopulatesAllSeventeenFields() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        CollateralPositionAnchor.AnchorInput memory input = _validInput(ASSET_1, lenderIdA);
        input.haircutBps = 2500;
        input.maxLTVBps = 6000;
        input.eligibleValue = 120 ether;
        input.creditCapacity = 72 ether;
        input.verdict = 2; // POLICY_MISSING
        input.performedAt = t - 100;
        input.validUntil = t + 100 days;

        vm.prank(governanceAddr);
        uint256 id = anchor.anchorAssessment(input);

        CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1, lenderIdA);

        // Verify all 17 fields
        assertEq(r.assetId, ASSET_1); // 1
        assertEq(r.assessmentHash, ASSESSMENT_H); // 2
        assertEq(r.navHash, NAV_H); // 3
        assertEq(r.policyHash, POLICY_H); // 4
        assertEq(r.lenderId, lenderIdA); // 5
        assertEq(r.haircutBps, 2500); // 6
        assertEq(r.maxLTVBps, 6000); // 7
        assertEq(r.eligibleValue, 120 ether); // 8
        assertEq(r.creditCapacity, 72 ether); // 9
        assertEq(r.currencyCode, CURRENCY_USD); // 10
        assertEq(r.verdict, 2); // 11
        assertEq(r.writer, governanceAddr); // 12
        assertEq(r.writerRole, ROLE_ANALYST); // 13
        assertEq(r.performedAt, t - 100); // 14
        assertEq(r.anchoredAt, t); // 15 (contract-set)
        assertEq(r.validUntil, t + 100 days); // 16
        assertTrue(r.demoAtAnchoring); // 17
        assertEq(id, 1);
    }

    function test_AnchorAssessment_WriterIsMsgSender() public {
        _anchor(ASSET_1, lenderIdA);
        CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1, lenderIdA);
        assertEq(r.writer, governanceAddr);
    }

    function test_AnchorAssessment_AnchoredAtIsBlockTimestamp() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        _anchor(ASSET_1, lenderIdA);
        CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1, lenderIdA);
        assertEq(r.anchoredAt, t);
    }

    function test_AnchorAssessment_UpdatesByAssetIndex() public {
        _anchor(ASSET_1, lenderIdA);
        assertEq(anchor.historyLength(ASSET_1), 1);

        CollateralPositionAnchor.AnchorRecord memory r = anchor.getAssessment(ASSET_1, 0);
        assertEq(r.assetId, ASSET_1);
    }

    function test_AnchorAssessment_UpdatesByAssetLenderIndex() public {
        _anchor(ASSET_1, lenderIdA);
        assertEq(anchor.historyLength(ASSET_1, lenderIdA), 1);

        CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1, lenderIdA);
        assertEq(r.lenderId, lenderIdA);
    }

    function test_AnchorAssessment_EmitsAssessmentAnchored() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        vm.expectEmit(true, true, true, true);
        emit AssessmentAnchored(1, ASSET_1, lenderIdA, 0, governanceAddr, ROLE_ANALYST, t, uint64(t + 30 days));
        _anchor(ASSET_1, lenderIdA);
    }

    function test_AnchorAssessment_EmitsAssessmentHashes() public {
        vm.expectEmit(true, false, false, true);
        emit AssessmentHashes(1, ASSESSMENT_H, NAV_H, POLICY_H);
        _anchor(ASSET_1, lenderIdA);
    }

    function test_AnchorAssessment_EmitsAssessmentAmounts() public {
        uint64 t = uint64(block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit AssessmentAmounts(1, 2000, 5000, 100 ether, 50 ether, CURRENCY_USD, t, true);
        _anchor(ASSET_1, lenderIdA);
    }

    // ── §12.7 anchorAssessment duplicates allowed ─────────────────

    function test_AnchorAssessment_DuplicateAssessmentHashAllowed() public {
        uint256 id1 = _anchor(ASSET_1, lenderIdA);
        vm.warp(block.timestamp + 1);
        uint256 id2 = _anchor(ASSET_1, lenderIdA); // SAME hash (default)

        assertTrue(id1 != id2);
        assertEq(anchor.historyLength(ASSET_1, lenderIdA), 2);

        CollateralPositionAnchor.AnchorRecord memory r0 = anchor.getAssessment(ASSET_1, 0);
        CollateralPositionAnchor.AnchorRecord memory r1 = anchor.getAssessment(ASSET_1, 1);
        assertEq(r0.assessmentHash, ASSESSMENT_H);
        assertEq(r1.assessmentHash, ASSESSMENT_H);
        assertTrue(r0.anchoredAt < r1.anchoredAt);
    }

    // ── §12.8 Read function invariants ────────────────────────────

    function test_LatestPair_RevertsWhenEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.NoAnchorForPair.selector, ASSET_1, lenderIdA));
        anchor.latest(ASSET_1, lenderIdA);
    }

    function test_LatestAsset_RevertsWhenEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.NoAnchorForAsset.selector, ASSET_1));
        anchor.latest(ASSET_1);
    }

    function test_LatestAsset_ReturnsMostRecentAcrossAllLenders() public {
        _anchor(ASSET_1, lenderIdA);
        vm.warp(block.timestamp + 1);
        _anchor(ASSET_1, lenderIdB);
        vm.warp(block.timestamp + 1);
        _anchor(ASSET_1, lenderIdA);

        CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1);
        assertEq(r.lenderId, lenderIdA);
    }

    function test_HistoryLength_ZeroForUnknown() public {
        assertEq(anchor.historyLength(ASSET_1), 0);
        assertEq(anchor.historyLength(ASSET_1, lenderIdA), 0);
    }

    function test_HistoryLength_CorrectAfterAnchors() public {
        _anchor(ASSET_1, lenderIdA);
        _anchor(ASSET_1, lenderIdA);
        _anchor(ASSET_1, lenderIdB);

        assertEq(anchor.historyLength(ASSET_1), 3);
        assertEq(anchor.historyLength(ASSET_1, lenderIdA), 2);
        assertEq(anchor.historyLength(ASSET_1, lenderIdB), 1);
    }

    function test_GetAssessment_OutOfBoundsReverts() public {
        _anchor(ASSET_1, lenderIdA);
        vm.expectRevert(abi.encodeWithSelector(CollateralPositionAnchor.IndexOutOfBounds.selector, ASSET_1, 1));
        anchor.getAssessment(ASSET_1, 1);
    }

    function test_GetAssessment_InsertionOrder() public {
        uint256 t = block.timestamp;
        vm.warp(t);
        _anchorFull(ASSET_1, keccak256("a1"), lenderIdA, 0, uint64(t), uint64(t + 10 days));
        vm.warp(t + 1);
        _anchorFull(ASSET_1, keccak256("a2"), lenderIdB, 1, uint64(t + 1), uint64(t + 20 days));
        vm.warp(t + 2);
        _anchorFull(ASSET_1, keccak256("a3"), lenderIdA, 2, uint64(t + 2), uint64(t + 30 days));

        assertEq(anchor.getAssessment(ASSET_1, 0).assessmentHash, keccak256("a1"));
        assertEq(anchor.getAssessment(ASSET_1, 1).assessmentHash, keccak256("a2"));
        assertEq(anchor.getAssessment(ASSET_1, 2).assessmentHash, keccak256("a3"));
    }

    function test_TotalAnchors_MonotonicAndInitiallyZero() public {
        assertEq(anchor.totalAnchors(), 0);
        _anchor(ASSET_1, lenderIdA);
        assertEq(anchor.totalAnchors(), 1);
        _anchor(ASSET_2, lenderIdB);
        assertEq(anchor.totalAnchors(), 2);
    }

    // ── §12.9 state(...) snapshot semantics ───────────────────────

    function test_State_NoRecordReturnsUnknown() public {
        assertEq(
            uint8(anchor.state(ASSET_1, lenderIdA, uint64(block.timestamp))),
            uint8(CollateralPositionAnchor.State.UNKNOWN)
        );
    }

    function test_State_BeforePerformedAtReturnsUnknown() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        _anchorFull(ASSET_1, ASSESSMENT_H, lenderIdA, 0, t, t + 30 days);
        assertEq(uint8(anchor.state(ASSET_1, lenderIdA, t - 1)), uint8(CollateralPositionAnchor.State.UNKNOWN));
    }

    function test_State_AtPerformedAtReturnsActive() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        _anchorFull(ASSET_1, ASSESSMENT_H, lenderIdA, 0, t, t + 30 days);
        assertEq(uint8(anchor.state(ASSET_1, lenderIdA, t)), uint8(CollateralPositionAnchor.State.ACTIVE));
    }

    function test_State_BetweenPerformedAndValidUntilReturnsActive() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        _anchorFull(ASSET_1, ASSESSMENT_H, lenderIdA, 0, t, t + 30 days);
        assertEq(uint8(anchor.state(ASSET_1, lenderIdA, t + 15 days)), uint8(CollateralPositionAnchor.State.ACTIVE));
    }

    function test_State_AtValidUntilReturnsActive() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        _anchorFull(ASSET_1, ASSESSMENT_H, lenderIdA, 0, t, t + 30 days);
        assertEq(uint8(anchor.state(ASSET_1, lenderIdA, t + 30 days)), uint8(CollateralPositionAnchor.State.ACTIVE));
    }

    function test_State_AfterValidUntilReturnsExpired() public {
        uint64 t = 2_000_000_000;
        vm.warp(t);
        _anchorFull(ASSET_1, ASSESSMENT_H, lenderIdA, 0, t, t + 30 days);
        assertEq(
            uint8(anchor.state(ASSET_1, lenderIdA, t + 30 days + 1)), uint8(CollateralPositionAnchor.State.EXPIRED)
        );
    }

    function test_State_EvaluatesOnlyLatestRecord_NotHistorical() public {
        // v1 covers [t0, t0+30d]. v2 covers [t0+10d, t0+60d].
        uint64 t0 = 2_000_000_000;
        vm.warp(t0);
        _anchorFull(ASSET_1, keccak256("v1"), lenderIdA, 0, t0, t0 + 30 days);

        vm.warp(t0 + 10 days);
        _anchorFull(ASSET_1, keccak256("v2"), lenderIdA, 0, t0 + 10 days, t0 + 60 days);

        // At t0 + 20d: latest = v2. ACTIVE.
        assertEq(uint8(anchor.state(ASSET_1, lenderIdA, t0 + 20 days)), uint8(CollateralPositionAnchor.State.ACTIVE));

        // At t0 + 5d: latest = v2 with performedAt = t0+10d. 5d < 10d → UNKNOWN.
        // This is the snapshot behavior: state() only evaluates the latest record.
        assertEq(uint8(anchor.state(ASSET_1, lenderIdA, t0 + 5 days)), uint8(CollateralPositionAnchor.State.UNKNOWN));

        // At t0 + 70d: latest = v2 with validUntil = t0+60d. 70d > 60d → EXPIRED.
        assertEq(uint8(anchor.state(ASSET_1, lenderIdA, t0 + 70 days)), uint8(CollateralPositionAnchor.State.EXPIRED));
    }

    // ── §12.10 Multiple lenders on same asset ─────────────────────

    function test_MultipleLenders_IndicesDoNotCrossContaminate() public {
        _anchor(ASSET_1, lenderIdA);
        vm.warp(block.timestamp + 1);
        _anchor(ASSET_1, lenderIdA);
        vm.warp(block.timestamp + 1);
        _anchor(ASSET_1, lenderIdB);

        assertEq(anchor.historyLength(ASSET_1), 3);
        assertEq(anchor.historyLength(ASSET_1, lenderIdA), 2);
        assertEq(anchor.historyLength(ASSET_1, lenderIdB), 1);

        assertEq(anchor.latest(ASSET_1).lenderId, lenderIdB);
        assertEq(anchor.latest(ASSET_1, lenderIdA).lenderId, lenderIdA);
        assertEq(anchor.latest(ASSET_1, lenderIdB).lenderId, lenderIdB);
    }

    // ── §12.11 Records unaffected by later lender changes ─────────

    function test_Records_UnaffectedByLenderDeactivation() public {
        _anchor(ASSET_1, lenderIdA);

        vm.prank(governanceAddr);
        lenderRegistry.deactivateLender(lenderIdA_u256);

        CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1, lenderIdA);
        assertEq(r.lenderId, lenderIdA);
        assertEq(r.writer, governanceAddr);
        assertEq(r.assessmentHash, ASSESSMENT_H);
    }

    function test_Records_UnaffectedByLenderKybChange() public {
        _anchor(ASSET_1, lenderIdA);

        vm.prank(governanceAddr);
        lenderRegistry.updateLender(lenderIdA_u256, "Alpha Capital", "US-DE", LenderRegistry.KybStatus.EXPIRED, signerA);

        CollateralPositionAnchor.AnchorRecord memory r = anchor.latest(ASSET_1, lenderIdA);
        assertEq(r.lenderId, lenderIdA);
    }

    // ── §12.12 Governance transfer ────────────────────────────────

    function test_TransferGovernance_RevertsIfNotGovernance() public {
        vm.prank(notGovernance);
        vm.expectRevert(CollateralPositionAnchor.NotGovernance.selector);
        anchor.transferGovernance(newGovernance);
    }

    function test_TransferGovernance_RevertsOnZero() public {
        vm.prank(governanceAddr);
        vm.expectRevert(CollateralPositionAnchor.ZeroGovernance.selector);
        anchor.transferGovernance(address(0));
    }

    function test_TransferGovernance_SetsPendingOnly() public {
        vm.prank(governanceAddr);
        anchor.transferGovernance(newGovernance);
        assertEq(anchor.pendingGovernance(), newGovernance);
        assertEq(anchor.governance(), governanceAddr);
    }

    function test_TransferGovernance_EmitsInitiated() public {
        vm.expectEmit(true, true, false, false);
        emit GovernanceTransferInitiated(governanceAddr, newGovernance);
        vm.prank(governanceAddr);
        anchor.transferGovernance(newGovernance);
    }

    function test_AcceptGovernance_RevertsIfNotPending() public {
        vm.prank(governanceAddr);
        anchor.transferGovernance(newGovernance);
        vm.prank(notGovernance);
        vm.expectRevert(CollateralPositionAnchor.NotPendingGovernance.selector);
        anchor.acceptGovernance();
    }

    function test_AcceptGovernance_RevertsIfNoPending() public {
        vm.prank(newGovernance);
        vm.expectRevert(CollateralPositionAnchor.NotPendingGovernance.selector);
        anchor.acceptGovernance();
    }

    function test_AcceptGovernance_Completes() public {
        vm.prank(governanceAddr);
        anchor.transferGovernance(newGovernance);
        vm.prank(newGovernance);
        anchor.acceptGovernance();
        assertEq(anchor.governance(), newGovernance);
        assertEq(anchor.pendingGovernance(), address(0));
    }

    function test_AcceptGovernance_EmitsTransferred() public {
        vm.prank(governanceAddr);
        anchor.transferGovernance(newGovernance);
        vm.expectEmit(true, true, false, false);
        emit GovernanceTransferred(governanceAddr, newGovernance);
        vm.prank(newGovernance);
        anchor.acceptGovernance();
    }

    function test_TransferGovernance_CanBeOverwritten() public {
        vm.startPrank(governanceAddr);
        anchor.transferGovernance(newGovernance);
        address other = address(0x9999);
        anchor.transferGovernance(other);
        assertEq(anchor.pendingGovernance(), other);
        vm.stopPrank();
    }

    // ── §12.13 No custody / no funds ──────────────────────────────

    function test_NoCustody_RejectsEthTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(anchor).call{value: 1 ether}("");
        assertFalse(sent);
        assertEq(address(anchor).balance, 0);
    }

    // ── §12.14 Guardrail integration ──────────────────────────────

    function test_Guardrail_ConstantsMatchGovernance() public {
        assertEq(anchor.governance(), Constants.expectedSafeFor(block.chainid));
    }

    function test_Guardrail_DependenciesLinked() public {
        assertEq(anchor.lenderRegistry(), address(lenderRegistry));
        assertEq(anchor.lenderPolicyRegistry(), address(lenderPolicyRegistry));
    }
}
