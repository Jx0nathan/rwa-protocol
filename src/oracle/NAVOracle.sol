// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title NAVOracle
 * @author jonathan.ji
 * @notice Daily Net Asset Value (NAV) oracle for RWA tokens.
 *         NAV represents the USDC value of one RWA token unit.
 *
 * @dev The oracle price is pushed daily by an authorized operator.
 *      Price is expressed in USDC (6 decimals): 1e6 = $1.00
 *
 * Example:
 *   Day 0: NAV = 1.000000e6 ($1.00 per token)
 *   Day 365: NAV = 1.045000e6 ($1.045 per token, ~4.5% APY)
 */
contract NAVOracle is AccessControl {

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    struct NAVData {
        uint256 nav;          // NAV in USDC (6 decimals)
        uint256 totalAUM;     // Total assets under management (USDC)
        uint256 totalSupply;  // Total token supply at this NAV
        uint48  timestamp;    // When this NAV was published
    }

    NAVData public currentNAV;
    NAVData[] public navHistory;

    // Maximum allowed NAV change per update (prevents oracle manipulation)
    // 500 bps = 5% max daily change
    uint256 public constant MAX_NAV_CHANGE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // Minimum update interval (23 hours, allows for timezone flexibility)
    uint256 public constant MIN_UPDATE_INTERVAL = 23 hours;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event NAVUpdated(
        uint256 indexed nav,
        uint256 totalAUM,
        uint256 totalSupply,
        uint48  timestamp
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NAVChangeTooLarge(uint256 oldNAV, uint256 newNAV);
    error UpdateTooFrequent(uint256 lastUpdate, uint256 minInterval);
    error InvalidNAV();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param admin     Admin address
     * @param oracle    Oracle operator address
     * @param initialNAV  Starting NAV (typically 1e6 = $1.00)
     */
    constructor(address admin, address oracle, uint256 initialNAV) {
        if (initialNAV == 0) revert InvalidNAV();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ROLE, oracle);

        currentNAV = NAVData({
            nav: initialNAV,
            totalAUM: 0,
            totalSupply: 0,
            timestamp: uint48(block.timestamp)
        });
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the NAV — called daily by the oracle operator
     * @param newNAV        New NAV in USDC (6 decimals)
     * @param newTotalAUM   Total AUM in USDC
     * @param newTotalSupply Total token supply
     */
    function updateNAV(
        uint256 newNAV,
        uint256 newTotalAUM,
        uint256 newTotalSupply
    ) external onlyRole(ORACLE_ROLE) {
        if (newNAV == 0) revert InvalidNAV();

        // Enforce minimum update interval
        if (block.timestamp < currentNAV.timestamp + MIN_UPDATE_INTERVAL) {
            revert UpdateTooFrequent(currentNAV.timestamp, MIN_UPDATE_INTERVAL);
        }

        // Enforce maximum NAV change (prevents oracle manipulation)
        uint256 oldNAV = currentNAV.nav;
        if (oldNAV > 0) {
            uint256 change = newNAV > oldNAV
                ? ((newNAV - oldNAV) * BPS_DENOMINATOR) / oldNAV
                : ((oldNAV - newNAV) * BPS_DENOMINATOR) / oldNAV;
            if (change > MAX_NAV_CHANGE_BPS) {
                revert NAVChangeTooLarge(oldNAV, newNAV);
            }
        }

        // Archive current NAV
        navHistory.push(currentNAV);

        // Update current NAV
        currentNAV = NAVData({
            nav: newNAV,
            totalAUM: newTotalAUM,
            totalSupply: newTotalSupply,
            timestamp: uint48(block.timestamp)
        });

        emit NAVUpdated(newNAV, newTotalAUM, newTotalSupply, uint48(block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current NAV
     */
    function getLatestNAV() external view returns (uint256) {
        return currentNAV.nav;
    }

    /**
     * @notice Calculate how many tokens a given USDC amount would mint
     * @param usdcAmount Amount in USDC (6 decimals)
     * @return tokenAmount Amount of RWA tokens (18 decimals)
     */
    function usdcToTokens(uint256 usdcAmount) external view returns (uint256) {
        // tokens = usdcAmount * 1e18 / nav
        // nav is in 6 decimals, result in 18 decimals
        return (usdcAmount * 1e18) / currentNAV.nav;
    }

    /**
     * @notice Calculate USDC value of a token amount
     * @param tokenAmount Amount of RWA tokens (18 decimals)
     * @return usdcAmount USDC value (6 decimals)
     */
    function tokensToUsdc(uint256 tokenAmount) external view returns (uint256) {
        // usdc = tokenAmount * nav / 1e18
        return (tokenAmount * currentNAV.nav) / 1e18;
    }

    /**
     * @notice Get NAV history length
     */
    function getHistoryLength() external view returns (uint256) {
        return navHistory.length;
    }

    /**
     * @notice Get historical NAV at a specific index
     */
    function getHistoricalNAV(uint256 index) external view returns (NAVData memory) {
        return navHistory[index];
    }
}
