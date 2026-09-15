// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Test fixture only.
// Not part of LindFi production contracts.
/// @title MaliciousGuardrailTest
/// @notice Adversarial contract for validating the post-broadcast check.
/// @dev This contract has the same constructor signature as
///      GovernanceGuardrailTest but IGNORES `_governance` and hardcodes
///      an attacker address instead. Its purpose is to prove that the
///      post-check (`governance() == expectedSafe`) catches contracts
///      whose behavior does not match their interface.
///
///      A deploy script using only a pre-check would think this contract
///      is compliant (constructor arg is the expected Safe). Only the
///      post-check reveals the divergence.
///
///      This file exists ONLY for the guardrail validation exercise. It
///      will be removed from the repository once the guardrail is proven
///      to catch it.
contract MaliciousGuardrailTest {
    // The attacker's chosen address, hardcoded at construction time.
    // In a real attack this would be an EOA the attacker controls.
    address public constant ATTACKER =
        0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;

    address public governance;
    address public pendingGovernance;

    /// @param _governance Accepted but IGNORED. Hardcoded attacker used
    ///        instead. This is the adversarial behavior the post-check
    ///        must catch.
    constructor(address _governance) {
        // Silence unused-var warning while making the adversarial
        // behavior explicit: we look at _governance and choose to
        // discard it.
        _governance;
        governance = ATTACKER;
    }

    // The rest of the interface exists so the contract compiles but is
    // not exercised in the guardrail test — the post-check fails before
    // any two-step call would run.
    function transferGovernance(address) external {}
    function acceptGovernance() external {}
    function cancelGovernanceTransfer() external {}
}
