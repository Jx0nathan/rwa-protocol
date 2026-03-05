// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "src/usdy/rwahub/RWAHub.sol";
import "src/usdy/interfaces/IRWAHubOffChainRedemptions.sol";

/**
 * @title RWAHubOffChainRedemptions
 * @notice 扩展 RWAHub，增加链下赎回功能
 *
 * ===== 为什么需要链下赎回？ =====
 *
 * 普通赎回（on-chain）：
 *   用户烧 USDY → 等待定价 → 领取 USDC（链上）
 *
 * 链下赎回（off-chain）：
 *   用户烧 USDY → Ondo 通过银行电汇发送 USD → 资金到银行账户
 *
 * 大额赎回（如 $1M+）通常走链下电汇，因为：
 *   1. 链上 USDC 流动性可能不足
 *   2. 机构投资者更习惯电汇
 *   3. 合规要求可能需要银行间结算
 *
 * ===== offChainDestination 是什么？ =====
 *
 * 用户提交 keccak256(电汇信息) 的哈希
 * 明文电汇信息（银行名、账号等）通过链下渠道发送
 * 链上只存哈希 → 隐私保护
 *
 * ===== 与 on-chain 赎回共享 redemptionRequestCounter =====
 *
 * 链下赎回也使用 redemptionRequestCounter++
 * → 所有赎回（链上+链下）的 ID 是全局唯一的
 * → 但链下赎回没有 Redeemer 记录（因为不需要链上 claim）
 */
abstract contract RWAHubOffChainRedemptions is RWAHub, IRWAHubOffChainRedemptions {
  /// @dev 链下赎回暂停标志
  bool public offChainRedemptionPaused;

  /// @dev 链下赎回最低金额
  uint256 public minimumOffChainRedemptionAmount;

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
  )
    RWAHub(
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
  {
    minimumOffChainRedemptionAmount = _minimumRedemptionAmount;
  }

  /**
   * @notice 请求链下赎回
   *
   * 与 requestRedemption 的区别：
   *   1. 不记录 Redeemer（因为不需要链上 claim）
   *   2. 记录 offChainDestination（电汇目标哈希）
   *   3. 使用独立的暂停标志和最低金额
   */
  function requestRedemptionServicedOffchain(
    uint256 amountRWATokenToRedeem,
    bytes32 offChainDestination
  ) external nonReentrant ifNotPaused(offChainRedemptionPaused) checkRestrictions(msg.sender) {
    if (amountRWATokenToRedeem < minimumOffChainRedemptionAmount) {
      revert RedemptionTooSmall();
    }

    bytes32 redemptionId = bytes32(redemptionRequestCounter++);

    rwa.burnFrom(msg.sender, amountRWATokenToRedeem);

    emit RedemptionRequestedServicedOffChain(
      msg.sender,
      redemptionId,
      amountRWATokenToRedeem,
      offChainDestination
    );
  }

  // ============ 暂停/恢复 ============

  function pauseOffChainRedemption() external onlyRole(PAUSER_ADMIN) {
    offChainRedemptionPaused = true;
    emit OffChainRedemptionPaused(msg.sender);
  }

  function unpauseOffChainRedemption() external onlyRole(MANAGER_ADMIN) {
    offChainRedemptionPaused = false;
    emit OffChainRedemptionUnpaused(msg.sender);
  }

  function setOffChainRedemptionMinimum(
    uint256 _minimumOffChainRedemptionAmount
  ) external onlyRole(MANAGER_ADMIN) {
    uint256 old = minimumOffChainRedemptionAmount;
    minimumOffChainRedemptionAmount = _minimumOffChainRedemptionAmount;
    emit OffChainRedemptionMinimumSet(old, _minimumOffChainRedemptionAmount);
  }
}
