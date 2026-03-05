// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import "src/usdy/proxy/TokenProxy.sol";
import "src/usdy/USDY.sol";
import "src/usdy/interfaces/IMulticall.sol";

/**
 * @title USDYFactory
 * @notice USDY Token 工厂合约
 *
 * ===== 为什么需要 Factory？ =====
 *
 * 部署一个可升级的 USDY Token 需要协调多个步骤：
 *   1. 部署 Implementation 合约
 *   2. 部署 Proxy（v5 自动创建 ProxyAdmin）
 *   3. 通过 Proxy 调用 initialize()
 *   4. 设置角色权限
 *   5. 把控制权移交给 guardian（多签钱包）
 *
 * 如果手动做：
 *   - 容易遗漏（忘了 revoke 自己的权限 → 安全漏洞）
 *   - 多个交易之间有被抢跑（front-run）的风险
 *   - 不可重复、不可审计
 *
 * Factory 把所有步骤封装在一个原子交易中：
 *   - 要么全部成功，要么全部回滚
 *   - 部署完成时权限已正确配置
 *   - 过程确定、可审计
 *
 * ===== guardian 是谁？ =====
 *
 * guardian 通常是一个多签钱包（如 Gnosis Safe）
 * → 不是单个 EOA，防止单点故障
 * → 需要 N/M 签名才能执行操作
 * → 是整个协议的最终管理员
 *
 * ===== v4 vs v5 部署差异 =====
 *
 * v4 Factory（原始版本）:
 *   impl = new USDY()
 *   proxyAdmin = new ProxyAdmin()                   ← 手动创建
 *   proxy = new TokenProxy(impl, proxyAdmin, "")    ← 传 proxyAdmin 地址
 *   USDY(proxy).initialize(...)                     ← 单独调 initialize
 *   proxyAdmin.transferOwnership(guardian)           ← 手动转移所有权
 *
 * v5 Factory（本版本）:
 *   impl = new USDY()
 *   proxy = new TokenProxy(impl, guardian, initData) ← 构造函数一步完成：
 *                                                      创建 ProxyAdmin(guardian)
 *                                                      + delegatecall initialize
 *
 * v5 更简洁，但 delegatecall 时 msg.sender = Factory 地址
 * → initialize 把角色给了 Factory → 仍需权限移交
 *
 * ===== 权限移交（最关键的安全步骤） =====
 *
 * 部署时的权限状态：
 *   USDY 的 DEFAULT_ADMIN_ROLE → Factory 合约 ⚠️ 不安全
 *   USDY 的 MINTER_ROLE → Factory 合约
 *   USDY 的 PAUSER_ROLE → Factory 合约
 *   ProxyAdmin 的 owner → guardian ✓（构造时设置好了）
 *
 * 移交后的权限状态：
 *   USDY 的 DEFAULT_ADMIN_ROLE → guardian ✓
 *   USDY 的 MINTER_ROLE → 无人持有（后续按需 grant）
 *   USDY 的 PAUSER_ROLE → guardian ✓
 *   ProxyAdmin 的 owner → guardian ✓
 *
 * ===== multiexcall 的用途 =====
 *
 * 部署后可能还需要额外操作（添加白名单条款等）
 * guardian 通过 multiexcall 批量执行，一次签名搞定
 * 注意：msg.sender 是 Factory 合约，不是 guardian
 */
contract USDYFactory is IMulticall {
  // ============ 数据结构 ============

  struct USDYListData {
    address blocklist;
    address allowlist;
    address sanctionsList;
  }

  // ============ 角色常量 ============

  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

  // ============ 状态 ============

  address internal immutable guardian;
  USDY public usdyImplementation;
  TokenProxy public usdyProxy;

  // ============ 构造函数 ============

  constructor(address _guardian) {
    guardian = _guardian;
  }

  // ============ 部署函数 ============

  /**
   * @notice 一键部署可升级 USDY Token
   *
   * @return proxy          代理合约地址（用户通过此地址交互）
   * @return implementation Implementation 合约地址
   */
  function deployUSDY(
    string calldata name,
    string calldata ticker,
    USDYListData calldata listData
  ) external onlyGuardian returns (address proxy, address implementation) {
    // Step 1: 部署 Implementation
    usdyImplementation = new USDY();

    // Step 2: 编码 initialize 调用
    bytes memory initData = abi.encodeCall(
      USDY.initialize,
      (name, ticker, listData.blocklist, listData.allowlist, listData.sanctionsList)
    );

    // Step 3: 部署 Proxy（一步完成 proxy + proxyAdmin + initialize）
    //
    // 构造函数内部：
    //   a. ERC1967Proxy: upgradeToAndCall(impl, initData)
    //      → 设置 implementation 槽
    //      → delegatecall initData（msg.sender = Factory）
    //   b. TransparentUpgradeableProxy: new ProxyAdmin(guardian)
    //      → admin 固化为 immutable
    //      → ProxyAdmin.owner() = guardian
    usdyProxy = new TokenProxy(
      address(usdyImplementation),
      guardian,
      initData
    );

    // Step 4: 权限移交
    //
    // 此时 Factory 是 USDY 的 DEFAULT_ADMIN（因为 delegatecall 中 msg.sender = Factory）
    // 必须把权限转给 guardian 并 revoke 自己的
    USDY usdyProxied = USDY(address(usdyProxy));

    usdyProxied.grantRole(DEFAULT_ADMIN_ROLE, guardian);
    usdyProxied.grantRole(PAUSER_ROLE, guardian);

    // ！！！关键安全步骤：撤销 Factory 的所有角色
    // 如果忘了 → Factory 永久持有 admin 权限 → 严重安全漏洞
    usdyProxied.revokeRole(MINTER_ROLE, address(this));
    usdyProxied.revokeRole(PAUSER_ROLE, address(this));
    usdyProxied.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

    emit USDYDeployed(
      address(usdyProxy),
      address(usdyImplementation),
      name,
      ticker,
      listData
    );

    return (address(usdyProxy), address(usdyImplementation));
  }

  // ============ 批量调用 ============

  /**
   * @notice 批量执行任意外部调用
   *
   * @dev msg.sender 是 Factory 合约地址（不是 guardian）
   *      所以 target 合约看到的调用者是 Factory
   */
  function multiexcall(
    ExCallData[] calldata exCallData
  ) external payable override onlyGuardian returns (bytes[] memory results) {
    results = new bytes[](exCallData.length);
    for (uint256 i = 0; i < exCallData.length; ++i) {
      (bool success, bytes memory ret) = address(exCallData[i].target).call{
        value: exCallData[i].value
      }(exCallData[i].data);
      require(success, "Call Failed");
      results[i] = ret;
    }
  }

  // ============ 事件 ============

  event USDYDeployed(
    address proxy,
    address implementation,
    string name,
    string ticker,
    USDYListData listData
  );

  // ============ 修饰符 ============

  modifier onlyGuardian() {
    require(msg.sender == guardian, "USDYFactory: Not Guardian");
    _;
  }
}
