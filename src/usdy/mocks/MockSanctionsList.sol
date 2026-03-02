// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/ISanctionsList.sol";

/**
 * @title MockSanctionsList
 * @notice 测试用 Chainalysis SanctionsList mock
 * @dev 生产环境用真实地址：0x40C57923924B5c5c5455c48D93317139ADDaC8fb
 */
contract MockSanctionsList is ISanctionsList {
  mapping(address => bool) private _sanctioned;

  function isSanctioned(address addr) external view override returns (bool) {
    return _sanctioned[addr];
  }

  /// @notice 测试辅助：手动添加制裁地址
  function addSanctionedAddress(address addr) external {
    _sanctioned[addr] = true;
  }

  /// @notice 测试辅助：移除制裁
  function removeSanctionedAddress(address addr) external {
    _sanctioned[addr] = false;
  }
}
