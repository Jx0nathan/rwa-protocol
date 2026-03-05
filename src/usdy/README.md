# USDY — Rebase Token + T+1 Settlement System

参考 [Ondo Finance USDY](https://github.com/ondoprotocol/usdy) 实现的 RWA 代币系统，底层资产为美国短期国债。

## 核心设计

- **USDY Token** — 带合规检查的 ERC-20（可升级），支持 rebase 机制
- **T+1 结算** — 模拟传统金融的国债结算周期：`请求 → 等待链下结算 → 领取`
- **零余额设计** — 合约本身不持有资金，USDC 直接转入链下托管地址
- **三层合规** — 每笔转账/铸造/销毁都强制执行 Blocklist + Allowlist + Sanctions 检查

## 合约结构

```
src/usdy/
├── USDY.sol                          # 代币合约（ERC-20 + 合规）
├── factory/
│   └── USDYFactory.sol               # 一键部署工厂
├── proxy/
│   └── TokenProxy.sol                # Transparent Upgradeable Proxy
├── rwahub/
│   ├── RWAHub.sol                    # 申购/赎回中枢（abstract）
│   ├── RWAHubOffChainRedemptions.sol # 链下赎回扩展
│   └── USDYManager.sol              # 最终实现（含 Reg D/S 时间门控）
├── pricer/
│   └── Pricer.sol                    # NAV 价格预言机
├── allowlist/
│   ├── AllowlistUpgradeable.sol      # 白名单合约（含签名验证）
│   ├── AllowlistClient.sol           # 白名单客户端 Mixin
│   └── AllowlistClientUpgradeable.sol
├── blocklist/
│   ├── Blocklist.sol                 # 黑名单合约（Ownable2Step）
│   ├── BlocklistClient.sol           # 黑名单客户端 Mixin
│   └── BlocklistClientUpgradeable.sol
├── sanctions/
│   ├── SanctionsListClient.sol       # Chainalysis OFAC 制裁检查
│   └── SanctionsListClientUpgradeable.sol
└── interfaces/                       # 所有接口定义
```

## 核心流程

### 申购（Subscription）

```
用户                    RWAHub/USDYManager              链下托管
 │                           │                            │
 │  1. approve(hub, amt)     │                            │
 │  2. requestSubscription() │                            │
 │  ─────────────────────────>                            │
 │                           │  USDC → assetRecipient     │
 │                           │  ───────────────────────────>
 │                           │  记录 depositId            │
 │                           │                            │
 │           等待 T+1 结算...                              │
 │                           │                            │
 │       3. 管理员 setPriceIdForDeposits()                 │
 │                           │                            │
 │  4. claimMint(depositId)  │                            │
 │  ─────────────────────────>                            │
 │  <── USDY minted ────────│                            │
```

### 赎回（Redemption）

```
用户                    RWAHub/USDYManager              链下托管
 │                           │                            │
 │  1. requestRedemption()   │                            │
 │  ─────────────────────────>                            │
 │                           │  burn USDY                 │
 │                           │  记录 redemptionId         │
 │                           │                            │
 │           等待 T+1 结算...                              │
 │                           │                            │
 │       2. 管理员 setPriceIdForRedemptions()              │
 │                           │                            │
 │  3. claimRedemption()     │                            │
 │  ─────────────────────────>                            │
 │                           │  USDC ← assetSender        │
 │  <── USDC returned ──────│  <──────────────────────────│
```

## 三层合规检查

USDY 的 `_update()` 在每次转账/铸造/销毁时执行：

| 检查层 | 合约 | 说明 |
|--------|------|------|
| **Blocklist** | `Blocklist.sol` | 内部黑名单，`Ownable2Step` 管理 |
| **Allowlist** | `AllowlistUpgradeable.sol` | 白名单，支持链上/链下签名验证 |
| **Sanctions** | Chainalysis SanctionsList | OFAC 制裁名单（外部预言机） |

检查目标：`msg.sender`（调用者）+ `from`（发送方）+ `to`（接收方）三方都必须通过。

## 角色权限

### USDY Token

| 角色 | 权限 |
|------|------|
| `DEFAULT_ADMIN_ROLE` | 管理所有角色 |
| `MINTER_ROLE` | 铸造 USDY（授予 USDYManager） |
| `BURNER_ROLE` | 销毁 USDY（授予 USDYManager） |
| `PAUSER_ROLE` | 暂停/恢复所有转账 |
| `LIST_CONFIGURER_ROLE` | 切换 Blocklist/Allowlist/SanctionsList 地址 |

### USDYManager

| 角色 | 权限 |
|------|------|
| `OPERATOR_ROLE` | 设置 priceId、管理最低额度 |
| `ASSET_SENDER_ROLE` | 赎回时发送 USDC 给用户 |
| `RELAYER_ROLE` | 添加链下存款证明 |
| `PAUSER_ROLE` | 暂停申购/赎回 |

## 精度处理

| 资产 | 精度 | 说明 |
|------|------|------|
| USDC | 6 decimals | 稳定币输入 |
| USDY | 18 decimals | 代币输出 |
| Price | 18 decimals | NAV 价格 |

转换公式：`usdyAmount = usdcAmount * 1e12 * 1e18 / price`

## Pricer 安全机制

- **陈旧检查** — 价格超过 7 天未更新则拒绝使用
- **变动限制** — 单次价格变动不超过 5%（500 bps）
- **时间戳验证** — 不接受未来时间的价格
- **T+1 门控** — `claimTimestamp` 确保价格在到期后才可使用

## 技术栈

- Solidity 0.8.23 + Foundry
- OpenZeppelin v5（Contracts + Contracts Upgradeable）
- ERC-7201 Namespaced Storage（升级安全）
- Transparent Upgradeable Proxy

## 参考

- [Ondo Finance USDY](https://github.com/ondoprotocol/usdy)
- [Ondo Finance Contracts](https://github.com/ondoprotocol/tokenized-funds)
- [Chainalysis Sanctions Oracle](https://go.chainalysis.com/chainalysis-oracle-docs.html)
