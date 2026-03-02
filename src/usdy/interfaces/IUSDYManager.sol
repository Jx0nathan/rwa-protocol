// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUSDYManager
 * @notice USDY 认购/赎回管理合约接口
 */
interface IUSDYManager {
  // ─────────────────────────────────────────────
  // 事件
  // ─────────────────────────────────────────────

  /// @notice 用户提交认购请求时触发
  event DepositRequested(
    address indexed depositor,
    uint256 indexed depositId,
    uint256 usdcAmount,
    uint256 timestamp
  );

  /// @notice 运营方为 depositId 批量绑定 priceId
  event PriceIdSetForDeposits(uint256 indexed priceId, uint256[] depositIds);

  /// @notice 用户领取 USDY 铸造
  event DepositClaimed(
    address indexed depositor,
    uint256 indexed depositId,
    uint256 usdyMinted,
    uint256 price
  );

  /// @notice 用户提交赎回请求
  event RedemptionRequested(
    address indexed redeemer,
    uint256 indexed redemptionId,
    uint256 usdyBurned,
    uint256 timestamp
  );

  /// @notice 运营方完成赎回结算
  event RedemptionCompleted(
    address indexed redeemer,
    uint256 indexed redemptionId,
    uint256 usdcReturned
  );

  // ─────────────────────────────────────────────
  // 用户操作
  // ─────────────────────────────────────────────

  /**
   * @notice 认购：用户存入 USDC，等待 T+1 后领取 USDY
   * @dev USDC 不停留在合约中，直接转入 assetRecipient（托管方）
   * @param usdcAmount 存入的 USDC 数量（6 位小数）
   * @return depositId 本次认购 ID，用于后续 claimMint
   */
  function requestDeposit(uint256 usdcAmount) external returns (uint256 depositId);

  /**
   * @notice 领取：T+1 后，用 depositId 铸造对应 USDY
   * @dev 需要 depositId 已绑定 priceId，且 claimableTimestamp 已过
   * @param depositId requestDeposit 返回的 ID
   */
  function claimMint(uint256 depositId) external;

  /**
   * @notice 赎回：销毁 USDY，等待运营方结算 USDC
   * @param usdyAmount 赎回的 USDY 数量（18 位小数）
   * @return redemptionId 本次赎回 ID
   */
  function requestRedemption(uint256 usdyAmount) external returns (uint256 redemptionId);

  // ─────────────────────────────────────────────
  // 运营方操作
  // ─────────────────────────────────────────────

  /**
   * @notice 为一批 depositId 绑定同一个 priceId（每日批量处理）
   * @param depositIds 当日所有认购 ID
   * @param priceId    对应日期的价格 ID
   */
  function setPriceIdForDeposits(
    uint256[] calldata depositIds,
    uint256 priceId
  ) external;

  /**
   * @notice 设置某 priceId 的可领取时间（T+1）
   * @param priceId   价格 ID
   * @param claimableTimestamp 用户可以 claimMint 的最早时间
   */
  function setClaimableTimestamp(
    uint256 priceId,
    uint256 claimableTimestamp
  ) external;

  /**
   * @notice 完成赎回结算，发送 USDC 给用户
   * @param redemptionId 赎回 ID
   * @param usdcAmount   实际结算 USDC 数量
   */
  function completeRedemption(
    uint256 redemptionId,
    uint256 usdcAmount
  ) external;
}
