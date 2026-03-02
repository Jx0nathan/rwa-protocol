// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/usdy/USDY.sol";
import "../../src/usdy/USDYManager.sol";
import "../../src/usdy/USDYPricer.sol";
import "../../src/usdy/KYCRegistry.sol";
import "../../src/usdy/Blocklist.sol";

/**
 * @title DeployUSDY
 * @notice USDY 系统完整部署脚本
 *
 * 部署顺序（有依赖关系）：
 *   1. KYCRegistry    （无依赖）
 *   2. Blocklist      （无依赖）
 *   3. USDY           （依赖 KYCRegistry + Blocklist + SanctionsList）
 *   4. USDYPricer     （无依赖）
 *   5. USDYManager    （依赖 USDY + USDYPricer + USDC）
 *   6. 权限配置        （MINTER/BURNER 授给 Manager）
 *
 * 运行（本地 anvil）：
 *   forge script script/usdy/DeployUSDY.s.sol --broadcast --rpc-url http://localhost:8545
 *
 * 运行（Sepolia testnet）：
 *   forge script script/usdy/DeployUSDY.s.sol --broadcast --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
 */
contract DeployUSDY is Script {
  // ─────────────────────────────────────────────
  // 配置（测试网）
  // ─────────────────────────────────────────────

  // Sepolia USDC（Circle 官方测试地址）
  address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

  // Chainlink ETH/USD（Sepolia，仅供参考；生产用 T-bills rate）
  address constant CHAINLINK_SEPOLIA = address(0); // 暂不配置

  // Chainalysis SanctionsList（主网地址，测试网无效）
  address constant SANCTIONS_MAINNET = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;

  // 最小认购：500 USDC
  uint256 constant MIN_DEPOSIT = 500_000000;

  // 最大认购：1,000,000 USDC
  uint256 constant MAX_DEPOSIT = 1_000_000_000000;

  // 最小赎回：100 USDY
  uint256 constant MIN_REDEMPTION = 100e18;

  // KYC 分组 ID（1 = USDY 标准 KYC）
  uint256 constant KYC_GROUP = 1;

  function run() external {
    uint256 deployerKey = vm.envUint("PRIVATE_KEY");
    address admin = vm.addr(deployerKey);
    address assetRecipient = vm.envAddress("ASSET_RECIPIENT"); // Coinbase Custody 地址

    console.log("Deploying USDY system...");
    console.log("Admin:", admin);
    console.log("AssetRecipient:", assetRecipient);

    vm.startBroadcast(deployerKey);

    // ── Step 1: KYCRegistry ──────────────────────
    KYCRegistry kyc = new KYCRegistry(admin);
    console.log("KYCRegistry:", address(kyc));

    // ── Step 2: Blocklist ────────────────────────
    Blocklist blocklist = new Blocklist(admin);
    console.log("Blocklist:", address(blocklist));

    // ── Step 3: USDY Token ───────────────────────
    // 生产环境：使用真实 Chainalysis 地址
    // 测试环境：需要先部署 MockSanctionsList
    address sanctionsAddr = block.chainid == 1
      ? SANCTIONS_MAINNET
      : address(0); // ⚠️ 测试网：需替换为 MockSanctionsList 地址

    require(sanctionsAddr != address(0), "DeployUSDY: set sanctions address");

    USDY usdy = new USDY(
      admin,
      address(kyc),
      address(blocklist),
      sanctionsAddr,
      KYC_GROUP
    );
    console.log("USDY:", address(usdy));

    // ── Step 4: USDYPricer ───────────────────────
    USDYPricer pricer = new USDYPricer(admin, CHAINLINK_SEPOLIA);
    console.log("USDYPricer:", address(pricer));

    // ── Step 5: USDYManager ──────────────────────
    address usdcAddr = block.chainid == 1
      ? 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48  // 主网 USDC
      : USDC_SEPOLIA;                                 // 测试网 USDC

    USDYManager manager = new USDYManager(
      admin,
      address(usdy),
      address(pricer),
      usdcAddr,
      assetRecipient,
      MIN_DEPOSIT,
      MAX_DEPOSIT,
      MIN_REDEMPTION
    );
    console.log("USDYManager:", address(manager));

    // ── Step 6: 权限配置 ─────────────────────────
    usdy.grantRole(usdy.MINTER_ROLE(), address(manager));
    usdy.grantRole(usdy.BURNER_ROLE(), address(manager));
    console.log("Granted MINTER_ROLE + BURNER_ROLE to USDYManager");

    vm.stopBroadcast();

    // ── 输出部署汇总 ─────────────────────────────
    console.log("\n=== USDY Deployment Summary ===");
    console.log("KYCRegistry:  ", address(kyc));
    console.log("Blocklist:    ", address(blocklist));
    console.log("USDY Token:   ", address(usdy));
    console.log("USDYPricer:   ", address(pricer));
    console.log("USDYManager:  ", address(manager));
  }
}
