// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISanctionsList
 * @notice Chainalysis 制裁名单预言机的接口
 *
 * 这个接口对应的合约不是我们写的，而是 Chainalysis 公司部署在以太坊主网上的：
 * https://etherscan.io/address/0x40C57923924B5c5c5455c48D93317139ADDaC8fb
 *
 * 和 IBlocklist 的区别：
 * - IBlocklist：有 add/remove/isBlocked → 我们自己管理
 * - ISanctionsList：只有 isSanctioned → 我们只能查询，不能修改
 *
 * Chainalysis 维护一份全球制裁名单（OFAC SDN List 等），
 * 任何被美国财政部制裁的地址都会出现在这里。
 * 我们的合约只需要调用 isSanctioned() 检查即可。
 */
interface ISanctionsList {
   function isSanctioned(address addr) external view returns(bool);
}    