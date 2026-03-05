// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/usdy/interfaces/IAllowlist.sol";

/// @title IAllowlistClient
/// @notice 白名单客户端接口 — 和 IBlocklistClient 对称的结构
interface IAllowlistClient {
  
  function allowlist() external view returns (IAllowlist);
  function setAllowlist(address allowlist) external; 

  event AllowlistSet(address oldAllowlist, address newAllowlist);
  error AllowlistZeroAddress();

}    