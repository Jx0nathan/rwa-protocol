// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/usdy/blocklist/BlocklistClientUpgradeable.sol";
import "src/usdy/allowlist/AllowlistClientUpgradeable.sol";
import "src/usdy/sanctions/SanctionsListClientUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract USDY is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    BlocklistClientUpgradeable,
    AllowlistClientUpgradeable,
    SanctionsListClientUpgradeable
{
    // ============ 角色常量 ============
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant LIST_CONFIGURER_ROLE =
        keccak256("LIST_CONFIGURER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // ============ 初始化 ============

    /**
     * @notice 初始化 USDY Token — 替代 constructor
     *
     * 逐个初始化每个模块：
     *   initialize() ← initializer（开门）
     *     ├─ __ERC20_init(name, symbol)                   ← 设置代币名称和符号
     *     ├─ __ERC20Burnable_init()                       ← 初始化可销毁模块
     *     ├─ __ERC20Pausable_init()                       ← 初始化可暂停模块
     *     ├─ __AccessControl_init()                       ← 初始化角色管理
     *     ├─ __BlocklistClientInitializable_init()        ← 黑名单引用
     *     ├─ __AllowlistClientInitializable_init()        ← 白名单引用
     *     └─ __SanctionsListClientInitializable_init()    ← 制裁名单引用
     *   initialize() 结束 ← initializer（关门）
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _blocklist,
        address _allowlist,
        address _sanctionsList
    ) public initializer {
        __ERC20_init(_name, _symbol); // 设置代币名称和符号
        __ERC20Burnable_init(); // 初始化可销毁模块
        __ERC20Pausable_init(); // 初始化可暂停模块
        __AccessControl_init(); // 初始化角色管理

        // 角色分配
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        __BlocklistClientInitializable_init(_blocklist); // 黑名单引用
        __AllowlistClientInitializable_init(_allowlist); // 白名单引用
        __SanctionsListClientInitializable_init(_sanctionsList); // 制裁名单引用
    }

    // ============ Mint / Pause / Unpause ============
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============ 列表管理（LIST_CONFIGURER_ROLE） ============

    function setBlocklist(
        address _blocklist
    ) external override onlyRole(LIST_CONFIGURER_ROLE) {
        _setBlocklist(_blocklist);
    }

    function setAllowlist(
        address _allowlist
    ) external override onlyRole(LIST_CONFIGURER_ROLE) {
        _setAllowlist(_allowlist);
    }

    function setSanctionsList(
        address _sanctionsList
    ) external override onlyRole(LIST_CONFIGURER_ROLE) {
        _setSanctionsList(_sanctionsList);
    }

    // ============ 核心：转账合规检查 ============

    /**
     * @notice 三重合规检查 — v5 用 _update 替代 _beforeTokenTransfer
     *
     * v5: _update() → 先执行自定义逻辑 → 然后 super._update() 修改余额
     *
     * ===== override 多个父合约 =====
     *
     * ERC20Upgradeable 和 ERC20PausableUpgradeable 都定义了 _update
     * 所以必须声明 override(ERC20Upgradeable, ERC20PausableUpgradeable)
     * super._update() 会按继承顺序调用最近的父合约（ERC20PausableUpgradeable）
     * → 它会检查是否暂停 → 然后调用 ERC20Upgradeable._update() → 修改余额
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        // === 检查 msg.sender（调用者）===
        // 当第三方帮别人转账 (transferFrom) 时，必须通过合规检查
        // 如果不检查，可能会出现：被制裁地址 -> approve -> 第三方合约 -> 转走资金（这样就绕过合规规则了）
        if (from != msg.sender && to != msg.sender) {
            require(!_isBlocked(msg.sender), "USDY: 'sender' address blocked");
            require(
                !_isSanctioned(msg.sender),
                "USDY: 'sender' address sanctioned"
            );
            require(
                _isAllowed(msg.sender),
                "USDY: 'sender' address not on allowlist"
            );
        }

        // === 检查 from（发送方）===
        // mint 时 from = address(0)，跳过
        if (from != address(0)) {
            require(!_isBlocked(from), "USDY: 'from' address blocked");
            require(!_isSanctioned(from), "USDY: 'from' address sanctioned");
            require(_isAllowed(from), "USDY: 'from' address not on allowlist");
        }

        // === 检查 to（接收方）===
        // burn 时 to = address(0)，跳过
        if (to != address(0)) {
            require(!_isBlocked(to), "USDY: 'to' address blocked");
            require(!_isSanctioned(to), "USDY: 'to' address sanctioned");
            require(_isAllowed(to), "USDY: 'to' address not on allowlist");
        }

        // 所有检查通过后，调用 super._update 执行实际的余额修改
        super._update(from, to, value);
    }

    // ============ 管理员销毁 ============

    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }
}
