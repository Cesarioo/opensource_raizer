// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IMintableToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function decimals() external view returns (uint8);
}

interface Whitelist {
    function isAddressWhitelisted(address account) external view returns (bool);
}

/**
 * @title PrimarySale Contract
 * @dev Manages token sale with USD contributions and role-based access control
 */
contract PrimarySale is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============
    /// @dev Thrown when an invalid (zero) address is provided
    error ZeroAddress();
    
    /// @dev Thrown when a USD token is already added or not found
    error USDTokenAlreadyAdded(address token);
    error USDTokenNotFound(address token);
    
    /// @dev Thrown for various contribution errors
    error NotWhitelisted(address account);
    error USDTokenNotAllowed(address token);
    error USDAlreadyDistributed();
    error ZeroAmount();
    error DifferentUSDTokenUsed(address existing, address attempted);
    
    /// @dev Thrown for distribution errors
    error NoUSDTokensProvided();
    error NoUSDToDistribute();
    error MustDistributeUSDFirst();
    error MintingAlreadyEnabled();
    error TotalSharesNotSet();
    
    /// @dev Thrown for share management errors
    error TotalSharesTooLow();
    error CannotChangeTotalSharesAfterMintingEnabled();
    
    /// @dev Thrown for claiming errors
    error MintingNotEnabled();
    error AlreadyClaimed(address account);
    error NoContribution(address account);
    error TokenAmountTooSmall();
    error InvalidUSDTokenDecimals();
    
    /// @dev Thrown for token recovery errors
    error CannotRecoverUSDToken();
    error CannotRecoverMainToken();
    error NoTokensToRecover();

    // Constants
    uint8 internal constant NORMALIZATION_DECIMALS = 18;

    // ============ State Variables ============
    // External contracts
    IMintableToken public immutable token;
    Whitelist public immutable whitelist;
    
    // Mappings
    mapping(address => mapping(address => uint256)) public usdContributionsByToken; // user => usdToken => amount
    mapping(address => address) public primaryContributionToken; // Tracks which USD token was first used by each contributor
    mapping(address => uint256) public normalizedContributions; // Normalized to 18 decimals
    mapping(address => bool) public hasClaimed;
    mapping(address => bool) public allowedUSDTokens;
    
    // Public variables
    uint256 public totalNormalizedUSD; // Total USD collected, normalized to 18 decimals
    bool public hasDistributedUSD;
    bool public canMintTokens;
    uint256 public totalShares; // Total number of shares to be distributed (used for calculating token allocation)

    // ============ Events ============
    event ContributionReceived(address indexed contributor, address indexed usdToken, uint256 amount, uint256 normalizedAmount, uint256 totalNormalizedForUser);
    event USDDistributed(uint256 totalUSD);
    event MintingEnabled();
    event TokensClaimed(address indexed contributor, uint256 amount);
    event TotalSharesUpdated(uint256 oldValue, uint256 newValue);
    event USDTokenAdded(address indexed usdToken);
    event USDTokenRemoved(address indexed usdToken);

    // ============ Constructor ============
    /**
     * @dev Sets up the initial roles and contract dependencies
     * @param _token The token being sold
     * @param _whitelist The whitelist contract determining eligible participants
     * @param admin Address that will have DEFAULT_ADMIN_ROLE permissions
     */
    constructor(address _token, address _whitelist, address admin) {
        if (_token == address(0)) revert ZeroAddress();
        if (_whitelist == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        
        token = IMintableToken(_token);
        whitelist = Whitelist(_whitelist);
        
        // Setup role management
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        
        // Initialize state
        hasDistributedUSD = false;
        canMintTokens = false;
    }

    // ============ External Functions ============
    // USD token management
    /**
     * @dev Adds a USD token to the allowed list
     * @param _usdToken The address of the USD token to add
     */
    function addUSDToken(address _usdToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_usdToken == address(0)) revert ZeroAddress();
        if (allowedUSDTokens[_usdToken]) revert USDTokenAlreadyAdded(_usdToken);
        
        // Verify the token has decimals() function
        try IERC20Metadata(_usdToken).decimals() returns (uint8 decimals) {
            // Successful call to decimals()
            if (decimals == 0) revert InvalidUSDTokenDecimals();
        } catch {
            revert InvalidUSDTokenDecimals();
        }
        
        allowedUSDTokens[_usdToken] = true;
        emit USDTokenAdded(_usdToken);
    }

    /**
     * @dev Removes a USD token from the allowed list
     * @param _usdToken The address of the USD token to remove
     */
    function removeUSDToken(address _usdToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!allowedUSDTokens[_usdToken]) revert USDTokenNotFound(_usdToken);
        
        allowedUSDTokens[_usdToken] = false;
        emit USDTokenRemoved(_usdToken);
    }

    /**
     * @dev Gets the decimals of a token
     * @param tokenAddress The token address
     * @return The token's decimals
     */
    function _getTokenDecimals(address tokenAddress) internal view returns (uint8) {
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            revert InvalidUSDTokenDecimals();
        }
    }

    /**
     * @dev Normalizes an amount from a token's native decimals to the standard 18 decimals
     * @param amount The amount to normalize
     * @param tokenDecimals The token's decimal places
     * @return The normalized amount (with 18 decimals)
     */
    function _normalizeAmount(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == NORMALIZATION_DECIMALS) {
            return amount;
        } else if (tokenDecimals < NORMALIZATION_DECIMALS) {
            return amount * (10 ** (NORMALIZATION_DECIMALS - tokenDecimals));
        } else {
            return amount / (10 ** (tokenDecimals - NORMALIZATION_DECIMALS));
        }
    }

    /**
     * @dev Calculate token amount from share amount based on decimals
     * @param shareAmount The share amount
     * @param tokenDecimals The token's decimal places
     * @return The token amount adjusted for decimals
     */
    function _calculateTokenAmount(uint256 shareAmount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == NORMALIZATION_DECIMALS) {
            return shareAmount;
        } else if (tokenDecimals < NORMALIZATION_DECIMALS) {
            return shareAmount / (10 ** (NORMALIZATION_DECIMALS - tokenDecimals));
        } else {
            return shareAmount * (10 ** (tokenDecimals - NORMALIZATION_DECIMALS));
        }
    }

    // Contribution functions
    /**
     * @dev Allows a whitelisted user to contribute USD tokens
     * @param usdToken The address of the USD token being contributed
     * @param amount The amount of USD tokens to contribute
     */
    function contribute(address usdToken, uint256 amount) external whenNotPaused nonReentrant {
        if (!whitelist.isAddressWhitelisted(msg.sender)) revert NotWhitelisted(msg.sender);
        if (!allowedUSDTokens[usdToken]) revert USDTokenNotAllowed(usdToken);
        if (hasDistributedUSD) revert USDAlreadyDistributed();
        if (amount == 0) revert ZeroAmount();
        
        // Enforce one-token-per-user policy
        if (primaryContributionToken[msg.sender] != address(0) && primaryContributionToken[msg.sender] != usdToken) {
            revert DifferentUSDTokenUsed(primaryContributionToken[msg.sender], usdToken);
        }
        
        // Transfer USD from sender to contract - SafeERC20 will revert on insufficient balance/allowance
        IERC20(usdToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Get token decimals
        uint8 usdDecimals = _getTokenDecimals(usdToken);
        
        // Normalize the amount to 18 decimals for consistent accounting
        uint256 normalizedAmount = _normalizeAmount(amount, usdDecimals);
        
        // Record the contribution
        if (primaryContributionToken[msg.sender] == address(0)) {
            primaryContributionToken[msg.sender] = usdToken;
        }
        
        usdContributionsByToken[msg.sender][usdToken] += amount;
        normalizedContributions[msg.sender] += normalizedAmount;
        totalNormalizedUSD += normalizedAmount;
        
        emit ContributionReceived(msg.sender, usdToken, amount, normalizedAmount, normalizedContributions[msg.sender]);
    }

    // Distribution functions
    /**
     * @dev Distributes collected USD tokens to the admin
     * @param usdTokens Array of USD token addresses to distribute
     */
    function distributeUSD(address[] calldata usdTokens) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused nonReentrant {
        if (hasDistributedUSD) revert USDAlreadyDistributed();
        if (usdTokens.length == 0) revert NoUSDTokensProvided();
        
        uint256 totalDistributed;
        address adminAddress = _msgSender();
        
        // Use an array to track already processed tokens
        address[] memory processedTokens = new address[](usdTokens.length);
        uint256 processedCount = 0;
        
        for (uint256 i = 0; i < usdTokens.length; i++) {
            address usdToken = usdTokens[i];
            
            // Skip if we've already processed this token
            bool alreadyProcessed = false;
            for (uint256 j = 0; j < processedCount; j++) {
                if (processedTokens[j] == usdToken) {
                    alreadyProcessed = true;
                    break;
                }
            }
            if (alreadyProcessed) continue;
            
            // Mark as processed
            processedTokens[processedCount++] = usdToken;
            
            if (!allowedUSDTokens[usdToken]) revert USDTokenNotAllowed(usdToken);
            
            IERC20 USD = IERC20(usdToken);
            uint256 balance = USD.balanceOf(address(this));
            if (balance > 0) {
                USD.safeTransfer(adminAddress, balance);
                
                // Get token decimals and normalize for the total
                uint8 usdDecimals = _getTokenDecimals(usdToken);
                uint256 normalizedBalance = _normalizeAmount(balance, usdDecimals);
                totalDistributed += normalizedBalance;
            }
        }
        
        if (totalDistributed == 0) revert NoUSDToDistribute();
        hasDistributedUSD = true;
        emit USDDistributed(totalDistributed);
    }

    /**
     * @dev Enables token minting after USD distribution
     */
    function enableMinting() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!hasDistributedUSD) revert MustDistributeUSDFirst();
        if (canMintTokens) revert MintingAlreadyEnabled();
        if (totalShares == 0) revert TotalSharesNotSet();
        
        canMintTokens = true;
        emit MintingEnabled();
    }

    // Share management
    /**
     * @dev Sets the total number of shares for token distribution
     * @param _totalShares The total number of shares to be distributed (whole numbers, 0 decimals)
     * @notice Shares represent whole units with 0 decimals. The minimum value of 1 shares ensures
     * sufficient precision for distribution calculations. All share-based calculations are internally 
     * adjusted to account for normalization to 18 decimals.
     */
    function setTotalShares(uint256 _totalShares) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_totalShares == 0) revert ZeroAmount();
        if (canMintTokens) revert CannotChangeTotalSharesAfterMintingEnabled();
        
        uint256 oldValue = totalShares;
        totalShares = _totalShares;
        emit TotalSharesUpdated(oldValue, _totalShares);
    }

    // Claiming functions
    /**
     * @dev Allows users to claim tokens based on their USD contribution
     */
    function claim() external whenNotPaused nonReentrant {
        if (!canMintTokens) revert MintingNotEnabled();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed(msg.sender);
        
        uint256 normalizedAmount = normalizedContributions[msg.sender];
        if (normalizedAmount == 0) revert NoContribution(msg.sender);
        
        // Calculate tokens based on the proportion of normalized USD contributed
        // Formula: (user's normalized USD / total normalized USD) * totalShares
        // Since totalShares has 0 decimals but normalizedAmount is 18 decimals,
        // we need to scale totalShares to match the 18 decimal precision
        uint256 scaledShares = totalShares * (10 ** NORMALIZATION_DECIMALS);
        uint256 shareAmount = (normalizedAmount * scaledShares) / totalNormalizedUSD;
        
        // Scale to token decimals
        uint8 tokenDecimals = token.decimals();
        uint256 tokenAmount = _calculateTokenAmount(shareAmount, tokenDecimals);
        
        if (tokenAmount == 0) revert TokenAmountTooSmall();

        // Mark as claimed before minting to prevent reentrancy
        hasClaimed[msg.sender] = true;

        // Mint tokens directly using the interface
        token.mint(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    // View functions
    /**
     * @dev Checks if a USD token is allowed
     * @param usdToken The address of the USD token to check
     * @return bool True if the token is allowed, false otherwise
     */
    function isUSDTokenAllowed(address usdToken) external view returns (bool) {
        return allowedUSDTokens[usdToken];
    }

    /**
     * @dev Gets the contribution amount for a specific USD token
     * @param contributor The address to check
     * @param usdToken The USD token to check
     * @return uint256 The amount of the specific USD token contributed
     */
    function getContributionByToken(address contributor, address usdToken) external view returns (uint256) {
        if (contributor == address(0)) revert ZeroAddress();
        return usdContributionsByToken[contributor][usdToken];
    }

    /**
     * @dev Gets the total normalized contribution of an address
     * @param contributor The address to check
     * @return uint256 The total normalized USD contributed (18 decimals)
     */
    function getNormalizedContribution(address contributor) external view returns (uint256) {
        if (contributor == address(0)) revert ZeroAddress();
        return normalizedContributions[contributor];
    }

    /**
     * @dev Gets the primary USD token used by a contributor
     * @param contributor The address to check
     * @return address The primary USD token address used
     */
    function getPrimaryContributionToken(address contributor) external view returns (address) {
        if (contributor == address(0)) revert ZeroAddress();
        return primaryContributionToken[contributor];
    }

    /**
     * @dev Calculates the amount of tokens claimable by an address
     * @param account The address to check
     * @return uint256 The amount of tokens claimable
     */
    function getClaimableAmount(address account) external view returns (uint256) {
        if (hasClaimed[account] || !canMintTokens || totalNormalizedUSD == 0) {
            return 0;
        }
        
        uint256 normalizedAmount = normalizedContributions[account];
        if (normalizedAmount == 0) return 0;
        
        // Calculate tokens based on the proportion of normalized USD contributed
        // Scale totalShares to match 18 decimal precision for calculation
        uint256 scaledShares = totalShares * (10 ** NORMALIZATION_DECIMALS);
        uint256 shareAmount = (normalizedAmount * scaledShares) / totalNormalizedUSD;
        
        // Scale to token decimals
        uint8 tokenDecimals = token.decimals();
        return _calculateTokenAmount(shareAmount, tokenDecimals);
    }

    /**
     * @dev Returns a user's share of the total USD collected
     * @param account The address to check
     * @return uint256 The proportion of total USD contributed (in 18 decimals)
     */
    function getUserSharePercentage(address account) external view returns (uint256) {
        if (totalNormalizedUSD == 0) return 0;
        uint256 normalizedAmount = normalizedContributions[account];
        if (normalizedAmount == 0) return 0;
        
        // Return percentage with 18 decimals (1e18 = 100%)
        return (normalizedAmount * 1e18) / totalNormalizedUSD;
    }

    // Admin functions
    /**
     * @dev Pauses all functions with the whenNotPaused modifier
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all functions with the whenNotPaused modifier
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Recovers accidentally sent tokens (except USD tokens and the main token)
     * @param _token The address of the token to recover
     */
    function emergencyTokenRecovery(IERC20 _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (allowedUSDTokens[address(_token)]) revert CannotRecoverUSDToken();
        if (address(_token) == address(token)) revert CannotRecoverMainToken();
        
        uint256 balance = _token.balanceOf(address(this));
        if (balance == 0) revert NoTokensToRecover();
        
        _token.safeTransfer(msg.sender, balance);
    }
}
