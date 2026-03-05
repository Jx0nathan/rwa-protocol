# RWA Protocol

RWA（Real World Asset）技术方案调研与实现。本仓库用于研究和实现当前感兴趣的 RWA 代币化技术方案，涵盖合规设计、T+1 结算、价格预言机等核心模块。

## 技术方案

### 1. USDY — Rebase Token + T+1 Settlement

参考 Ondo Finance USDY 实现的合规代币系统，底层资产为美国短期国债。

**核心特性：**
- 带三层合规检查（Blocklist + Allowlist + Sanctions）的 ERC-20
- T+1 结算流程：`申购请求 → 链下结算 → 领取代币`
- 零余额设计：合约不持有资金，USDC 直接转入托管地址
- NAV 价格预言机，含陈旧检查和变动限制

**详细文档：** [src/usdy/README.md](src/usdy/README.md)

### 2. Generic RWA System（通用 RWA 基础设施）

工厂模式部署的多资产基础设施，使用 UUPS 升级代理：

| 合约 | 说明 |
|------|------|
| `RWAToken` | 带 KYC 门控的 ERC-20 |
| `KYCAllowlist` | 分级 KYC 白名单（Tier 1/2/3） |
| `SubscriptionManager` | USDC → RWA Token 申购 |
| `RedemptionManager` | RWA Token → USDC 赎回 |
| `NAVOracle` | 每日 NAV 价格预言机 |
| `RWAFactory` | 多资产实例部署工厂 |

## 技术栈

- **Solidity** 0.8.23 + **Foundry**
- **OpenZeppelin** v5（Contracts + Contracts Upgradeable）
- ERC-7201 Namespaced Storage
- Transparent Upgradeable Proxy / UUPS Proxy

## 快速开始

```bash
# 安装 Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 安装依赖
forge install foundry-rs/forge-std --no-commit
npm install @openzeppelin/contracts

# 构建
forge build

# 测试
forge test -vvv

# 部署（本地 Anvil）
forge script script/usdy/DeployUSDY.s.sol --broadcast --rpc-url http://localhost:8545
```

## License

MIT / BUSL-1.1
