// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title Whitelist Contract
 * @dev Manages a whitelist of addresses with associated UUIDs using OpenZeppelin's AccessControl
 * Defines two roles: ADMIN_ROLE and WHITELISTER_ROLE for permission management
 */
contract Whitelist is AccessControl {
    // ============ Custom Errors ============
    /// @dev Thrown when an invalid (zero) address is provided
    error ZeroAddress();
    
    /// @dev Thrown when attempting to add an address that is already whitelisted
    error AlreadyWhitelisted(address account);
    
    /// @dev Thrown when attempting to remove an address that is not whitelisted
    error NotWhitelisted(address account);
    
    /// @dev Thrown when an empty UUID is provided
    error EmptyUUID();

    // ============ State Variables ============
    /**
     * @dev Structure to store whitelist information for an address
     * @param isWhitelisted Boolean flag indicating if address is whitelisted
     * @param uuid Unique identifier associated with the whitelisted address as bytes16 (128 bits)
     */
    struct WhitelistEntry {
        bool isWhitelisted;
        bytes16 uuid;
    }
    
    /// @dev Maps addresses to their whitelist entry data (status and UUID)
    mapping(address => WhitelistEntry) public whitelistEntries;
    
    /// @dev Tracks the total number of currently whitelisted addresses
    uint256 public whitelistedCount;

    // ============ Roles ============
    /// @dev Role identifier for administrative privileges
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @dev Role identifier for addresses allowed to manage the whitelist
    bytes32 public constant WHITELISTER_ROLE = keccak256("WHITELISTER_ROLE");

    // ============ Events ============
    /// @dev Emitted when an address is added to the whitelist
    event AddressWhitelisted(address indexed account, bytes16 uuid);
    
    /// @dev Emitted when an address is removed from the whitelist
    event AddressRemovedFromWhitelist(address indexed account);

    // ============ Constructor ============
    /**
     * @dev Sets up the initial roles and permissions
     * @param admin Address that will have ADMIN_ROLE and DEFAULT_ADMIN_ROLE permissions
     * @notice The deployer is automatically granted WHITELISTER_ROLE
     * @notice Configures ADMIN_ROLE as the admin for both ADMIN_ROLE and WHITELISTER_ROLE
     */
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        
        // Grant DEFAULT_ADMIN_ROLE to the admin address (required for initial setup)
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        
        // Set ADMIN_ROLE as the admin for both roles (instead of DEFAULT_ADMIN_ROLE)
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(WHITELISTER_ROLE, ADMIN_ROLE);
        
        // Grant admin roles to the specified admin address
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(WHITELISTER_ROLE, admin);
        
        // Grant WHITELISTER_ROLE to the deployer 
        _grantRole(WHITELISTER_ROLE, msg.sender);
    }

    // ============ Admin Management ============
    /**
     * @dev Adds a new admin address with full administrative privileges
     * @param account The address to grant ADMIN_ROLE to
     * @notice Only callable by addresses with ADMIN_ROLE (since we set it as its own admin)
     */
    function addAdmin(address account) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        grantRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Removes admin privileges from an address
     * @param account The address to revoke ADMIN_ROLE from
     * @notice Only callable by addresses with ADMIN_ROLE (since we set it as its own admin)
     */
    function removeAdmin(address account) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        revokeRole(ADMIN_ROLE, account);
    }

    /**
     * @dev Grants whitelisting privileges to an address
     * @param account The address to grant WHITELISTER_ROLE to
     * @notice Only callable by addresses with ADMIN_ROLE (since we set it as the admin for WHITELISTER_ROLE)
     */
    function addWhitelister(address account) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        grantRole(WHITELISTER_ROLE, account);
    }

    /**
     * @dev Revokes whitelisting privileges from an address
     * @param account The address to revoke WHITELISTER_ROLE from
     * @notice Only callable by addresses with ADMIN_ROLE (since we set it as the admin for WHITELISTER_ROLE)
     */
    function removeWhitelister(address account) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        revokeRole(WHITELISTER_ROLE, account);
    }

    // ============ Whitelist Management ============
    /**
     * @dev Adds an address to the whitelist with an associated UUID
     * @param account The address to whitelist
     * @param uuid The unique identifier to associate with this address (16 bytes)
     * @notice Only callable by addresses with WHITELISTER_ROLE
     * @notice Uses bytes16 for efficient UUID storage (standard UUID is 16 bytes/128 bits)
     */
    function addToWhitelist(address account, bytes16 uuid) external onlyRole(WHITELISTER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (whitelistEntries[account].isWhitelisted) revert AlreadyWhitelisted(account);
        if (uuid == bytes16(0)) revert EmptyUUID();
        
        whitelistEntries[account] = WhitelistEntry(true, uuid);
        whitelistedCount++;
        emit AddressWhitelisted(account, uuid);
    }

    /**
     * @dev Removes an address from the whitelist
     * @param account The address to remove from the whitelist
     * @notice Only callable by addresses with WHITELISTER_ROLE
     * @notice This completely deletes the entry, clearing both isWhitelisted and uuid, providing gas refund
     */
    function removeFromWhitelist(address account) external onlyRole(WHITELISTER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (!whitelistEntries[account].isWhitelisted) revert NotWhitelisted(account);
        
        delete whitelistEntries[account];
        whitelistedCount--;
        emit AddressRemovedFromWhitelist(account);
    }

    // ============ View Functions ============
    /**
     * @dev Checks if an address is currently whitelisted
     * @param account The address to check
     * @return bool True if the address is whitelisted, false otherwise
     */
    function isAddressWhitelisted(address account) external view returns (bool) {
        return whitelistEntries[account].isWhitelisted;
    }

    /**
     * @dev Returns the total count of currently whitelisted addresses
     * @return uint256 The number of whitelisted addresses
     */
    function getWhitelistedCount() external view returns (uint256) {
        return whitelistedCount;
    }
    
    /**
     * @dev Retrieves the complete whitelist entry for an address
     * @param account The address to retrieve information for
     * @return bool The whitelist status
     * @return bytes16 The UUID associated with the address
     * @notice Returns the UUID even if address is no longer whitelisted
     */
    function getWhitelistEntry(address account) external view returns (bool, bytes16) {
        WhitelistEntry memory entry = whitelistEntries[account];
        return (entry.isWhitelisted, entry.uuid);
    }
} 