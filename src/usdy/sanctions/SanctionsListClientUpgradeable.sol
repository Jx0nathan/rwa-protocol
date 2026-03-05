// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "src/usdy/interfaces/ISanctionsListClient.sol";

/**
 * @title SanctionsListClientUpgradeable
 * @notice 制裁名单客户端 Mixin（升级版）— 使用 ERC-7201 Namespaced Storage
 *
 * 和 BlocklistClientUpgradeable 完全对称的结构：
 *   blocklist   → sanctionsList
 *   _isBlocked  → _isSanctioned
 */
abstract contract SanctionsListClientUpgradeable is
  Initializable,
  ISanctionsListClient
{
  // ============ ERC-7201 Namespaced Storage ============

  /// @custom:storage-location erc7201:sanctionslistclient.storage
  struct SanctionsListClientStorage {
    ISanctionsList sanctionsList;
  }

  /// @dev keccak256(abi.encode(uint256(keccak256("sanctionslistclient.storage")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_LOCATION =
    0xd0a3d8e3f5f97a7e35d6abd6677285352db75371141270abaee110af5e6ea100;

  function _getSanctionsStorage()
    private
    pure
    returns (SanctionsListClientStorage storage $)
  {
    bytes32 slot = STORAGE_LOCATION;
    assembly {
      $.slot := slot
    }
  }

  // ============ 公开 getter ============

  function sanctionsList() external view override returns (ISanctionsList) {
    return _getSanctionsStorage().sanctionsList;
  }

  // ============ 初始化 ============

  function __SanctionsListClientInitializable_init(
    address _sanctionsList
  ) internal onlyInitializing {
    __SanctionsListClientInitializable_init_unchained(_sanctionsList);
  }

  function __SanctionsListClientInitializable_init_unchained(
    address _sanctionsList
  ) internal onlyInitializing {
    _setSanctionsList(_sanctionsList);
  }

  // ============ 内部函数 ============

  function _setSanctionsList(address _sanctionsList) internal {
    if (_sanctionsList == address(0)) {
      revert SanctionsListZeroAddress();
    }
    SanctionsListClientStorage storage $ = _getSanctionsStorage();
    address oldSanctionsList = address($.sanctionsList);
    $.sanctionsList = ISanctionsList(_sanctionsList);
    emit SanctionsListSet(oldSanctionsList, _sanctionsList);
  }

  function _isSanctioned(address account) internal view returns (bool) {
    return _getSanctionsStorage().sanctionsList.isSanctioned(account);
  }
}