// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBlocklist
 * @notice 内部黑名单接口
 *
 * 与 ISanctionsList 的区别：
 * - ISanctionsList = Chainalysis 维护的 OFAC 外部制裁名单（被动）
 * - IBlocklist     = Ondo 自己维护的内部黑名单（主动），用于封禁违规用户
 *
 * 两者在 transfer 时都需要检查（三层合规：KYC + Blocklist + Sanctions）
 */
interface IBlocklist {
  /**
   * @notice 检查地址是否在 Ondo 内部黑名单中
   * @param account 待检查地址
   * @return true = 已被封禁
   */
  function isBlocked(address account) external view returns (bool);
}
