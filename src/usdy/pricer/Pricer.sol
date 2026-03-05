// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "src/usdy/interfaces/IPricer.sol";

contract Pricer is AccessControl, IPricer {
    /// @dev 价格信息：价格 + 时间戳
    struct PriceInfo {
        uint256 price;
        uint256 timestamp;
    }

    // ============ 状态变量 ============

    /// @notice priceId → PriceInfo 映射
    mapping(uint256 => PriceInfo) public prices;

    /// @notice 自增指针：最后一次 addPrice 分配的 priceId
    /// @dev 不一定是时间最新的，只是最后添加的
    uint256 public currentPriceId;

    /// @notice timestamp 最大的 priceId
    /// @dev 这才是"最新价格"的指针
    uint256 public latestPriceId;

    // ============ 常量 ============

    /// @notice 价格过期时间（7 天）
    uint256 public constant MAX_STALENESS = 7 days;

    /// @notice 最大单次价格变动（5%，以 BPS 表示）
    uint256 public constant MAX_CHANGE_DIFF_BPS = 500;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ============ 角色 ============
    bytes32 public constant PRICE_UPDATE_ROLE = keccak256("PRICE_UPDATE_ROLE");

    // ============ 事件 ============
    event PriceAdded(uint256 indexed priceId, uint256 price, uint256 timestamp);
    event PriceUpdated(
        uint256 indexed priceId,
        uint256 oldPrice,
        uint256 newPrice
    );

    // ============ 错误 ============
    error InvalidPrice();
    error PriceIdDoesNotExist();
    error PriceStale();
    error TimestampInFuture();
    error PriceChangeTooLarge();

    // ============ 构造函数 ============
    constructor(address admin, address pricer) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PRICE_UPDATE_ROLE, pricer);
    }

    // ============ 读取函数 ============

    /// @notice 获取最新价格（timestamp 最大的那个），含过期检查
    function getLatestPrice() external view override returns (uint256) {
        PriceInfo memory info = prices[latestPriceId];
        if (block.timestamp > info.timestamp + MAX_STALENESS) {
            revert PriceStale();
        }
        return info.price;
    }

    /// @notice 通过 priceId 获取特定价格
    function getPrice(
        uint256 priceId
    ) external view override returns (uint256) {
        return prices[priceId].price;
    }

    // ============ 写入函数 ============

    /**
     * @notice 添加新价格
     * @param price     价格（18位精度，如 1.05e18 = $1.05）
     * @param timestamp 这个价格对应的时间
     *
     * 安全检查：
     * 1. price != 0
     * 2. timestamp 不能是未来时间
     * 3. 价格变动不能超过 5%（相对最新价格）
     */
    function addPrice(
        uint256 price,
        uint256 timestamp
    ) external virtual override onlyRole(PRICE_UPDATE_ROLE) {
        if (price == 0) {
            revert InvalidPrice();
        }
        if (timestamp > block.timestamp) {
            revert TimestampInFuture();
        }

        // 价格变动检查（首次添加时跳过）
        if (latestPriceId != 0) {
            uint256 latestPrice = prices[latestPriceId].price;
            uint256 diff = price > latestPrice
                ? price - latestPrice
                : latestPrice - price;
            if (diff * BPS_DENOMINATOR > latestPrice * MAX_CHANGE_DIFF_BPS) {
                revert PriceChangeTooLarge();
            }
        }

        // 分配新 priceId（从 1 开始，0 保留）
        uint256 priceId = ++currentPriceId;
        prices[priceId] = PriceInfo(price, timestamp);

        // 更新 latestPriceId：只有当新 timestamp 更大时才更新
        if (timestamp > prices[latestPriceId].timestamp) {
            latestPriceId = priceId;
        }
        emit PriceAdded(priceId, price, timestamp);
    }

    /**
     * @notice 更新已有价格（保留原始 timestamp）
     * @param priceId 要更新的 priceId
     * @param price   新价格
     *
     * 使用场景：发现之前提交的价格有误，需要修正
     * 注意：不改 timestamp，所以不影响 latestPriceId
     */
    function updatePrice(
        uint256 priceId,
        uint256 price
    ) external override onlyRole(PRICE_UPDATE_ROLE) {
        if (price == 0) {
            revert InvalidPrice();
        }
        if (prices[priceId].price == 0) {
            revert PriceIdDoesNotExist();
        }

        PriceInfo memory oldInfo = prices[priceId];
        prices[priceId] = PriceInfo(price, oldInfo.timestamp);

        emit PriceUpdated(priceId, oldInfo.price, price);
    }
}
