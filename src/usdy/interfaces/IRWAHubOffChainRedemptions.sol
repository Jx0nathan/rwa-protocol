// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRWAHubOffChainRedemptions
 * @notice 链下赎回接口
 *
 * 普通赎回（on-chain）：用户烧 USDY → 链上领取 USDC
 * 链下赎回（off-chain）：用户烧 USDY → 链下电汇到银行账户
 *
 * offChainDestination 是银行电汇信息的 keccak256 哈希
 * 不把明文存链上是为了隐私保护
 */
interface IRWAHubOffChainRedemptions {
  function requestRedemptionServicedOffchain(
    uint256 amountRWATokenToRedeem,
    bytes32 offChainDestination
  ) external;

  function pauseOffChainRedemption() external;
  function unpauseOffChainRedemption() external;
  function setOffChainRedemptionMinimum(uint256 minimumAmount) external;

  event RedemptionRequestedServicedOffChain(
    address indexed user,
    bytes32 indexed redemptionId,
    uint256 rwaTokenAmountIn,
    bytes32 offChainDestination
  );

  event OffChainRedemptionPaused(address caller);
  event OffChainRedemptionUnpaused(address caller);
  event OffChainRedemptionMinimumSet(uint256 oldMinimum, uint256 newMinimum);
}