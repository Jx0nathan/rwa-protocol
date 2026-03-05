// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "src/usdy/interfaces/IBlocklistClient.sol";

/**
 * @title BlocklistClient
 * @notice 黑名单客户端 Mixin — 让任何合约都能 "混入" 黑名单检查能力
 * 
 * ===== 什么是 Mixin 模式？ =====
 * 
 * Mixin 是一个 abstract 合约，它：
 *   - 不能单独部署（因为是 abstract 的）
 *   - 提供一组可复用的功能（这里是黑名单查询）
 *   - 被其他合约通过继承来 "混入" 这些功能
 * 
 * 例如：USDYManager 继承 BlocklistClient 后就自动获得了 _isBlocked() 能力
 * 
 * ===== 为什么不直接在 USDY 合约里写？ =====
 *  1. 复用：多个合约都需要查黑名单（USDY Token、USDYManager），写一次到处用
 *  2. 单一职责：每个 Mixin 只管一件事
 *  3. 可组合：USDY Token = ERC20 + BlocklistClient + AllowlistClient + SanctionsClient 就像乐高积木一样组合
 * 
 * ===== internal vs external vs public =====
 *
 * - _setBlocklist(): internal → 只有子合约能调用，外部不可见
 *   子合约会包一层 external 函数 + 权限检查后再调用它
 *
 * - _isBlocked(): internal view → 子合约的 _beforeTokenTransfer 里会调用
 *   不需要外部直接调用（外部可以直接查 Blocklist 合约）
 *
 * - blocklist: public → 自动生成 getter，让任何人都能查到当前引用的黑名单地址
 * 
 * abstract 合约允许不实现接口的全部函数。 它把 setBlocklist() 留给了最终的子合约去实现
 * 
 */
abstract contract BlocklistClient is IBlocklistClient {

  /// @notice 当前引用的黑名单合约
  /// @dev override 是因为 IBlocklistClient 接口声明了这个 getter (这样写的作用是为了节省审计成本)
  IBlocklist public override blocklist;

  // ============ 构造函数 ============

  /// @notice 初始化时必须传入黑名单地址
  /// @dev 这是非升级版本，用 constructor。升级版本会改用 initializer
  constructor(address _blocklist) {
    _setBlocklist(_blocklist);
  }

   /**
   * @notice 设置黑名单合约地址
   * @dev 为什么是 internal 而非 external？
   *      - constructor 需要调用它（constructor 不能调 external）
   *      - 子合约需要包一层权限检查后调用它
   *      - 不应该让任何人直接调用（没有权限控制）
   *
   *      为什么要记录 oldBlocklist？
   *      - 事件中记录新旧值，方便链下追踪变更历史
   *      - 调试和审计时可以回溯
   */
  function _setBlocklist(address _blocklist) internal {
    // 不允许零地址
    if (_blocklist == address(0)) {
      revert BlocklistZeroAddress();
    }
    // 记录旧的地址，为了发送事件
    address oldBlocklist = address(blocklist);

    // 赋值：把address转为 IBlocklist 接口类型存储（类型转换：这个地址上的合约实现了 IBlocklist 接口）
    blocklist = IBlocklist(_blocklist);

    // 发射事件：记录新旧值，方便链下追踪
    emit BlocklistSet(oldBlocklist, _blocklist);
  }
  
  /**
   * @notice 检查地址是否被拉黑
   * @dev 为什么要封装而不直接调用 blocklist.isBlocked()？
   *      - 封装提供统一入口，未来如果查询逻辑变了只改这一处
   *      - 子合约用 _isBlocked(account) 比 blocklist.isBlocked(account) 更简洁
   *      - 如果 blocklist 地址被更新，所有调用自动指向新合约（因为读的是 storage 变量）
   */
  function _isBlocked(address account) internal view returns (bool) {
    return blocklist.isBlocked(account);
  }
}    