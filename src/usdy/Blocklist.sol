// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IBlocklist.sol";

/**
 * @title Blocklist
 * @notice Ondo 内部黑名单合约
 *
 * ═══════════════════════════════════════════════════
 * 设计要点（来自 Ondo 真实实现）
 * ═══════════════════════════════════════════════════
 *
 * 1. 职责分离：封禁权限和解封权限是不同的 role
 *    - BLOCKLIST_ROLE  → 只能封禁（addToBlocklist）
 *    - ADMIN_ROLE      → 可以解封（removeFromBlocklist）
 *    这样操作员无法自行解封，降低内部作恶风险。
 *
 * 2. 这个合约只做黑名单，不做 KYC。
 *    黑名单 = 主动封禁违规用户（AML 可疑账户、争议地址）
 *    KYC    = 被动允许已认证用户（见 KYCRegistry.sol）
 *
 * 3. USDY.sol 在 _beforeTokenTransfer 中调用 isBlocked()，
 *    被封禁地址无法发送或接收 USDY。
 */
contract Blocklist is IBlocklist, AccessControl {
  bytes32 public constant BLOCKLIST_ROLE = keccak256("BLOCKLIST_ROLE");

  /// @notice 地址 → 是否被封禁
  mapping(address => bool) private _blocked;

  // ─────────────────────────────────────────────
  // 事件
  // ─────────────────────────────────────────────

  event AddedToBlocklist(address indexed account, address indexed operator);
  event RemovedFromBlocklist(address indexed account, address indexed operator);

  // ─────────────────────────────────────────────
  // 构造函数
  // ─────────────────────────────────────────────

  constructor(address admin) {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(BLOCKLIST_ROLE, admin);
  }

  // ─────────────────────────────────────────────
  // 查询
  // ─────────────────────────────────────────────

  /// @inheritdoc IBlocklist
  function isBlocked(address account) external view override returns (bool) {
    return _blocked[account];
  }

  // ─────────────────────────────────────────────
  // 管理操作
  // ─────────────────────────────────────────────

  /**
   * @notice 封禁地址（需要 BLOCKLIST_ROLE）
   * @dev 封禁后该地址无法收发 USDY
   */
  function addToBlocklist(address account) external onlyRole(BLOCKLIST_ROLE) {
    require(account != address(0), "Blocklist: zero address");
    _blocked[account] = true;
    emit AddedToBlocklist(account, msg.sender);
  }

  /**
   * @notice 批量封禁（节省 gas）
   */
  function addToBlocklistBatch(
    address[] calldata accounts
  ) external onlyRole(BLOCKLIST_ROLE) {
    for (uint256 i = 0; i < accounts.length; i++) {
      require(accounts[i] != address(0), "Blocklist: zero address");
      _blocked[accounts[i]] = true;
      emit AddedToBlocklist(accounts[i], msg.sender);
    }
  }

  /**
   * @notice 解封地址（需要 DEFAULT_ADMIN_ROLE）
   * @dev 注意：解封权限比封禁权限更高，防止操作员自行解封
   */
  function removeFromBlocklist(
    address account
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _blocked[account] = false;
    emit RemovedFromBlocklist(account, msg.sender);
  }
}
