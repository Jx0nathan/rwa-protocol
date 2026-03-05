// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/usdy/interfaces/IBlocklist.sol";

/**
 * @title IBlocklistClient
 * @notice 黑名单客户端接口 — 任何需要查询黑名单的合约都应实现此接口
 *
 * 设计思路：
 * - IBlocklist 是 "黑名单服务" 的接口
 * - IBlocklistClient 是 "黑名单消费者" 的接口
 * - 分开定义的好处：USDY Token 只需要实现 Client 接口，
 *   不需要知道 Blocklist 内部怎么存储数据
 *
 * 为什么用 custom error 而不是 require(xxx, "string")？
 * - custom error 比 revert string 省 gas（不需要存储字符串）
 * - 更结构化，前端/测试可以精确捕获错误类型
 */
interface IBlocklistClient {
  /// @notice 获取当前引用的黑名单合约
  function blocklist() external view returns (IBlocklist);

  /// @notice 更新黑名单合约地址（管理员功能）
  function setBlocklist(address registry) external;

  /// @notice 尝试设置零地址为黑名单时抛出
  error BlocklistZeroAddress();

  /// @notice 被拉黑的账户尝试操作时抛出
  error BlockedAccount();

  /// @notice 黑名单地址被更新时触发
  /// @param oldBlocklist 旧的黑名单合约地址
  /// @param newBlocklist 新的黑名单合约地址
  event BlocklistSet(address oldBlocklist, address newBlocklist);
}     
