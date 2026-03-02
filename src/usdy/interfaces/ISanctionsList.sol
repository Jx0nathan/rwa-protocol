// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISanctionsList
 * @notice Chainalysis 链上制裁名单接口
 *
 * 真实地址（以太坊主网）：0x40C57923924B5c5c5455c48D93317139ADDaC8fb
 * 这是 OFAC SDN 制裁名单的链上镜像，由 Chainalysis 维护。
 *
 * Ondo 在 USDY transfer 时实时调用此接口，被制裁地址无法收发 token。
 * 参考：Ondo SanctionsList.sol
 */
interface ISanctionsList {
  /**
   * @notice 检查某地址是否在 OFAC 制裁名单中
   * @param addr 待检查地址
   * @return true = 被制裁，应拒绝交易
   */
  function isSanctioned(address addr) external view returns (bool);
}
