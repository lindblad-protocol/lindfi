// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Constants} from "../src/Constants.sol";

/// @notice Helper to place Constants calls in a separate call frame so
///         vm.expectRevert() can catch reverts from `internal pure` library
///         functions. Foundry's expectRevert requires a call boundary.
contract ConstantsRevertsHelper {
    function resolve(uint256 chainId) external pure returns (address) {
        return Constants.expectedSafeFor(chainId);
    }
}
