// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IRWALike
 * @notice RWA Token 的最小接口 — RWAHub 通过此接口与 USDY 交互
 *
 * 为什么用接口而不直接 import USDY？
 * → 解耦。RWAHub 不需要知道 USDY 的全部实现细节
 * → 只需要知道它能 mint、burn 和 burnFrom
 * → 这样 RWAHub 可以服务多种 RWA Token（USDY、OMMF 等）
 */
interface IRWALike is IERC20 {
  function mint(address to, uint256 amount) external;
  function burn(uint256 amount) external;
  function burnFrom(address from, uint256 amount) external;
}