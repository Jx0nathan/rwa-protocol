// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IKYCRegistry
 * @notice KYC 白名单注册表接口
 *
 * Ondo 的设计：KYC 与 token 合约解耦，独立合约管理白名单。
 * 好处：多个 token（OUSG/USDY）共用同一份 KYC 状态，不重复管理。
 */
interface IKYCRegistry {
  /**
   * @notice 检查地址是否通过 KYC
   * @param account 待检查地址
   * @param kycRequirementGroup KYC 分组 ID（不同产品可要求不同 KYC 级别）
   * @return true = 已通过 KYC
   */
  function isKYCVerified(
    address account,
    uint256 kycRequirementGroup
  ) external view returns (bool);
}
