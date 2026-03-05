// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRWAHub
 * @notice RWAHub 的接口 — 定义申购/赎回的数据结构、函数签名和事件
 *
 * ===== RWAHub 是什么？ =====
 *
 * RWAHub 是 USDY 协议的「业务中枢」，管理用户的申购（买入）和赎回（卖出）流程
 *
 * 与 Uniswap 这样的 DEX 不同，USDY 的买卖不是即时的：
 *   - 用户存入 USDC → 等待链下结算 → 管理员设置价格 → 用户领取 USDY
 *   - 这是因为底层资产是美国国债，需要 T+1 或 T+2 的结算时间
 *
 * ===== 核心数据结构 =====
 *
 * Depositor（申购者）：
 *   - user: 申购者地址
 *   - amountDepositedMinusFees: 扣除手续费后的存款金额（USDC 精度）
 *   - priceId: 管理员设置的价格 ID（用于计算应得的 USDY 数量）
 *
 * Redeemer（赎回者）：
 *   - user: 赎回者地址
 *   - amountRwaTokenBurned: 销毁的 USDY 数量
 *   - priceId: 管理员设置的价格 ID（用于计算应得的 USDC 数量）
 */
interface IRWAHub {
    // ============ 数据结构 ============
    struct Depositor {
        address user;
        uint256 amountDepositedMinusFees;
        uint256 priceId;
    }

    struct Redeemer {
        address user;
        uint256 amountRwaTokenBurned;
        uint256 priceId;
    }

    // ============ 核心函数 ============

    function requestSubscription(uint256 amount) external;

    function claimMint(bytes32[] calldata depositIds) external;

    function requestRedemption(uint256 amount) external;

    function claimRedemption(bytes32[] calldata redemptionIds) external;

    // ============ Relayer ============
    // 可以理解成是一个运营管理接口, 应对某些特殊场景（链上没有真实产生资金），把链下发生的存款记录到链上
    function addProof(
        bytes32 txHash,
        address user,
        uint256 depositAmountAfterFee,
        uint256 feeAmount,
        uint256 timestamp
    ) external;

    // ============ Price ID 设置 ============

    function setPriceIdForDeposits(
        bytes32[] calldata depositIds,
        uint256[] calldata priceIds
    ) external;

    function setPriceIdForRedemptions(
        bytes32[] calldata redemptionIds,
        uint256[] calldata priceIds
    ) external;

    // ============ Admin ============

    function setPricer(address newPricer) external;

    function overwriteDepositor(
        bytes32 depositIdToOverride,
        address user,
        uint256 depositAmountAfterFee,
        uint256 priceId
    ) external;

    function overwriteRedeemer(
        bytes32 redemptionIdToOverride,
        address user,
        uint256 rwaTokenAmountBurned,
        uint256 priceId
    ) external;

    // ============ 事件 ============

    event FeeRecipientSet(address oldFeeRecipient, address newFeeRecipient);
    event AssetSenderSet(address oldAssetSender, address newAssetSender);
    event MinimumDepositAmountSet(uint256 oldMinimum, uint256 newMinimum);
    event MinimumRedemptionAmountSet(
        uint256 oldRedemptionMin,
        uint256 newRedemptionMin
    );
    event MintFeeSet(uint256 oldFee, uint256 newFee);
    event RedemptionFeeSet(uint256 oldFee, uint256 newFee);

    event MintRequested(
        address indexed user,
        bytes32 indexed depositId,
        uint256 collateralAmountDeposited,
        uint256 depositAmountAfterFee,
        uint256 feeAmount
    );

    event MintCompleted(
        address indexed user,
        bytes32 indexed depositId,
        uint256 rwaAmountOut,
        uint256 collateralAmountDeposited,
        uint256 price,
        uint256 priceId
    );

    event RedemptionRequested(
        address indexed user,
        bytes32 indexed redemptionId,
        uint256 rwaAmountIn
    );

    event RedemptionCompleted(
        address indexed user,
        bytes32 indexed redemptionId,
        uint256 rwaAmountRequested,
        uint256 collateralAmountReturned,
        uint256 price
    );

    event PriceIdSetForDeposit(
        bytes32 indexed depositIdSet,
        uint256 indexed priceIdSet
    );
    event PriceIdSetForRedemption(
        bytes32 indexed redemptionIdSet,
        uint256 indexed priceIdSet
    );
    event NewPricerSet(address oldPricer, address newPricer);

    event DepositProofAdded(
        bytes32 indexed txHash,
        address indexed user,
        uint256 depositAmountAfterFee,
        uint256 feeAmount,
        uint256 timestamp
    );

    event SubscriptionPaused(address caller);
    event RedemptionPaused(address caller);
    event SubscriptionUnpaused(address caller);
    event RedemptionUnpaused(address caller);

    event DepositorOverwritten(
        bytes32 indexed depositId,
        address oldDepositor,
        address newDepositor,
        uint256 oldPriceId,
        uint256 newPriceId,
        uint256 oldDepositAmount,
        uint256 newDepositAmount
    );

    event RedeemerOverwritten(
        bytes32 indexed redemptionId,
        address oldRedeemer,
        address newRedeemer,
        uint256 oldPriceId,
        uint256 newPriceId,
        uint256 oldRWATokenAmountBurned,
        uint256 newRWATokenAmountBurned
    );

    // ============ 错误 ============

    error PriceIdNotSet();
    error ArraySizeMismatch();
    error DepositTooSmall();
    error RedemptionTooSmall();
    error CollateralCannotBeZero();
    error RWACannotBeZero();
    error AssetRecipientCannotBeZero();
    error AssetSenderCannotBeZero();
    error FeeRecipientCannotBeZero();
    error FeeTooLarge();
    error AmountTooSmall();
    error DepositorNull();
    error RedeemerNull();
    error DepositProofAlreadyExists();
    error FeaturePaused();
    error PriceIdAlreadySet();
}
