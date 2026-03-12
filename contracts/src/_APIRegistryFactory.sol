// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev DEPRECATED — superseded by the RS-token-native version (ERC4626 vault removed). Kept for reference only.

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ProviderRevenueVault.sol";
import "./ProviderRevenueShare.sol";
import "./_ProviderRevenueSplitter.sol";
import "./interfaces/IAPIIntegrityRegistry.sol";

/**
 * @title APIRegistryFactory (DEPRECATED)
 * @notice Deploys a matched ProviderRevenueVault + optional ProviderRevenueShare
 *         + ProviderRevenueSplitter for each API provider in a single transaction.
 *
 * @dev    Two-tier revenue model:
 *
 *           Tier 1 — ProviderRevenueVault (ERC4626)
 *             Investors deposit USDC at current NAV and receive vault shares.
 *             Revenue from the splitter (vaultBp) flows in as direct USDC transfers,
 *             raising sharePrice() without minting new shares.
 *             Holders can redeem shares for proportional USDC at any time.
 *
 *           Tier 2 — ProviderRevenueShare (dividend accumulator, optional)
 *             Fixed-supply shares minted once at genesis to the provider / team.
 *             Revenue from the splitter (revenueShareBp) is credited via a
 *             per-share accumulator. Holders call claim() to withdraw earned USDC
 *             without burning their shares — perpetual, equity-like dividend rights.
 *             Set revenueShareBp = 0 to skip this tier entirely.
 *
 *         Deploy flow:
 *           1. Deploy ProviderRevenueVault  (factory is temporary owner)
 *           2. Optional genesisMint(vaultGenesisRecipient, vaultGenesisShares)
 *           3. Optional genesisDeposit — seed vault with USDC so share price > 0
 *              before external investors deposit. Recommended when genesis shares > 0.
 *           4. Transfer vault ownership → msg.sender
 *           5. If revenueShareBp > 0: deploy ProviderRevenueShare, genesisMint,
 *              transfer ownership → msg.sender
 *           6. Deploy ProviderRevenueSplitter with full immutable split config
 *           7. Emit ProviderDeployed
 */
contract APIRegistryFactory_Deprecated {
    using SafeERC20 for IERC20;

    // =============================================================
    //                      PROTOCOL CONFIG
    // =============================================================

    /// @notice Hard cap on the protocol treasury cut (3%). Enforced at construction.
    uint256 public constant MAX_PROTOCOL_BP = 300;

    IERC20  public immutable USDC;

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
        address vault;        // address(0) when revenue-share-only
        address revenueShare; // address(0) when vault-only
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
        address indexed vault,
        address indexed splitter,
        address revenueShare,
        address vaultGenesisRecipient,
        uint256 vaultGenesisShares,
        uint256 genesisDeposit,
        address revenueShareRecipient,
        uint256 revenueShareShares,
        address providerTreasury,
        uint256 protocolTreasuryBp,
        uint256 providerTreasuryBp,
        uint256 revenueShareBp,
        uint256 vaultBp
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
        require(address(_usdc)    != address(0), "zero USDC");
        require(_protocolTreasury != address(0), "zero protocol treasury");
        require(_protocolTreasuryBp <= MAX_PROTOCOL_BP, "protocol bp exceeds 3% cap");

        USDC               = _usdc;
        protocolTreasury   = _protocolTreasury;
        protocolTreasuryBp = _protocolTreasuryBp;
        registry           = IAPIIntegrityRegistry(_registry); // address(0) = no registry
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

    function deployProvider(
        string memory vaultName,
        string memory vaultSymbol,
        uint256       vaultBp,
        uint256       vaultGenesisShares,
        address       vaultGenesisRecipient,
        uint256       genesisDeposit,
        address       providerTreasury,
        uint256       revenueShareBp,
        uint256       revenueShareShares,
        address       revenueShareRecipient,
        string memory metadataURI
    )
        external
        returns (address vaultAddr, address revenueShareAddr, address splitterAddr)
    {
        uint256 allocatedBp        = protocolTreasuryBp + vaultBp + revenueShareBp;
        uint256 providerTreasuryBp = 10_000 - allocatedBp;

        require(allocatedBp <= 10_000, "bp exceeds 100%");
        require(
            vaultBp > 0 || revenueShareBp > 0,
            "at least one of vaultBp or revenueShareBp must be > 0"
        );
        require(
            providerTreasuryBp == 0 || providerTreasury != address(0),
            "provider treasury address required when remainder bp > 0"
        );
        require(
            revenueShareBp == 0 || revenueShareShares > 0,
            "genesis shares required for revenue share"
        );

        bool deployVault = vaultBp > 0;

        require(
            !deployVault || genesisDeposit == 0 || vaultGenesisShares > 0,
            "genesis deposit requires vault genesis shares"
        );

        if (deployVault && vaultGenesisShares > 0 && vaultGenesisRecipient == address(0)) {
            vaultGenesisRecipient = msg.sender;
        }
        if (revenueShareBp > 0 && revenueShareRecipient == address(0)) {
            revenueShareRecipient = msg.sender;
        }

        ProviderRevenueVault vault;
        if (deployVault) {
            vault = new ProviderRevenueVault(
                USDC,
                vaultName,
                vaultSymbol,
                address(this)
            );

            if (vaultGenesisShares > 0) {
                vault.genesisMint(vaultGenesisRecipient, vaultGenesisShares);
            }

            if (genesisDeposit > 0) {
                USDC.safeTransferFrom(msg.sender, address(vault), genesisDeposit);
            }

            vault.transferOwnership(msg.sender);
        }

        ProviderRevenueShare revShare;
        if (revenueShareBp > 0) {
            revShare = new ProviderRevenueShare(
                USDC,
                string.concat(vaultName, " Revenue Share"),
                string.concat(vaultSymbol, "RS"),
                address(this)
            );
            revShare.genesisMint(revenueShareRecipient, revenueShareShares);
            revShare.transferOwnership(msg.sender);
        }

        ProviderRevenueSplitter_Deprecated splitter = new ProviderRevenueSplitter_Deprecated(
            USDC,
            protocolTreasury,
            protocolTreasuryBp,
            providerTreasury,
            providerTreasuryBp,
            IProviderRevenueShare_Old(address(revShare)),
            revenueShareBp,
            address(vault)
        );

        vaultAddr        = address(vault);
        revenueShareAddr = address(revShare);
        splitterAddr     = address(splitter);

        if (address(registry) != address(0)) {
            registry.registerProvider(
                msg.sender,
                metadataURI,
                splitterAddr,
                splitterAddr
            );
        }

        uint256 idx = _providers.length;
        _providers.push(ProviderRecord({
            deployer:     msg.sender,
            vault:        vaultAddr,
            revenueShare: revenueShareAddr,
            splitter:     splitterAddr,
            deployedAt:   block.timestamp
        }));
        _providersByDeployer[msg.sender].push(idx);
        _indexBySplitter[splitterAddr] = idx + 1;

        uint256 _vaultBp = vaultBp;

        emit ProviderDeployed(
            msg.sender,
            vaultAddr,
            splitterAddr,
            revenueShareAddr,
            vaultGenesisRecipient,
            vaultGenesisShares,
            genesisDeposit,
            revenueShareRecipient,
            revenueShareShares,
            providerTreasury,
            protocolTreasuryBp,
            providerTreasuryBp,
            revenueShareBp,
            _vaultBp
        );
    }
}
