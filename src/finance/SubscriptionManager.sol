// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RWAToken} from "../token/RWAToken.sol";
import {KYCAllowlist} from "../compliance/KYCAllowlist.sol";
import {NAVOracle} from "../oracle/NAVOracle.sol";

/**
 * @title SubscriptionManager
 * @author jonathan.ji
 * @notice Handles the subscription (purchase) flow for RWA tokens.
 *
 * @dev Flow:
 *   1. User calls subscribe(usdcAmount) → USDC locked in this contract
 *   2. Off-chain operator processes: buys underlying assets with USDC
 *   3. Operator calls fulfillSubscription(requestId) → RWA tokens minted to user
 *
 * This T+1 settlement model mirrors traditional fund subscription mechanics.
 * For T+0 instant settlement, see InstantSubscriptionManager (future extension).
 */
contract SubscriptionManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                              DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    enum SubscriptionStatus { PENDING, FULFILLED, CANCELLED }

    struct SubscriptionRequest {
        address subscriber;
        uint256 usdcAmount;
        uint256 tokenAmount;    // Filled on fulfillment
        uint256 navAtFulfill;   // NAV used for pricing
        uint48  requestedAt;
        uint48  fulfilledAt;
        SubscriptionStatus status;
    }

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IERC20     public immutable usdc;
    RWAToken   public immutable rwaToken;
    KYCAllowlist public immutable kycAllowlist;
    NAVOracle  public immutable navOracle;

    /// @notice Custodian address — USDC is sent here after fulfillment
    address public custodian;

    /// @notice Minimum subscription amount (USDC, 6 decimals)
    uint256 public minSubscriptionAmount;

    /// @notice Maximum daily subscription cap (USDC, 6 decimals)
    uint256 public dailySubscriptionCap;

    /// @notice Total USDC subscribed today
    uint256 public todaySubscribed;

    /// @notice Last reset day (unix day number)
    uint256 public lastResetDay;

    /// @notice All subscription requests
    mapping(uint256 => SubscriptionRequest) public subscriptions;
    uint256 public nextRequestId;

    /// @notice Pending USDC locked in this contract
    uint256 public pendingUsdc;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SubscriptionRequested(
        uint256 indexed requestId,
        address indexed subscriber,
        uint256 usdcAmount,
        uint48  requestedAt
    );
    event SubscriptionFulfilled(
        uint256 indexed requestId,
        address indexed subscriber,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 nav
    );
    event SubscriptionCancelled(uint256 indexed requestId, address indexed subscriber);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotKYCApproved();
    error BelowMinimum(uint256 amount, uint256 minimum);
    error DailyCapExceeded(uint256 amount, uint256 remaining);
    error RequestNotPending(uint256 requestId);
    error NotSubscriber(uint256 requestId);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address admin,
        address _usdc,
        address _rwaToken,
        address _kycAllowlist,
        address _navOracle,
        address _custodian,
        uint256 _minSubscriptionAmount,
        uint256 _dailySubscriptionCap
    ) {
        if (admin == address(0) || _custodian == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);

        usdc = IERC20(_usdc);
        rwaToken = RWAToken(_rwaToken);
        kycAllowlist = KYCAllowlist(_kycAllowlist);
        navOracle = NAVOracle(_navOracle);
        custodian = _custodian;
        minSubscriptionAmount = _minSubscriptionAmount;
        dailySubscriptionCap = _dailySubscriptionCap;
        lastResetDay = block.timestamp / 1 days;
    }

    /*//////////////////////////////////////////////////////////////
                            USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Submit a subscription request
     * @param usdcAmount Amount of USDC to subscribe (6 decimals)
     * @return requestId ID of the subscription request
     */
    function subscribe(uint256 usdcAmount)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        // KYC check
        if (!kycAllowlist.isApproved(msg.sender)) revert NotKYCApproved();

        // Minimum check
        if (usdcAmount < minSubscriptionAmount) {
            revert BelowMinimum(usdcAmount, minSubscriptionAmount);
        }

        // Daily cap check
        _resetDailyCapIfNeeded();
        if (todaySubscribed + usdcAmount > dailySubscriptionCap) {
            revert DailyCapExceeded(usdcAmount, dailySubscriptionCap - todaySubscribed);
        }

        // Transfer USDC from subscriber to this contract (held pending fulfillment)
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Record request
        requestId = nextRequestId++;
        subscriptions[requestId] = SubscriptionRequest({
            subscriber: msg.sender,
            usdcAmount: usdcAmount,
            tokenAmount: 0,
            navAtFulfill: 0,
            requestedAt: uint48(block.timestamp),
            fulfilledAt: 0,
            status: SubscriptionStatus.PENDING
        });

        todaySubscribed += usdcAmount;
        pendingUsdc += usdcAmount;

        emit SubscriptionRequested(requestId, msg.sender, usdcAmount, uint48(block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                           OPERATOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fulfill a pending subscription — called after buying underlying assets
     * @param requestId Subscription request ID
     */
    function fulfillSubscription(uint256 requestId)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        SubscriptionRequest storage req = subscriptions[requestId];
        if (req.status != SubscriptionStatus.PENDING) revert RequestNotPending(requestId);

        uint256 currentNAV = navOracle.getLatestNAV();

        // Calculate token amount: tokens = usdc * 1e18 / nav
        // nav is 6 decimals, result is 18 decimals
        uint256 tokenAmount = (req.usdcAmount * 1e18) / currentNAV;

        req.status = SubscriptionStatus.FULFILLED;
        req.tokenAmount = tokenAmount;
        req.navAtFulfill = currentNAV;
        req.fulfilledAt = uint48(block.timestamp);

        pendingUsdc -= req.usdcAmount;

        // Send USDC to custodian (who will invest in underlying assets)
        usdc.safeTransfer(custodian, req.usdcAmount);

        // Mint RWA tokens to subscriber
        rwaToken.mint(req.subscriber, tokenAmount, req.usdcAmount);

        emit SubscriptionFulfilled(
            requestId,
            req.subscriber,
            req.usdcAmount,
            tokenAmount,
            currentNAV
        );
    }

    /**
     * @notice Batch fulfill multiple subscriptions
     */
    function batchFulfillSubscriptions(uint256[] calldata requestIds)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        for (uint256 i = 0; i < requestIds.length; ++i) {
            SubscriptionRequest storage req = subscriptions[requestIds[i]];
            if (req.status != SubscriptionStatus.PENDING) continue;

            uint256 currentNAV = navOracle.getLatestNAV();
            uint256 tokenAmount = (req.usdcAmount * 1e18) / currentNAV;

            req.status = SubscriptionStatus.FULFILLED;
            req.tokenAmount = tokenAmount;
            req.navAtFulfill = currentNAV;
            req.fulfilledAt = uint48(block.timestamp);

            pendingUsdc -= req.usdcAmount;
            usdc.safeTransfer(custodian, req.usdcAmount);
            rwaToken.mint(req.subscriber, tokenAmount, req.usdcAmount);

            emit SubscriptionFulfilled(
                requestIds[i], req.subscriber, req.usdcAmount, tokenAmount, currentNAV
            );
        }
    }

    /**
     * @notice Cancel a pending subscription and return USDC
     */
    function cancelSubscription(uint256 requestId) external nonReentrant {
        SubscriptionRequest storage req = subscriptions[requestId];
        if (req.status != SubscriptionStatus.PENDING) revert RequestNotPending(requestId);
        if (req.subscriber != msg.sender && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotSubscriber(requestId);
        }

        req.status = SubscriptionStatus.CANCELLED;
        pendingUsdc -= req.usdcAmount;

        usdc.safeTransfer(req.subscriber, req.usdcAmount);

        emit SubscriptionCancelled(requestId, req.subscriber);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _resetDailyCapIfNeeded() internal {
        uint256 today = block.timestamp / 1 days;
        if (today > lastResetDay) {
            lastResetDay = today;
            todaySubscribed = 0;
        }
    }
}
