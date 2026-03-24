// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RebasingRevenueShare
 * @notice Rebasing ERC20 token representing a perpetual right to revenue.
 *
 * How it works (shares model, like Yearn vaults):
 * ─────────────────────────────────────────────────────
 * - Each holder has "shares" - their underlying ownership
 * - Total "assets" = USDC balance in contract
 * - balanceOf(user) = shares[user] * (assets / totalShares)
 * - When USDC comes in, assets increases, everyone's balance rebases up
 * - This is how rETH, stETH, Yearn vaults work
 *
 * Key difference from original RS:
 * - Original: claim() - holders claim USDC, balance stays same
 * - Rebasing: distribute() - USDC stays in pool, balance increases
 *
 * Flow:
 * ─────
 * 1. Genesis: mint initial shares to bootstrappers
 * 2. Revenue flows in → assets increase → balances rebase up
 * 3. Holders can redeem shares for USDC at current rate
 * 4. Exchange rate = assets / totalShares
 *
 * Benefits:
 * ────────
 * - wRS can be 1:1 wrapper (non-rebasing) like wstETH
 * - No early depositer advantage - everyone gets proportional
 * - Simple, proven model (stETH, rETH, Yearn use this)
 */
contract RebasingRevenueShare is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                 CONFIG
    // ─────────────────────────────────────────────────────────────────────────────

    IERC20 public immutable USDC;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                STORAGE
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Total assets (USDC) in the pool, excluding pending claims
    uint256 public totalAssets;

    /// @dev Total USDC harvested since genesis (for tracking)
    uint256 public totalHarvested;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                 EVENTS
    // ─────────────────────────────────────────────────────────────────────────────

    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Redeem(address indexed user, uint256 shares, uint256 assets);
    event Distribute(uint256 usdcIn, uint256 totalAssetsDelta);
    event Mint(address indexed to, uint256 shares);

    // ─────────────────────────────────────────────────────────────────────────────
    //                               CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────────

    constructor(
        IERC20 _usdc,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        require(address(_usdc) != address(0), "zero usdc");
        USDC = _usdc;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                CORE
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint initial shares. Can only be called once.
     *         Used to bootstrap the token supply.
     *
     * @param to Address to receive shares
     * @param shares Amount of shares to mint
     */
    function mint(address to, uint256 shares) external onlyOwner {
        require(totalSupply() == 0, "already minted");
        require(to != address(0), "zero address");
        require(shares > 0, "zero shares");

        _mint(to, shares);
        emit Mint(to, shares);
    }

    /**
     * @notice Deposit USDC and receive shares 1:1 (at initial rate).
     *         First depositor gets shares at whatever rate the pool has.
     *
     * @param usdcAmount Amount of USDC to deposit
     * @return shares Amount of shares received
     */
    function deposit(uint256 usdcAmount) external nonReentrant returns (uint256 shares) {
        require(usdcAmount > 0, "zero amount");

        // Transfer USDC from user
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 supply = totalSupply();
        uint256 assets = totalAssets;

        if (supply == 0) {
            // First depositor: shares = usdc (1:1 at genesis)
            shares = usdcAmount;
        } else {
            // Subsequent: shares = usdcAmount * supply / assets
            shares = (usdcAmount * supply) / assets;
        }

        require(shares > 0, "share amount too small");

        totalAssets += usdcAmount;
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, usdcAmount, shares);
    }

    /**
     * @notice Burn shares and receive USDC at current exchange rate.
     *
     * @param shareAmount Amount of shares to burn
     * @return usdcOut USDC received
     */
    function redeem(uint256 shareAmount) external nonReentrant returns (uint256 usdcOut) {
        require(shareAmount > 0, "zero amount");
        require(balanceOf(msg.sender) >= shareAmount, "insufficient balance");

        uint256 supply = totalSupply();
        uint256 assets = totalAssets;

        // usdcOut = shareAmount * assets / supply
        usdcOut = (shareAmount * assets) / supply;
        require(usdcOut > 0, "redeem amount too small");

        _burn(msg.sender, shareAmount);
        totalAssets -= usdcOut;
        USDC.safeTransfer(msg.sender, usdcOut);

        emit Redeem(msg.sender, shareAmount, usdcOut);
    }

    /**
     * @notice Called when USDC revenue flows in.
     *         Updates totalAssets, which increases all balances proportionally.
     *
     * Anyone can call this after USDC has been transferred to the contract.
     *
     * @return harvested Amount of USDC distributed
     */
    function distribute() external nonReentrant returns (uint256 harvested) {
        uint256 usdcBalance = USDC.balanceOf(address(this));
        
        // Calculate how much new USDC came in since last distribute
        // (assets is what we've accounted for, balance is what we have)
        require(usdcBalance > totalAssets, "no new usdc");

        harvested = usdcBalance - totalAssets;
        totalAssets = usdcBalance;
        totalHarvested += harvested;

        emit Distribute(usdcBalance, harvested);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                VIEWS
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Current exchange rate: USDC per share, scaled by 1e6.
     *         Example: 1500000 = $1.50 per share
     */
    function exchangeRate() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        return (totalAssets * 1e6) / supply;
    }

    /**
     * @notice Total USDC in the pool (assets).
     */
    function totalAssetsStored() external view returns (uint256) {
        return totalAssets;
    }

    /**
     * @notice Total USDC harvested since genesis.
     */
    function totalHarvestedAmount() external view returns (uint256) {
        return totalHarvested;
    }

    /**
     * @notice Preview how many shares you'd get for depositing USDC.
     */
    function previewDeposit(uint256 usdcAmount) external view returns (uint256 shares) {
        if (usdcAmount == 0) return 0;
        uint256 supply = totalSupply();
        uint256 assets = totalAssets;
        if (supply == 0) return usdcAmount;
        shares = (usdcAmount * supply) / assets;
    }

    /**
     * @notice Preview how much USDC you'd get for burning shares.
     */
    function previewRedeem(uint256 shareAmount) external view returns (uint256 usdcOut) {
        if (shareAmount == 0) return 0;
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        usdcOut = (shareAmount * totalAssets) / supply;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                ADMIN
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Rescue accidentally sent tokens. Cannot rescue USDC.
     */
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero address");
        require(address(token) != address(USDC), "cannot rescue USDC");
        token.safeTransfer(to, amount);
    }
}
