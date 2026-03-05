// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPricer
 * @notice 价格管理接口
 *
 * ===== 什么是 Pricer？ =====
 *
 * USDY 的价格不是由市场决定的（不像 ETH/USDT 在交易所交易）
 * 而是由链下计算后提交到链上的：
 *
 *   链下流程：
 *   1. Ondo 每天计算 USDY 的 NAV（净资产价值）
 *   2. 通过后端调用 addPrice(price, timestamp)
 *   3. 链上记录这个价格
 *
 *   链上用途：
 *   - RWAHub 用 priceId 来确定用户的申购/赎回价格
 *   - 例如：用户存入 1000 USDC，价格是 $1.05/USDY → 得到 ~952 USDY
 *
 * ===== priceId 是什么？ =====
 *
 * 每次添加价格都分配一个自增 ID：
 *   addPrice(1.05e18, ts1) → priceId = 1
 *   addPrice(1.06e18, ts2) → priceId = 2
 *   addPrice(1.04e18, ts0) → priceId = 3（注意：timestamp 可以乱序）
 *
 * RWAHub 在处理申购时会记录 "这笔订单用 priceId=2 结算"
 */
interface IPricer {
    function getLatestPrice() external view returns (uint256);
    function getPrice(uint256 priceId) external view returns (uint256);
    function addPrice(uint256 price, uint256 timestamp) external;
    function updatePrice(uint256 priceId, uint256 price) external;
}