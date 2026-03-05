// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBlocklist
 * @notice 黑名单接口 — 定义了黑名单合约必须实现的功能
 *
 * 设计思路：
 * - 接口只声明 "做什么"，不关心 "怎么做"
 * - 其他合约只依赖接口，不依赖具体实现 → 解耦
 * - 事件也定义在接口中 → 确保所有实现都 emit 相同的事件签名
 */
interface IBlocklist {

  /// @notice 批量添加地址到黑名单
  /// @dev 用 address[] calldata 而非 memory → 节省 gas（calldata 不可修改，比 memory 便宜）
  function addToBlocklist(address[] calldata accounts) external;

  /// @notice 批量从黑名单移除地址
  function removeFromBlockList(address[] calldata accounts) external;

  /// @notice 查询某地址是否被拉黑
  /// @dev view 函数，不修改状态，不消耗 gas（在链下调用时）
  function isBlocked(address account) external view returns (bool);

  /// @notice 地址被添加到黑名单时触发
  event BlockedAddressesAdded(address[] accounts);

  /// @notice 地址从黑名单移除时触发
  event BlockedAddressesRemoved(address[] accounts);

}
