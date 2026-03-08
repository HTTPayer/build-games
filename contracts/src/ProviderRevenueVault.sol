// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ProviderRevenueVault
 * @notice ERC4626 vault representing fractional yield claims on a provider's API revenue.
 *
 * @dev Revenue flows into the vault via direct USDC transfer from ProviderRevenueSplitter
 *      — no new shares are minted from revenue. This increases totalAssets without changing
 *      totalSupply, so sharePrice() rises with each API payment settled onchain.
 *
 *      Lifecycle:
 *        1. Factory deploys this vault (zero shares, zero assets).
 *        2. Factory optionally calls genesisMint(recipient, shares) — one-time, owner-only,
 *           to give the provider an initial allocation. If used, pair with a genesisDeposit
 *           so the share price is non-zero before external investors deposit.
 *        3. Investors call deposit(usdc) to receive shares at the current NAV.
 *        4. ProviderRevenueSplitter.distribute() transfers USDC directly to this address.
 *           totalAssets() grows; sharePrice() rises; all holders benefit proportionally.
 */
contract ProviderRevenueVault is ERC4626, Ownable {

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    /// @notice Dead shares minted at construction to keep totalSupply > 0 permanently.
    ///         Prevents revenue accumulated while supply approaches zero from being
    ///         captured by the next depositor at a 1:1 rate (ERC4626 donation attack).
    ///         1_000 raw units = 0.001 shares (6 decimals). USDC backing these shares
    ///         is permanently locked — acceptable dust for the protection it provides.
    uint256 private constant DEAD_SHARES = 1_000;

    // =============================================================
    //                          STATE
    // =============================================================

    /// @notice True after genesisMint has been called. Prevents a second genesis.
    bool public genesisComplete;

    /// @notice True once the owner has opened the vault to external depositors.
    ///         Defaults to false — shares are provider-only until explicitly opened.
    bool public depositsEnabled;

    // =============================================================
    //                          EVENTS
    // =============================================================

    /// @notice Emitted once when the genesis share allocation is minted.
    event GenesisMint(address indexed recipient, uint256 shares);

    /// @notice Emitted when the owner opens the vault to external depositors.
    event DepositsOpened();

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    /**
     * @param _asset    The underlying asset (USDC).
     * @param _name     Vault token name  (e.g. "AI API Revenue Vault").
     * @param _symbol   Vault token symbol (e.g. "rvAI").
     * @param _owner    Initial owner — typically the factory, which transfers ownership
     *                  to the provider after calling genesisMint.
     */
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _owner
    )
        ERC4626(_asset)
        ERC20(_name, _symbol)
        Ownable(_owner)
    {
        require(_owner != address(0), "zero owner");

        // Permanently lock a dust amount of shares so totalSupply never reaches zero.
        _mint(address(0xdead), DEAD_SHARES);
    }

    // =============================================================
    //                       GENESIS MINT
    // =============================================================

    /**
     * @notice Mint the initial share supply to a designated recipient.
     *         Can only be called once, by the owner (the factory at deploy time).
     *
     * @dev    Calls ERC20._mint directly — bypasses ERC4626 deposit logic intentionally.
     *         Shares are created with zero USDC backing; share price initialises to 0
     *         and rises as API revenue flows in via direct USDC transfers.
     *
     * @param  recipient  Address to receive all genesis shares. Can be the developer's
     *                    wallet, a multisig, an IAO contract, a vesting contract, etc.
     * @param  shares     Number of shares to mint (in raw units, 6 decimals).
     */
    function genesisMint(address recipient, uint256 shares) external onlyOwner {
        require(!genesisComplete,        "genesis already complete");
        require(recipient != address(0), "zero recipient");
        require(shares > 0,              "zero shares");

        genesisComplete = true;
        _mint(recipient, shares);

        emit GenesisMint(recipient, shares);
    }

    // =============================================================
    //                     DEPOSIT GATING
    // =============================================================

    /// @notice Open the vault to external depositors. One-way switch, owner only.
    function openDeposits() external onlyOwner {
        depositsEnabled = true;
        emit DepositsOpened();
    }

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(depositsEnabled, "deposits not open");
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        require(depositsEnabled, "deposits not open");
        return super.mint(shares, receiver);
    }

    // =============================================================
    //                         TOTAL ASSETS
    // =============================================================

    /**
     * @notice Total USDC held in the vault.
     * @dev    Reads balanceOf directly so that revenue transferred by the splitter
     *         (without calling deposit) is reflected immediately in totalAssets()
     *         and therefore in sharePrice().
     */
    function totalAssets()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return IERC20(asset()).balanceOf(address(this));
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Current share price expressed as USDC per share (1e18-scaled).
     *         Returns 0 before any revenue has been distributed or USDC deposited.
     *         Increases with every ProviderRevenueSplitter.distribute() call.
     * @dev    totalSupply is never zero (DEAD_SHARES minted at construction), so
     *         this never reverts. Returns 0 when totalAssets is 0.
     */
    function sharePrice() external view returns (uint256) {
        return (totalAssets() * 1e18) / totalSupply();
    }
}
