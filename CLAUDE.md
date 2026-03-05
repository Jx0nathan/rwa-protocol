# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Install dependencies (OpenZeppelin via npm, forge-std via forge)
npm install @openzeppelin/contracts
forge install foundry-rs/forge-std --no-commit

# Build
forge build

# Run all tests
forge test -vvv

# Run a single test contract
forge test --match-contract USDYTest -vvv
forge test --match-contract USDYManagerTest -vvv

# Run a single test function
forge test --match-test testMintAndTransfer -vvv

# Deploy (local anvil)
forge script script/usdy/DeployUSDY.s.sol --broadcast --rpc-url http://localhost:8545

# Deploy (Sepolia)
forge script script/usdy/DeployUSDY.s.sol --broadcast --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
```

## Project Overview

Solidity 0.8.23, Foundry-based RWA (Real World Asset) tokenization protocol targeting Singapore MAS compliance. Code comments and documentation are in Chinese.

## Architecture

Two parallel contract systems exist:

### 1. Generic RWA System (`src/token/`, `src/compliance/`, `src/finance/`, `src/oracle/`, `src/factory/`)

Factory-deployed multi-asset infrastructure using UUPS upgradeable proxies:
- `RWAToken` — Permissioned ERC-20 with KYC gating
- `KYCAllowlist` — Tiered KYC whitelist (Tier 1: $1K, Tier 2: $100K, Tier 3: unlimited)
- `SubscriptionManager` / `RedemptionManager` — T+1 settlement flows
- `NAVOracle` — Daily NAV price feed with operator signing and staleness checks
- `RWAFactory` — Deploys new RWA product instances

### 2. USDY Rebase Token System (`src/usdy/`)

Ondo Finance-inspired rebase token with T+1 settlement:

- **`USDY`** — Rebase ERC-20. Stores internal `shares`; external `balance = shares * rebaseIndex / 1e18`. When `REBASE_ROLE` increases `rebaseIndex`, all holders' balances grow automatically without transactions.
- **`USDYManager`** — T+1 subscription/redemption manager with **zero-balance design**: USDC transfers directly to `assetRecipient` (custodian), contract never holds funds. Deposit flow: `requestDeposit` → operator sets `priceId` → user `claimMint` after T+1.
- **`USDYPricer`** — NAV price oracle with T+1 claimable timestamps, staleness checks (7-day max), and 5% max daily change limit.
- **`KYCRegistry`** — Multi-group KYC verification.
- **`Blocklist`** / **`BlocklistClient`** — Internal blacklist management and mixin.

### Compliance: Three-Layer Check

Every transfer/mint/burn enforces `_checkCompliance()`:
1. **KYC** — Must be verified in `KYCRegistry` for the token's group (toggleable)
2. **Blocklist** — Must not be on internal blocklist
3. **Sanctions** — Must not be on Chainalysis OFAC sanctions list

### Roles (AccessControl)

USDY system uses granular roles: `MINTER_ROLE`, `BURNER_ROLE`, `PAUSER_ROLE`, `REBASE_ROLE`, `KYC_CONFIG_ROLE` on USDY; `OPERATOR_ROLE`, `ASSET_SENDER_ROLE` on USDYManager. The deploy script grants `MINTER_ROLE` and `BURNER_ROLE` to `USDYManager`.

### Decimal Handling

USDC uses 6 decimals, USDY uses 18 decimals. Conversion: `usdyAmount = usdcAmount * 1e12 * 1e18 / price`. Price precision is 1e18.

## Testing Patterns

Tests use forge-std `Test.sol` with `vm.startPrank`/`vm.stopPrank` for role simulation. Mock contracts (`MockSanctionsList`, `MockUSDC`) live in `src/usdy/mocks/`. Test setup deploys the full compliance stack (KYCRegistry + Blocklist + MockSanctionsList) before the core contracts.

## Key Configuration

- Solc: 0.8.23, optimizer 200 runs
- Fuzz: 1000 runs
- Remappings: `@openzeppelin/=node_modules/@openzeppelin/`, `forge-std/=lib/forge-std/src/`
- Deploy defaults: min deposit 500 USDC, max deposit 1M USDC, min redemption 100 USDY
