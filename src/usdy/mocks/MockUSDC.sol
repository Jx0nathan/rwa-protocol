// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice 测试用 USDC（6位小数，可自由 mint）
 */
contract MockUSDC is ERC20 {
  constructor() ERC20("USD Coin", "USDC") {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}
