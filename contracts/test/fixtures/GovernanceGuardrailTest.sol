// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Test fixture only.
// Not part of LindFi production contracts.
/// @title GovernanceGuardrailTest
/// @notice Minimal dummy contract implementing the standardized two-step
///         governance interface frozen in MVP03A_GOVERNANCE_AMENDMENT_01.md.
/// @dev This contract exists ONLY to validate the deploy guardrail
///      (pre-check + post-check) end to end. It is not part of the
///      LindFi production surface and is expected to be removed once
///      the guardrail is validated.
contract GovernanceGuardrailTest {
    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    address public governance;
    address public pendingGovernance;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event GovernanceTransferInitiated(address indexed previousGovernance, address indexed newGovernance);
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed newGovernance);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroGovernance();
    error NotGovernance();
    error NotPendingGovernance();
    error NoPendingTransfer();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @param _governance Expected Safe address. Rejects zero.
    /// @dev The constructor is intentionally simple: it accepts governance
    ///      as an argument and rejects the zero address. It does NOT read
    ///      Constants.sol; canonicalization is the deploy script's job.
    constructor(address _governance) {
        if (_governance == address(0)) revert ZeroGovernance();
        governance = _governance;
    }

    // -----------------------------------------------------------------------
    // Two-step governance transfer
    // -----------------------------------------------------------------------

    /// @notice Initiate transfer of governance to a new address.
    /// @dev Only the current governance can call this. The transfer is not
    ///      complete until the new address calls `acceptGovernance()`.
    function transferGovernance(address newGovernance) external {
        if (msg.sender != governance) revert NotGovernance();
        if (newGovernance == address(0)) revert ZeroGovernance();
        pendingGovernance = newGovernance;
        emit GovernanceTransferInitiated(governance, newGovernance);
    }

    /// @notice Accept a pending governance transfer.
    /// @dev Only the pending governance can call this.
    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotPendingGovernance();
        address previous = governance;
        governance = pendingGovernance;
        pendingGovernance = address(0);
        emit GovernanceTransferred(previous, governance);
    }

    /// @notice Cancel a pending governance transfer.
    /// @dev Only the current governance can call this.
    function cancelGovernanceTransfer() external {
        if (msg.sender != governance) revert NotGovernance();
        if (pendingGovernance == address(0)) revert NoPendingTransfer();
        address cancelled = pendingGovernance;
        pendingGovernance = address(0);
        emit GovernanceTransferCancelled(cancelled);
    }
}
