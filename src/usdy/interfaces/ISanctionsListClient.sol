// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ISanctionsList.sol";

/**
 * @title ISanctionsListClient
 * @notice 制裁名单客户端接口 — 结构和 IBlocklistClient 完全对称
 *
 * IBlocklistClient 对比：
 *   blocklist()     → sanctionsList()
 *   setBlocklist()  → setSanctionsList()
 *   BlockedAccount  → SanctionedAccount
 *
 * 同样的设计：
 * - 接口只声明 getter + setter + error + event
 * - 具体权限控制留给实现者（USDYManager 用 MANAGER_ADMIN，USDY 用 LIST_CONFIGURER_ROLE）
 */
interface ISanctionsListClient {
  /// @notice 获取当前引用的制裁名单合约
  function sanctionsList() external view returns (ISanctionsList);

  /// @notice 更新制裁名单合约地址
  function setSanctionsList(address sanctionsList) external;

  /// @notice 尝试设置零地址时抛出
  error SanctionsListZeroAddress();

  /// @notice 被制裁账户尝试操作时抛出
  error SanctionedAccount();

  /// @notice 制裁名单地址被更新时触发
  event SanctionsListSet(address oldSanctionsList, address newSanctionsList);
}