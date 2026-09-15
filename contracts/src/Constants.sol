// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Constants
/// @notice Canonical source of truth for Lindblad Safe addresses per network.
/// @dev This library is the ONLY source of the expected governance Safe.
///      `.env` values MUST match `expectedSafeFor(block.chainid)`, they do not
///      decide it. See DEPLOY_GUARDRAIL_SPEC.md for the enforcement pattern.
library Constants {
    // -----------------------------------------------------------------------
    // Chain IDs
    // -----------------------------------------------------------------------

    uint256 internal constant CHAIN_ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant CHAIN_ARBITRUM_ONE = 42161;

    // -----------------------------------------------------------------------
    // Governance Safe — per network
    // -----------------------------------------------------------------------

    /// @notice Arbitrum Sepolia governance Safe (2-of-3 multisig, threshold 2).
    /// @dev Deployed via Safe 1.4.1. Public deployment address:
    ///      https://sepolia.arbiscan.io/address/0x87039DF20338A876FB3b4dbd787816D42eecbACa
    address internal constant ARBITRUM_SEPOLIA_SAFE = 0x87039DF20338A876FB3b4dbd787816D42eecbACa;

    /// @notice Arbitrum One governance Safe — NOT YET DEFINED.
    /// @dev When Arbitrum One deployment happens, the production Safe is a
    ///      SEPARATE DECISION and MUST be defined explicitly here. Do not
    ///      assume it equals the Sepolia Safe. Leaving this as address(0)
    ///      causes `expectedSafeFor(CHAIN_ARBITRUM_ONE)` to revert until a
    ///      real value is set.
    address internal constant ARBITRUM_ONE_SAFE = address(0);

    // -----------------------------------------------------------------------
    // Resolver
    // -----------------------------------------------------------------------

    /// @notice Return the expected Safe for a given chain id.
    /// @dev Reverts on unsupported networks or on networks where the Safe
    ///      has not yet been defined. Reverting is deliberate: it prevents
    ///      any deploy from proceeding on a network whose canonical Safe
    ///      is not yet committed to source.
    function expectedSafeFor(uint256 chainId) internal pure returns (address) {
        if (chainId == CHAIN_ARBITRUM_SEPOLIA) {
            return ARBITRUM_SEPOLIA_SAFE;
        }
        if (chainId == CHAIN_ARBITRUM_ONE) {
            require(ARBITRUM_ONE_SAFE != address(0), "Constants: Arbitrum One Safe not yet defined");
            return ARBITRUM_ONE_SAFE;
        }
        revert("Constants: unsupported chain id");
    }
}
