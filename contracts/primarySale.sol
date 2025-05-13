// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IMintableToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function decimals() external view returns (uint8);
}

interface Whitelist {
    function isAddressWhitelisted(address account) external view returns (bool);
}

contract PrimarySale is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ State Variables ============
    // External contracts
    IMintableToken public immutable token;
    Whitelist public immutable whitelist;
    
    // Mappings
    mapping(address => uint256) public usdContributions;
    mapping(address => bool) public hasClaimed;
    mapping(address => bool) public allowedUSDTokens;
    
    // Public variables
    uint256 public totalUSDCollected;
    bool public hasDistributedUSD;
    bool public canMintTokens;
    uint256 public usdPerShare; // USD required per token, scaled to 6 decimals (e.g., 100e6 = 100 USD per token)

    // ============ Events ============
    event ContributionReceived(address indexed contributor, address indexed usdToken, uint256 amount, uint256 totalContributed);
    event USDDistributed(uint256 totalUSD);
    event MintingEnabled();
    event TokensClaimed(address indexed contributor, uint256 amount);
    event USDPerShareUpdated(uint256 oldValue, uint256 newValue);
    event USDTokenAdded(address indexed usdToken);
    event USDTokenRemoved(address indexed usdToken);

    // ============ Constructor ============
    constructor(address _token, address _whitelist) Ownable(msg.sender) {
        require(_token != address(0), "Invalid token address");
        require(_whitelist != address(0), "Invalid whitelist address");
        token = IMintableToken(_token);
        whitelist = Whitelist(_whitelist);
        hasDistributedUSD = false;
        canMintTokens = false;
    }

    // ============ External Functions ============
    // USD token management
    function addUSDToken(address _usdToken) external onlyOwner {
        require(_usdToken != address(0), "Invalid USD token address");
        require(!allowedUSDTokens[_usdToken], "USD token already added");
        allowedUSDTokens[_usdToken] = true;
        emit USDTokenAdded(_usdToken);
    }

    function removeUSDToken(address _usdToken) external onlyOwner {
        require(allowedUSDTokens[_usdToken], "USD token not found");
        allowedUSDTokens[_usdToken] = false;
        emit USDTokenRemoved(_usdToken);
    }

    // Contribution functions
    function contribute(address usdToken, uint256 amount) external whenNotPaused nonReentrant {
        require(whitelist.isAddressWhitelisted(msg.sender), "Address not whitelisted");
        require(allowedUSDTokens[usdToken], "USD token not allowed");
        require(!hasDistributedUSD, "USD has already been distributed");
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20 USD = IERC20(usdToken);
        
        // Check USD balance first
        uint256 balance = USD.balanceOf(msg.sender);
        require(balance >= amount, "Insufficient USD balance");
        
        // Check allowance
        uint256 allowance = USD.allowance(msg.sender, address(this));
        require(allowance >= amount, "Insufficient USD allowance");
        
        // Transfer USD from sender to contract
        USD.safeTransferFrom(msg.sender, address(this), amount);
        
        usdContributions[msg.sender] += amount;
        totalUSDCollected += amount;
        
        emit ContributionReceived(msg.sender, usdToken, amount, usdContributions[msg.sender]);
    }

    // Distribution functions
    function distributeUSD(address[] calldata usdTokens) external onlyOwner whenNotPaused nonReentrant {
        require(!hasDistributedUSD, "USD has already been distributed");
        require(usdTokens.length > 0, "No USD tokens provided");
        
        uint256 totalDistributed;
        
        for (uint256 i = 0; i < usdTokens.length; i++) {
            address usdToken = usdTokens[i];
            require(allowedUSDTokens[usdToken], "Invalid USD token");
            
            IERC20 USD = IERC20(usdToken);
            uint256 balance = USD.balanceOf(address(this));
            if (balance > 0) {
                USD.safeTransfer(owner(), balance);
                totalDistributed += balance;
            }
        }
        
        require(totalDistributed > 0, "No USD to distribute");
        hasDistributedUSD = true;
        emit USDDistributed(totalDistributed);
    }

    function enableMinting() external onlyOwner {
        require(hasDistributedUSD, "Must distribute USD first");
        require(!canMintTokens, "Minting already enabled");
        require(usdPerShare > 0, "USD per share must be set first");
        
        canMintTokens = true;
        emit MintingEnabled();
    }

    // Share price management
    function setUSDPerShare(uint256 _usdPerShare) external onlyOwner {
        require(_usdPerShare > 0, "USD per share must be greater than 0");
        require(!canMintTokens, "Cannot change USD per share after minting is enabled");
        // Ensure usdPerShare is properly scaled to 6 decimals
        require(_usdPerShare >= 1e6, "USD per share must be at least 1 USD (1e6)");
        uint256 oldValue = usdPerShare;
        usdPerShare = _usdPerShare;
        emit USDPerShareUpdated(oldValue, _usdPerShare);
    }

    // Claiming functions
    function claim() external whenNotPaused nonReentrant {
        require(canMintTokens, "Minting not enabled");
        require(!hasClaimed[msg.sender], "Already claimed");
        require(usdContributions[msg.sender] > 0, "No contribution found");

        uint256 usdAmount = usdContributions[msg.sender];
        uint8 tokenDecimals = token.decimals();
        
        // Calculate tokens: (USD amount * 10^tokenDecimals) / usdPerShare
        // Both usdAmount and usdPerShare are in 6 decimals, so the division is correct
        uint256 tokenAmount = (usdAmount * (10 ** tokenDecimals)) / usdPerShare;
        require(tokenAmount > 0, "Token amount too small");

        // Mark as claimed before minting to prevent reentrancy
        hasClaimed[msg.sender] = true;

        // Mint tokens directly using the interface
        token.mint(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    // View functions
    function isUSDTokenAllowed(address usdToken) external view returns (bool) {
        return allowedUSDTokens[usdToken];
    }

    function getContribution(address contributor) external view returns (uint256) {
        require(contributor != address(0), "Invalid address");
        return usdContributions[contributor];
    }

    function getClaimableAmount(address account) external view returns (uint256) {
        if (hasClaimed[account] || !canMintTokens) {
            return 0;
        }
        uint256 usdAmount = usdContributions[account];
        if (usdAmount == 0) return 0;
        
        uint8 tokenDecimals = token.decimals();
        return (usdAmount * (10 ** tokenDecimals)) / usdPerShare;
    }

    // Admin functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyTokenRecovery(IERC20 _token) external onlyOwner {
        require(!allowedUSDTokens[address(_token)], "Cannot recover USD token");
        require(address(_token) != address(token), "Cannot recover token");
        uint256 balance = _token.balanceOf(address(this));
        require(balance > 0, "No tokens to recover");
        _token.safeTransfer(owner(), balance);
    }
}
