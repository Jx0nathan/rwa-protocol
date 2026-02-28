// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title KYCAllowlist
 * @author jonathan.ji
 * @notice Manages on-chain KYC allowlist for RWA token holders.
 *         Only KYC-verified addresses can hold, send, or receive RWA tokens.
 *
 * @dev KYC verification happens off-chain (SumSub/Jumio).
 *      Verified addresses are added to this allowlist by the OPERATOR_ROLE.
 *
 * KYC Tiers:
 *   Tier 1 - Email + Phone: $1,000 limit
 *   Tier 2 - ID + Face:     $100,000 limit
 *   Tier 3 - Accredited:    Unlimited
 */
contract KYCAllowlist is AccessControl {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    enum KYCTier { NONE, TIER_1, TIER_2, TIER_3 }

    struct KYCStatus {
        KYCTier tier;
        uint48  approvedAt;
        uint48  expiresAt;   // 0 = never expires
        bool    sanctioned;  // OFAC / UN sanctions flag
    }

    mapping(address => KYCStatus) private _kycStatus;

    // Maximum subscription amounts per tier (in 6-decimal USDC)
    uint256 public constant TIER_1_LIMIT = 1_000e6;
    uint256 public constant TIER_2_LIMIT = 100_000e6;
    uint256 public constant TIER_3_LIMIT = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AddressApproved(address indexed account, KYCTier tier, uint48 expiresAt);
    event AddressRevoked(address indexed account);
    event AddressSanctioned(address indexed account);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotKYCApproved(address account);
    error AddressSanctionedError(address account);
    error InvalidTier();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Approve an address after off-chain KYC verification
     * @param account   Address to approve
     * @param tier      KYC tier (1, 2, or 3)
     * @param expiresAt Expiry timestamp (0 = never expires)
     */
    function approveAddress(
        address account,
        KYCTier tier,
        uint48 expiresAt
    ) external onlyRole(OPERATOR_ROLE) {
        if (tier == KYCTier.NONE) revert InvalidTier();
        _kycStatus[account] = KYCStatus({
            tier: tier,
            approvedAt: uint48(block.timestamp),
            expiresAt: expiresAt,
            sanctioned: false
        });
        emit AddressApproved(account, tier, expiresAt);
    }

    /**
     * @notice Batch approve addresses
     */
    function batchApproveAddresses(
        address[] calldata accounts,
        KYCTier tier,
        uint48 expiresAt
    ) external onlyRole(OPERATOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (tier == KYCTier.NONE) revert InvalidTier();
            _kycStatus[accounts[i]] = KYCStatus({
                tier: tier,
                approvedAt: uint48(block.timestamp),
                expiresAt: expiresAt,
                sanctioned: false
            });
            emit AddressApproved(accounts[i], tier, expiresAt);
        }
    }

    /**
     * @notice Revoke KYC approval for an address
     */
    function revokeAddress(address account) external onlyRole(OPERATOR_ROLE) {
        delete _kycStatus[account];
        emit AddressRevoked(account);
    }

    /**
     * @notice Mark address as sanctioned (OFAC / UN sanctions)
     */
    function sanctionAddress(address account) external onlyRole(OPERATOR_ROLE) {
        _kycStatus[account].sanctioned = true;
        emit AddressSanctioned(account);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if an address is KYC approved and not sanctioned
     */
    function isApproved(address account) public view returns (bool) {
        KYCStatus memory status = _kycStatus[account];
        if (status.tier == KYCTier.NONE) return false;
        if (status.sanctioned) return false;
        if (status.expiresAt != 0 && block.timestamp > status.expiresAt) return false;
        return true;
    }

    /**
     * @notice Get KYC tier for an address
     */
    function getTier(address account) external view returns (KYCTier) {
        return _kycStatus[account].tier;
    }

    /**
     * @notice Get subscription limit for an address based on KYC tier
     */
    function getSubscriptionLimit(address account) external view returns (uint256) {
        KYCTier tier = _kycStatus[account].tier;
        if (tier == KYCTier.TIER_1) return TIER_1_LIMIT;
        if (tier == KYCTier.TIER_2) return TIER_2_LIMIT;
        if (tier == KYCTier.TIER_3) return TIER_3_LIMIT;
        return 0;
    }

    /**
     * @notice Get full KYC status for an address
     */
    function getKYCStatus(address account) external view returns (KYCStatus memory) {
        return _kycStatus[account];
    }
}
