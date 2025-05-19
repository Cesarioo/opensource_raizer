// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
/**
 * @title OFT Contract
 * @dev OFT is an ERC-20 token that extends the functionality of the OFTCore contract with role-based access control.
 */
abstract contract OFT is ERC20, ERC20Permit, ERC20Votes, OFTCore, AccessControl {
    // Define roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /**
     * @dev Constructor for the OFT contract.
     * @param _name The name of the OFT.
     * @param _symbol The symbol of the OFT.
     * @param _lzEndpoint The LayerZero endpoint address.
     * @param _delegate The delegate capable of making OApp configurations inside of the endpoint.
     * @param _admin Address to be granted the DEFAULT_ADMIN_ROLE
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate,
        address _admin
    ) ERC20(_name, _symbol) OFTCore(decimals(), _lzEndpoint, _delegate) ERC20Permit(_name){
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
        _grantRole(BURNER_ROLE, _admin);
    }

    /**
     * @dev Retrieves the address of the underlying ERC20 implementation.
     * @return The address of the OFT token.
     *
     * @dev In the case of OFT, address(this) and erc20 are the same contract.
     */
    function token() public view returns (address) {
        return address(this);
    }

    /**
     * @notice Indicates whether the OFT contract requires approval of the 'token()' to send.
     * @return requiresApproval Needs approval of the underlying token implementation.
     *
     * @dev In the case of OFT where the contract IS the token, approval is NOT required.
     */
    function approvalRequired() external pure virtual returns (bool) {
        return false;
    }

    /**
     * @dev Function to mint tokens to a specific address
     * Auto-delegates the minted tokens to the recipient
     * @param to The address that will receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
        
        // Auto-delegate to themselves if they haven't delegated yet
        if (delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    /**
     * @dev Function to burn tokens from a specific address
     * @param from The address from which to burn tokens
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    /**
     * @dev Adds a new admin
     * @param newAdmin Address to be granted the DEFAULT_ADMIN_ROLE
     * @notice Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function addAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        // Also grant minter and burner roles by default to new admins
        _grantRole(MINTER_ROLE, newAdmin);
        _grantRole(BURNER_ROLE, newAdmin);
    }

    /**
     * @dev Removes an admin
     * @param admin Address to revoke the DEFAULT_ADMIN_ROLE from
     * @notice Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function removeAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != msg.sender, "Cannot remove self as admin");
        _revokeRole(DEFAULT_ADMIN_ROLE, admin);
        // Also revoke minter and burner roles
        _revokeRole(MINTER_ROLE, admin);
        _revokeRole(BURNER_ROLE, admin);
    }

    /**
     * @dev Adds a new minter
     * @param minter Address to be granted the MINTER_ROLE
     * @notice Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function addMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
    }

    /**
     * @dev Removes a minter
     * @param minter Address to revoke the MINTER_ROLE from
     * @notice Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function removeMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, minter);
    }

    /**
     * @dev Adds a new burner
     * @param burner Address to be granted the BURNER_ROLE
     * @notice Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function addBurner(address burner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(BURNER_ROLE, burner);
    }

    /**
     * @dev Removes a burner
     * @param burner Address to revoke the BURNER_ROLE from
     * @notice Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function removeBurner(address burner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BURNER_ROLE, burner);
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._update(from, to, amount);
        
        // Auto-delegate for the recipient if they haven't delegated yet
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    // Required override for AccessControl + ERC20Votes/ERC20Permit due to diamond inheritance
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Burns tokens from the sender's specified balance.
     * @param _from The address to debit the tokens from.
     * @param _amountLD The amount of tokens to send in local decimals.
     * @param _minAmountLD The minimum amount to send in local decimals.
     * @param _dstEid The destination chain ID.
     * @return amountSentLD The amount sent in local decimals.
     * @return amountReceivedLD The amount received in local decimals on the remote.
     */
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        // @dev In NON-default OFT, amountSentLD could be 100, with a 10% fee, the amountReceivedLD amount is 90,
        // therefore amountSentLD CAN differ from amountReceivedLD.

        // @dev Default OFT burns on src.
        _burn(_from, amountSentLD);
    }

    /**
     * @dev Credits tokens to the specified address.
     * @param _to The address to credit the tokens to.
     * @param _amountLD The amount of tokens to credit in local decimals.
     * @dev _srcEid The source chain ID.
     * @return amountReceivedLD The amount of tokens ACTUALLY received in local decimals.
     */
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (_to == address(0x0)) _to = address(0xdead); // _mint(...) does not support address(0x0)
        // @dev Default OFT mints on dst.
        _mint(_to, _amountLD);
        
        // Auto-delegate for cross-chain transfers
        if (delegates(_to) == address(0)) {
            _delegate(_to, _to);
        }
        
        // @dev In the case of NON-default OFT, the _amountLD MIGHT not be == amountReceivedLD.
        return _amountLD;
    }
}