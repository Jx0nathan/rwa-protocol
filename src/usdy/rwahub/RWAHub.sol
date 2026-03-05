// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "src/usdy/interfaces/IPricer.sol";
import "src/usdy/interfaces/IRWALike.sol";
import "src/usdy/interfaces/IRWAHub.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RWAHub
 * @notice 申购/赎回中枢 — Phase 7 学习合约
 *
 * ===== 整体定位 =====
 *
 * RWAHub 是 USDY 协议中最核心的合约，管理用户「买入」和「卖出」USDY 的完整生命周期。
 *
 * 为什么不像 DEX 那样即时交易？
 * → USDY 的底层资产是美国短期国债
 * → 国债交易需要 T+1/T+2 结算（链下世界的限制）
 * → 所以用户的申购/赎回是「请求 → 等待 → 领取」三步走
 *
 * ===== 申购流程（Subscription） =====
 *
 *   用户                          RWAHub                     链下托管
 *   ─────────────────────────────────────────────────────────────────
 *   1. approve(hub, amount)
 *   2. requestSubscription(amt)
 *      → USDC 转入 assetRecipient  ───────────────────→  收到 USDC
 *      → 记录 depositId → Depositor{user, amount, 0}     购买国债
 *
 *   3. 等待...链下托管完成国债购买
 *
 *   4. 管理员调用 setPriceIdForDeposits([depositId], [priceId])
 *      → 记录 depositor.priceId = priceId
 *
 *   5. claimMint([depositId])
 *      → 读取 price = pricer.getPrice(priceId)
 *      → 计算 rwaOwed = depositAmount * decimalsMultiplier * 1e18 / price
 *      → mint USDY 给用户
 *      → 删除 depositor 记录
 *
 * ===== 赎回流程（Redemption） =====
 *
 *   用户                          RWAHub                     链下托管
 *   ─────────────────────────────────────────────────────────────────
 *   1. approve(hub, amount)
 *   2. requestRedemption(amt)
 *      → burn USDY from 用户                              卖出国债
 *      → 记录 redemptionId → Redeemer{user, amount, 0}
 *
 *   3. 等待...链下托管完成国债卖出
 *
 *   4. 管理员调用 setPriceIdForRedemptions([redemptionId], [priceId])
 *
 *   5. claimRedemption([redemptionId])
 *      → 读取 price = pricer.getPrice(priceId)
 *      → 计算 collateralDue = rwaAmount * price / 1e18 / decimalsMultiplier
 *      → 从 assetSender 转 USDC 给用户
 *      → 删除 redeemer 记录
 *
 * ===== 精度转换（Decimals） =====
 *
 * USDC: 6 位小数（1 USDC = 1e6）
 * USDY: 18 位小数（1 USDY = 1e18）
 * Price: 18 位小数（$1.05 = 1.05e18）
 *
 * decimalsMultiplier = 10^(18 - 6) = 1e12
 *
 * 申购计算：
 *   depositAmt = 1000e6 (1000 USDC)
 *   price = 1.05e18
 *   rwaOwed = (1000e6 * 1e12) * 1e18 / 1.05e18
 *           = 1000e18 * 1e18 / 1.05e18
 *           = ~952.38e18 USDY
 *
 * 赎回计算：
 *   rwaAmount = 952.38e18 (USDY)
 *   price = 1.05e18
 *   collateralDue = (952.38e18 * 1.05e18 / 1e18) / 1e12
 *                 = 1000e18 / 1e12
 *                 = 1000e6 (1000 USDC)
 *
 * ===== 费用机制 =====
 *
 * mintFee / redemptionFee: 以基点（BPS）表示
 *   100 BPS = 1%
 *   10000 BPS = 100%
 *
 *   申购费在存款时扣除：depositAfterFee = amount - amount * mintFee / 10000
 *   赎回费在领取时扣除：collateralAfterFee = collateral - collateral * redemptionFee / 10000
 *
 * ===== 角色权限 =====
 *
 * DEFAULT_ADMIN_ROLE → 可以 grant/revoke 其他角色
 * MANAGER_ADMIN      → 管理参数（fee、minimum、pricer 等）+ unpause
 * PAUSER_ADMIN       → 暂停申购/赎回
 * PRICE_ID_SETTER_ROLE → 设置 depositId/redemptionId 对应的 priceId
 * RELAYER_ROLE       → 添加链下存款证明
 *
 * 注意权限层级设计：
 *   PAUSER_ADMIN 可以暂停，但只有 MANAGER_ADMIN 可以恢复
 *   → 确保暂停容易、恢复需要更高权限
 *
 * ===== 为什么是 abstract？ =====
 *
 * _checkRestrictions() 是纯虚函数，子类必须实现
 * → USDYManager 会实现为 blocklist + sanctions 检查
 * → 其他 RWA 产品可能有不同的限制逻辑
 */
abstract contract RWAHub is IRWAHub, ReentrancyGuard, AccessControl {
  using SafeERC20 for IERC20;

  // ============ 不可变量 ============

  /// @dev RWA Token（如 USDY）
  IRWALike public immutable rwa;

  /// @dev 抵押品代币（如 USDC）
  IERC20 public immutable collateral;

  /// @dev 精度乘数 = 10^(rwa.decimals - collateral.decimals)
  ///      USDY(18) - USDC(6) = 1e12
  uint256 public immutable decimalsMultiplier;

  // ============ 可变状态 ============

  /// @dev 价格合约
  IPricer public pricer;

  /// @dev 存款接收地址（用户的 USDC 转到这里）
  address public assetRecipient;

  /// @dev 赎回发送地址（USDC 从这里转给用户）
  address public assetSender;

  /// @dev 手续费接收地址
  address public feeRecipient;

  /// @dev depositId → 申购者信息
  mapping(bytes32 => Depositor) public depositIdToDepositor;

  /// @dev redemptionId → 赎回者信息
  mapping(bytes32 => Redeemer) public redemptionIdToRedeemer;

  /// @dev 最低存款金额（collateral 精度）
  uint256 public minimumDepositAmount;

  /// @dev 最低赎回金额
  uint256 public minimumRedemptionAmount;

  /// @dev 铸造手续费（基点）
  uint256 public mintFee = 0;

  /// @dev 赎回手续费（基点）
  uint256 public redemptionFee = 0;

  /// @dev 申购请求计数器（从 1 开始，0 保留）
  uint256 public subscriptionRequestCounter = 1;

  /// @dev 赎回请求计数器（从 1 开始）
  uint256 public redemptionRequestCounter = 1;

  /// @dev 基点分母
  uint256 public constant BPS_DENOMINATOR = 10_000;

  /// @dev 暂停标志
  bool public subscriptionPaused;
  bool public redemptionPaused;

  // ============ 角色 ============

  bytes32 public constant MANAGER_ADMIN = keccak256("MANAGER_ADMIN");
  bytes32 public constant PAUSER_ADMIN = keccak256("PAUSER_ADMIN");
  bytes32 public constant PRICE_ID_SETTER_ROLE = keccak256("PRICE_ID_SETTER_ROLE");
  bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

  // ============ 构造函数 ============

  constructor(
    address _collateral,
    address _rwa,
    address managerAdmin,
    address pauser,
    address _assetRecipient,
    address _assetSender,
    address _feeRecipient,
    uint256 _minimumDepositAmount,
    uint256 _minimumRedemptionAmount
  ) {
    if (_collateral == address(0)) revert CollateralCannotBeZero();
    if (_rwa == address(0)) revert RWACannotBeZero();
    if (_assetRecipient == address(0)) revert AssetRecipientCannotBeZero();
    if (_assetSender == address(0)) revert AssetSenderCannotBeZero();
    if (_feeRecipient == address(0)) revert FeeRecipientCannotBeZero();

    // 角色设置
    _grantRole(DEFAULT_ADMIN_ROLE, managerAdmin);
    _grantRole(MANAGER_ADMIN, managerAdmin);
    _grantRole(PAUSER_ADMIN, pauser);

    // 角色管理层级：MANAGER_ADMIN 管理下面三个角色
    _setRoleAdmin(PAUSER_ADMIN, MANAGER_ADMIN);
    _setRoleAdmin(PRICE_ID_SETTER_ROLE, MANAGER_ADMIN);
    _setRoleAdmin(RELAYER_ROLE, MANAGER_ADMIN);

    collateral = IERC20(_collateral);
    rwa = IRWALike(_rwa);
    assetRecipient = _assetRecipient;
    assetSender = _assetSender;
    feeRecipient = _feeRecipient;
    minimumDepositAmount = _minimumDepositAmount;
    minimumRedemptionAmount = _minimumRedemptionAmount;

    // 计算精度乘数
    // USDY(18 decimals) vs USDC(6 decimals) → 10^12
    decimalsMultiplier =
      10 ** (IERC20Metadata(_rwa).decimals() - IERC20Metadata(_collateral).decimals());
  }

  // ============================================================
  //                    申购/赎回核心函数
  // ============================================================

  /**
   * @notice 用户请求申购 — 存入 USDC
   *
   * 流程：
   *   1. 检查金额 ≥ minimumDepositAmount
   *   2. 计算手续费 → 扣除
   *   3. 生成唯一 depositId（自增计数器转 bytes32）
   *   4. 记录 Depositor 信息
   *   5. 转移 USDC：手续费 → feeRecipient，净额 → assetRecipient
   */
  function requestSubscription(
    uint256 amount
  )
    external
    virtual
    nonReentrant
    ifNotPaused(subscriptionPaused)
    checkRestrictions(msg.sender)
  {
    if (amount < minimumDepositAmount) revert DepositTooSmall();

    uint256 feesInCollateral = _getMintFees(amount);
    uint256 depositAmountAfterFee = amount - feesInCollateral;

    bytes32 depositId = bytes32(subscriptionRequestCounter++);
    depositIdToDepositor[depositId] = Depositor(msg.sender, depositAmountAfterFee, 0);

    if (feesInCollateral > 0) {
      collateral.safeTransferFrom(msg.sender, feeRecipient, feesInCollateral);
    }
    collateral.safeTransferFrom(msg.sender, assetRecipient, depositAmountAfterFee);

    emit MintRequested(msg.sender, depositId, amount, depositAmountAfterFee, feesInCollateral);
  }

  /**
   * @notice 用户领取 USDY — 批量处理多个 depositId
   */
  function claimMint(
    bytes32[] calldata depositIds
  ) external virtual nonReentrant ifNotPaused(subscriptionPaused) {
    for (uint256 i = 0; i < depositIds.length; ++i) {
      _claimMint(depositIds[i]);
    }
  }

  /**
   * @notice 内部 mint 领取逻辑 — 可被子类 override
   *
   * 计算公式：
   *   rwaOwed = (depositAmt * decimalsMultiplier) * 1e18 / price
   *
   * 例如 depositAmt=1000e6, price=1.05e18:
   *   rwaOwed = (1000e6 * 1e12) * 1e18 / 1.05e18 = ~952.38e18
   */
  function _claimMint(bytes32 depositId) internal virtual {
    Depositor memory depositor = depositIdToDepositor[depositId];
    if (depositor.priceId == 0) revert PriceIdNotSet();

    uint256 price = pricer.getPrice(depositor.priceId);
    uint256 rwaOwed = _getMintAmountForPrice(depositor.amountDepositedMinusFees, price);

    delete depositIdToDepositor[depositId];
    rwa.mint(depositor.user, rwaOwed);

    emit MintCompleted(
      depositor.user,
      depositId,
      rwaOwed,
      depositor.amountDepositedMinusFees,
      price,
      depositor.priceId
    );
  }

  /**
   * @notice 用户请求赎回 — 销毁 USDY
   */
  function requestRedemption(
    uint256 amount
  ) external virtual nonReentrant ifNotPaused(redemptionPaused) {
    if (amount < minimumRedemptionAmount) revert RedemptionTooSmall();

    bytes32 redemptionId = bytes32(redemptionRequestCounter++);
    redemptionIdToRedeemer[redemptionId] = Redeemer(msg.sender, amount, 0);

    rwa.burnFrom(msg.sender, amount);

    emit RedemptionRequested(msg.sender, redemptionId, amount);
  }

  /**
   * @notice 用户领取赎回的 USDC
   *
   * 注意：USDC 从 assetSender 转出（不是从合约本身）
   * → assetSender 需要提前 approve hub 足够的 USDC
   */
  function claimRedemption(
    bytes32[] calldata redemptionIds
  ) external virtual nonReentrant ifNotPaused(redemptionPaused) {
    uint256 fees;
    for (uint256 i = 0; i < redemptionIds.length; ++i) {
      Redeemer memory member = redemptionIdToRedeemer[redemptionIds[i]];
      _checkRestrictions(member.user);
      if (member.priceId == 0) revert PriceIdNotSet();

      uint256 price = pricer.getPrice(member.priceId);
      uint256 collateralDue = _getRedemptionAmountForRwa(member.amountRwaTokenBurned, price);
      uint256 fee = _getRedemptionFees(collateralDue);
      uint256 collateralDuePostFees = collateralDue - fee;
      fees += fee;

      delete redemptionIdToRedeemer[redemptionIds[i]];

      collateral.safeTransferFrom(assetSender, member.user, collateralDuePostFees);

      emit RedemptionCompleted(
        member.user,
        redemptionIds[i],
        member.amountRwaTokenBurned,
        collateralDuePostFees,
        price
      );
    }
    if (fees > 0) {
      collateral.safeTransferFrom(assetSender, feeRecipient, fees);
    }
  }

  // ============================================================
  //                      Relayer 函数
  // ============================================================

  /**
   * @notice Relayer 添加链下存款证明
   *
   * 场景：用户通过银行电汇存款（不是链上转账），
   *       Relayer 检测到后调用此函数记录存款
   *
   * txHash 作为 depositId 使用
   */
  function addProof(
    bytes32 txHash,
    address user,
    uint256 depositAmountAfterFee,
    uint256 feeAmount,
    uint256 timestamp
  ) external override onlyRole(RELAYER_ROLE) checkRestrictions(user) {
    if (depositIdToDepositor[txHash].user != address(0)) {
      revert DepositProofAlreadyExists();
    }
    depositIdToDepositor[txHash] = Depositor(user, depositAmountAfterFee, 0);
    emit DepositProofAdded(txHash, user, depositAmountAfterFee, feeAmount, timestamp);
  }

  // ============================================================
  //                    PriceId 设置
  // ============================================================

  /**
   * @notice 管理员为 depositId 关联 priceId
   *
   * 这是申购流程中关键的「链下→链上」桥接步骤：
   *   链下完成国债购买 → 确定价格 → 管理员调用此函数 → 用户可以 claimMint
   */
  function setPriceIdForDeposits(
    bytes32[] calldata depositIds,
    uint256[] calldata priceIds
  ) external virtual onlyRole(PRICE_ID_SETTER_ROLE) {
    if (depositIds.length != priceIds.length) revert ArraySizeMismatch();
    for (uint256 i = 0; i < depositIds.length; ++i) {
      if (depositIdToDepositor[depositIds[i]].user == address(0)) revert DepositorNull();
      if (depositIdToDepositor[depositIds[i]].priceId != 0) revert PriceIdAlreadySet();
      depositIdToDepositor[depositIds[i]].priceId = priceIds[i];
      emit PriceIdSetForDeposit(depositIds[i], priceIds[i]);
    }
  }

  /**
   * @notice 管理员为 redemptionId 关联 priceId
   */
  function setPriceIdForRedemptions(
    bytes32[] calldata redemptionIds,
    uint256[] calldata priceIds
  ) external virtual onlyRole(PRICE_ID_SETTER_ROLE) {
    if (redemptionIds.length != priceIds.length) revert ArraySizeMismatch();
    for (uint256 i = 0; i < redemptionIds.length; ++i) {
      if (redemptionIdToRedeemer[redemptionIds[i]].user == address(0)) revert RedeemerNull();
      if (redemptionIdToRedeemer[redemptionIds[i]].priceId != 0) revert PriceIdAlreadySet();
      redemptionIdToRedeemer[redemptionIds[i]].priceId = priceIds[i];
      emit PriceIdSetForRedemption(redemptionIds[i], priceIds[i]);
    }
  }

  // ============================================================
  //                     Admin Setters
  // ============================================================

  function overwriteDepositor(
    bytes32 depositIdToOverwrite,
    address user,
    uint256 depositAmountAfterFee,
    uint256 priceId
  ) external onlyRole(MANAGER_ADMIN) checkRestrictions(user) {
    Depositor memory old = depositIdToDepositor[depositIdToOverwrite];
    depositIdToDepositor[depositIdToOverwrite] = Depositor(user, depositAmountAfterFee, priceId);
    emit DepositorOverwritten(
      depositIdToOverwrite, old.user, user, old.priceId, priceId,
      old.amountDepositedMinusFees, depositAmountAfterFee
    );
  }

  function overwriteRedeemer(
    bytes32 redemptionIdToOverwrite,
    address user,
    uint256 rwaTokenAmountBurned,
    uint256 priceId
  ) external onlyRole(MANAGER_ADMIN) checkRestrictions(user) {
    Redeemer memory old = redemptionIdToRedeemer[redemptionIdToOverwrite];
    redemptionIdToRedeemer[redemptionIdToOverwrite] = Redeemer(user, rwaTokenAmountBurned, priceId);
    emit RedeemerOverwritten(
      redemptionIdToOverwrite, old.user, user, old.priceId, priceId,
      old.amountRwaTokenBurned, rwaTokenAmountBurned
    );
  }

  function setMinimumDepositAmount(uint256 amt) external onlyRole(MANAGER_ADMIN) {
    if (amt < BPS_DENOMINATOR) revert AmountTooSmall();
    uint256 old = minimumDepositAmount;
    minimumDepositAmount = amt;
    emit MinimumDepositAmountSet(old, amt);
  }

  function setMinimumRedemptionAmount(uint256 amt) external onlyRole(MANAGER_ADMIN) {
    if (amt < BPS_DENOMINATOR) revert AmountTooSmall();
    uint256 old = minimumRedemptionAmount;
    minimumRedemptionAmount = amt;
    emit MinimumRedemptionAmountSet(old, amt);
  }

  function setMintFee(uint256 _mintFee) external onlyRole(MANAGER_ADMIN) {
    if (_mintFee > BPS_DENOMINATOR) revert FeeTooLarge();
    uint256 old = mintFee;
    mintFee = _mintFee;
    emit MintFeeSet(old, _mintFee);
  }

  function setRedemptionFee(uint256 _redemptionFee) external onlyRole(MANAGER_ADMIN) {
    if (_redemptionFee > BPS_DENOMINATOR) revert FeeTooLarge();
    uint256 old = redemptionFee;
    redemptionFee = _redemptionFee;
    emit RedemptionFeeSet(old, _redemptionFee);
  }

  function setPricer(address newPricer) external onlyRole(MANAGER_ADMIN) {
    address old = address(pricer);
    pricer = IPricer(newPricer);
    emit NewPricerSet(old, newPricer);
  }

  function setFeeRecipient(address r) external onlyRole(MANAGER_ADMIN) {
    address old = feeRecipient;
    feeRecipient = r;
    emit FeeRecipientSet(old, r);
  }

  function setAssetSender(address s) external onlyRole(MANAGER_ADMIN) {
    address old = assetSender;
    assetSender = s;
    emit AssetSenderSet(old, s);
  }

  // ============================================================
  //                      暂停控制
  // ============================================================

  modifier ifNotPaused(bool feature) {
    if (feature) revert FeaturePaused();
    _;
  }

  function pauseSubscription() external onlyRole(PAUSER_ADMIN) {
    subscriptionPaused = true;
    emit SubscriptionPaused(msg.sender);
  }

  function pauseRedemption() external onlyRole(PAUSER_ADMIN) {
    redemptionPaused = true;
    emit RedemptionPaused(msg.sender);
  }

  /// @dev 注意：unpause 需要 MANAGER_ADMIN，不是 PAUSER_ADMIN
  function unpauseSubscription() external onlyRole(MANAGER_ADMIN) {
    subscriptionPaused = false;
    emit SubscriptionUnpaused(msg.sender);
  }

  function unpauseRedemption() external onlyRole(MANAGER_ADMIN) {
    redemptionPaused = false;
    emit RedemptionUnpaused(msg.sender);
  }

  // ============================================================
  //                     限制检查
  // ============================================================

  modifier checkRestrictions(address account) {
    _checkRestrictions(account);
    _;
  }

  /// @dev 纯虚函数 — 子类实现具体的限制逻辑
  function _checkRestrictions(address account) internal view virtual;

  // ============================================================
  //                     数学工具
  // ============================================================

  function _getMintFees(uint256 amount) internal view returns (uint256) {
    return (amount * mintFee) / BPS_DENOMINATOR;
  }

  function _getRedemptionFees(uint256 amount) internal view returns (uint256) {
    return (amount * redemptionFee) / BPS_DENOMINATOR;
  }

  /**
   * @notice 根据存款金额和价格计算应 mint 的 RWA 数量
   *
   * rwaOwed = (depositAmt * decimalsMultiplier) * 1e18 / price
   *
   * 为什么 * 1e18 再 / price？
   * → 因为 price 是 18 位精度的（1.05 USDC = 1.05e18）
   * → 先 * 1e18 提升精度，再 / price 得到 18 位精度的 RWA 数量
   */
  function _getMintAmountForPrice(
    uint256 depositAmt,
    uint256 price
  ) internal view returns (uint256) {
    uint256 amountE36 = _scaleUp(depositAmt) * 1e18;
    return amountE36 / price;
  }

  /**
   * @notice 根据赎回的 RWA 数量和价格计算应得的 collateral
   *
   * collateralOwed = (rwaAmount * price / 1e18) / decimalsMultiplier
   */
  function _getRedemptionAmountForRwa(
    uint256 rwaTokenAmountBurned,
    uint256 price
  ) internal view returns (uint256) {
    uint256 amountE36 = rwaTokenAmountBurned * price;
    return _scaleDown(amountE36 / 1e18);
  }

  function _scaleUp(uint256 amount) internal view returns (uint256) {
    return amount * decimalsMultiplier;
  }

  function _scaleDown(uint256 amount) internal view returns (uint256) {
    return amount / decimalsMultiplier;
  }
}
