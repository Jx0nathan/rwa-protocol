// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMulticall
 * @notice 批量调用接口
 *
 * 为什么需要 multiexcall？
 * → 部署后需要做很多初始化操作（设置角色、添加条款等）
 * → 如果一个个调用，guardian（多签钱包）需要签名很多次
 * → multiexcall 把多个调用打包成一个交易，只需签名一次
 *
 * 安全考虑：
 * → msg.sender 是 Factory 合约地址（不是 guardian）
 * → 所以 target 合约需要信任 Factory 地址，或者 Factory 已拥有相应权限
 */
interface IMulticall {
  struct ExCallData {
    address target;  // 目标合约
    bytes data;      // 编码的函数调用
    uint256 value;   // 附带的 ETH
  }

  function multiexcall(
    ExCallData[] calldata exdata
  ) external payable returns (bytes[] memory results);
}