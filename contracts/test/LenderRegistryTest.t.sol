// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Constants} from "../src/Constants.sol";
import {LenderRegistry} from "../src/LenderRegistry.sol";

/// @title LenderRegistryTest
/// @notice Covers every invariant in the approved LenderRegistry
///         implementation specification (§4.1 through §4.12).
contract LenderRegistryTest is Test {
    LenderRegistry internal registry;

    // ─── Local event declarations for vm.expectEmit ────────────────
    // Solidity 0.8.20 does not allow `emit LenderRegistry.EventName(...)`.
    // Redeclaring the events locally is the standard workaround; the
    // event signatures must match LenderRegistry exactly.

    event LenderRegistered(
        uint256 indexed lenderId,
        address indexed signerAddress,
        string name,
        string jurisdiction,
        LenderRegistry.KybStatus kybStatus,
        uint256 addedAt
    );

    event LenderUpdated(
        uint256 indexed lenderId,
        address indexed newSignerAddress,
        address indexed previousSignerAddress,
        string name,
        string jurisdiction,
        LenderRegistry.KybStatus kybStatus
    );

    event LenderDeactivated(uint256 indexed lenderId);

    event LenderReactivated(uint256 indexed lenderId);

    event GovernanceTransferInitiated(address indexed previousGovernance, address indexed newGovernance);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    // Governance and non-governance actors
    address internal governanceAddr;
    address internal notGovernance = address(0xBAD);
    address internal newGovernance = address(0x1234);

    // Signer addresses used across tests
    address internal signerA = address(0xA11CE);
    address internal signerB = address(0xB0B);
    address internal signerC = address(0xC0DE);
    address internal signerD = address(0xDEAD);

    // Fixed lender metadata for readability
    string internal constant NAME_A = "Alpha Capital";
    string internal constant JUR_A = "US-DE";
    string internal constant NAME_B = "Beta Fund";
    string internal constant JUR_B = "BO";

    function setUp() public {
        vm.chainId(Constants.CHAIN_ARBITRUM_SEPOLIA);
        governanceAddr = Constants.expectedSafeFor(block.chainid);
        registry = new LenderRegistry(governanceAddr);
    }

    // ── §4.1 Constructor ──────────────────────────────────────────

    function test_Constructor_RevertsOnZeroGovernance() public {
        vm.expectRevert(LenderRegistry.ZeroGovernance.selector);
        new LenderRegistry(address(0));
    }

    function test_Constructor_SetsGovernance() public {
        assertEq(registry.governance(), governanceAddr);
    }

    function test_Constructor_PendingGovernanceIsZero() public {
        assertEq(registry.pendingGovernance(), address(0));
    }

    function test_Constructor_NextLenderIdStartsAtOne() public {
        vm.prank(governanceAddr);
        uint256 firstId = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
        assertEq(firstId, 1);
    }

    // ── §4.2 registerLender ───────────────────────────────────────

    function test_RegisterLender_RevertsIfNotGovernance() public {
        vm.prank(notGovernance);
        vm.expectRevert(LenderRegistry.NotGovernance.selector);
        registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
    }

    function test_RegisterLender_RevertsOnZeroSigner() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.ZeroSignerAddress.selector);
        registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, address(0));
    }

    function test_RegisterLender_RevertsOnEmptyName() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.EmptyName.selector);
        registry.registerLender("", JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
    }

    function test_RegisterLender_RevertsOnEmptyJurisdiction() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.EmptyJurisdiction.selector);
        registry.registerLender(NAME_A, "", LenderRegistry.KybStatus.PENDING, signerA);
    }

    function test_RegisterLender_RevertsOnKybStatusNone() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.InvalidKybStatus.selector);
        registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.NONE, signerA);
    }

    function test_RegisterLender_RevertsIfSignerAlreadyAssignedActive() public {
        vm.prank(governanceAddr);
        uint256 id1 = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);

        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.SignerAlreadyAssigned.selector, signerA, id1));
        registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerA);
    }

    function test_RegisterLender_RevertsIfSignerAlreadyAssignedInactive() public {
        vm.startPrank(governanceAddr);
        uint256 id1 = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
        registry.deactivateLender(id1);

        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.SignerAlreadyAssigned.selector, signerA, id1));
        registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerA);
        vm.stopPrank();
    }

    function test_RegisterLender_IncrementsIdMonotonically() public {
        vm.startPrank(governanceAddr);
        uint256 id1 = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
        uint256 id2 = registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerB);
        uint256 id3 = registry.registerLender("Gamma", "EU", LenderRegistry.KybStatus.VERIFIED, signerC);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_RegisterLender_PopulatesFields() public {
        uint256 t = 1_800_000_000;
        vm.warp(t);
        vm.prank(governanceAddr);
        uint256 id = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.VERIFIED, signerA);

        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(l.lenderId, id);
        assertEq(l.name, NAME_A);
        assertEq(l.jurisdiction, JUR_A);
        assertTrue(l.kybStatus == LenderRegistry.KybStatus.VERIFIED);
        assertEq(l.signerAddress, signerA);
        assertTrue(l.active);
        assertEq(l.addedAt, t);
    }

    function test_RegisterLender_SetsReverseIndex() public {
        vm.prank(governanceAddr);
        uint256 id = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
        assertEq(registry.signerToLender(signerA), id);
    }

    function test_RegisterLender_EmitsEvent() public {
        uint256 t = 1_800_000_000;
        vm.warp(t);
        vm.expectEmit(true, true, false, true);
        emit LenderRegistered(1, signerA, NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, t);
        vm.prank(governanceAddr);
        registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
    }

    // ── §4.3 updateLender ─────────────────────────────────────────

    function _registerA() internal returns (uint256) {
        vm.prank(governanceAddr);
        return registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
    }

    function test_UpdateLender_RevertsIfNotGovernance() public {
        uint256 id = _registerA();
        vm.prank(notGovernance);
        vm.expectRevert(LenderRegistry.NotGovernance.selector);
        registry.updateLender(id, NAME_A, JUR_A, LenderRegistry.KybStatus.VERIFIED, signerA);
    }

    function test_UpdateLender_RevertsIfLenderDoesNotExist() public {
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderDoesNotExist.selector, 999));
        registry.updateLender(999, NAME_A, JUR_A, LenderRegistry.KybStatus.VERIFIED, signerA);
    }

    function test_UpdateLender_AllowedOnInactiveLender() public {
        uint256 id = _registerA();
        vm.startPrank(governanceAddr);
        registry.deactivateLender(id);

        // Metadata-only update on inactive lender (same signer)
        registry.updateLender(id, "Alpha II", JUR_A, LenderRegistry.KybStatus.VERIFIED, signerA);
        vm.stopPrank();

        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(l.name, "Alpha II");
        assertTrue(l.kybStatus == LenderRegistry.KybStatus.VERIFIED);
        assertFalse(l.active); // still inactive
    }

    function test_UpdateLender_RevertsOnZeroSigner() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.ZeroSignerAddress.selector);
        registry.updateLender(id, NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, address(0));
    }

    function test_UpdateLender_RevertsOnEmptyName() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.EmptyName.selector);
        registry.updateLender(id, "", JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
    }

    function test_UpdateLender_RevertsOnEmptyJurisdiction() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.EmptyJurisdiction.selector);
        registry.updateLender(id, NAME_A, "", LenderRegistry.KybStatus.PENDING, signerA);
    }

    function test_UpdateLender_RevertsOnKybStatusNone() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.InvalidKybStatus.selector);
        registry.updateLender(id, NAME_A, JUR_A, LenderRegistry.KybStatus.NONE, signerA);
    }

    function test_UpdateLender_SameSignerMetadataOnly() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        registry.updateLender(id, "Alpha II", "US-NY", LenderRegistry.KybStatus.VERIFIED, signerA);

        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(l.name, "Alpha II");
        assertEq(l.jurisdiction, "US-NY");
        assertTrue(l.kybStatus == LenderRegistry.KybStatus.VERIFIED);
        assertEq(l.signerAddress, signerA);
        // Reverse index unchanged
        assertEq(registry.signerToLender(signerA), id);
    }

    function test_UpdateLender_SignerTransition() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        registry.updateLender(id, NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerB);

        // Old signer released
        assertEq(registry.signerToLender(signerA), 0);
        // New signer reserved
        assertEq(registry.signerToLender(signerB), id);
        // Stored signerAddress updated
        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(l.signerAddress, signerB);
    }

    function test_UpdateLender_RevertsOnNewSignerReservedByActiveLender() public {
        uint256 id1 = _registerA();
        vm.startPrank(governanceAddr);
        uint256 id2 = registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerB);

        // Try to steal signerB (owned by id2) for id1
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.SignerAlreadyAssigned.selector, signerB, id2));
        registry.updateLender(id1, NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerB);
        vm.stopPrank();
    }

    function test_UpdateLender_RevertsOnNewSignerReservedByInactiveLender() public {
        uint256 id1 = _registerA();
        vm.startPrank(governanceAddr);
        uint256 id2 = registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerB);
        registry.deactivateLender(id2);

        // Try to steal signerB (owned by INACTIVE id2) for id1
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.SignerAlreadyAssigned.selector, signerB, id2));
        registry.updateLender(id1, NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerB);
        vm.stopPrank();
    }

    function test_UpdateLender_PreservesImmutableFields() public {
        uint256 t = 1_800_000_000;
        vm.warp(t);
        uint256 id = _registerA();

        vm.warp(t + 3600);
        vm.prank(governanceAddr);
        registry.updateLender(id, "Alpha II", "US-NY", LenderRegistry.KybStatus.VERIFIED, signerC);

        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(l.lenderId, id); // preserved
        assertTrue(l.active); // preserved
        assertEq(l.addedAt, t); // preserved (not t + 3600)
    }

    function test_UpdateLender_EmitsEvent() public {
        uint256 id = _registerA();
        vm.expectEmit(true, true, true, true);
        emit LenderUpdated(id, signerB, signerA, "Alpha II", "US-NY", LenderRegistry.KybStatus.VERIFIED);
        vm.prank(governanceAddr);
        registry.updateLender(id, "Alpha II", "US-NY", LenderRegistry.KybStatus.VERIFIED, signerB);
    }

    // ── §4.4 deactivateLender ─────────────────────────────────────

    function test_DeactivateLender_RevertsIfNotGovernance() public {
        uint256 id = _registerA();
        vm.prank(notGovernance);
        vm.expectRevert(LenderRegistry.NotGovernance.selector);
        registry.deactivateLender(id);
    }

    function test_DeactivateLender_RevertsIfLenderDoesNotExist() public {
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderDoesNotExist.selector, 42));
        registry.deactivateLender(42);
    }

    function test_DeactivateLender_RevertsIfAlreadyInactive() public {
        uint256 id = _registerA();
        vm.startPrank(governanceAddr);
        registry.deactivateLender(id);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderAlreadyInactive.selector, id));
        registry.deactivateLender(id);
        vm.stopPrank();
    }

    function test_DeactivateLender_SetsActiveFalse() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        registry.deactivateLender(id);
        assertFalse(registry.isActive(id));
    }

    function test_DeactivateLender_PreservesReverseIndex() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        registry.deactivateLender(id);
        assertEq(registry.signerToLender(signerA), id);
    }

    function test_DeactivateLender_PreservesHistoricalFields() public {
        uint256 t = 1_800_000_000;
        vm.warp(t);
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        registry.deactivateLender(id);

        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(l.lenderId, id);
        assertEq(l.name, NAME_A);
        assertEq(l.jurisdiction, JUR_A);
        assertTrue(l.kybStatus == LenderRegistry.KybStatus.PENDING);
        assertEq(l.signerAddress, signerA);
        assertEq(l.addedAt, t);
    }

    function test_DeactivateLender_EmitsEvent() public {
        uint256 id = _registerA();
        vm.expectEmit(true, false, false, false);
        emit LenderDeactivated(id);
        vm.prank(governanceAddr);
        registry.deactivateLender(id);
    }

    // ── §4.5 reactivateLender ─────────────────────────────────────

    function test_ReactivateLender_RevertsIfNotGovernance() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        registry.deactivateLender(id);
        vm.prank(notGovernance);
        vm.expectRevert(LenderRegistry.NotGovernance.selector);
        registry.reactivateLender(id);
    }

    function test_ReactivateLender_RevertsIfLenderDoesNotExist() public {
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderDoesNotExist.selector, 42));
        registry.reactivateLender(42);
    }

    function test_ReactivateLender_RevertsIfAlreadyActive() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderAlreadyActive.selector, id));
        registry.reactivateLender(id);
    }

    function test_ReactivateLender_SetsActiveTrue() public {
        uint256 id = _registerA();
        vm.startPrank(governanceAddr);
        registry.deactivateLender(id);
        assertFalse(registry.isActive(id));
        registry.reactivateLender(id);
        vm.stopPrank();
        assertTrue(registry.isActive(id));
    }

    function test_ReactivateLender_PreservesSignerAndReverseIndex() public {
        uint256 id = _registerA();
        vm.startPrank(governanceAddr);
        registry.deactivateLender(id);
        registry.reactivateLender(id);
        vm.stopPrank();

        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(l.signerAddress, signerA);
        assertEq(registry.signerToLender(signerA), id);
    }

    function test_ReactivateLender_EmitsEvent() public {
        uint256 id = _registerA();
        vm.prank(governanceAddr);
        registry.deactivateLender(id);

        vm.expectEmit(true, false, false, false);
        emit LenderReactivated(id);
        vm.prank(governanceAddr);
        registry.reactivateLender(id);
    }

    // ── §4.6 Signer uniqueness invariants ─────────────────────────

    function test_ReverseIndex_ConsistencyAfterRegistration() public {
        uint256 id = _registerA();
        LenderRegistry.Lender memory l = registry.getLender(id);
        assertEq(registry.signerToLender(l.signerAddress), id);
    }

    function test_DistinctLendersHaveDistinctSigners() public {
        vm.startPrank(governanceAddr);
        uint256 id1 = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
        uint256 id2 = registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerB);
        vm.stopPrank();
        assertTrue(id1 != id2);
        assertTrue(registry.getLender(id1).signerAddress != registry.getLender(id2).signerAddress);
    }

    function test_SignerReleasePath() public {
        // Register lender 1 with signerA. Deactivate. Update signer to signerB.
        // signerA is now free and can be assigned to a new lender.
        uint256 id1 = _registerA();

        vm.startPrank(governanceAddr);
        registry.deactivateLender(id1);
        registry.updateLender(id1, NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerB);
        // Now signerA is free
        assertEq(registry.signerToLender(signerA), 0);
        // Register lender 2 using signerA
        uint256 id2 = registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerA);
        vm.stopPrank();

        assertEq(registry.signerToLender(signerA), id2);
        assertEq(registry.signerToLender(signerB), id1);
    }

    // ── §4.7 ID reuse invariants ──────────────────────────────────

    function test_IdsNeverReused() public {
        vm.startPrank(governanceAddr);
        uint256 id1 = registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
        registry.deactivateLender(id1);
        uint256 id2 = registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerB);
        vm.stopPrank();

        assertTrue(id2 > id1);
        assertEq(id2, id1 + 1);
    }

    function test_TotalLenders_ReflectsMonotonicCounter() public {
        assertEq(registry.totalLenders(), 0);

        vm.startPrank(governanceAddr);
        registry.registerLender(NAME_A, JUR_A, LenderRegistry.KybStatus.PENDING, signerA);
        assertEq(registry.totalLenders(), 1);

        registry.registerLender(NAME_B, JUR_B, LenderRegistry.KybStatus.VERIFIED, signerB);
        assertEq(registry.totalLenders(), 2);

        registry.deactivateLender(1);
        // Deactivation does NOT decrement totalLenders
        assertEq(registry.totalLenders(), 2);
        vm.stopPrank();
    }

    // ── §4.8 Governance transfer invariants ───────────────────────

    function test_TransferGovernance_RevertsIfNotGovernance() public {
        vm.prank(notGovernance);
        vm.expectRevert(LenderRegistry.NotGovernance.selector);
        registry.transferGovernance(newGovernance);
    }

    function test_TransferGovernance_RevertsOnZeroAddress() public {
        vm.prank(governanceAddr);
        vm.expectRevert(LenderRegistry.ZeroGovernance.selector);
        registry.transferGovernance(address(0));
    }

    function test_TransferGovernance_SetsPendingButNotGovernance() public {
        vm.prank(governanceAddr);
        registry.transferGovernance(newGovernance);
        assertEq(registry.pendingGovernance(), newGovernance);
        assertEq(registry.governance(), governanceAddr); // unchanged
    }

    function test_TransferGovernance_EmitsInitiated() public {
        vm.expectEmit(true, true, false, false);
        emit GovernanceTransferInitiated(governanceAddr, newGovernance);
        vm.prank(governanceAddr);
        registry.transferGovernance(newGovernance);
    }

    function test_AcceptGovernance_RevertsIfNotPending() public {
        vm.prank(governanceAddr);
        registry.transferGovernance(newGovernance);
        vm.prank(notGovernance);
        vm.expectRevert(LenderRegistry.NotPendingGovernance.selector);
        registry.acceptGovernance();
    }

    function test_AcceptGovernance_RevertsIfNoPending() public {
        vm.prank(newGovernance);
        vm.expectRevert(LenderRegistry.NotPendingGovernance.selector);
        registry.acceptGovernance();
    }

    function test_AcceptGovernance_CompletesTransfer() public {
        vm.prank(governanceAddr);
        registry.transferGovernance(newGovernance);
        vm.prank(newGovernance);
        registry.acceptGovernance();

        assertEq(registry.governance(), newGovernance);
        assertEq(registry.pendingGovernance(), address(0));
    }

    function test_AcceptGovernance_EmitsTransferred() public {
        vm.prank(governanceAddr);
        registry.transferGovernance(newGovernance);

        vm.expectEmit(true, true, false, false);
        emit GovernanceTransferred(governanceAddr, newGovernance);
        vm.prank(newGovernance);
        registry.acceptGovernance();
    }

    function test_TransferGovernance_CanBeOverwritten() public {
        vm.startPrank(governanceAddr);
        registry.transferGovernance(newGovernance);
        assertEq(registry.pendingGovernance(), newGovernance);

        address anotherGovernance = address(0x5678);
        registry.transferGovernance(anotherGovernance);
        assertEq(registry.pendingGovernance(), anotherGovernance);
        vm.stopPrank();
    }

    // ── §4.9 No funds / no custody invariants ─────────────────────

    function test_NoCustody_ContractRejectsEthTransfer() public {
        // No receive() no fallback() → send should fail.
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(registry).call{value: 1 ether}("");
        assertFalse(sent);
        assertEq(address(registry).balance, 0);
    }

    // ── §4.10 Deployment guardrail integration ────────────────────

    function test_Guardrail_ConstantsMatchGovernance() public {
        // The registry was deployed with governance = canonical Safe.
        assertEq(registry.governance(), Constants.expectedSafeFor(block.chainid));
    }

    // ── §4.11 Read function invariants ────────────────────────────

    function test_GetLender_RevertsOnUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(LenderRegistry.LenderDoesNotExist.selector, 999));
        registry.getLender(999);
    }

    function test_LenderExists_ReturnsFalseForZero() public {
        assertFalse(registry.lenderExists(0));
    }

    function test_LenderExists_TrueForRegistered_ActiveAndInactive() public {
        uint256 id = _registerA();
        assertTrue(registry.lenderExists(id));

        vm.prank(governanceAddr);
        registry.deactivateLender(id);
        assertTrue(registry.lenderExists(id)); // still exists after deactivation
    }

    function test_IsActive_ReturnsFalseForUnknown() public {
        assertFalse(registry.isActive(999));
    }

    function test_IsActive_ReturnsFalseForZero() public {
        assertFalse(registry.isActive(0));
    }

    function test_TotalLenders_ZeroBeforeAnyRegistration() public {
        assertEq(registry.totalLenders(), 0);
    }
}
