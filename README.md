# RWA Protocol

A compliant, payment-native Real World Asset tokenization protocol built for Singapore MAS regulatory framework.

## Overview

This protocol enables the tokenization of real-world financial assets (money market funds, T-bills, bonds) with built-in KYC/AML compliance, designed specifically for payment float management use cases.

## Architecture

```
RWAToken (ERC-20 + KYC gating)
    ├── KYCAllowlist (compliance layer)
    ├── SubscriptionManager (mint on deposit)
    ├── RedemptionManager (burn on withdrawal)
    ├── NAVOracle (daily price feed)
    └── RWAFactory (multi-asset deployment)
```

## Contracts

| Contract | Description |
|----------|-------------|
| `RWAToken` | Permissioned ERC-20 representing fund shares |
| `KYCAllowlist` | On-chain KYC whitelist management |
| `SubscriptionManager` | Handles USDC → RWA Token subscriptions |
| `RedemptionManager` | Handles RWA Token → USDC redemptions |
| `NAVOracle` | Daily NAV price feed with operator signing |
| `RWAFactory` | Factory for deploying new RWA token instances |

## Getting Started

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable

# Build
forge build

# Test
forge test -vvv
```

## License
MIT
