// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title USDYPricer
 * @notice NAV 价格预言机，模拟 Ondo PricerWithOracle.sol
 *
 * ═══════════════════════════════════════════════════
 * 设计要点
 * ═══════════════════════════════════════════════════
 *
 * 1. PriceId 快照模式（Ondo 的核心创新）
 *    - 每天运营方设置一个新的 priceId（递增 ID）
 *    - 每个 priceId 对应一个价格 + claimableTimestamp
 *    - 认购请求绑定到某个 priceId
 *    - 用户只能在 claimableTimestamp 之后 claim
 *    - 好处：价格和认购请求解耦，批量处理高效
 *
 * 2. 双重验证
 *    - 运营方每日 push 一个价格（off-chain NAV 计算）
 *    - 可选：Chainlink 喂价作为参考，价格偏差过大时拒绝
 *
 * 3. Staleness 检查
 *    - 7 天没有更新价格，视为过期，拒绝使用
 *    - 防止节点宕机时用旧价格铸造
 *
 * ═══════════════════════════════════════════════════
 * 价格精度：1e18（1.0 = 1e18）
 * 例：USDY 价格约 $1.0xxx，表示为 1_004_300_000_000_000_000
 * ═══════════════════════════════════════════════════
 */
contract USDYPricer is AccessControl {
  bytes32 public constant PRICE_UPDATE_ROLE = keccak256("PRICE_UPDATE_ROLE");

  // ─────────────────────────────────────────────
  // 价格状态
  // ─────────────────────────────────────────────

  /// @notice 当前最新 priceId（每次 addPrice 自增）
  uint256 public latestPriceId;

  struct PriceData {
    uint256 price;               // NAV 价格（精度 1e18）
    uint256 timestamp;           // 价格推送时间
    uint256 claimableTimestamp;  // 用户可 claim 的最早时间（T+1）
    bool    isSet;               // 是否已设置
  }

  /// @notice priceId → 价格数据
  mapping(uint256 => PriceData) public prices;

  /// @notice Staleness 限制：7 天内必须有新价格
  uint256 public constant MAX_PRICE_AGE = 7 days;

  /// @notice 最小价格（防止 oracle 被操纵为 0）
  uint256 public constant MIN_PRICE = 1e17; // $0.1

  // ─────────────────────────────────────────────
  // Chainlink 可选验证（接口定义，可传 address(0) 禁用）
  // ─────────────────────────────────────────────

  /// @notice Chainlink AggregatorV3 接口（仅用于交叉验证）
  address public chainlinkOracle;

  /// @notice 允许运营方价格与 Chainlink 的最大偏差（basis points）
  /// @dev 默认 200 = 2%，超过此偏差拒绝 setPrice
  uint256 public maxDeviationBps = 200;

  // ─────────────────────────────────────────────
  // 事件
  // ─────────────────────────────────────────────

  event PriceAdded(
    uint256 indexed priceId,
    uint256 price,
    uint256 claimableTimestamp
  );

  event ChainlinkOracleSet(address indexed old, address indexed newOracle);

  // ─────────────────────────────────────────────
  // 构造函数
  // ─────────────────────────────────────────────

  constructor(address admin, address _chainlinkOracle) {
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PRICE_UPDATE_ROLE, admin);
    chainlinkOracle = _chainlinkOracle; // 可传 address(0) 禁用 Chainlink 验证
    // priceId 从 1 开始，0 作为"未绑定"的哨兵值
    latestPriceId = 0;
  }

  // ─────────────────────────────────────────────
  // 价格管理
  // ─────────────────────────────────────────────

  /**
   * @notice 每日添加新价格（运营方每天调用一次）
   * @dev 自动分配新的 priceId（latestPriceId + 1）
   * @param price              NAV 价格（精度 1e18）
   * @param claimableTimestamp 用户最早可 claim 的时间（通常是明天凌晨，T+1）
   * @return newPriceId        新分配的 priceId
   *
   * ⚠️ 学习要点：
   * Ondo 的设计是先记录 priceId，再由运营方批量绑定 depositId → priceId
   * 这样认购和定价是异步的，可以日终批量结算
   */
  function addPrice(
    uint256 price,
    uint256 claimableTimestamp
  ) external onlyRole(PRICE_UPDATE_ROLE) returns (uint256 newPriceId) {
    require(price > MIN_PRICE, "USDYPricer: price too low");
    require(
      claimableTimestamp > block.timestamp,
      "USDYPricer: claimableTimestamp must be in future"
    );

    // 如果配置了 Chainlink，进行交叉验证
    if (chainlinkOracle != address(0)) {
      _validateWithChainlink(price);
    }

    newPriceId = ++latestPriceId;
    prices[newPriceId] = PriceData({
      price:               price,
      timestamp:           block.timestamp,
      claimableTimestamp:  claimableTimestamp,
      isSet:               true
    });

    emit PriceAdded(newPriceId, price, claimableTimestamp);
  }

  // ─────────────────────────────────────────────
  // 查询
  // ─────────────────────────────────────────────

  /**
   * @notice 获取某 priceId 的价格（供 USDYManager 在 claimMint 时调用）
   * @dev 会做两项检查：
   *      1. priceId 已设置
   *      2. 价格未过期（不超过 7 天）
   */
  function getPriceById(uint256 priceId) external view returns (uint256 price) {
    PriceData memory data = prices[priceId];
    require(data.isSet, "USDYPricer: priceId not set");
    require(
      block.timestamp - data.timestamp <= MAX_PRICE_AGE,
      "USDYPricer: price is stale"
    );
    return data.price;
  }

  /**
   * @notice 获取某 priceId 的可 claim 时间
   */
  function getClaimableTimestamp(uint256 priceId) external view returns (uint256) {
    require(prices[priceId].isSet, "USDYPricer: priceId not set");
    return prices[priceId].claimableTimestamp;
  }

  /**
   * @notice 获取最新价格（用于日常查询，不用于精确结算）
   */
  function getLatestPrice() external view returns (uint256 price, uint256 timestamp) {
    require(latestPriceId > 0, "USDYPricer: no price set yet");
    PriceData memory data = prices[latestPriceId];
    require(
      block.timestamp - data.timestamp <= MAX_PRICE_AGE,
      "USDYPricer: latest price is stale"
    );
    return (data.price, data.timestamp);
  }

  // ─────────────────────────────────────────────
  // Chainlink 交叉验证（内部）
  // ─────────────────────────────────────────────

  /**
   * @notice 验证运营方推送的价格与 Chainlink 偏差不超过 maxDeviationBps
   * @dev 这里是简化版。Ondo 真实实现用 AggregatorV3Interface.latestRoundData()
   *
   * ⚠️ 复写练习：
   * 真正的 Chainlink 调用：
   *   (,int256 answer,,uint256 updatedAt,) = AggregatorV3Interface(oracle).latestRoundData();
   *   uint256 chainlinkPrice = uint256(answer) * 1e10; // 8位 → 18位
   */
  function _validateWithChainlink(uint256 operatorPrice) internal view {
    // TODO: 复写时在这里接入真实 Chainlink 调用
    // 目前仅做 placeholder，不实际验证
    // 示例逻辑：
    // uint256 chainlinkPrice = _getChainlinkPrice();
    // uint256 diff = operatorPrice > chainlinkPrice
    //     ? operatorPrice - chainlinkPrice
    //     : chainlinkPrice - operatorPrice;
    // require(
    //     diff * 10000 / chainlinkPrice <= maxDeviationBps,
    //     "USDYPricer: price deviates too much from Chainlink"
    // );
    (operatorPrice); // suppress unused warning
  }

  // ─────────────────────────────────────────────
  // 管理员配置
  // ─────────────────────────────────────────────

  function setChainlinkOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
    emit ChainlinkOracleSet(chainlinkOracle, _oracle);
    chainlinkOracle = _oracle;
  }

  function setMaxDeviationBps(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_bps <= 1000, "USDYPricer: max deviation too large"); // 最大 10%
    maxDeviationBps = _bps;
  }
}
