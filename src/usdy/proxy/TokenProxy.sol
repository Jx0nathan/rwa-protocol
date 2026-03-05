// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title TokenProxy
 * @notice 透明可升级代理
 *
 * ===== 为什么需要 Proxy？ =====
 * Solidity 合约部署后代码不可变。但 USDY 这样的协议需要修复 bug、升级功能。
 * 解决方案：把「存储」和「逻辑」分离
 *   用户 → Proxy（存储在这里）→ delegatecall → Implementation（逻辑在这里）
 * 
 * 升级时只需把 Proxy 指向新的 Implementation，存储保持不变
 * 
 * ===== Transparent Proxy 透明代理模式 =====
 *
 * 问题：如果 Proxy 和 Implementation 都有一个 upgrade() 函数怎么办？
 * → 「函数选择器冲突」(Selector Clashing)
 *
 * 透明代理的解决方案 — 根据调用者身份路由：
 *
 *   if (msg.sender == admin) {
 *     // admin 只能调用管理函数（upgradeToAndCall）
 *     // admin 不能调用 Implementation 的函数
 *   } else {
 *     // 普通用户的所有调用都转发给 Implementation
 *     // 即使调用的函数签名与 Proxy 的管理函数相同
 *   }
 * 
 * ===== 继承链 =====
 * 
 *   Proxy (abstract)                     → fallback() + _delegate() 汇编
 *     └─ ERC1967Proxy                    → constructor 设置 implementation 槽
 *         └─ TransparentUpgradeableProxy → _fallback() 路由 + 自动部署 ProxyAdmin
 *             └─ TokenProxy              → 就是一个空壳，类型标记而已
 *
 * ===== 完整部署流程 =====
 *
 *   1. 部署 Implementation（如 USDY）
 *   2. 编码 initialize() 调用数据
 *   3. 部署 TokenProxy(implementation, initialOwner, initData)
 *      → 构造函数内部：
 *        a. ERC1967Proxy 将 implementation 地址写入 EIP-1967 槽
 *        b. delegatecall initData（即调用 implementation.initialize()）
 *        c. new ProxyAdmin(initialOwner) → admin 固化为 ProxyAdmin 地址
 *   4. 用户通过 Proxy 地址交互（所有调用 delegatecall 到 Implementation）
 *   5. 升级时：ProxyAdmin.upgradeAndCall(proxy, newImpl, data)
 * 
 */
contract TokenProxy is TransparentUpgradeableProxy {
    constructor(
        address _logic,
        address _initialOwner,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, _initialOwner, _data) {}
}
