// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Contract signer that accepts exactly one (digest, signature) pair. The only mocks in the
///         B5 suite, because no real EIP-1271 wallet exists on the target testnet.
contract MockERC1271Wallet {
    bytes32 private constant MAGIC = 0x1626ba7e00000000000000000000000000000000000000000000000000000000;
    address public owner;
    bool public accept = true;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAccept(bool a) external {
        accept = a;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (!accept) return 0xffffffff;
        (bytes32 r, bytes32 s, uint8 v) = _split(signature);
        address recovered = ecrecover(digest, v, r, s);
        return recovered == owner && recovered != address(0) ? bytes4(MAGIC) : bytes4(0xffffffff);
    }

    function _split(bytes calldata sig) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "bad length");
        r = bytes32(sig[0:32]);
        s = bytes32(sig[32:64]);
        v = uint8(sig[64]);
    }
}

/// @notice Contract signer whose isValidSignature always reverts. Must yield an invalid signature,
///         never a bubbled revert that could be used to grief the caller.
contract RevertingERC1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("signer unavailable");
    }
}

/// @notice Contract signer that returns a wrong magic value (non-conforming).
contract NonConformingERC1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @notice Contract with no isValidSignature at all.
contract SilentContract {
    uint256 public x;
}

/// @notice Attempts to send value to the registry, proving no payable path exists.
contract ValueSender {
    function sendTo(address target) external payable returns (bool ok) {
        (ok,) = target.call{value: msg.value}("");
    }
}
