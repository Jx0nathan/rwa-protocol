// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "src/usdy/blocklist/BlocklistClient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title BlocklistClientUpgradeable
 * @notice 黑名单客户端 Mixin（升级版）— 使用 ERC-7201 Namespaced Storage
 *
 * 和非升级版 BlocklistClient 的功能完全一样，提供 _isBlocked() 和 _setBlocklist()
 *
 * 升级版的两个关键区别：
 *   1. 用 initializer 函数替代 constructor（兼容 Proxy 模式）
 *   2. 使用 ERC-7201 Namespaced Storage 替代 __gap[50]
 *
 * 谁会继承这个合约？
 *   → USDY Token（可升级的 ERC20，需要黑名单检查）
 */
abstract contract BlocklistClientUpgradeable is
    Initializable,
    IBlocklistClient
{
    // ============ ERC-7201 Namespaced Storage ============

    /// @custom:storage-location erc7201:blocklistclient.storage
    struct BlocklistClientStorage {
        IBlocklist blocklist;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("blocklistclient.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x0c0ca4b5fc675e8dd78b35cf4b739be01edd8e3ceb335aed4e544bee67070500;

    function _getBlocklistStorage()
        private
        pure
        returns (BlocklistClientStorage storage $)
    {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // ============ 公开 getter ============
    function blocklist() external view override returns (IBlocklist) {
        return _getBlocklistStorage().blocklist;
    }

    // ============ 初始化 ============

    function __BlocklistClientInitializable_init(
        address _blocklist
    ) internal onlyInitializing {
        __BlocklistClientInitializable_init_unchained(_blocklist);
    }

    function __BlocklistClientInitializable_init_unchained(
        address _blocklist
    ) internal onlyInitializing {
        _setBlocklist(_blocklist);
    }

    // ============ 内部函数 ============

    function _setBlocklist(address _blocklist) internal {
        if (_blocklist == address(0)) {
            revert BlocklistZeroAddress();
        }
        BlocklistClientStorage storage $ = _getBlocklistStorage();
        address oldBlocklist = address($.blocklist);
        $.blocklist = IBlocklist(_blocklist);
        emit BlocklistSet(oldBlocklist, _blocklist);
    }

    function _isBlocked(address account) internal view returns (bool) {
        return _getBlocklistStorage().blocklist.isBlocked(account);
    }
}
