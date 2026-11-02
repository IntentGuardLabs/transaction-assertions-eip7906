// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal standard ERC-20.
contract MockERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 added) external returns (bool) {
        allowance[msg.sender][spender] += added;
        emit Approval(msg.sender, spender, allowance[msg.sender][spender]);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    /// @dev Like OpenZeppelin's ERC-20, spending an allowance does not emit `Approval`.
    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Deducts a fee from the recipient but reports the full amount in `Transfer`.
contract UnderReportingFeeERC20 is MockERC20 {
    uint256 public constant FEE_BPS = 100;

    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = amount * FEE_BPS / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount);
    }
}

/// @notice Changes balances without emitting any event.
contract SilentRebasingERC20 is MockERC20 {
    function rebase(address account, uint256 newBalance) external {
        balanceOf[account] = newBalance;
    }
}

/// @notice Emits `Transfer` events that do not match any balance change, and sets allowances silently.
contract MisleadingERC20 is MockERC20 {
    function fakeTransfer(address from, address to, uint256 amount) external {
        emit Transfer(from, to, amount);
    }

    function silentApprove(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }
}

/// @notice Minimal standard ERC-721.
contract MockERC721 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    mapping(uint256 => address) internal _owners;
    mapping(uint256 => address) internal _approvals;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 tokenId) external {
        require(_owners[tokenId] == address(0), "minted");
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _owners[tokenId];
        require(owner != address(0), "nonexistent");
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        ownerOf(tokenId);
        return _approvals[tokenId];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        require(msg.sender == owner || isApprovedForAll[owner][msg.sender], "unauthorized");
        _approvals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @dev Clears the token approval without emitting `Approval`, as ERC-721 permits.
    function transferFrom(address from, address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        require(owner == from, "wrong from");
        require(
            msg.sender == owner || _approvals[tokenId] == msg.sender || isApprovedForAll[owner][msg.sender],
            "unauthorized"
        );
        delete _approvals[tokenId];
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}

/// @notice Answers every call with preconfigured raw return data (or a revert), to exercise strict decoding.
contract RawResponder {
    bytes internal _response;
    bool internal _revert;

    function setResponse(bytes calldata response, bool shouldRevert) external {
        _response = response;
        _revert = shouldRevert;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory response = _response;
        if (_revert) {
            assembly {
                revert(add(response, 0x20), mload(response))
            }
        }
        // Return the raw bytes, not ABI-encoded `bytes`.
        assembly {
            return(add(response, 0x20), mload(response))
        }
    }
}
