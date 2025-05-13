// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract Whitelist is Ownable, Pausable {
    // ============ State Variables ============
    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public isAdmin;
    uint256 public whitelistedCount;

    // ============ Events ============
    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);
    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    // ============ Constructor ============
    constructor() Ownable(msg.sender) {
        isAdmin[msg.sender] = true; // Owner is admin by default
        emit AdminAdded(msg.sender);
    }

    // ============ Modifiers ============
    modifier onlyAdmin() {
        require(isAdmin[msg.sender], "Caller is not an admin");
        _;
    }

    // ============ Admin Functions ============
    function addAdmin(address account) external onlyOwner {
        require(account != address(0), "Invalid address");
        require(!isAdmin[account], "Account is already admin");
        isAdmin[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyOwner {
        require(account != msg.sender, "Cannot remove self as admin");
        require(isAdmin[account], "Account is not admin");
        isAdmin[account] = false;
        emit AdminRemoved(account);
    }

    // ============ Whitelist Management ============
    function addToWhitelist(address account) external whenNotPaused onlyAdmin {
        require(account != address(0), "Invalid address");
        require(!isWhitelisted[account], "Address already whitelisted");
        
        isWhitelisted[account] = true;
        whitelistedCount++;
        emit AddressWhitelisted(account);
    }

    function removeFromWhitelist(address account) external onlyAdmin {
        require(account != address(0), "Invalid address");
        require(isWhitelisted[account], "Address not whitelisted");
        
        isWhitelisted[account] = false;
        whitelistedCount--;
        emit AddressRemovedFromWhitelist(account);
    }

    // ============ View Functions ============
    function isAddressWhitelisted(address account) external view returns (bool) {
        return isWhitelisted[account];
    }

    function isAddressAdmin(address account) external view returns (bool) {
        return isAdmin[account];
    }

    function getWhitelistedCount() external view returns (uint256) {
        return whitelistedCount;
    }

    // ============ Admin Functions ============
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
