// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/usdy/USDY.sol";
import "../../src/usdy/USDYManager.sol";
import "../../src/usdy/USDYPricer.sol";
import "../../src/usdy/KYCRegistry.sol";
import "../../src/usdy/Blocklist.sol";
import "../../src/usdy/mocks/MockSanctionsList.sol";
import "../../src/usdy/mocks/MockUSDC.sol";

/**
 * @title USDYManagerTest
 * @notice T+1 认购/赎回流程测试
 *
 * 运行方式：
 *   forge test --match-contract USDYManagerTest -vvv
 */
contract USDYManagerTest is Test {
  // 合约实例
  USDY              public usdy;
  USDYManager       public manager;
  USDYPricer        public pricer;
  KYCRegistry       public kyc;
  Blocklist         public blocklist;
  MockSanctionsList public sanctions;
  MockUSDC          public mockUsdc;

  // 角色地址
  address admin          = address(0x1);
  address alice          = address(0x2);  // 用户
  address bob            = address(0x3);  // 用户
  address assetRecipient = address(0x9);  // 模拟 Coinbase Custody

  uint256 constant KYC_GROUP = 1;

  // 初始价格：1.000 USDC per USDY
  uint256 constant INITIAL_PRICE = 1_000_000_000_000_000_000; // 1.0e18

  function setUp() public {
    vm.startPrank(admin);

    // 1. 部署合规组件
    sanctions = new MockSanctionsList();
    kyc       = new KYCRegistry(admin);
    blocklist = new Blocklist(admin);
    mockUsdc  = new MockUSDC();

    // 2. 部署 USDY token
    usdy = new USDY(
      admin,
      address(kyc),
      address(blocklist),
      address(sanctions),
      KYC_GROUP
    );

    // 3. 部署 Pricer（无 Chainlink，传 address(0)）
    pricer = new USDYPricer(admin, address(0));

    // 4. 部署 Manager
    manager = new USDYManager(
      admin,
      address(usdy),
      address(pricer),
      address(mockUsdc),
      assetRecipient,
      500_000000,    // 最小认购 500 USDC
      1_000_000_000000, // 最大认购 1,000,000 USDC
      100e18         // 最小赎回 100 USDY
    );

    // 5. 给 manager 授权 mint/burn USDY
    usdy.grantRole(usdy.MINTER_ROLE(), address(manager));
    usdy.grantRole(usdy.BURNER_ROLE(), address(manager));

    // 6. KYC 白名单
    address[] memory accounts = new address[](2);
    accounts[0] = alice;
    accounts[1] = bob;
    kyc.addKYCAddresses(KYC_GROUP, accounts);

    vm.stopPrank();

    // 7. 给用户 mint USDC
    mockUsdc.mint(alice, 10_000_000000); // 10,000 USDC
    mockUsdc.mint(bob,   10_000_000000);
  }

  // ─────────────────────────────────────────────
  // 完整 T+1 认购流程测试
  // ─────────────────────────────────────────────

  /**
   * @notice 测试完整认购流程：requestDeposit → 运营方设置价格 → claimMint
   */
  function test_FullDepositFlow_T1() public {
    uint256 depositAmount = 1000_000000; // 1000 USDC

    // Step 1: Alice approve + requestDeposit
    vm.startPrank(alice);
    mockUsdc.approve(address(manager), depositAmount);
    uint256 depositId = manager.requestDeposit(depositAmount);
    vm.stopPrank();

    // 验证：USDC 已转到 assetRecipient（不在合约）
    assertEq(mockUsdc.balanceOf(assetRecipient), depositAmount);
    assertEq(mockUsdc.balanceOf(address(manager)), 0, "manager should hold zero USDC");

    // Step 2: 运营方设置价格（T+1 = 明天）
    vm.startPrank(admin);
    uint256 claimableAt = block.timestamp + 1 days;
    uint256 priceId = pricer.addPrice(INITIAL_PRICE, claimableAt);

    // 绑定 depositId 到 priceId
    uint256[] memory ids = new uint256[](1);
    ids[0] = depositId;
    manager.setPriceIdForDeposits(ids, priceId);
    vm.stopPrank();

    // Step 3: T+1 时间到，Alice claimMint
    vm.warp(block.timestamp + 1 days + 1); // 快进时间
    vm.prank(alice);
    manager.claimMint(depositId);

    // 验证：Alice 收到 USDY
    // price = 1.0，所以 1000 USDC → 1000 USDY（需要 6位 → 18位换算）
    assertApproxEqAbs(usdy.balanceOf(alice), 1000e18, 1e15);
  }

  /**
   * @notice T+1 未到时不能 claimMint
   */
  function test_ClaimMint_TooEarly_Reverts() public {
    uint256 depositAmount = 1000_000000;

    vm.startPrank(alice);
    mockUsdc.approve(address(manager), depositAmount);
    uint256 depositId = manager.requestDeposit(depositAmount);
    vm.stopPrank();

    vm.startPrank(admin);
    uint256 priceId = pricer.addPrice(INITIAL_PRICE, block.timestamp + 1 days);
    uint256[] memory ids = new uint256[](1);
    ids[0] = depositId;
    manager.setPriceIdForDeposits(ids, priceId);
    vm.stopPrank();

    // 不快进时间，立刻 claim → 应该 revert
    vm.prank(alice);
    vm.expectRevert("USDYManager: too early, T+1 not reached");
    manager.claimMint(depositId);
  }

  /**
   * @notice priceId 未绑定时不能 claimMint
   */
  function test_ClaimMint_PriceNotSet_Reverts() public {
    uint256 depositAmount = 1000_000000;

    vm.startPrank(alice);
    mockUsdc.approve(address(manager), depositAmount);
    uint256 depositId = manager.requestDeposit(depositAmount);

    // 直接 claimMint，运营方还没绑定 priceId
    vm.expectRevert("USDYManager: priceId not set yet, wait for operator");
    manager.claimMint(depositId);
    vm.stopPrank();
  }

  // ─────────────────────────────────────────────
  // 赎回流程测试
  // ─────────────────────────────────────────────

  /**
   * @notice 测试赎回流程：requestRedemption → completeRedemption
   */
  function test_FullRedemptionFlow() public {
    // 先给 Alice mint 一些 USDY
    vm.prank(admin);
    usdy.mint(alice, 1000e18);

    // Alice 申请赎回 500 USDY
    vm.prank(alice);
    uint256 redemptionId = manager.requestRedemption(500e18);

    // 验证：USDY 已被销毁
    assertEq(usdy.balanceOf(alice), 500e18);

    // 运营方结算：给 alice 打回 USDC
    // 先给 admin 一些 USDC（模拟从托管方提取）
    mockUsdc.mint(admin, 500_000000);
    vm.startPrank(admin);
    mockUsdc.approve(address(manager), 500_000000);
    manager.completeRedemption(redemptionId, 500_000000);
    vm.stopPrank();

    // 验证：Alice 收到 USDC
    assertEq(mockUsdc.balanceOf(alice), 10_000_000000 + 500_000000);
  }

  // ─────────────────────────────────────────────
  // TODO: 复写练习区
  // ─────────────────────────────────────────────

  /**
   * @notice TODO: 测试 NAV 涨价后，相同 USDC 铸造的 USDY 更少
   * @dev 验证：price = 1.004e18 时，1000 USDC 只能铸 ~996 USDY
   */
  function test_TODO_HigherNAV_MintsFewer_USDY() public {
    // TODO: 自己实现
    // 1. alice 认购 1000 USDC
    // 2. 运营方设置价格 1.004e18
    // 3. claimMint
    // 4. 验证 usdy.balanceOf(alice) ≈ 996e18
  }

  /**
   * @notice TODO: 测试 rebase 后赎回能拿到更多 USDC
   * @dev 收益已经体现在 USDY 数量上（rebase 增多了），
   *      赎回时运营方按实时 NAV 结算
   */
  function test_TODO_Rebase_Then_Redeem_MoreUSDC() public {
    // TODO: 自己实现
  }
}
