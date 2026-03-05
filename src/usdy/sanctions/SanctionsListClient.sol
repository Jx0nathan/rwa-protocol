// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/usdy/interfaces/ISanctionsListClient.sol";

abstract contract SanctionsListClient is ISanctionsListClient {

  /// @notice 当前引用的制裁名单预言机
  ISanctionsList public override sanctionsList;

  /// @notice 初始化制裁名单引用
  constructor(address _sanctionsList) {
    _setSanctionsList(_sanctionsList);
  }

  /// @notice 设置制裁名单地址（internal，权限由子合约控制）
  function _setSanctionsList(address _sanctionsList) internal {
    if (_sanctionsList == address(0)) {
      revert SanctionsListZeroAddress();
    }
    address oldSanctionsList = address(sanctionsList);
    sanctionsList = ISanctionsList(_sanctionsList);
    emit SanctionsListSet(oldSanctionsList, _sanctionsList);
  }

  /// @notice 查询地址是否被制裁
  function _isSanctioned(address account) internal view returns (bool) {
    return sanctionsList.isSanctioned(account);
  }
}    