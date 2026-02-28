// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RWAToken} from "../token/RWAToken.sol";
import {KYCAllowlist} from "../compliance/KYCAllowlist.sol";
import {NAVOracle} from "../oracle/NAVOracle.sol";
import {SubscriptionManager} from "../finance/SubscriptionManager.sol";
import {RedemptionManager} from "../finance/RedemptionManager.sol";

/**
 * @title RWAFactory
 * @author jonathan.ji
 * @notice Factory contract for deploying new RWA token instances.
 *         Each RWA product (e.g., SGD MMF, USD T-Bill) gets its own
 *         set of contracts deployed via this factory.
 *
 * @dev Deploys:
 *   - KYCAllowlist (shared or per-product)
 *   - NAVOracle
 *   - RWAToken (via UUPS proxy)
 *   - SubscriptionManager
 *   - RedemptionManager
 */
contract RWAFactory is AccessControl {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice RWAToken implementation contract (shared across all proxies)
    address public immutable tokenImplementation;

    struct RWAProduct {
        address token;
        address kycAllowlist;
        address navOracle;
        address subscriptionManager;
        address redemptionManager;
        string  name;
        string  symbol;
        bool    active;
        uint48  deployedAt;
    }

    mapping(uint256 => RWAProduct) public products;
    uint256 public productCount;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RWAProductDeployed(
        uint256 indexed productId,
        address token,
        address kycAllowlist,
        address navOracle,
        address subscriptionManager,
        address redemptionManager,
        string  name,
        string  symbol
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);

        // Deploy the RWAToken implementation (shared)
        tokenImplementation = address(new RWAToken());
    }

    /*//////////////////////////////////////////////////////////////
                           FACTORY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a complete RWA product suite
     * @param name              Token name
     * @param symbol            Token symbol
     * @param assetDescription  Underlying asset description
     * @param assetIdentifier   ISIN or fund identifier
     * @param admin             Admin address for all contracts
     * @param operator          Operator address (subscription/redemption processor)
     * @param oracle            Oracle address (NAV updater)
     * @param usdc              USDC token address
     * @param custodian         Custodian address for subscription USDC
     * @param initialNAV        Starting NAV (typically 1e6 = $1.00)
     * @param minSubscription   Minimum subscription in USDC
     * @param dailyCap          Daily subscription cap in USDC
     * @param instantFeeBps     Instant redemption fee in bps
     * @return productId        ID of the newly deployed product
     */
    function deployRWAProduct(
        string memory name,
        string memory symbol,
        string memory assetDescription,
        string memory assetIdentifier,
        address admin,
        address operator,
        address oracle,
        address usdc,
        address custodian,
        uint256 initialNAV,
        uint256 minSubscription,
        uint256 dailyCap,
        uint256 instantFeeBps
    ) external onlyRole(OPERATOR_ROLE) returns (uint256 productId) {

        // 1. Deploy KYCAllowlist
        KYCAllowlist kycAllowlist = new KYCAllowlist(admin);
        kycAllowlist.grantRole(kycAllowlist.OPERATOR_ROLE(), operator);

        // 2. Deploy NAVOracle
        NAVOracle navOracle = new NAVOracle(admin, oracle, initialNAV);

        // 3. Deploy RWAToken proxy
        bytes memory initData = abi.encodeCall(
            RWAToken.initialize,
            (
                name,
                symbol,
                admin,
                operator,
                address(kycAllowlist),
                assetDescription,
                assetIdentifier
            )
        );
        address tokenProxy = address(new ERC1967Proxy(tokenImplementation, initData));
        RWAToken rwaToken = RWAToken(tokenProxy);

        // 4. Deploy SubscriptionManager
        SubscriptionManager subManager = new SubscriptionManager(
            admin,
            usdc,
            address(rwaToken),
            address(kycAllowlist),
            address(navOracle),
            custodian,
            minSubscription,
            dailyCap
        );
        subManager.grantRole(subManager.OPERATOR_ROLE(), operator);

        // 5. Deploy RedemptionManager
        RedemptionManager redManager = new RedemptionManager(
            admin,
            usdc,
            address(rwaToken),
            address(kycAllowlist),
            address(navOracle),
            instantFeeBps
        );
        redManager.grantRole(redManager.OPERATOR_ROLE(), operator);

        // 6. Grant OPERATOR_ROLE on RWAToken to both managers
        rwaToken.grantRole(rwaToken.OPERATOR_ROLE(), address(subManager));
        rwaToken.grantRole(rwaToken.OPERATOR_ROLE(), address(redManager));

        // 7. Record product
        productId = productCount++;
        products[productId] = RWAProduct({
            token: address(rwaToken),
            kycAllowlist: address(kycAllowlist),
            navOracle: address(navOracle),
            subscriptionManager: address(subManager),
            redemptionManager: address(redManager),
            name: name,
            symbol: symbol,
            active: true,
            deployedAt: uint48(block.timestamp)
        });

        emit RWAProductDeployed(
            productId,
            address(rwaToken),
            address(kycAllowlist),
            address(navOracle),
            address(subManager),
            address(redManager),
            name,
            symbol
        );
    }

    /**
     * @notice Get all deployed product addresses
     */
    function getProduct(uint256 productId) external view returns (RWAProduct memory) {
        return products[productId];
    }
}
