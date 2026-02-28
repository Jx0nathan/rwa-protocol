# RWA Protocol — 技术架构文档

**版本：** v1.0  
**作者：** Jonathan Ji  
**日期：** 2026-02

---

## 1. 执行摘要

本文档描述一套面向支付场景的 RWA（Real World Asset）代币化协议的完整技术架构。

**核心定位：**  
帮助支付机构、大型商户和稳定币用户，将链上闲置资金（USDC/USDT）转化为持有代币化货币市场基金或短期国债的份额，在资金等待清算的每一秒都在生息，目标年化收益 3–5%。

**与 Ondo 的差异化：**
- Ondo 面向通用 DeFi 用户；本协议专注**支付场景浮存金**
- 原生集成支付清算流程，资金可在 T+0 内完成申购和赎回
- 面向新加坡 MAS 监管框架设计，优先满足 PSP/CASP 持牌机构合规需求

---

## 2. 业务模型

### 2.1 目标用户

| 用户类型 | 场景 | 规模 |
|---------|------|------|
| 支付机构（PSP）| 清算浮存金收益管理 | 数百万至数亿美元 |
| 大型电商平台 | 备付金收益管理 | 数十万至数百万 |
| 稳定币发行方 | 储备金收益管理 | 亿级别 |
| 高净值 C 端用户 | 闲置稳定币生息 | 万至百万 |

### 2.2 商业模式

- **管理费**：AUM 的 0.3–0.5%/年（从底层资产收益中扣除）
- **技术服务费**：向 B 端集成方收取 API 接入费
- **赎回手续费**：T+0 即时赎回收取 0.1% 手续费（普通 T+1 免费）

### 2.3 底层资产选项

| 资产 | 预期收益 | 流动性 | 监管要求 |
|------|---------|--------|---------|
| 新加坡 MAS 认可货币市场基金 | 3–4% | T+1 | CMS 牌照 |
| 美国短期国债（SHV ETF）| 4–5% | T+1 | 仅限合格投资者 |
| 银行定期存款（短期）| 2–3% | T+0/T+1 | 最低门槛 |

---

## 3. 法律结构

```
投资人（KYC 通过）
      │ 申购 USDC
      ▼
  RWA Token 智能合约
  （链上份额凭证）
      │
      ▼
  Singapore SPV
  （持牌基金管理人）
      │
      ▼
  传统托管账户
  （DBS / BNY Mellon）
      │
      ▼
  底层资产
  （MMF / T-Bills / Bank Deposits）
```

**关键法律文件：**
- SPV 设立文件（新加坡 Private Limited 或 VCC）
- 法律意见书（Token = 基金份额的经济权益）
- 托管协议
- 投资者认购协议（含 KYC/AML 声明）
- CMS 牌照申请（资本市场服务，新加坡 MAS）

---

## 4. 技术架构总览

```
┌──────────────────────────────────────────────────────┐
│                    用户接口层                           │
│         Web App / Mobile App / API (B2B)              │
└──────────────────────┬───────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────┐
│                  合规中台（链下）                        │
│  KYC Engine │ AML Screening │ Allowlist Manager       │
│  Subscription Processor │ Redemption Processor        │
│  NAV Calculator │ Reporting Engine                    │
└──────────────────────┬───────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────┐
│                智能合约层（链上）                        │
│  RWAToken │ KYCAllowlist │ SubscriptionManager        │
│  RedemptionManager │ NAVOracle │ RWAFactory            │
└──────────────────────┬───────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────┐
│               跨链 / 基础设施层                         │
│  LayerZero Bridge │ Chainlink Oracle │ USDC / USDT    │
└──────────────────────────────────────────────────────┘
```

---

## 5. 智能合约设计

### 5.1 合约清单

| 合约名 | 功能 |
|-------|------|
| `RWAToken.sol` | ERC-20 代币，含转账白名单和暂停功能 |
| `KYCAllowlist.sol` | KYC 白名单地址管理 |
| `SubscriptionManager.sol` | 申购流程：接收 USDC，发行 Token |
| `RedemptionManager.sol` | 赎回流程：销毁 Token，返还 USDC |
| `NAVOracle.sol` | 每日净资产价值（NAV）推送 |
| `RWAFactory.sol` | 工厂合约，支持部署多种资产类型的 RWA |

### 5.2 RWAToken 核心设计

```solidity
// 核心特性
- ERC-20 标准接口
- 转账白名单（KYC 地址才能 send/receive）
- 基于 NAV 的价格增长（非 rebase，Token 价值随时间增加）
- 紧急暂停（Pausable）
- UUPS 可升级代理模式
- 角色控制：OPERATOR_ROLE / ORACLE_ROLE / ADMIN_ROLE
```

### 5.3 申购流程

```
用户调用 SubscriptionManager.subscribe(usdcAmount)
    │
    ├─ 检查：用户地址在 KYCAllowlist
    ├─ 检查：申购金额 >= 最小申购额
    ├─ 转入 USDC 到托管地址
    ├─ 记录申购请求（PendingSubscription）
    │
    ▼
链下 Operator 处理（T+1）
    ├─ 将 USDC 转换为底层资产
    ├─ 确认买入完成
    │
    ▼
调用 SubscriptionManager.fulfillSubscription(requestId)
    ├─ 计算 Token 数量 = usdcAmount / currentNAV
    └─ Mint Token 给用户
```

### 5.4 赎回流程

```
用户调用 RedemptionManager.redeem(tokenAmount)
    │
    ├─ 检查：用户地址在 KYCAllowlist
    ├─ 锁定用户 Token（transferFrom 到合约）
    ├─ 记录赎回请求（PendingRedemption）
    │
    ▼
链下 Operator 处理（T+1 普通 / T+0 需额外手续费）
    ├─ 出售底层资产
    ├─ 获得 USDC
    │
    ▼
调用 RedemptionManager.fulfillRedemption(requestId)
    ├─ Burn 锁定的 Token
    └─ 转 USDC 给用户
```

### 5.5 NAV Oracle

```
每日由授权 Oracle 节点推送：
- 当前 NAV（每单位 Token 对应的 USDC 价值）
- 总资产净值（AUM）
- 时间戳
- 签名验证（防止篡改）

NAV 更新触发：
- Token 价格重新计算
- 事件日志记录（用于审计）
```

---

## 6. KYC / AML 合规层

### 6.1 KYC 流程

```
用户提交身份信息
    │
    ▼
KYC 服务商（SumSub / Jumio / Onfido）
    │ 验证通过
    ▼
后端系统记录 KYC 状态
    │
    ▼
调用 KYCAllowlist.addAddress(userAddress, tier)
    │ 链上白名单生效
    ▼
用户可以申购 / 持有 / 转账 RWA Token
```

### 6.2 KYC 等级

| 等级 | 验证内容 | 申购上限 |
|------|---------|---------|
| Tier 1 | 邮箱 + 手机 | $1,000 |
| Tier 2 | 身份证 + 人脸 | $100,000 |
| Tier 3 | 合格投资者认证 | 无上限 |

### 6.3 AML 筛查

- 钱包地址筛查：Chainalysis / Elliptic API
- 黑名单地址自动拒绝（OFAC / UN 制裁名单）
- 大额交易自动触发人工审核（>$10,000 单笔）

---

## 7. 后端系统设计

### 7.1 核心服务

```
┌─────────────────────────────────────────┐
│  API Gateway（身份验证 + 限流）            │
└──────────────┬──────────────────────────┘
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
 KYC Service  Sub/Red   NAV Service
 (合规验证)    Service   (净值计算)
              (申购赎回)
    │          │          │
    └──────────┼──────────┘
               ▼
        Event Bus (Kafka)
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
 Blockchain  Custody    Reporting
 Operator    Bridge     Service
 (链上操作)  (资金托管)  (报告生成)
```

### 7.2 技术栈建议

| 层级 | 技术选型 |
|------|---------|
| 智能合约 | Solidity + Foundry |
| 后端服务 | Java Spring Boot / Go |
| 消息队列 | Kafka |
| 数据库 | PostgreSQL（业务）+ Redis（缓存）|
| 链上监听 | The Graph / 自建 Indexer |
| KYC 集成 | SumSub SDK |
| 钱包托管 | Fireblocks MPC |
| 区块链网络 | Ethereum（主网）+ Polygon（低费用）|

---

## 8. 安全架构

### 8.1 智能合约安全

- 所有合约使用 UUPS 可升级代理
- 升级需 Timelock（48h 时间锁）+ 多签审批
- 关键操作（Mint/Burn）需 Operator 角色 + 多签
- 审计：上线前必须通过 Trail of Bits 或 OpenZeppelin 审计

### 8.2 私钥管理

```
Admin Key    → Gnosis Safe 多签（3/5）
Operator Key → Fireblocks MPC 钱包
Oracle Key   → 独立 HSM 签名
```

### 8.3 运营风险控制

- 每日申购上限（防止大额挤兑）
- 底层资产流动性监控（确保赎回可执行）
- 链上暂停机制（发现异常立即暂停）
- 多级告警体系（链上事件 → Slack/PagerDuty）

---

## 9. 监管合规（新加坡）

### 9.1 所需牌照

| 牌照 | 监管机构 | 用途 |
|------|---------|------|
| CMS（资本市场服务）| MAS | 基金管理、证券代币发行 |
| PSP（支付服务）| MAS | 稳定币收单、法币出入金 |
| VCC 或 Private Ltd | ACRA | SPV 法律实体 |

### 9.2 MAS Project Guardian 对接

- 申请加入 MAS Project Guardian 机构试点
- 遵循 MAS TRM Guidelines（技术风险管理）
- 定期向 MAS 提交合规报告

### 9.3 投资者保护措施

- 资产隔离：SPV 资产与运营主体完全隔离，破产隔离
- 独立审计：年度财务审计 + 季度 NAV 验证
- 信息披露：实时 AUM、NAV、底层资产构成公开

---

## 10. 技术路线图

### Phase 1：MVP（0–6个月）

- [ ] 完成法律结构搭建（SPV + 法律意见书）
- [ ] 核心合约开发（RWAToken + KYCAllowlist + SubscriptionManager）
- [ ] 接入 SumSub KYC
- [ ] 接入 DBS 托管账户
- [ ] 底层资产：新加坡货币市场基金
- [ ] 测试网部署 + 第三方审计
- [ ] 首批种子用户（机构投资人）

### Phase 2：产品完善（6–12个月）

- [ ] 主网上线
- [ ] 接入第二种底层资产（美债 ETF）
- [ ] T+0 即时赎回功能
- [ ] B2B API 开放（支付机构接入）
- [ ] Polygon / Base 多链部署

### Phase 3：规模化（12–24个月）

- [ ] LayerZero 跨链桥接
- [ ] DeFi 集成（Aave / Compound 抵押品）
- [ ] 香港、迪拜市场扩张
- [ ] 第三方 RWA 发行服务（白标模式）

---

## 11. 与 DCS 支付生态的集成

本协议天然与支付系统集成：

```
商户收款 (USDC)
    │
    ▼
自动申购 RWA Token（资金进入生息）
    │
    ▼
清算时触发赎回（T+0 快速通道）
    │
    ▼
USDC 转出用于结算
```

这样商户的每一笔备付金都在生息，而不是闲置。

---

## 附录：参考项目

| 项目 | 定位 | 学习点 |
|------|------|--------|
| Ondo Finance | 代币化美债 | KYC 白名单合约设计 |
| Franklin Templeton BENJI | 代币化国债基金 | 传统 AM + 链上结合 |
| Centrifuge | 贸易融资 RWA | 链下资产上链机制 |
| Maple Finance | 私人信贷 | 机构信贷 RWA |
| BlackRock BUIDL | 代币化 MMF | 机构级别运营标准 |

---

*本文档为技术规划文档，不构成投资建议或监管意见。实际实施需结合当地监管要求和法律意见。*
