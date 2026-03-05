// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "src/usdy/interfaces/IAllowlistClient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title AllowlistClientUpgradeable
 * @notice 白名单客户端 Mixin（升级版）
 **/
abstract contract AllowlistClientUpgradeable is Initializable, IAllowlistClient {

   // ============ ERC-7201 Namespaced Storage ============
   /**
    * @dev 把所有需要持久化的变量放在这个 struct 里，未来升级需要加新变量？直接在 struct 末尾添加即可
    *      不需要管 gap，不会影响子合约的 storage layout     
    */
   struct AllowlistClientStorage {
      IAllowlist allowlist;
   }
   
   /**
   * @dev ERC-7201 计算出的固定 slot 位置
   *
   * 计算过程：
   *   1. keccak256("allowlistclient.storage")
   *      = 0x4f2a14dc185cebc27f7e014733cf31a106148f73ba0b28ab1c2c30e0fa6f0bd0
   *   2. 减 1
   *      = 0x4f2a14dc185cebc27f7e014733cf31a106148f73ba0b28ab1c2c30e0fa6f0bcf
   *   3. keccak256(abi.encode(上面的值))
   *      = 某个 hash
   *   4. & ~bytes32(uint256(0xff))  → 清除最后一个字节
   *      = 0x9f19b4a5fe8fe5ec843a64ea5fcab0d4a4f7fdf58c6084e66c8fc61f7fe39500
   */
   bytes32 private constant STORAGE_LOCATION = 0x9f19b4a5fe8fe5ec843a64ea5fcab0d4a4f7fdf58c6084e66c8fc61f7fe39500;

  /**
   * @dev 获取 namespaced storage 的引用
   *
   * 这里必须用 assembly 因为 Solidity 不支持直接指定 storage slot
   * 返回的 $ 是一个 storage 指针，读写 $.allowlist 就是直接操作链上 storage
   *
   * 为什么变量名叫 $？
   *   → OZ v5 的惯例，简短且和普通变量名区分开
   */
  function _getStorage() private pure returns (AllowlistClientStorage storage $){
    bytes32 slot = STORAGE_LOCATION;
    assembly {
      $.slot := slot
    }
  }

   // ============ 公开 getter ============

  /**
   * @dev 旧方案中 `IAllowlist public override allowlist` 会自动生成 getter
   *      现在变量藏在 struct 里，需要手动实现 getter 来满足接口
   */
  function allowlist() external view override returns (IAllowlist) {
    return _getStorage().allowlist;
  }

  // ============ 初始化 ============

  /// @notice 完整初始化（调用自身 + 所有父级的初始化链）
  function __AllowlistClientInitializable_init(
    address _allowlist
  ) internal onlyInitializing {
    __AllowlistClientInitializable_init_unchained(_allowlist);
  }

  /// @notice 只做自身这层的初始化
  function __AllowlistClientInitializable_init_unchained(
    address _allowlist
  ) internal onlyInitializing {
    _setAllowlist(_allowlist);
  }

  // ============ 内部函数 ============

  function _setAllowlist(address _allowlist) internal {
    if (_allowlist == address(0)) {
      revert AllowlistZeroAddress();
    }
    AllowlistClientStorage storage $ = _getStorage();
    address oldAllowlist = address($.allowlist);
    $.allowlist = IAllowlist(_allowlist);
    emit AllowlistSet(oldAllowlist, _allowlist);
  }

  function _isAllowed(address account) internal view returns (bool) {
    return _getStorage().allowlist.isAllowed(account);
  }
}