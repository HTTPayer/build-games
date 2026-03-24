// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ProviderRevenueShare.sol";
import "./ProviderRevenueSplitter.sol";
import "./interfaces/IProviderRevenueShare.sol";
import "./interfaces/IAPIIntegrityRegistry.sol";

/**
 * @title APIRegistryFactory
 * @notice Deploys a ProviderRevenueShare (RS token) + ProviderRevenueSplitter
 *         for each API provider in a single transaction.
 *
 * @dev    RS-native revenue model:
 *
 *           ProviderRevenueShare — royalty trust unit (core primitive)
 *             Fixed supply minted once at genesis. Revenue from the splitter
 *             (revenueShareBp) is credited via a per-share accumulator.
 *             Holders call claim() to withdraw earned USDC without burning shares.
 *             Perpetual, equity-like dividend rights. Secondary-market tradeable.
 *
 *         Revenue split (must sum to 10_000 bp):
 *           protocolTreasuryBp  →  protocol treasury  (fixed at factory deploy, ≤ 3%)
 *           providerTreasuryBp  →  provider treasury  (set by provider, can be 0)
 *           revenueShareBp      →  ProviderRevenueShare holders (remainder)
 *
 *         Deploy flow:
 *           1. Deploy ProviderRevenueShare (factory is temporary owner)
 *           2. genesisMint(revenueShareRecipient, revenueShareShares)
 *           3. Transfer RS ownership → msg.sender
 *           4. Deploy ProviderRevenueSplitter with full split config
 *              - protocolAdmin = protocolTreasury (protocol controls its own treasury address)
 *              - providerAdmin = msg.sender (provider controls their treasury address)
 *           5. Optional: register in APIIntegrityRegistry
 *           6. Register in onchain factory registry
 *           7. Emit ProviderDeployed
 */
contract APIRegistryFactory {

    // =============================================================
    //                      PROTOCOL CONFIG
    // =============================================================

    /// @notice Hard cap on the protocol treasury cut (3%). Enforced at construction.
    uint256 public constant MAX_PROTOCOL_BP = 300;

    IERC20 public immutable USDC;

    /// @notice Protocol treasury — receives protocolTreasuryBp on every distribute().
    address public immutable protocolTreasury;

    /// @notice Protocol's cut in basis points (set once at factory deployment).
    uint256 public immutable protocolTreasuryBp;

    /// @notice APIIntegrityRegistry — optional. When set, deployProvider() registers
    ///         the provider in the same transaction. Set address(0) to skip.
    IAPIIntegrityRegistry public immutable registry;

    // =============================================================
    //                       PROVIDER REGISTRY
    // =============================================================

    struct ProviderRecord {
        address deployer;
        address revenueShare;
        address splitter;
        uint256 deployedAt;
    }

    /// @notice All providers deployed through this factory, in order.
    ProviderRecord[] private _providers;

    /// @notice deployer → list of indices into _providers.
    mapping(address => uint256[]) private _providersByDeployer;

    /// @notice splitter address → index+1 in _providers (0 = not registered).
    ///         The +1 offset lets us distinguish "index 0" from "not found".
    mapping(address => uint256) private _indexBySplitter;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event ProviderDeployed(
        address indexed deployer,
        address indexed revenueShare,
        address indexed splitter,
        address revenueShareRecipient,
        uint256 revenueShareShares,
        address providerTreasury,
        uint256 protocolTreasuryBp,
        uint256 providerTreasuryBp,
        uint256 revenueShareBp
    );

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(
        IERC20  _usdc,
        address _protocolTreasury,
        uint256 _protocolTreasuryBp,
        address _registry
    ) {
        require(address(_usdc)      != address(0), "zero USDC");
        require(_protocolTreasury   != address(0), "zero protocol treasury");
        require(_protocolTreasuryBp <= MAX_PROTOCOL_BP, "protocol bp exceeds 3% cap");

        USDC               = _usdc;
        protocolTreasury   = _protocolTreasury;
        protocolTreasuryBp = _protocolTreasuryBp;
        registry           = IAPIIntegrityRegistry(_registry);
    }

    // =============================================================
    //                      REGISTRY VIEWS
    // =============================================================

    /// @notice Total number of providers deployed through this factory.
    function providerCount() external view returns (uint256) {
        return _providers.length;
    }

    /// @notice Get a provider record by its global index.
    function getProvider(uint256 index) external view returns (ProviderRecord memory) {
        require(index < _providers.length, "out of range");
        return _providers[index];
    }

    /// @notice All global indices of providers deployed by a specific address.
    function getProviderIndicesByDeployer(address deployer)
        external view returns (uint256[] memory)
    {
        return _providersByDeployer[deployer];
    }

    /// @notice Number of providers deployed by a specific address.
    function getProviderCountByDeployer(address deployer) external view returns (uint256) {
        return _providersByDeployer[deployer].length;
    }

    /// @notice Look up a provider record directly by its splitter address.
    ///         Reverts if the splitter was not deployed by this factory.
    function getProviderBySplitter(address splitter)
        external view returns (ProviderRecord memory)
    {
        uint256 stored = _indexBySplitter[splitter];
        require(stored != 0, "splitter not registered");
        return _providers[stored - 1];
    }

    /// @notice Returns true if the splitter was deployed by this factory.
    function isRegisteredSplitter(address splitter) external view returns (bool) {
        return _indexBySplitter[splitter] != 0;
    }

    // =============================================================
    //                       DEPLOY PROVIDER
    // =============================================================

    /**
     * @notice Deploy a ProviderRevenueShare token + ProviderRevenueSplitter for a new
     *         API provider.
     *
     * @dev    Revenue split — all basis points must sum to 10_000:
     *
     *           protocolTreasuryBp  →  protocol treasury  (fixed at factory deploy)
     *           providerTreasuryBp  →  provider treasury  (set by provider, can be 0)
     *           revenueShareBp      →  RS token holders   (10_000 - protocol - provider)
     *
     * @param rsName                ERC20 name for the RS token (e.g. "My API Revenue Share").
     * @param rsSymbol              ERC20 symbol for the RS token (e.g. "MARSRS").
     * @param revenueShareShares    Genesis shares to mint (raw units, 6 decimals). Required > 0.
     * @param revenueShareRecipient Receives genesis shares. Defaults to msg.sender.
     * @param providerTreasury      Provider's direct cut destination.
     *                              Required when providerTreasuryBp > 0.
     * @param providerTreasuryBp    Basis points routed to the provider treasury directly.
     *                              Set 0 to route everything (minus protocol cut) to RS holders.
     * @param metadataURI           Provider metadata URI for the APIIntegrityRegistry.
     *
     * @return revenueShareAddr     Deployed ProviderRevenueShare address.
     * @return splitterAddr         Deployed ProviderRevenueSplitter address.
     */
    function deployProvider(
        string memory rsName,
        string memory rsSymbol,
        uint256       revenueShareShares,
        address       revenueShareRecipient,
        address       providerTreasury,
        uint256       providerTreasuryBp,
        string memory metadataURI
    )
        external
        returns (address revenueShareAddr, address splitterAddr)
    {
        uint256 allocatedBp    = protocolTreasuryBp + providerTreasuryBp;
        uint256 revenueShareBp = 10_000 - allocatedBp; // underflow reverts if > 100%

        require(allocatedBp <= 10_000,       "bp exceeds 100%");
        require(revenueShareShares > 0,      "genesis shares required");
        require(
            providerTreasuryBp == 0 || providerTreasury != address(0),
            "provider treasury required when bp > 0"
        );

        // Default genesis recipient to msg.sender
        if (revenueShareRecipient == address(0)) {
            revenueShareRecipient = msg.sender;
        }

        // ------------------------------------------------------------------
        // 1. Deploy ProviderRevenueShare (factory is temporary owner)
        // ------------------------------------------------------------------
        ProviderRevenueShare revShare = new ProviderRevenueShare(
            USDC,
            rsName,
            rsSymbol,
            address(this)
        );

        // ------------------------------------------------------------------
        // 2. Genesis mint — one-shot, all shares go to the designated recipient
        // ------------------------------------------------------------------
        revShare.genesisMint(revenueShareRecipient, revenueShareShares);

        // ------------------------------------------------------------------
        // 3. Transfer RS ownership to the provider
        // ------------------------------------------------------------------
        revShare.transferOwnership(msg.sender);

        // ------------------------------------------------------------------
        // 4. Deploy ProviderRevenueSplitter
        //    - protocolAdmin = protocolTreasury (protocol controls its own address)
        //    - providerAdmin = msg.sender (provider controls their treasury address)
        // ------------------------------------------------------------------
        ProviderRevenueSplitter splitter = new ProviderRevenueSplitter(
            USDC,
            protocolTreasury,   // protocolAdmin
            protocolTreasury,   // protocolTreasury (initial)
            protocolTreasuryBp,
            msg.sender,         // providerAdmin
            providerTreasury,   // providerTreasury (initial, address(0) ok when bp == 0)
            providerTreasuryBp,
            IProviderRevenueShare(address(revShare)),
            revenueShareBp
        );

        revenueShareAddr = address(revShare);
        splitterAddr     = address(splitter);

        // ------------------------------------------------------------------
        // 5. Optional: register in APIIntegrityRegistry
        // ------------------------------------------------------------------
        if (address(registry) != address(0)) {
            registry.registerProvider(
                msg.sender,
                metadataURI,
                splitterAddr,
                splitterAddr
            );
        }

        // ------------------------------------------------------------------
        // 6. Register in onchain factory registry
        // ------------------------------------------------------------------
        uint256 idx = _providers.length;
        _providers.push(ProviderRecord({
            deployer:     msg.sender,
            revenueShare: revenueShareAddr,
            splitter:     splitterAddr,
            deployedAt:   block.timestamp
        }));
        _providersByDeployer[msg.sender].push(idx);
        _indexBySplitter[splitterAddr] = idx + 1;

        emit ProviderDeployed(
            msg.sender,
            revenueShareAddr,
            splitterAddr,
            revenueShareRecipient,
            revenueShareShares,
            providerTreasury,
            protocolTreasuryBp,
            providerTreasuryBp,
            revenueShareBp
        );
    }
}
