// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUSDYManager
 * @notice USDYManager 特有的接口 — 时间戳门控
 */
interface IUSDYManager {
  function setClaimableTimestamp(
    uint256 claimDate,
    bytes32[] calldata depositIds
  ) external;

  event ClaimableTimestampSet(
    uint256 indexed claimTimestamp,
    bytes32 indexed depositId
  );

  error MintNotYetClaimable();
  error ClaimableTimestampInPast();
  error ClaimableTimestampNotSet();
}