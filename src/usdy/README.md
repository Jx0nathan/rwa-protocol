# USDY 代码脚手架

模仿 Ondo Finance USDY 的一比一结构复写练习。

## 文件结构

```
src/usdy/
├── USDY.sol             # Rebase ERC-20 token（核心）
├── USDYManager.sol      # 认购/赎回 Hub（T+1 流程）
├── USDYPricer.sol       # NAV 价格预言机（PriceId 快照）
├── KYCRegistry.sol      # KYC 白名单注册表
├── Blocklist.sol        # 内部黑名单
├── interfaces/
│   ├── ISanctionsList.sol   # Chainalysis 接口
│   ├── IKYCRegistry.sol
│   ├── IBlocklist.sol
│   └── IUSDYManager.sol
└── mocks/
    ├── MockSanctionsList.sol
    └── MockUSDC.sol

test/usdy/
├── USDY.t.sol           # Rebase + 合规测试
└── USDYManager.t.sol    # T+1 流程测试

script/usdy/
└── DeployUSDY.s.sol     # 完整部署脚本
```

## 快速开始

### 1. 安装依赖

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

### 2. 添加 remappings（在 foundry.toml 中）

```toml
remappings = [
  "@openzeppelin/=lib/openzeppelin-contracts/"
]
```

### 3. 运行测试

```bash
# 运行所有 USDY 测试
forge test --match-path "test/usdy/*" -vvv

# 只跑 Rebase 测试
forge test --match-contract USDYTest -vvv

# 只跑 Manager 流程测试
forge test --match-contract USDYManagerTest -vvv
```

### 4. 本地部署

```bash
# 启动本地节点
anvil

# 部署（另一个终端）
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ASSET_RECIPIENT=0x...
forge script script/usdy/DeployUSDY.s.sol --broadcast --rpc-url http://localhost:8545
```

## 核心学习要点

### 1. Rebase 机制

```
普通 ERC-20: balances[alice] = 1000
Rebase ERC-20: shares[alice] = 1000, rebaseIndex = 1.004
balanceOf(alice) = shares[alice] * rebaseIndex / 1e18 = 1004
```

Alice 不需要任何操作，运营方每天调用 `setRebaseIndex()`，所有人余额自动增加。

### 2. PriceId 快照（T+1）

```
用户认购 → depositId (priceId=0)
运营方日终 → addPrice(nav, tomorrow) → priceId=42
运营方绑定 → setPriceIdForDeposits([depositId], 42)
用户T+1 →   claimMint(depositId) → 铸造 USDY
```

### 3. 零余额设计

```
用户 USDC → safeTransferFrom(user, assetRecipient, amount)
合约始终持有 0 USDC
```

### 4. 三层合规

```
_beforeTransfer →
  Layer 1: kycRegistry.isKYCVerified(addr, group)
  Layer 2: blocklist.isBlocked(addr)
  Layer 3: sanctionsList.isSanctioned(addr)
```

## 对照 Ondo 真实合约

| 本脚手架             | Ondo 真实合约                    |
|---------------------|--------------------------------|
| USDY.sol            | USDY.sol                       |
| USDYManager.sol     | USDYManager.sol + RWAHub.sol   |
| USDYPricer.sol      | PricerWithOracle.sol           |
| KYCRegistry.sol     | KYCRegistry.sol                |
| Blocklist.sol       | Blocklist.sol                  |
| MockSanctionsList   | SanctionsList.sol（接口）       |

Ondo GitHub: https://github.com/ondoprotocol/usdy
