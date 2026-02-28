// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {KYCAllowlist} from "../compliance/KYCAllowlist.sol";

/**
 * @title RWAToken
 * @author jonathan.ji
 * @notice Permissioned ERC-20 representing shares in a tokenized real-world asset fund.
 *
 * @dev Key properties:
 *   - Only KYC-verified addresses can hold, send, or receive tokens
 *   - Mint/Burn controlled by OPERATOR_ROLE (SubscriptionManager / RedemptionManager)
 *   - Pausable for emergency situations
 *   - UUPS upgradeable (upgrade requires multisig + timelock)
 *   - Token value grows with NAV (not rebasing)
 *
 * Token economics:
 *   - Initial NAV: $1.00 per token
 *   - Token price increases daily as underlying assets earn yield
 *   - Total return = (currentNAV - initialNAV) / initialNAV
 */
contract RWAToken is
    Initializable,
    ERC20Upgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice KYC allowlist contract — all transfers are gated through this
    KYCAllowlist public kycAllowlist;

    /// @notice Metadata: underlying asset description
    string public assetDescription;

    /// @notice Metadata: ISIN or identifier of underlying fund
    string public assetIdentifier;

    /// @notice Total USDC subscribed (for accounting)
    uint256 public totalSubscribed;

    /// @notice Total USDC redeemed (for accounting)
    uint256 public totalRedeemed;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokensMinted(address indexed to, uint256 amount, uint256 usdcAmount);
    event TokensBurned(address indexed from, uint256 amount, uint256 usdcAmount);
    event KYCAllowlistUpdated(address indexed oldAllowlist, address indexed newAllowlist);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SenderNotKYCApproved(address sender);
    error RecipientNotKYCApproved(address recipient);
    error ZeroAddress();
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR / INIT
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the RWA token
     * @param name_             Token name (e.g., "Ondo SGD Money Market Fund")
     * @param symbol_           Token symbol (e.g., "oSGD-MMF")
     * @param admin             Admin address (multisig)
     * @param operator          Operator address (SubscriptionManager)
     * @param kycAllowlist_     KYCAllowlist contract address
     * @param assetDescription_ Description of underlying asset
     * @param assetIdentifier_  ISIN or identifier
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address admin,
        address operator,
        address kycAllowlist_,
        string memory assetDescription_,
        string memory assetIdentifier_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        if (admin == address(0) || operator == address(0) || kycAllowlist_ == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(PAUSER_ROLE, admin);

        kycAllowlist = KYCAllowlist(kycAllowlist_);
        assetDescription = assetDescription_;
        assetIdentifier = assetIdentifier_;
    }

    /*//////////////////////////////////////////////////////////////
                           OPERATOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint tokens to a KYC-verified address
     * @dev Called by SubscriptionManager after processing subscription
     * @param to         Recipient address (must be KYC approved)
     * @param amount     Token amount to mint (18 decimals)
     * @param usdcAmount USDC amount subscribed (for accounting)
     */
    function mint(
        address to,
        uint256 amount,
        uint256 usdcAmount
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!kycAllowlist.isApproved(to)) revert RecipientNotKYCApproved(to);

        totalSubscribed += usdcAmount;
        _mint(to, amount);

        emit TokensMinted(to, amount, usdcAmount);
    }

    /**
     * @notice Burn tokens from an address
     * @dev Called by RedemptionManager after processing redemption
     * @param from       Address to burn from
     * @param amount     Token amount to burn (18 decimals)
     * @param usdcAmount USDC amount redeemed (for accounting)
     */
    function burn(
        address from,
        uint256 amount,
        uint256 usdcAmount
    ) external onlyRole(OPERATOR_ROLE) {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        totalRedeemed += usdcAmount;
        _burn(from, amount);

        emit TokensBurned(from, amount, usdcAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function updateKYCAllowlist(address newAllowlist) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAllowlist == address(0)) revert ZeroAddress();
        address old = address(kycAllowlist);
        kycAllowlist = KYCAllowlist(newAllowlist);
        emit KYCAllowlistUpdated(old, newAllowlist);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Override ERC-20 transfer to enforce KYC gating
     *      Both sender and recipient must be KYC approved
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        // Skip KYC check for mint (from == address(0)) and burn (to == address(0))
        if (from != address(0) && !kycAllowlist.isApproved(from)) {
            revert SenderNotKYCApproved(from);
        }
        if (to != address(0) && !kycAllowlist.isApproved(to)) {
            revert RecipientNotKYCApproved(to);
        }
        super._update(from, to, amount);
    }

    /**
     * @notice Authorize contract upgrades (only through multisig self-call)
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        (newImplementation); // suppress unused warning
    }
}
