// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "src/usdy/interfaces/IBlocklist.sol";

/**
 * @title Blocklist
 * @notice 黑名单合约 — 管理被禁止的地址
 * 
 * ===== 设计决策 =====
 * 
 * 1. 为什么继承 Ownable2Step 而不是 Ownable？
 *    - Ownable: transferOwnership(newOwner) → 一步完成，如果填错地址，永久失去控制权
 *    - Ownable2Step: transferOwnership(newOwner) + acceptOwnership() → 两步完成
 *      新 owner 必须主动接受，防止误操作导致合约无人管理
 *    - 黑名单是安全关键合约，ownership 必须万无一失
 * 
 *  2. 为什么不可升级（没有用 Proxy 模式）？
 *    - 黑名单逻辑极其简单（add/remove/check），不太可能需要修改
 *    - 不可升级 = 更少的攻击面（没有人能通过升级绕过黑名单）
 *    - 如果真的需要换，可以部署新合约，然后让 USDY 的 LIST_CONFIGURER_ROLE 指向新地址
 * 
 *  3. 为什么 mapping 是 private 而非 public？
 *    - private 不会自动生成 getter 函数
 *    - 我们用自定义的 isBlocked() 替代，命名更清晰
 *    - 对外只暴露 IBlocklist 接口定义的函数
 *
 *  4. 为什么用批量操作（address[]）而非单个地址？
 *    - 链上每笔交易都有固定的 base gas（21000）
 *    - 拉黑 100 个地址：批量 = 1 笔交易，逐个 = 100 笔交易
 *    - 批量操作可以节省大量 gas
 */
contract Blocklist is Ownable2Step, IBlocklist {

    /// @dev 使用 private 而非 public，通过 isBlocked() 暴露
    mapping(address => bool) private blockedAddresses;

    // ============ 构造函数 ============
    /// @dev OZ v5 Ownable 需要显式传入 owner 地址
    constructor() Ownable(msg.sender) {}

    /// @notice 返回合约名称，用于标识
    /// @dev pure 函数：不读取也不修改任何状态变量，比 view 更省 gas
    function name() external pure returns(string memory) {
       return "Blocklist Oracle";
    }

    /// @notice 查询地址是否被拉黑
    /// @param addr 要查询的地址
    /// @return 如果地址被拉黑返回 true
    function isBlocked(address addr) external view returns(bool){
       return blockedAddresses[addr];
    }

    // ============ 管理函数 ============

    /// @notice 批量添加地址到黑名单
    /// @dev onlyOwner 修饰符确保只有 owner 可以调用
    /// @param accounts 要拉黑的地址数组
    function addToBlocklist(address[] calldata accounts) external onlyOwner {
        // 用 ++i 而非 i++：前置自增比后置自增省约 5 gas（不需要缓存旧值）
        for(uint256 i; i< accounts.length; ++i){
           blockedAddresses[accounts[i]] = true;
        }
        // 一次性 emit，而非循环内 emit → 省 gas
        emit BlockedAddressesAdded(accounts);
    }

    /// @notice 批量从黑名单移除地址
    /// @param accounts 要解除拉黑的地址数组
    /// 为什么不是直接删除 「delete deposits[depositId]」，而是放置为false。直接删除不是能够更加节省gas吗? 
    /// 因为对于简单的value值来说，删除和赋予false在 opcode 层面都是一样的
    function removeFromBlockList(address[] calldata accounts) external onlyOwner {
        for(uint256 i; i< accounts.length; ++i){
            blockedAddresses[accounts[i]] = false;
        }
        emit BlockedAddressesRemoved(accounts);    
    }
}