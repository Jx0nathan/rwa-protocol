// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "src/usdy/interfaces/IAllowlistClient.sol";
import "src/usdy/interfaces/IAllowlist.sol";

/// @title AllowlistClient
/// @notice 白名单客户端 Mixin（非升级版）— 和 BlocklistClient 完全对称
abstract contract AllowlistClient is IAllowlistClient {

    IAllowlist public override allowlist;

    constructor(address _allowlist) {
        _setAllowlist(_allowlist);
    }

    function _setAllowlist(address _allowlist) internal {
      if (_allowlist == address(0)) {
         revert AllowlistZeroAddress();
      }
      address oldAllowlist = address(allowlist);
      allowlist = IAllowlist(_allowlist);
      emit AllowlistSet(oldAllowlist, _allowlist);
    }

    function _isAllowed(address account) internal view returns (bool) {
      return allowlist.isAllowed(account);
    }
}