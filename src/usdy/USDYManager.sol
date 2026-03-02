// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./USDY.sol";
import "./USDYPricer.sol";
import "./interfaces/IUSDYManager.sol";

/**
 * @title USDYManager
 * @notice USDY 认购/赎回管理合约，模拟 Ondo USDYManager.sol + RWAHub.sol
 *
 * ═══════════════════════════════════════════════════
 * 完整认购流程（T+1 模式）
 * ═══════════════════════════════════════════════════
 *
 * 第一步：用户认购
 *   用户调用 requestDeposit(1000_000000)  // 1000 USDC (6位小数)
 *   ↓
 *   USDC 直接转入 assetRecipient（Coinbase 托管地址）
 *   ↗ ⚠️ 关键：USDC 不停留在合约中！合约余额始终为 0
 *   ↓
 *   创建 DepositRequest { depositor, usdcAmount, priceId: 0, claimed: false }
 *   返回 depositId
 *
 * 第二步：运营方日终处理（off-chain）
 *   计算当日 NAV（净资产值）
 *   调用 pricer.addPrice(navPrice, tomorrow_8am)  →  返回 priceId = 42
 *   调用 setPriceIdForDeposits([depositId1, depositId2, ...], 42)
 *   ↓
 *   所有当日认购被绑定到 priceId=42
 *
 * 第三步：用户领取（T+1 之后）
 *   用户调用 claimMint(depositId)
 *   ↓
 *   检查：block.timestamp >= pricer.getClaimableTimestamp(priceId)
 *   计算：usdyAmount = usdcAmount * 1e12 / price  (USDC 6位 → USDY 18位)
 *   调用：usdy.mint(depositor, usdyAmount)
 *   ↓
 *   用户收到 USDY
 *
 * ═══════════════════════════════════════════════════
 * 赎回流程
 * ═══════════════════════════════════════════════════
 *
 * 用户调用 requestRedemption(usdyAmount)
 *   → USDY 立即销毁（burn）
 *   → 创建 RedemptionRequest 等待运营方处理
 *
 * 运营方调用 completeRedemption(redemptionId, usdcAmount)
 *   → 从运营方钱包发送 USDC 给用户
 *   → 注意：这笔 USDC 来自 assetRecipient，需要运营方审批
 *
 * ═══════════════════════════════════════════════════
 * 为什么 USDC 不停留在合约中？（零余额设计）
 * ═══════════════════════════════════════════════════
 *
 * 合规原因：合约持有大量 USDC 会被视为"money transmission"，
 *           在美国可能需要 MTL（货币传输许可证）。
 * 安全原因：合约持有资金是黑客攻击的首要目标，
 *           钱在合约里 = 攻击面最大。
 * Ondo 的做法：USDC 直接 safeTransfer 到 assetRecipient（Coinbase Custody 地址），
 *              合约只记账，不持币。
 */
contract USDYManager is IUSDYManager, AccessControl, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  // ─────────────────────────────────────────────
  // 角色
  // ─────────────────────────────────────────────

  bytes32 public constant OPERATOR_ROLE      = keccak256("OPERATOR_ROLE");
  bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
  bytes32 public constant ASSET_SENDER_ROLE  = keccak256("ASSET_SENDER_ROLE"); // 执行赎回结算

  // ─────────────────────────────────────────────
  // 核心合约引用
  // ─────────────────────────────────────────────

  USDY        public immutable usdy;
  USDYPricer  public immutable pricer;
  IERC20      public immutable usdc;

  /**
   * @notice 资产接收方地址（托管方，如 Coinbase Custody）
   * @dev ⚠️ 这是零余额设计的关键：
   *      用户 USDC → 直接打到这个地址，合约不持有
   */
  address public immutable assetRecipient;

  // ─────────────────────────────────────────────
  // 认购请求状态
  // ─────────────────────────────────────────────

  struct DepositRequest {
    address depositor;    // 认购人
    uint256 usdcAmount;   // 存入 USDC 数量（6位小数）
    uint256 priceId;      // 绑定的价格 ID（0 = 未绑定）
    bool    claimed;      // 是否已领取 USDY
  }

  /// @notice 递增的认购 ID
  uint256 public depositIdCounter;

  /// @notice depositId → 认购请求
  mapping(uint256 => DepositRequest) public depositRequests;

  // ─────────────────────────────────────────────
  // 赎回请求状态
  // ─────────────────────────────────────────────

  struct RedemptionRequest {
    address redeemer;      // 赎回人
    uint256 usdyBurned;    // 已销毁 USDY 数量
    bool    completed;     // 是否已结算 USDC
  }

  /// @notice 递增的赎回 ID
  uint256 public redemptionIdCounter;

  /// @notice redemptionId → 赎回请求
  mapping(uint256 => RedemptionRequest) public redemptionRequests;

  // ─────────────────────────────────────────────
  // 限额配置
  // ─────────────────────────────────────────────

  /// @notice 单笔认购最小金额（USDC，6位）
  uint256 public minimumDepositAmount;

  /// @notice 单笔认购最大金额（USDC，6位）
  uint256 public maximumDepositAmount;

  /// @notice 单笔赎回最小金额（USDY，18位）
  uint256 public minimumRedemptionAmount;

  // ─────────────────────────────────────────────
  // 精度常量
  // ─────────────────────────────────────────────

  /// @notice USDC 精度：6位小数
  uint256 private constant USDC_DECIMALS = 1e6;

  /// @notice USDY 精度：18位小数
  uint256 private constant USDY_DECIMALS = 1e18;

  /// @notice 价格精度：1e18
  uint256 private constant PRICE_PRECISION = 1e18;

  // ─────────────────────────────────────────────
  // 构造函数
  // ─────────────────────────────────────────────

  constructor(
    address admin,
    address _usdy,
    address _pricer,
    address _usdc,
    address _assetRecipient,
    uint256 _minimumDepositAmount,
    uint256 _maximumDepositAmount,
    uint256 _minimumRedemptionAmount
  ) {
    require(admin            != address(0), "USDYManager: zero admin");
    require(_usdy            != address(0), "USDYManager: zero usdy");
    require(_pricer          != address(0), "USDYManager: zero pricer");
    require(_usdc            != address(0), "USDYManager: zero usdc");
    require(_assetRecipient  != address(0), "USDYManager: zero assetRecipient");

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(OPERATOR_ROLE,      admin);
    _grantRole(PAUSER_ROLE,        admin);
    _grantRole(ASSET_SENDER_ROLE,  admin);

    usdy           = USDY(_usdy);
    pricer         = USDYPricer(_pricer);
    usdc           = IERC20(_usdc);
    assetRecipient = _assetRecipient;

    minimumDepositAmount    = _minimumDepositAmount;
    maximumDepositAmount    = _maximumDepositAmount;
    minimumRedemptionAmount = _minimumRedemptionAmount;
  }

  // ─────────────────────────────────────────────
  // 用户操作：认购
  // ─────────────────────────────────────────────

  /**
   * @inheritdoc IUSDYManager
   *
   * ⚠️ 学习要点 1：零余额设计
   *    USDC 直接 safeTransferFrom(user, assetRecipient, amount)
   *    合约本身不接触 USDC，不需要 approve 到合约
   *
   * ⚠️ 学习要点 2：priceId = 0 是"未绑定"哨兵
   *    运营方日终才批量绑定 priceId，用户不知道自己的 price 是多少
   *    直到运营方调用 setPriceIdForDeposits
   */
  function requestDeposit(
    uint256 usdcAmount
  ) external override whenNotPaused nonReentrant returns (uint256 depositId) {
    require(
      usdcAmount >= minimumDepositAmount,
      "USDYManager: amount below minimum"
    );
    require(
      usdcAmount <= maximumDepositAmount,
      "USDYManager: amount exceeds maximum"
    );

    // USDC 直接转入托管方（assetRecipient），合约不持有
    usdc.safeTransferFrom(msg.sender, assetRecipient, usdcAmount);

    // 创建认购记录
    depositId = ++depositIdCounter;
    depositRequests[depositId] = DepositRequest({
      depositor:  msg.sender,
      usdcAmount: usdcAmount,
      priceId:    0,       // 未绑定，等待运营方日终处理
      claimed:    false
    });

    emit DepositRequested(msg.sender, depositId, usdcAmount, block.timestamp);
  }

  // ─────────────────────────────────────────────
  // 用户操作：领取 USDY
  // ─────────────────────────────────────────────

  /**
   * @inheritdoc IUSDYManager
   *
   * ⚠️ 学习要点：铸造数量计算
   *    usdyAmount = usdcAmount * 1e12 / price
   *
   *    为什么乘 1e12？
   *    USDC = 6位小数，USDY = 18位小数，差 12 位
   *    price 精度 = 1e18（即 1.0 = 1000000000000000000）
   *
   *    例子：price = 1.004e18, usdcAmount = 1000_000000 (1000 USDC)
   *    usdyAmount = 1000_000000 * 1e12 / 1.004e18
   *               = 1000_000000_000000_000000 / 1_004_000_000_000_000_000
   *               ≈ 996.01 USDY（即用 1000 USDC 买到 996 USDY，因为 NAV 已经 $1.004）
   */
  function claimMint(
    uint256 depositId
  ) external override whenNotPaused nonReentrant {
    DepositRequest storage req = depositRequests[depositId];

    require(req.depositor  != address(0), "USDYManager: depositId not found");
    require(req.depositor  == msg.sender, "USDYManager: not the depositor");
    require(!req.claimed,                 "USDYManager: already claimed");
    require(req.priceId    != 0,          "USDYManager: priceId not set yet, wait for operator");

    // 检查 T+1 时间锁
    uint256 claimableAt = pricer.getClaimableTimestamp(req.priceId);
    require(
      block.timestamp >= claimableAt,
      "USDYManager: too early, T+1 not reached"
    );

    // 获取价格（含 staleness 检查）
    uint256 price = pricer.getPriceById(req.priceId);

    // 计算铸造量（USDC 6位 → USDY 18位，需补 1e12）
    uint256 usdyAmount = (req.usdcAmount * 1e12 * PRICE_PRECISION) / price;
    require(usdyAmount > 0, "USDYManager: mint amount is zero");

    // 标记已领取
    req.claimed = true;

    // 铸造 USDY 给用户
    usdy.mint(req.depositor, usdyAmount);

    emit DepositClaimed(req.depositor, depositId, usdyAmount, price);
  }

  // ─────────────────────────────────────────────
  // 用户操作：赎回
  // ─────────────────────────────────────────────

  /**
   * @inheritdoc IUSDYManager
   *
   * ⚠️ 学习要点：赎回时立即销毁 USDY
   *    USDY 先 burn（不可逆），再等运营方结算 USDC
   *    用户需要信任运营方会履约打回 USDC
   *    这是 off-chain 托管模型的固有风险
   */
  function requestRedemption(
    uint256 usdyAmount
  ) external override whenNotPaused nonReentrant returns (uint256 redemptionId) {
    require(
      usdyAmount >= minimumRedemptionAmount,
      "USDYManager: redemption below minimum"
    );

    // 立即销毁 USDY（T+0）
    usdy.burn(msg.sender, usdyAmount);

    // 创建赎回记录
    redemptionId = ++redemptionIdCounter;
    redemptionRequests[redemptionId] = RedemptionRequest({
      redeemer:  msg.sender,
      usdyBurned: usdyAmount,
      completed:  false
    });

    emit RedemptionRequested(msg.sender, redemptionId, usdyAmount, block.timestamp);
  }

  // ─────────────────────────────────────────────
  // 运营方操作
  // ─────────────────────────────────────────────

  /**
   * @inheritdoc IUSDYManager
   * @dev 日终批量操作：将当日所有认购绑定到同一个 priceId
   *
   * ⚠️ 学习要点：批量绑定 vs 逐一绑定
   *    Ondo 一天可能有几百笔认购，
   *    一次 setPriceIdForDeposits 调用搞定所有，gas 高效
   */
  function setPriceIdForDeposits(
    uint256[] calldata depositIds,
    uint256 priceId
  ) external override onlyRole(OPERATOR_ROLE) {
    require(priceId != 0, "USDYManager: priceId cannot be 0");
    require(pricer.prices(priceId).isSet, "USDYManager: priceId not in pricer");

    for (uint256 i = 0; i < depositIds.length; i++) {
      uint256 did = depositIds[i];
      DepositRequest storage req = depositRequests[did];
      require(req.depositor != address(0), "USDYManager: invalid depositId");
      require(!req.claimed,                "USDYManager: already claimed");
      require(req.priceId == 0,            "USDYManager: priceId already set");
      req.priceId = priceId;
    }

    emit PriceIdSetForDeposits(priceId, depositIds);
  }

  /**
   * @inheritdoc IUSDYManager
   */
  function setClaimableTimestamp(
    uint256 priceId,
    uint256 claimableTimestamp
  ) external override onlyRole(OPERATOR_ROLE) {
    // NOTE: claimableTimestamp 通过 pricer.addPrice() 设置，这里是预留接口
    // 实际在 addPrice 时已经包含 claimableTimestamp
    // 如需单独覆盖，可在 pricer 上增加 override 方法
    (priceId, claimableTimestamp); // suppress unused
    revert("USDYManager: use pricer.addPrice() to set claimableTimestamp");
  }

  /**
   * @inheritdoc IUSDYManager
   * @dev 运营方发送 USDC 给赎回用户
   *      ⚠️ 注意：USDC 来自运营方钱包（assetRecipient 托管的资金），
   *              需要运营方在链下先从 Coinbase 提取 USDC 再调用本函数
   */
  function completeRedemption(
    uint256 redemptionId,
    uint256 usdcAmount
  ) external override onlyRole(ASSET_SENDER_ROLE) nonReentrant {
    RedemptionRequest storage req = redemptionRequests[redemptionId];

    require(req.redeemer   != address(0), "USDYManager: redemptionId not found");
    require(!req.completed,               "USDYManager: already completed");
    require(usdcAmount     > 0,           "USDYManager: zero usdc amount");

    req.completed = true;

    // 将 USDC 从运营方钱包发给赎回人
    usdc.safeTransferFrom(msg.sender, req.redeemer, usdcAmount);

    emit RedemptionCompleted(req.redeemer, redemptionId, usdcAmount);
  }

  // ─────────────────────────────────────────────
  // 批量 claimMint（节省 gas）
  // ─────────────────────────────────────────────

  /**
   * @notice 批量领取多个 depositId 的 USDY
   * @dev 遇到失败的 depositId 会跳过（不 revert 整批）
   */
  function claimMintBatch(uint256[] calldata depositIds) external whenNotPaused {
    for (uint256 i = 0; i < depositIds.length; i++) {
      // 只处理属于 msg.sender 的、已绑定 priceId 的、未 claimed 的请求
      DepositRequest storage req = depositRequests[depositIds[i]];
      if (
        req.depositor == msg.sender &&
        req.priceId   != 0 &&
        !req.claimed
      ) {
        // 简化：直接调用 claimMint 逻辑（也可以 call(this.claimMint)）
        uint256 claimableAt = pricer.getClaimableTimestamp(req.priceId);
        if (block.timestamp < claimableAt) continue; // T+1 未到，跳过

        uint256 price       = pricer.getPriceById(req.priceId);
        uint256 usdyAmount  = (req.usdcAmount * 1e12 * PRICE_PRECISION) / price;
        if (usdyAmount == 0) continue;

        req.claimed = true;
        usdy.mint(req.depositor, usdyAmount);
        emit DepositClaimed(req.depositor, depositIds[i], usdyAmount, price);
      }
    }
  }

  // ─────────────────────────────────────────────
  // 管理员配置
  // ─────────────────────────────────────────────

  function setMinimumDepositAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    minimumDepositAmount = amount;
  }

  function setMaximumDepositAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    maximumDepositAmount = amount;
  }

  function setMinimumRedemptionAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    minimumRedemptionAmount = amount;
  }

  function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
  function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
