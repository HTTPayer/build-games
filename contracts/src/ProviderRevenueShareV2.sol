// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ProviderRevenueShareV2
 * @notice Rebasing ERC20 token representing a perpetual right to revenue.
 *
 * How it works (shares model, like Yearn vaults, rETH):
 * ─────────────────────────────────────────────────────────────
 * - Each holder has "shares" - their underlying ownership
 * - Total "assets" = USDC balance in contract
 * - balanceOf(user) = shares[user] * (assets / totalShares)
 * - When USDC comes in via distribute(), assets increases, all balances rebase up
 *
 * Key difference from V1 (ProviderRevenueShare):
 * - V1: claim() - holders claim USDC, balance stays same, checkpoint tracking
 * - V2: distribute() - USDC stays in pool, balance increases proportionally
 *
 * This model is like stETH/rETH - yield compounds into the token price.
 *
 * Flow:
 * ─────
 * 1. Genesis: mint initial supply to bootstrappers
 * 2. Revenue flows in from splitter → USDC in contract
 * 3. distribute() called → assets increase → all balances rebase up
 * 4. Holders can:
 *    - Hold: value compounds automatically as rate increases
 *    - Transfer: shares can be traded (value is in the token)
 *    - Redeem: burn shares for USDC at current rate
 *
 * Exchange rate:
 * ────────────
 * exchangeRate = USDC_balance / totalSupply
 * - Starts at some initial rate based on genesis supply
 * - Increases as revenue is distributed
 * - wRS (wrapper) can be 1:1 since this rebases fairly
 *
 * Benefits over V1:
 * ─────────────────
 * - No checkpoint tracking needed (simpler)
 * - wRS can be 1:1 wrapper (no exploit)
 * - Early depositer advantage is time-based, not ratio-based
 * - Better composability - token value is intrinsic
 */
contract ProviderRevenueShareV2 is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                 CONFIG
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice The USDC token this contract uses
    IERC20 public immutable USDC;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                STORAGE
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Total USDC in the pool (assets)
    uint256 public totalAssets;

    /// @notice Total USDC distributed since genesis (for tracking)
    uint256 public totalDistributed;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                 EVENTS
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Shares minted to an address
    event Mint(address indexed to, uint256 shares);

    /// @notice Shares burned, USDC redeemed
    event Redeem(address indexed user, uint256 shares, uint256 usdcOut);

    /// @notice USDC distributed, balances rebased
    event Distribute(uint256 usdcIn, uint256 newTotalAssets);

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
     * @notice Mint initial supply. Can only be called once.
     *         Used to bootstrap the token at genesis.
     *
     * @param to Address to receive initial shares
     * @param shares Amount of shares to mint
     */
    function mint(address to, uint256 shares) external onlyOwner {
        require(totalSupply() == 0, "already minted");
        require(to != address(0), "zero address");
        require(shares > 0, "zero shares");

        // Initial assets should be 0 or some bootstrapped amount
        // If bootstrapping with USDC, would need to track that

        _mint(to, shares);
        emit Mint(to, shares);
    }

    /**
     * @notice Burn shares and receive USDC at current exchange rate.
     *
     * @param shareAmount Amount of shares to burn.
     * @return usdcOut USDC received.
     */
    function redeem(uint256 shareAmount) external nonReentrant returns (uint256 usdcOut) {
        require(shareAmount > 0, "zero amount");
        require(balanceOf(msg.sender) >= shareAmount, "insufficient balance");

        uint256 supply = totalSupply();
        require(supply > 0, "no supply");

        // usdcOut = shareAmount * totalAssets / supply
        usdcOut = (shareAmount * totalAssets) / supply;
        require(usdcOut > 0, "redeem amount too small");

        _burn(msg.sender, shareAmount);
        totalAssets -= usdcOut;
        USDC.safeTransfer(msg.sender, usdcOut);

        emit Redeem(msg.sender, shareAmount, usdcOut);
    }

    /**
     * @notice Distribute incoming USDC revenue.
     *         This increases totalAssets, which rebases all holder balances up.
     *
     * Anyone can call this after USDC has been transferred to the contract.
     * Called by the revenue splitter when USDC flows in.
     *
     * @return distributed Amount of USDC distributed
     */
    function distribute() external nonReentrant returns (uint256 distributed) {
        uint256 usdcBalance = USDC.balanceOf(address(this));
        
        // Check that there's new USDC since last distribute
        require(usdcBalance > totalAssets, "no new usdc");

        distributed = usdcBalance - totalAssets;
        totalAssets = usdcBalance;
        totalDistributed += distributed;

        emit Distribute(distributed, usdcBalance);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                VIEWS
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Current exchange rate: USDC per share, scaled by 1e6.
     *         Example: 1500000 = $1.50 per share
     *         
     *         This is the "price" of 1 share in USDC terms.
     */
    function exchangeRate() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        return (totalAssets * 1e6) / supply;
    }

    /**
     * @notice Total USDC held in the pool.
     */
    function totalAssetsStored() external view returns (uint256) {
        return totalAssets;
    }

    /**
     * @notice Total USDC distributed since genesis.
     */
    function totalDistributedAmount() external view returns (uint256) {
        return totalDistributed;
    }

    /**
     * @notice Preview how much USDC you'd get for burning shares.
     *
     * @param shareAmount Amount of shares to redeem
     * @return usdcOut USDC you'd receive
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
