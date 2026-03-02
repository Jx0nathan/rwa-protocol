// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IKYCRegistry.sol";

/**
 * @title KYCRegistry
 * @notice KYC 白名单注册表
 *
 * ═══════════════════════════════════════════════════
 * 设计要点（来自 Ondo 真实实现）
 * ═══════════════════════════════════════════════════
 *
 * 1. kycRequirementGroup（KYC 分组）
 *    不同产品可以要求不同 KYC 等级，例如：
 *    - Group 1 = USDY（非美国人，基础 KYC）
 *    - Group 2 = OUSG（美国机构，QP 认证）
 *    同一个 registry 可以服务多个产品。
 *
 * 2. 角色分离（Ondo 用了 5 个角色，这里简化为 3 个）：
 *    - KYC_CONFIGURER_ROLE → 添加/移除 KYC 验证者地址
 *    - KYC_VERIFIED_ROLE   → 向具体 group 添加/移除白名单用户
 *    - DEFAULT_ADMIN_ROLE  → 管理以上角色
 *
 * 3. 为什么和 token 合约解耦？
 *    如果 KYC 状态写在 USDY.sol 里，未来新产品（OUSG/GM）
 *    就要重新管理一份白名单。独立合约 → 共享 KYC 状态。
 */
contract KYCRegistry is IKYCRegistry, AccessControl {
  bytes32 public constant KYC_CONFIGURER_ROLE = keccak256("KYC_CONFIGURER_ROLE");

  /// @notice kycGroup → address → 是否通过 KYC
  /// @dev group 0 默认不使用，从 1 开始
  mapping(uint256 => mapping(address => bool)) private _kycVerified;

  // ─────────────────────────────────────────────
  // 事件
  // ─────────────────────────────────────────────

  event KYCAddressAdded(
    uint256 indexed kycRequirementGroup,
    address indexed account,
    address indexed operator
  );

  event KYCAddressRemoved(
    uint256 indexed kycRequirementGroup,
    address indexed account,
    address indexed operator
  );

  // ─────────────────────────────────────────────
  // 构造函数
  // ─────────────────────────────────────────────

  constructor(address admin) {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(KYC_CONFIGURER_ROLE, admin);
  }

  // ─────────────────────────────────────────────
  // 查询
  // ─────────────────────────────────────────────

  /// @inheritdoc IKYCRegistry
  function isKYCVerified(
    address account,
    uint256 kycRequirementGroup
  ) external view override returns (bool) {
    return _kycVerified[kycRequirementGroup][account];
  }

  // ─────────────────────────────────────────────
  // 管理操作
  // ─────────────────────────────────────────────

  /**
   * @notice 将地址加入某 KYC 分组白名单
   * @param kycRequirementGroup KYC 分组 ID（产品级别）
   * @param accounts            已通过 KYC 的地址列表
   */
  function addKYCAddresses(
    uint256 kycRequirementGroup,
    address[] calldata accounts
  ) external onlyRole(KYC_CONFIGURER_ROLE) {
    for (uint256 i = 0; i < accounts.length; i++) {
      require(accounts[i] != address(0), "KYCRegistry: zero address");
      _kycVerified[kycRequirementGroup][accounts[i]] = true;
      emit KYCAddressAdded(kycRequirementGroup, accounts[i], msg.sender);
    }
  }

  /**
   * @notice 将地址从某 KYC 分组白名单移除
   */
  function removeKYCAddresses(
    uint256 kycRequirementGroup,
    address[] calldata accounts
  ) external onlyRole(KYC_CONFIGURER_ROLE) {
    for (uint256 i = 0; i < accounts.length; i++) {
      _kycVerified[kycRequirementGroup][accounts[i]] = false;
      emit KYCAddressRemoved(kycRequirementGroup, accounts[i], msg.sender);
    }
  }
}
