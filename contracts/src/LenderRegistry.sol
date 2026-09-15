// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title LenderRegistry
/// @notice Identifies recognized lenders and maintains per-lender identity
///         records for the LindFi protocol. Governance-controlled. Holds
///         no funds. No receive/fallback. See docs/architecture.md and
///         MVP03A_GOVERNANCE_AMENDMENT_01 for context.
/// @dev Governance model follows the frozen amendment:
///        - governance supplied at construction (rejects address(0))
///        - two-step transfer via transferGovernance + acceptGovernance
///        - governance() / pendingGovernance() satisfied by public storage
///      Deployment must follow DEPLOY_GUARDRAIL_SPEC (pre-broadcast +
///      post-broadcast governance verification).
contract LenderRegistry {
    // ─── Types ─────────────────────────────────────────────────────

    enum KybStatus {
        NONE, // 0 — sentinel, not accepted by register/update
        PENDING, // 1
        VERIFIED, // 2
        REJECTED, // 3
        EXPIRED // 4
    }

    struct Lender {
        uint256 lenderId;
        string name;
        string jurisdiction;
        KybStatus kybStatus;
        address signerAddress;
        bool active;
        uint256 addedAt;
    }

    // ─── Storage ───────────────────────────────────────────────────

    /// @notice Current governance address. Two-step transfer authority.
    address public governance;

    /// @notice Address awaiting acceptGovernance() to become the new
    ///         governance. Zero when no transfer is pending.
    address public pendingGovernance;

    /// @dev Next lender id to assign. Monotonic, never decremented.
    ///      Explicitly starts at 1 so that lender id 0 remains the
    ///      "unassigned" sentinel for the reverse index.
    uint256 private _nextLenderId = 1;

    /// @dev Full lender records by lender id.
    mapping(uint256 => Lender) private _lenders;

    /// @notice Reverse index: signer address to the lender id that has
    ///         reserved it. Returns 0 for unassigned addresses.
    /// @dev The reverse index persists across deactivation. A signer
    ///      remains reserved to its lender identity regardless of the
    ///      lender's operational status (active/inactive). See the
    ///      updateLender signer-transition logic for how a signer is
    ///      released.
    mapping(address => uint256) public signerToLender;

    // ─── Events ────────────────────────────────────────────────────

    event LenderRegistered(
        uint256 indexed lenderId,
        address indexed signerAddress,
        string name,
        string jurisdiction,
        KybStatus kybStatus,
        uint256 addedAt
    );

    event LenderUpdated(
        uint256 indexed lenderId,
        address indexed newSignerAddress,
        address indexed previousSignerAddress,
        string name,
        string jurisdiction,
        KybStatus kybStatus
    );

    event LenderDeactivated(uint256 indexed lenderId);

    event LenderReactivated(uint256 indexed lenderId);

    event GovernanceTransferInitiated(address indexed previousGovernance, address indexed newGovernance);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    // ─── Custom errors ─────────────────────────────────────────────

    error ZeroGovernance();
    error ZeroSignerAddress();
    error NotGovernance();
    error NotPendingGovernance();
    error EmptyName();
    error EmptyJurisdiction();
    error InvalidKybStatus();
    error LenderDoesNotExist(uint256 lenderId);
    error LenderAlreadyInactive(uint256 lenderId);
    error LenderAlreadyActive(uint256 lenderId);
    error SignerAlreadyAssigned(address signerAddress, uint256 existingLenderId);
    error SignerAssociationBroken(uint256 lenderId);

    // ─── Modifiers ─────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────

    /// @param _governance Expected canonical governance for the target
    ///        network. Must be non-zero. Passed by the deploy script
    ///        from Constants.expectedSafeFor(block.chainid).
    constructor(address _governance) {
        if (_governance == address(0)) revert ZeroGovernance();
        governance = _governance;
    }

    // ─── Governance actions ────────────────────────────────────────

    /// @notice Register a new lender identity.
    /// @dev Reverts if signer is zero, already assigned, or if name /
    ///      jurisdiction is empty, or if kybStatus is NONE.
    /// @return lenderId Newly assigned id (monotonic, starting at 1).
    function registerLender(
        string calldata name,
        string calldata jurisdiction,
        KybStatus kybStatus,
        address signerAddress
    ) external onlyGovernance returns (uint256 lenderId) {
        if (signerAddress == address(0)) revert ZeroSignerAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(jurisdiction).length == 0) revert EmptyJurisdiction();
        if (kybStatus == KybStatus.NONE) revert InvalidKybStatus();

        uint256 reserved = signerToLender[signerAddress];
        if (reserved != 0) {
            revert SignerAlreadyAssigned(signerAddress, reserved);
        }

        lenderId = _nextLenderId;
        _nextLenderId = lenderId + 1;

        _lenders[lenderId] = Lender({
            lenderId: lenderId,
            name: name,
            jurisdiction: jurisdiction,
            kybStatus: kybStatus,
            signerAddress: signerAddress,
            active: true,
            addedAt: block.timestamp
        });

        signerToLender[signerAddress] = lenderId;

        emit LenderRegistered(lenderId, signerAddress, name, jurisdiction, kybStatus, block.timestamp);
    }

    /// @notice Update the mutable fields of a lender identity.
    /// @dev Allowed on both active and inactive lenders. Signer
    ///      transition atomically clears the previous signer's reverse
    ///      index entry and sets the new one. Same-signer updates are
    ///      permitted as metadata-only updates and do not release the
    ///      signer. New signer, if different, must not already be
    ///      reserved by another lender (active or inactive).
    function updateLender(
        uint256 lenderId,
        string calldata name,
        string calldata jurisdiction,
        KybStatus kybStatus,
        address signerAddress
    ) external onlyGovernance {
        Lender storage lender = _lenders[lenderId];
        if (lender.lenderId == 0) revert LenderDoesNotExist(lenderId);

        if (signerAddress == address(0)) revert ZeroSignerAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(jurisdiction).length == 0) revert EmptyJurisdiction();
        if (kybStatus == KybStatus.NONE) revert InvalidKybStatus();

        address previousSigner = lender.signerAddress;

        if (signerAddress != previousSigner) {
            uint256 reserved = signerToLender[signerAddress];
            if (reserved != 0) {
                revert SignerAlreadyAssigned(signerAddress, reserved);
            }
            signerToLender[previousSigner] = 0;
            signerToLender[signerAddress] = lenderId;
        }

        lender.name = name;
        lender.jurisdiction = jurisdiction;
        lender.kybStatus = kybStatus;
        lender.signerAddress = signerAddress;

        emit LenderUpdated(lenderId, signerAddress, previousSigner, name, jurisdiction, kybStatus);
    }

    /// @notice Mark a lender as inactive. Strict: reverts if the lender
    ///         is already inactive.
    /// @dev Preserves all historical fields, including the reverse
    ///      index. A deactivated lender's signer remains reserved to
    ///      that lender identity.
    function deactivateLender(uint256 lenderId) external onlyGovernance {
        Lender storage lender = _lenders[lenderId];
        if (lender.lenderId == 0) revert LenderDoesNotExist(lenderId);
        if (!lender.active) revert LenderAlreadyInactive(lenderId);

        lender.active = false;

        emit LenderDeactivated(lenderId);
    }

    /// @notice Reactivate an inactive lender.
    /// @dev Does not touch signerAddress or the reverse index. The
    ///      preconditions on the stored signer and reverse index are
    ///      defense-in-depth: under normal usage the invariants imply
    ///      they always hold.
    function reactivateLender(uint256 lenderId) external onlyGovernance {
        Lender storage lender = _lenders[lenderId];
        if (lender.lenderId == 0) revert LenderDoesNotExist(lenderId);
        if (lender.active) revert LenderAlreadyActive(lenderId);

        address storedSigner = lender.signerAddress;
        if (storedSigner == address(0)) revert ZeroSignerAddress();
        if (signerToLender[storedSigner] != lenderId) {
            revert SignerAssociationBroken(lenderId);
        }

        lender.active = true;

        emit LenderReactivated(lenderId);
    }

    // ─── Governance transfer (two-step, per Amendment 01) ──────────

    /// @notice Initiate a governance transfer. The new governance is
    ///         stored as pending and must call acceptGovernance to
    ///         complete the transfer.
    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroGovernance();
        pendingGovernance = newGovernance;
        emit GovernanceTransferInitiated(governance, newGovernance);
    }

    /// @notice Accept a pending governance transfer.
    function acceptGovernance() external {
        address pending = pendingGovernance;
        if (pending == address(0) || msg.sender != pending) {
            revert NotPendingGovernance();
        }
        address previous = governance;
        governance = pending;
        pendingGovernance = address(0);
        emit GovernanceTransferred(previous, pending);
    }

    // ─── Read functions ────────────────────────────────────────────

    /// @notice Return the full lender record for a given id.
    /// @dev Strict: reverts if the lender does not exist. Use
    ///      lenderExists / isActive for non-reverting queries.
    function getLender(uint256 lenderId) external view returns (Lender memory) {
        Lender storage lender = _lenders[lenderId];
        if (lender.lenderId == 0) revert LenderDoesNotExist(lenderId);
        return lender;
    }

    /// @notice Non-reverting existence check.
    function lenderExists(uint256 lenderId) external view returns (bool) {
        return _lenders[lenderId].lenderId != 0;
    }

    /// @notice Non-reverting operational-status check. Returns false
    ///         for unknown or inactive lenders.
    function isActive(uint256 lenderId) external view returns (bool) {
        return _lenders[lenderId].active;
    }

    /// @notice Total number of lenders registered so far.
    /// @dev Equal to _nextLenderId - 1. Does not decrement on
    ///      deactivation. Returns 0 before any registration.
    function totalLenders() external view returns (uint256) {
        return _nextLenderId - 1;
    }

    // ─── Explicitly absent ─────────────────────────────────────────

    // NO receive() external payable
    // NO fallback() external payable
    // NO withdraw / recover / rescue functions
    // NO delegatecall
    // NO selfdestruct
}
