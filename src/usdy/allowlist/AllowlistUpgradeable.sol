// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "src/usdy/interfaces/IAllowlist.sol";

contract AllowlistUpgradeable is
    Initializable,
    AccessControlEnumerableUpgradeable,
    IAllowlist
{
    // ============ 角色常量 ============
    // keccak256 哈希在编译时计算，运行时是常量，不占 storage slot
    bytes32 public constant ALLOWLIST_ADMIN = keccak256("ALLOWLIST_ADMIN");
    bytes32 public constant ALLOWLIST_SETTER = keccak256("ALLOWLIST_SETTER");

    // ============ 存储 ============

    /**
     * 核心数据结构：嵌套 mapping
     *
     * verifications[用户地址][条款索引] = 是否已验证
     *
     * 例如：
     *   verifications[alice][0] = true   → alice 签署了第 0 版条款
     *   verifications[alice][1] = false  → alice 没有签署第 1 版条款
     *   verifications[bob][1]   = true   → bob 签署了第 1 版条款
     */
    mapping(address => mapping(uint256 => bool)) public verifications;

    /// @notice 所有条款文本（只增不减）
    string[] public terms;

    /// @notice 当前条款索引（新用户应该签署的版本）
    uint256 public currentTermIndex = 0;

    /// @notice 有效条款索引列表（用户签过其中任意一个就被允许）
    uint256[] public validIndexes;

    // ============ 构造函数 ============

    /**
     * ===== _disableInitializers() 是什么？ =====
     *
     * 在 Proxy 模式下，合约分两部分：
     * - Implementation：包含逻辑代码（这个合约本身）
     * - Proxy：用户实际交互的地址，delegatecall 到 implementation
     *
     * initialize() 应该只在 Proxy 上调用（通过 Proxy 的 constructor）
     * 如果有人直接对 Implementation 调用 initialize()，就获得了 admin 权限
     *
     * _disableInitializers() 在 Implementation 的 constructor 里调用，
     * 确保 Implementation 合约自身永远不能被 initialize
     *
     *   Implementation: constructor() → _disableInitializers() → initialize 被锁死
     *   Proxy: constructor(impl, data) → delegatecall initialize() → 正常初始化
     */
    /// @dev 禁止 Implementation 合约被直接 initialize
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 初始化函数 — 替代 constructor
     *
     * initializer 修饰符确保只能调用一次
     * 如果有人第二次调用，会 revert
     *
     * @param admin  获得 DEFAULT_ADMIN_ROLE + ALLOWLIST_ADMIN
     * @param setter 获得 ALLOWLIST_SETTER
     */
    function initialize(address admin, address setter) public initializer {
        // _grantRole 是 AccessControl 的内部函数
        // 直接写 storage，不触发 external 调用
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ALLOWLIST_ADMIN, admin);
        _grantRole(ALLOWLIST_SETTER, setter);
    }

    // ============ 查询函数 ============

    /// @notice 获取所有有效的条款索引
    function getValidTermIndexes() external view override returns (uint256[] memory) {
        return validIndexes;
    }

    /// @notice 获取当前条款文本
    function getCurrentTerm() external view override returns (string memory) {
        return terms[currentTermIndex];
    }

    // ============ 条款管理（ALLOWLIST_ADMIN） ============

    /**
     * @notice 添加新条款版本
     * @param term 条款文本（如 "I agree to USDY Terms of Service v2"）
     *
     * 流程：
     * 1. push 到 terms 数组
     * 2. 自动设为 currentTermIndex
     * 3. 注意：新条款还不是 "有效" 的！必须通过 setValidTermIndexes 才生效
     *    这是有意的设计 — 管理员可以先添加条款，等审核完再激活
     */
    function addTerm(string calldata term) external override onlyRole(ALLOWLIST_ADMIN) {
        terms.push(term);
        setCurrentTermIndex(terms.length - 1);
        emit TermAdded(keccak256(bytes(term)), terms.length - 1);
    }

    /**
     * @notice 设置当前条款索引
     * @dev 注意这是 public 不是 external — 因为 addTerm() 内部要调用它
     *      external 函数不能被同合约的其他函数调用
     */
    function setCurrentTermIndex(uint256 _currentTermIndex) public override onlyRole(ALLOWLIST_ADMIN) {
        if (_currentTermIndex >= terms.length) {
            revert InvalidTermIndex();
        }
        uint256 oldIndex = currentTermIndex;
        currentTermIndex = _currentTermIndex;
        emit CurrentTermIndexSet(oldIndex, _currentTermIndex);
    }

    /**
     * @notice 设置哪些条款版本是有效的 — 核心治理函数
     * @param _validIndexes 有效条款索引数组
     *
     * 例如：
     *   setValidTermIndexes([0, 1])  → 签了 v0 或 v1 的用户都被允许
     *   setValidTermIndexes([1])     → 只有签了 v1 的用户被允许（v0 失效）
     *   setValidTermIndexes([])      → 所有 EOA 都不被允许（紧急暂停）
     *
     * 这是原子操作 — 直接替换整个数组，不是增量修改
     */
    function setValidTermIndexes(uint256[] calldata _validIndexes) external override onlyRole(ALLOWLIST_ADMIN) {
        // 校验所有索引都在范围内
        for (uint256 i; i < _validIndexes.length; ++i) {
            if (_validIndexes[i] >= terms.length) {
                revert InvalidTermIndex();
            }
        }
        uint256[] memory oldIndexes = validIndexes;
        validIndexes = _validIndexes;
        emit ValidTermIndexesSet(oldIndexes, _validIndexes);
    }

    // ============ 核心判断逻辑 ============

    /**
     * @notice 检查地址是否被允许
     *
     * 判断逻辑：
     * 1. 合约地址 → 直接允许（不需要签条款）
     * 2. EOA → 遍历 validIndexes，只要签过其中任意一个版本就允许
     *
     * 为什么合约地址自动豁免？
     * - 合约不能 "签署" 条款（没有私钥）
     * - 如果不豁免，所有 DeFi 集成（Uniswap 池、lending 协议等）都会被阻断
     * - 如果某个合约需要被禁止，用 Blocklist 拉黑它
     */
    function isAllowed(address account) external view override returns (bool) {
        // 合约地址自动允许（OZ v5 移除了 Address.isContract，直接用 code.length）
        if (account.code.length > 0) {
            return true;
        }

        // EOA：遍历有效条款，只要签过一个就通过
        // 用局部变量缓存 length → 避免每次循环都读 storage（省 gas）
        uint256 validIndexesLength = validIndexes.length;
        for (uint256 i; i < validIndexesLength; ++i) {
            if (verifications[account][validIndexes[i]]) {
                return true;
            }
        }
        return false;
    }

    // ============ 用户上白名单 — 三种路径 ============

    /**
     * @notice 路径 1：用户自助注册
     *
     * 最简单的路径：用户直接调用，同意某个版本的条款
     * 没有任何权限限制 — 任何人都可以调用
     *
     * 为什么检查 AlreadyVerified？
     * - 防止重复操作浪费 gas
     * - 事件不应重复 emit（链下索引会计算错误）
     */
    function addSelfToAllowlist(uint256 termIndex) external override {
        if (verifications[msg.sender][termIndex]) {
            revert AlreadyVerified();
        }
        _setAccountStatus(msg.sender, termIndex, true);
        emit AccountAddedSelf(msg.sender, termIndex);
    }

    /**
     * @notice 路径 2：通过签名注册
     *
     * ===== 新概念 3：ECDSA 签名验证 =====
     *
     * 场景：用户在前端离线签署条款文本，然后由第三方（relayer）提交到链上
     * 好处：
     * - 用户不需要自己发交易（gas 由 relayer 承担）
     * - 可以批量提交（一笔交易处理多个用户的签名）
     *
     * 签名流程：
     * 1. 前端获取条款文本：terms[termIndex]
     * 2. 用户用钱包签名：sign(terms[termIndex])
     *    → 产生 (v, r, s) 三个值
     * 3. Relayer 调用本函数，提交 (termIndex, account, v, r, s)
     * 4. 合约验证：用 (v, r, s) 恢复签名者地址，必须等于 account
     *
     * v: 恢复标识符（27 或 28）
     * r: 签名的前 32 字节
     * s: 签名的后 32 字节
     */
    function addAccountToAllowlist(
        uint256 termIndex,
        address account,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        // 检查未验证过
        if (verifications[account][termIndex]) {
            revert AlreadyVerified();
        }

        // v 必须是 27 或 28（以太坊签名标准）
        if (v != 27 && v != 28) {
            revert InvalidVSignature();
        }

        // 1. 对条款文本做 keccak256 哈希
        // 2. 加上以太坊签名前缀 "\x19Ethereum Signed Message:\n"
        //    → 这是 EIP-191 标准，防止签名被用于伪造交易
        bytes32 hashedMessage = MessageHashUtils.toEthSignedMessageHash(
            bytes(terms[termIndex])
        );

        // 从签名恢复签名者地址
        address signer = ECDSA.recover(hashedMessage, v, r, s);

        // 签名者必须是要添加的账户本人
        if (signer != account) {
            revert InvalidSigner();
        }

        _setAccountStatus(account, termIndex, true);
        emit AccountAddedFromSignature(account, termIndex, v, r, s);
    }

    /**
     * @notice 路径 3：管理员手动设置
     *
     * ALLOWLIST_SETTER 角色可以直接设置任何用户的状态
     * 用途：
     * - KYC 通过后由后端自动调用
     * - 批量导入已有的白名单用户
     * - 手动移除用户（status=false）
     *
     * 注意：被 setAccountStatus(false) 的用户可以通过 addSelfToAllowlist 重新加入
     * 这是有意的设计 — 如果需要永久禁止，应该用 Blocklist
     */
    function setAccountStatus(
        address account,
        uint256 termIndex,
        bool status
    ) external override onlyRole(ALLOWLIST_SETTER) {
        _setAccountStatus(account, termIndex, status);
        emit AccountStatusSetByAdmin(account, termIndex, status);
    }

    // ============ 内部函数 ============

    /**
     * @notice 设置用户状态的统一入口
     * @dev 三条路径最终都调用这个函数
     *      单一写入点 → 状态变更行为一致，不会出现某条路径忘记校验的情况
     */
    function _setAccountStatus(
        address account,
        uint256 termIndex,
        bool status
    ) internal {
        if (termIndex >= terms.length) {
            revert InvalidTermIndex();
        }
        verifications[account][termIndex] = status;
        emit AccountStatusSet(account, termIndex, status);
    }
}
