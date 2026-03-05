// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAllowlist
 * @notice 白名单接口 — Terms 模型
 * 
 * 和 IBlocklist 的本质区别：
 *   - IBlocklist：简单的 bool 黑名单（blocked or not）
 *   - IAllowlist：基于 "条款版本" 的白名单
 *   - 用户必须签署某个版本的 Terms of Service 才能被允许
 * 
 * 为什么要设计成 Terms 模型？
 *   - 法律合规：条款会更新（v1 → v2 → v3...），需要追踪用户签了哪个版本
 *   - 平滑迁移：可以同时承认多个版本有效，不需要所有用户同时迁移
 *   - 审计追踪：精确记录每个用户接受的条款版本
 */
interface IAllowlist {
  
  /// @notice 添加新条款版本（自动设为当前版本）
  function addTerm(string calldata term) external;

  /// @notice 设置当前条款索引
  function setCurrentTermIndex(uint256 _currentTermIndex) external;

  /// @notice 设置哪些条款版本是有效的（核心治理函数）
  function setValidTermIndexes(uint256[] calldata indexex) external;

  // ============ 查询函数 ============

  /// @notice 检查地址是否被允许
  function isAllowed(address account) external view returns (bool);

  /// @notice 获取当前条款文本
  function getCurrentTerm() external view returns (string memory);

  /// @notice 获取所有有效的条款索引
  function getValidTermIndexes() external view returns (uint256[] memory);

  // ============ 用户上白名单（三种路径） ============
  
  /// @notice 路径 1：用户自助注册
  function addSelfToAllowlist(uint256 termIndex) external;

  /// @notice 路径 2：通过签名注册（任何人可以提交用户的签名）
  function addAccountToAllowlist(uint256 termIndex, address account, uint8 v, bytes32 r, bytes32 s) external;

  /// @notice 路径 3：管理员手动设置
  function setAccountStatus(address account, uint256 termIndex, bool status) external;
  
  // ============ 事件 ============

  event TermAdded(bytes32 hashedMessage, uint256 termIndex);
  event CurrentTermIndexSet(uint256 oldIndex, uint256 newIndex);
  event ValidTermIndexesSet(uint256[] oldIndexes, uint256[] newIndexes);
  event AccountStatusSetByAdmin(
    address indexed account,
    uint256 indexed termIndex,
    bool status
  );
  event AccountAddedSelf(address indexed account, uint256 indexed termIndex);
  event AccountAddedFromSignature(
    address indexed account,
    uint256 indexed termIndex,
    uint8 v,
    bytes32 r,
    bytes32 s
  );
  event AccountStatusSet(
    address indexed account,
    uint256 indexed termIndex,
    bool status
  );

  // ============ 错误 ============

  error InvalidTermIndex();
  error InvalidVSignature();
  error AlreadyVerified();
  error InvalidSigner();

}
