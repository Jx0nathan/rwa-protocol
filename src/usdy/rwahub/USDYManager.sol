// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "src/usdy/rwaHub/RWAHubOffChainRedemptions.sol";
import "src/usdy/blocklist/BlocklistClient.sol";
import "src/usdy/sanctions/SanctionsListClient.sol";
import "src/usdy/interfaces/IUSDYManager.sol";

/**
 * @title USDYManager
 * @notice RWAHub 的具体实现 — Phase 8 学习合约
 *
 * ===== 整体定位 =====
 *
 * USDYManager 是继承链的「最终拼装」：
 *
 *   RWAHub (abstract)                    → 申购/赎回核心逻辑
 *     └─ RWAHubOffChainRedemptions       → 链下赎回扩展
 *         └─ USDYManager                 → USDY 特有的合规 + 时间门控
 *              ├─ BlocklistClient         → 黑名单检查
 *              └─ SanctionsListClient     → 制裁名单检查
 *
 * USDYManager 做了三件事：
 *   1. 实现 _checkRestrictions() → blocklist + sanctions 检查
 *   2. Override _claimMint() → 加入时间戳门控
 *   3. 暴露 setBlocklist/setSanctionsList 的 external 入口
 *
 * ===== 时间戳门控（Timestamp Gating） =====
 *
 * 为什么需要？
 * → 美国证券法要求 USDY 在发行后有一个「锁定期」
 * → 用户不能在锁定期结束前领取 USDY
 * → 典型的锁定期是 40-50 天（Reg D/S 豁免要求）
 *
 * 流程：
 *   1. 用户 requestSubscription → depositId 创建
 *   2. 管理员 setPriceIdForDeposits → 设置价格
 *   3. 管理员 setClaimableTimestamp → 设置可领取时间
 *   4. 用户 claimMint → 检查 block.timestamp ≥ claimableTimestamp
 *
 * 注意：priceId 和 claimableTimestamp 是独立设置的
 *       两个都满足了才能 claim
 *
 * ===== _checkRestrictions 的应用场景 =====
 *
 * RWAHub 中有两个地方调用 _checkRestrictions：
 *
 *   1. checkRestrictions modifier（用于 requestSubscription、addProof、overwrite）
 *      → 申购入口检查：被拉黑/制裁的用户不能开始申购
 *
 *   2. claimRedemption 内部直接调用
 *      → 赎回出口检查：领取 USDC 时再次检查
 *      → 防止「请求赎回后才被拉黑」的情况
 *
 * ===== 继承中的 super 调用 =====
 *
 * _claimMint 的调用链：
 *   USDYManager._claimMint()
 *     → 检查 claimableTimestamp
 *     → super._claimMint()  → RWAHub._claimMint()
 *       → 检查 priceId、计算金额、mint
 *     → delete claimableTimestamp
 *
 * 这展示了 virtual/override 的实际用途：
 * 子类在父类逻辑的「前后」插入自定义检查
 */
contract USDYManager is
  RWAHubOffChainRedemptions,
  BlocklistClient,
  SanctionsListClient,
  IUSDYManager
{
  // ============ 新角色 ============

  bytes32 public constant TIMESTAMP_SETTER_ROLE = keccak256("TIMESTAMP_SETTER_ROLE");

  // ============ 新状态 ============

  /// @dev depositId → 可领取时间戳
  ///      0 表示未设置（和 priceId 的设计类似）
  mapping(bytes32 => uint256) public depositIdToClaimableTimestamp;

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
    uint256 _minimumRedemptionAmount,
    address _blocklist,
    address _sanctionsList
  )
    RWAHubOffChainRedemptions(
      _collateral,
      _rwa,
      managerAdmin,
      pauser,
      _assetRecipient,
      _assetSender,
      _feeRecipient,
      _minimumDepositAmount,
      _minimumRedemptionAmount
    )
    BlocklistClient(_blocklist)
    SanctionsListClient(_sanctionsList)
  {}

  // ============ 实现 _checkRestrictions ============

  /**
   * @notice 实现 RWAHub 的纯虚函数 — blocklist + sanctions 双重检查
   */
  function _checkRestrictions(address account) internal view override {
    if (_isBlocked(account)) {
      revert BlockedAccount();
    }
    if (_isSanctioned(account)) {
      revert SanctionedAccount();
    }
  }

  // BlockedAccount / SanctionedAccount 错误已在
  // IBlocklistClient / ISanctionsListClient 接口中定义，无需重复声明

  // ============ Override _claimMint ============

  /**
   * @notice 在父类 _claimMint 基础上增加时间戳门控
   *
   * 检查顺序：
   *   1. claimableTimestamp 是否已设置（!= 0）
   *   2. 当前时间是否已过 claimableTimestamp
   *   3. 调用 super._claimMint() 执行标准 mint 逻辑
   *   4. 清理 claimableTimestamp（释放 gas）
   */
  function _claimMint(bytes32 depositId) internal virtual override {
    if (depositIdToClaimableTimestamp[depositId] == 0) {
      revert ClaimableTimestampNotSet();
    }
    if (depositIdToClaimableTimestamp[depositId] > block.timestamp) {
      revert MintNotYetClaimable();
    }

    super._claimMint(depositId);
    delete depositIdToClaimableTimestamp[depositId];
  }

  // ============ 时间戳设置 ============

  /**
   * @notice 批量设置 depositId 的可领取时间
   *
   * @param claimTimestamp 统一的可领取时间（通常是 T+40 天）
   * @param depositIds    要设置的 depositId 列表
   *
   * 为什么 timestamp 必须在未来？
   * → 设置过去的时间没有意义（用户立刻就能 claim）
   * → 防止管理员误操作
   */
  function setClaimableTimestamp(
    uint256 claimTimestamp,
    bytes32[] calldata depositIds
  ) external onlyRole(TIMESTAMP_SETTER_ROLE) {
    if (claimTimestamp < block.timestamp) {
      revert ClaimableTimestampInPast();
    }

    for (uint256 i; i < depositIds.length; ++i) {
      depositIdToClaimableTimestamp[depositIds[i]] = claimTimestamp;
      emit ClaimableTimestampSet(claimTimestamp, depositIds[i]);
    }
  }

  // ============ 列表管理 ============

  function setBlocklist(
    address _blocklist
  ) external override onlyRole(MANAGER_ADMIN) {
    _setBlocklist(_blocklist);
  }

  function setSanctionsList(
    address _sanctionsList
  ) external override onlyRole(MANAGER_ADMIN) {
    _setSanctionsList(_sanctionsList);
  }
}
