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
 * @title RedemptionManager
 * @author jonathan.ji
 * @notice Handles the redemption (withdrawal) flow for RWA tokens.
 *
 * @dev Flow:
 *   1. User calls redeem(tokenAmount) → tokens locked in this contract
 *   2. Off-chain operator sells underlying assets for USDC
 *   3. Operator deposits USDC and calls fulfillRedemption(requestId)
 *      → tokens burned, USDC returned to user
 *
 * Instant redemption (T+0) is available with an additional fee,
 * funded from a liquidity buffer maintained by the operator.
 */
contract RedemptionManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                              DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    enum RedemptionStatus { PENDING, FULFILLED, CANCELLED }

    struct RedemptionRequest {
        address redeemer;
        uint256 tokenAmount;
        uint256 usdcAmount;     // Filled on fulfillment
        uint256 navAtFulfill;
        uint256 feeAmount;      // Instant redemption fee (if applicable)
        bool    instant;        // T+0 instant redemption
        uint48  requestedAt;
        uint48  fulfilledAt;
        RedemptionStatus status;
    }

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IERC20       public immutable usdc;
    RWAToken     public immutable rwaToken;
    KYCAllowlist public immutable kycAllowlist;
    NAVOracle    public immutable navOracle;

    /// @notice Fee for instant (T+0) redemption in basis points (100 = 1%)
    uint256 public instantRedemptionFeeBps;

    /// @notice Liquidity buffer for instant redemptions (USDC)
    uint256 public liquidityBuffer;

    mapping(uint256 => RedemptionRequest) public redemptions;
    uint256 public nextRequestId;

    /// @notice Tokens locked pending redemption
    uint256 public pendingTokens;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RedemptionRequested(
        uint256 indexed requestId,
        address indexed redeemer,
        uint256 tokenAmount,
        bool    instant,
        uint48  requestedAt
    );
    event RedemptionFulfilled(
        uint256 indexed requestId,
        address indexed redeemer,
        uint256 tokenAmount,
        uint256 usdcAmount,
        uint256 feeAmount,
        uint256 nav
    );
    event RedemptionCancelled(uint256 indexed requestId);
    event LiquidityDeposited(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotKYCApproved();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error RequestNotPending(uint256 requestId);
    error NotRedeemer(uint256 requestId);
    error ZeroAmount();
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
        uint256 _instantRedemptionFeeBps
    ) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);

        usdc = IERC20(_usdc);
        rwaToken = RWAToken(_rwaToken);
        kycAllowlist = KYCAllowlist(_kycAllowlist);
        navOracle = NAVOracle(_navOracle);
        instantRedemptionFeeBps = _instantRedemptionFeeBps;
    }

    /*//////////////////////////////////////////////////////////////
                            USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Submit a redemption request (T+1 standard, no fee)
     * @param tokenAmount Amount of RWA tokens to redeem (18 decimals)
     * @return requestId ID of the redemption request
     */
    function redeem(uint256 tokenAmount)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        return _redeem(tokenAmount, false);
    }

    /**
     * @notice Submit an instant redemption request (T+0, fee applies)
     * @param tokenAmount Amount of RWA tokens to redeem (18 decimals)
     * @return requestId ID of the redemption request
     */
    function redeemInstant(uint256 tokenAmount)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        return _redeem(tokenAmount, true);
    }

    function _redeem(uint256 tokenAmount, bool instant)
        internal
        returns (uint256 requestId)
    {
        if (tokenAmount == 0) revert ZeroAmount();
        if (!kycAllowlist.isApproved(msg.sender)) revert NotKYCApproved();

        // For instant redemption, check liquidity buffer
        if (instant) {
            uint256 currentNAV = navOracle.getLatestNAV();
            uint256 grossUsdc = (tokenAmount * currentNAV) / 1e18;
            if (grossUsdc > liquidityBuffer) {
                revert InsufficientLiquidity(grossUsdc, liquidityBuffer);
            }
        }

        // Lock tokens in this contract
        IERC20(address(rwaToken)).safeTransferFrom(msg.sender, address(this), tokenAmount);

        requestId = nextRequestId++;
        redemptions[requestId] = RedemptionRequest({
            redeemer: msg.sender,
            tokenAmount: tokenAmount,
            usdcAmount: 0,
            navAtFulfill: 0,
            feeAmount: 0,
            instant: instant,
            requestedAt: uint48(block.timestamp),
            fulfilledAt: 0,
            status: RedemptionStatus.PENDING
        });

        pendingTokens += tokenAmount;

        // For instant redemption: process immediately
        if (instant) {
            _fulfillInstant(requestId);
        }

        emit RedemptionRequested(requestId, msg.sender, tokenAmount, instant, uint48(block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                           OPERATOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fulfill a standard (T+1) redemption
     * @param requestId Redemption request ID
     * @param usdcToDeliver USDC amount to deliver to the redeemer
     */
    function fulfillRedemption(uint256 requestId, uint256 usdcToDeliver)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        RedemptionRequest storage req = redemptions[requestId];
        if (req.status != RedemptionStatus.PENDING) revert RequestNotPending(requestId);
        if (req.instant) revert RequestNotPending(requestId); // instant handled separately

        uint256 currentNAV = navOracle.getLatestNAV();

        req.status = RedemptionStatus.FULFILLED;
        req.usdcAmount = usdcToDeliver;
        req.navAtFulfill = currentNAV;
        req.fulfilledAt = uint48(block.timestamp);
        pendingTokens -= req.tokenAmount;

        // Burn locked tokens
        rwaToken.burn(address(this), req.tokenAmount, usdcToDeliver);

        // Transfer USDC to redeemer (operator must have approved USDC first)
        usdc.safeTransferFrom(msg.sender, req.redeemer, usdcToDeliver);

        emit RedemptionFulfilled(requestId, req.redeemer, req.tokenAmount, usdcToDeliver, 0, currentNAV);
    }

    /**
     * @notice Deposit USDC into liquidity buffer (for instant redemptions)
     */
    function depositLiquidity(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        liquidityBuffer += amount;
        emit LiquidityDeposited(amount);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _fulfillInstant(uint256 requestId) internal {
        RedemptionRequest storage req = redemptions[requestId];
        uint256 currentNAV = navOracle.getLatestNAV();
        uint256 grossUsdc = (req.tokenAmount * currentNAV) / 1e18;
        uint256 fee = (grossUsdc * instantRedemptionFeeBps) / 10_000;
        uint256 netUsdc = grossUsdc - fee;

        req.status = RedemptionStatus.FULFILLED;
        req.usdcAmount = netUsdc;
        req.feeAmount = fee;
        req.navAtFulfill = currentNAV;
        req.fulfilledAt = uint48(block.timestamp);
        pendingTokens -= req.tokenAmount;
        liquidityBuffer -= grossUsdc;

        rwaToken.burn(address(this), req.tokenAmount, netUsdc);
        usdc.safeTransfer(req.redeemer, netUsdc);

        emit RedemptionFulfilled(requestId, req.redeemer, req.tokenAmount, netUsdc, fee, currentNAV);
    }
}
