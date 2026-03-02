// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IBlocklist.sol";
import "./interfaces/IKYCRegistry.sol";
import "./interfaces/ISanctionsList.sol";

/**
 * @title USDY
 * @notice Rebase ERC-20 token，模拟 Ondo Finance USDY 实现
 *
 * ═══════════════════════════════════════════════════
 * Rebase 机制核心原理
 * ═══════════════════════════════════════════════════
 *
 * 普通 ERC-20：直接存储 balance[address] = amount
 *
 * Rebase ERC-20（本合约方式）：
 *   - 内部存储：shares[address]（份额，不变）
 *   - 外部余额：balance = shares * rebaseIndex / 1e18
 *   - 当运营方每天调用 setRebaseIndex() 增大 rebaseIndex 时
 *     → 所有持有人的 balanceOf() 自动增大
 *     → 不需要给每个地址发一笔交易
 *
 * 示例：
 *   Alice 存 $1000 USDC，铸造时 rebaseIndex = 1.000e18
 *   → shares[Alice] = 1000e18 / 1.000e18 = 1000
 *
 *   30天后，利率累积，rebaseIndex = 1.004e18
 *   → balanceOf(Alice) = 1000 * 1.004e18 / 1e18 = 1004 USDY
 *   → Alice 不需要任何操作，余额自动多了 4 USDY
 *
 * 为什么用 Rebase 而不是价格上涨？
 *   → 价格恒定 ~$1，适合 DeFi AMM 池（Curve stableswap）
 *   → 无常损失极低（价格不波动）
 *   → 对比：OUSG 是价格涨，余额不变
 *
 * ═══════════════════════════════════════════════════
 * 三层合规检查（_checkCompliance）
 * ═══════════════════════════════════════════════════
 *
 * 每次 transfer/mint/burn 前都会检查：
 * Layer 1: KYC 白名单 —— 必须在 KYCRegistry 中（可选开关）
 * Layer 2: Blocklist  —— 不能在 Ondo 内部黑名单中
 * Layer 3: Sanctions  —— 不能在 Chainalysis OFAC 制裁名单中
 */
contract USDY is AccessControl, Pausable {
  // ─────────────────────────────────────────────
  // 角色
  // ─────────────────────────────────────────────

  bytes32 public constant MINTER_ROLE     = keccak256("MINTER_ROLE");
  bytes32 public constant BURNER_ROLE     = keccak256("BURNER_ROLE");
  bytes32 public constant PAUSER_ROLE     = keccak256("PAUSER_ROLE");
  bytes32 public constant REBASE_ROLE     = keccak256("REBASE_ROLE");
  bytes32 public constant KYC_CONFIG_ROLE = keccak256("KYC_CONFIG_ROLE");

  // ─────────────────────────────────────────────
  // Token 元数据
  // ─────────────────────────────────────────────

  string public constant name     = "USDY";
  string public constant symbol   = "USDY";
  uint8  public constant decimals = 18;

  // ─────────────────────────────────────────────
  // Rebase 状态
  // ─────────────────────────────────────────────

  /**
   * @notice Rebase 系数，初始 1e18（代表 1.0）
   * @dev 每天由 REBASE_ROLE 调用 setRebaseIndex() 增大
   *      所有用户余额 = shares * rebaseIndex / 1e18
   */
  uint256 public rebaseIndex;

  /// @notice 精度基数
  uint256 private constant INDEX_PRECISION = 1e18;

  /// @notice 内部份额映射（不直接暴露，balanceOf 做转换）
  mapping(address => uint256) private _shares;

  /// @notice allowance 仍用 amount（外部金额）存储，符合 ERC-20 标准
  mapping(address => mapping(address => uint256)) private _allowances;

  /// @notice 总份额之和
  uint256 private _totalShares;

  // ─────────────────────────────────────────────
  // 合规组件
  // ─────────────────────────────────────────────

  IKYCRegistry   public kycRegistry;
  IBlocklist     public blocklist;
  ISanctionsList public sanctionsList;

  /// @notice USDY 对应的 KYC 分组 ID（在 KYCRegistry 中）
  uint256 public kycRequirementGroup;

  /// @notice 是否强制要求 KYC（可关闭，用于白标或测试）
  bool public kycEnabled;

  // ─────────────────────────────────────────────
  // 事件
  // ─────────────────────────────────────────────

  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);
  event RebaseIndexSet(uint256 oldIndex, uint256 newIndex, uint256 timestamp);
  event KYCRegistrySet(address indexed oldRegistry, address indexed newRegistry);
  event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);
  event SanctionsListSet(address indexed old, address indexed newAddr);

  // ─────────────────────────────────────────────
  // 构造函数
  // ─────────────────────────────────────────────

  constructor(
    address admin,
    address _kycRegistry,
    address _blocklist,
    address _sanctionsList,
    uint256 _kycRequirementGroup
  ) {
    require(admin != address(0),         "USDY: zero admin");
    require(_kycRegistry != address(0),  "USDY: zero kycRegistry");
    require(_blocklist != address(0),    "USDY: zero blocklist");
    require(_sanctionsList != address(0),"USDY: zero sanctionsList");

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MINTER_ROLE,        admin);
    _grantRole(BURNER_ROLE,        admin);
    _grantRole(PAUSER_ROLE,        admin);
    _grantRole(REBASE_ROLE,        admin);
    _grantRole(KYC_CONFIG_ROLE,    admin);

    kycRegistry           = IKYCRegistry(_kycRegistry);
    blocklist             = IBlocklist(_blocklist);
    sanctionsList         = ISanctionsList(_sanctionsList);
    kycRequirementGroup   = _kycRequirementGroup;
    kycEnabled            = true;

    // rebaseIndex 从 1.0 开始（1e18）
    rebaseIndex = INDEX_PRECISION;
  }

  // ─────────────────────────────────────────────
  // ERC-20 标准接口
  // ─────────────────────────────────────────────

  /**
   * @notice 返回总供应量（基于份额 × rebaseIndex 换算）
   */
  function totalSupply() public view returns (uint256) {
    return (_totalShares * rebaseIndex) / INDEX_PRECISION;
  }

  /**
   * @notice 返回用户余额（份额 × rebaseIndex / 1e18）
   * @dev ⚠️ 这是 Rebase 的核心：余额 = 份额 * 系数
   *     每次 rebaseIndex 增大，所有持有人的 balanceOf 自动增加
   */
  function balanceOf(address account) public view returns (uint256) {
    return (_shares[account] * rebaseIndex) / INDEX_PRECISION;
  }

  function allowance(
    address owner,
    address spender
  ) public view returns (uint256) {
    return _allowances[owner][spender];
  }

  function approve(address spender, uint256 amount) public whenNotPaused returns (bool) {
    _allowances[msg.sender][spender] = amount;
    emit Approval(msg.sender, spender, amount);
    return true;
  }

  function transfer(address to, uint256 amount) public whenNotPaused returns (bool) {
    _transfer(msg.sender, to, amount);
    return true;
  }

  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) public whenNotPaused returns (bool) {
    uint256 currentAllowance = _allowances[from][msg.sender];
    require(currentAllowance >= amount, "USDY: insufficient allowance");
    unchecked {
      _allowances[from][msg.sender] = currentAllowance - amount;
    }
    _transfer(from, to, amount);
    return true;
  }

  // ─────────────────────────────────────────────
  // 内部转账逻辑（含合规检查）
  // ─────────────────────────────────────────────

  function _transfer(address from, address to, uint256 amount) internal {
    require(from != address(0), "USDY: from zero address");
    require(to   != address(0), "USDY: to zero address");

    // 三层合规检查（发送方 + 接收方）
    _checkCompliance(from);
    _checkCompliance(to);

    // amount → shares 转换
    // ⚠️ 关键：转账时用份额操作，amount 只是界面单位
    uint256 sharesAmount = _amountToShares(amount);
    require(_shares[from] >= sharesAmount, "USDY: insufficient balance");

    unchecked {
      _shares[from] -= sharesAmount;
    }
    _shares[to] += sharesAmount;

    emit Transfer(from, to, amount);
  }

  // ─────────────────────────────────────────────
  // Mint / Burn（只供 USDYManager 调用）
  // ─────────────────────────────────────────────

  /**
   * @notice 铸造 USDY
   * @dev 由 USDYManager 在用户 claimMint 时调用
   *      amount 会换算成份额后存储
   */
  function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
    require(to != address(0), "USDY: mint to zero address");
    _checkCompliance(to);

    uint256 sharesAmount = _amountToShares(amount);
    _shares[to]   += sharesAmount;
    _totalShares  += sharesAmount;

    emit Transfer(address(0), to, amount);
  }

  /**
   * @notice 销毁 USDY
   * @dev 由 USDYManager 在用户 requestRedemption 时调用
   */
  function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) whenNotPaused {
    require(from != address(0), "USDY: burn from zero address");

    uint256 sharesAmount = _amountToShares(amount);
    require(_shares[from] >= sharesAmount, "USDY: burn amount exceeds balance");

    unchecked {
      _shares[from] -= sharesAmount;
      _totalShares  -= sharesAmount;
    }

    emit Transfer(from, address(0), amount);
  }

  // ─────────────────────────────────────────────
  // Rebase 操作
  // ─────────────────────────────────────────────

  /**
   * @notice 更新 rebaseIndex（每日由运营方调用）
   * @dev ⚠️ 新 index 必须大于等于旧 index（不允许 deflation）
   *      调用后，所有持有人的 balanceOf 立即增加
   * @param newIndex 新的 rebase 系数（精度 1e18）
   */
  function setRebaseIndex(uint256 newIndex) external onlyRole(REBASE_ROLE) {
    require(newIndex >= rebaseIndex, "USDY: rebase index cannot decrease");
    uint256 oldIndex = rebaseIndex;
    rebaseIndex = newIndex;
    emit RebaseIndexSet(oldIndex, newIndex, block.timestamp);
  }

  // ─────────────────────────────────────────────
  // 合规工具函数
  // ─────────────────────────────────────────────

  /**
   * @notice 三层合规检查
   * @dev Layer 1: KYC（可选）
   *      Layer 2: Blocklist（Ondo 内部黑名单）
   *      Layer 3: Sanctions（Chainalysis OFAC 制裁名单）
   */
  function _checkCompliance(address account) internal view {
    // Layer 1: KYC 检查（仅在 kycEnabled 时）
    if (kycEnabled) {
      require(
        kycRegistry.isKYCVerified(account, kycRequirementGroup),
        "USDY: account not KYC verified"
      );
    }

    // Layer 2: 内部黑名单
    require(!blocklist.isBlocked(account), "USDY: account is blocked");

    // Layer 3: OFAC 制裁名单（Chainalysis 实时链上数据）
    require(!sanctionsList.isSanctioned(account), "USDY: account is sanctioned");
  }

  // ─────────────────────────────────────────────
  // 份额 ↔ 金额换算
  // ─────────────────────────────────────────────

  /**
   * @notice amount（外部金额）→ shares（内部份额）
   * @dev shares = amount * 1e18 / rebaseIndex
   *      当 rebaseIndex = 1e18 时，1 amount = 1 share
   *      当 rebaseIndex = 1.01e18 时，1 amount = 0.99 share（份额少了，但价值一样）
   */
  function _amountToShares(uint256 amount) internal view returns (uint256) {
    return (amount * INDEX_PRECISION) / rebaseIndex;
  }

  /**
   * @notice shares → amount（对外查询用）
   */
  function _sharesToAmount(uint256 shares) internal view returns (uint256) {
    return (shares * rebaseIndex) / INDEX_PRECISION;
  }

  /**
   * @notice 查询某地址持有的份额（原始值）
   * @dev 用于高精度计算，避免除法损失
   */
  function sharesOf(address account) external view returns (uint256) {
    return _shares[account];
  }

  // ─────────────────────────────────────────────
  // 管理员配置
  // ─────────────────────────────────────────────

  function setKYCRegistry(address _kycRegistry) external onlyRole(KYC_CONFIG_ROLE) {
    require(_kycRegistry != address(0), "USDY: zero address");
    emit KYCRegistrySet(address(kycRegistry), _kycRegistry);
    kycRegistry = IKYCRegistry(_kycRegistry);
  }

  function setBlocklist(address _blocklist) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_blocklist != address(0), "USDY: zero address");
    emit BlocklistSet(address(blocklist), _blocklist);
    blocklist = IBlocklist(_blocklist);
  }

  function setSanctionsList(address _sanctionsList) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_sanctionsList != address(0), "USDY: zero address");
    emit SanctionsListSet(address(sanctionsList), _sanctionsList);
    sanctionsList = ISanctionsList(_sanctionsList);
  }

  function setKYCEnabled(bool enabled) external onlyRole(KYC_CONFIG_ROLE) {
    kycEnabled = enabled;
  }

  function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
  function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
