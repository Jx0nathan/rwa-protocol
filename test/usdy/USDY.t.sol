// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/usdy/USDY.sol";
import "../../src/usdy/KYCRegistry.sol";
import "../../src/usdy/Blocklist.sol";
import "../../src/usdy/mocks/MockSanctionsList.sol";

/**
 * @title USDYTest
 * @notice USDY Rebase token 单元测试
 *
 * 运行方式：
 *   forge test --match-contract USDYTest -vvv
 */
contract USDYTest is Test {
  USDY              public usdy;
  KYCRegistry       public kyc;
  Blocklist         public blocklist;
  MockSanctionsList public sanctions;

  address admin  = address(0x1);
  address alice  = address(0x2);
  address bob    = address(0x3);
  address badGuy = address(0x4);

  uint256 constant KYC_GROUP = 1;

  function setUp() public {
    vm.startPrank(admin);

    // 部署合规组件
    sanctions = new MockSanctionsList();
    kyc       = new KYCRegistry(admin);
    blocklist = new Blocklist(admin);

    // 部署 USDY
    usdy = new USDY(
      admin,
      address(kyc),
      address(blocklist),
      address(sanctions),
      KYC_GROUP
    );

    // KYC 白名单加入 alice 和 bob
    address[] memory accounts = new address[](2);
    accounts[0] = alice;
    accounts[1] = bob;
    kyc.addKYCAddresses(KYC_GROUP, accounts);

    vm.stopPrank();
  }

  // ─────────────────────────────────────────────
  // Rebase 机制测试
  // ─────────────────────────────────────────────

  function test_MintAndBalanceOf() public {
    vm.prank(admin);
    usdy.mint(alice, 1000e18);

    assertEq(usdy.balanceOf(alice), 1000e18);
  }

  /**
   * @notice 测试 rebaseIndex 增大后余额自动增加
   * @dev 这是 USDY 最核心的机制：不发 token，通过更新系数让所有人余额增加
   */
  function test_Rebase_BalanceIncreases() public {
    vm.startPrank(admin);
    usdy.mint(alice, 1000e18);

    // 模拟 30 天后，rebaseIndex 从 1.0 增加到 1.004（年化约 5%）
    uint256 newIndex = 1_004_000_000_000_000_000; // 1.004e18
    usdy.setRebaseIndex(newIndex);
    vm.stopPrank();

    // Alice 的余额应该从 1000 增加到 1004
    // balanceOf = shares * rebaseIndex / 1e18
    assertApproxEqAbs(usdy.balanceOf(alice), 1004e18, 1e15); // 允许 0.001 误差
  }

  /**
   * @notice 测试两个用户有相同份额时，rebase 后余额同等比例增加
   */
  function test_Rebase_ProportionalForAllHolders() public {
    vm.startPrank(admin);
    usdy.mint(alice, 1000e18);
    usdy.mint(bob,   2000e18);

    usdy.setRebaseIndex(1_050_000_000_000_000_000); // 1.05
    vm.stopPrank();

    // Alice: 1000 * 1.05 = 1050
    // Bob:   2000 * 1.05 = 2100
    assertApproxEqAbs(usdy.balanceOf(alice), 1050e18, 1e15);
    assertApproxEqAbs(usdy.balanceOf(bob),   2100e18, 1e15);
  }

  /**
   * @notice rebaseIndex 只能增大，不能减小
   */
  function test_Rebase_CannotDecrease() public {
    vm.startPrank(admin);
    usdy.setRebaseIndex(1_050_000_000_000_000_000);

    vm.expectRevert("USDY: rebase index cannot decrease");
    usdy.setRebaseIndex(1_000_000_000_000_000_000); // 回到 1.0，应该失败
    vm.stopPrank();
  }

  // ─────────────────────────────────────────────
  // 合规测试
  // ─────────────────────────────────────────────

  /**
   * @notice KYC 未通过的地址不能接收 USDY
   */
  function test_Compliance_KYC_Blocks_NonKYC() public {
    vm.prank(admin);
    // badGuy 没有加入 KYC 白名单，mint 应该失败
    vm.expectRevert("USDY: account not KYC verified");
    usdy.mint(badGuy, 100e18);
  }

  /**
   * @notice 被 blocklist 的地址不能转账
   */
  function test_Compliance_Blocklist_Blocks_Transfer() public {
    vm.startPrank(admin);
    usdy.mint(alice, 1000e18);

    // 封禁 bob
    blocklist.addToBlocklist(bob);
    vm.stopPrank();

    // alice 转给 bob 应该失败
    vm.prank(alice);
    vm.expectRevert("USDY: account is blocked");
    usdy.transfer(bob, 100e18);
  }

  /**
   * @notice 被制裁的地址不能转账
   */
  function test_Compliance_Sanctions_Blocks_Transfer() public {
    vm.startPrank(admin);
    usdy.mint(alice, 1000e18);

    // 将 alice 加入制裁名单
    sanctions.addSanctionedAddress(alice);
    vm.stopPrank();

    vm.prank(alice);
    vm.expectRevert("USDY: account is sanctioned");
    usdy.transfer(bob, 100e18);
  }

  // ─────────────────────────────────────────────
  // TODO: 复写练习区
  // ─────────────────────────────────────────────

  /**
   * @notice TODO: 测试 transfer 时 shares 正确更新
   * @dev 复写要点：transfer amount 时，实际操作的是 shares
   *      转 100 USDY（rebaseIndex=1.05）→ 实际转 95.23 shares
   */
  function test_TODO_Transfer_SharesAccounting() public {
    // TODO: 自己写这个测试
  }

  /**
   * @notice TODO: 测试 KYC disabled 时任何人都能转账
   */
  function test_TODO_KYCDisabled_AllowsTransfer() public {
    // TODO: 调用 usdy.setKYCEnabled(false) 后验证 badGuy 能收到 token
  }
}
