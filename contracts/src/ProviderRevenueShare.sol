// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ProviderRevenueShare
 * @notice Fixed-supply ERC20 token representing a perpetual right to a fraction
 *         of an API provider's onchain revenue.
 *
 * Plain-english model
 * ───────────────────
 * Think of shares like stock in a royalty trust (e.g. an oil royalty trust):
 *
 *   - A fixed number of shares is created once, at genesis.
 *   - Shares represent a perpetual, proportional claim on all future revenue.
 *   - Revenue is paid as USDC dividends — holders call claim() to receive their cut.
 *   - Claiming does NOT burn shares. You keep your equity and keep earning.
 *   - To exit, you sell your shares on a secondary market.
 *   - The share price on the open market reflects expected *future* revenue
 *     (forward-looking), not accumulated past revenue (backward-looking).
 *
 * How the math works
 * ──────────────────
 * A global counter called `revenuePerShare` tracks the total USDC earned
 * per share since the contract was deployed. Every time revenue arrives,
 * this number goes up.
 *
 * Each holder has a `checkpoint` — the value of `revenuePerShare` the last
 * time they claimed (or received/sent shares). The gap between the global
 * counter and their checkpoint, multiplied by their balance, is what they
 * can claim right now.
 *
 *   claimable = (revenuePerShare - holder.checkpoint) × holder.balance
 *
 * When shares are transferred, both sender and receiver are settled first —
 * the sender claims what they earned, the receiver's checkpoint is updated
 * to now. This prevents a buyer from claiming revenue earned before they
 * owned the shares.
 *
 * Regulatory note
 * ───────────────
 * This instrument represents an onchain revenue right only — not equity,
 * debt, or any claim against a legal entity. Revenue source is onchain
 * x402 payments; there is no off-chain promise or issuer obligation.
 * Holders should seek independent legal advice regarding their jurisdiction.
 */
contract ProviderRevenueShare is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    //                              CONSTANTS
    // =========================================================================

    /// @dev Scaling factor for revenuePerShare to preserve precision.
    ///      Using 1e18 gives us 12 decimal places of headroom with 6-decimal
    ///      USDC and up to 1 trillion shares (1e12 raw units).
    uint256 private constant SCALE = 1e18;

    uint256 public constant SECONDS_PER_YEAR      = 365 days;

    /// @dev Minimum time between automatic rate snapshots.
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;

    /// @dev Circular buffer depth: 90 days × 24 snapshots/day = 2160.
    uint256 public constant MAX_SNAPSHOTS         = 2160;

    // =========================================================================
    //                               STATE
    // =========================================================================

    /// @notice The USDC token this contract distributes.
    IERC20 public immutable USDC;

    /// @notice Running total of USDC earned per share, scaled by SCALE.
    ///         Increases monotonically every time distribute() is called.
    uint256 public revenuePerShare;

    /// @notice Per-holder checkpoint: the value of revenuePerShare at the
    ///         time of their last claim or balance change.
    mapping(address => uint256) public checkpoint;

    /// @notice Settled but not-yet-withdrawn USDC owed to each holder.
    ///         Accumulates on transfer; drained on claim().
    mapping(address => uint256) public pendingClaims;

    /// @notice Prevents a second genesis mint.
    bool public genesisComplete;

    /// @notice Total USDC distributed into this contract over its lifetime.
    uint256 public totalDistributed;

    /// @notice Total USDC claimed by holders over the lifetime of the contract.
    uint256 public totalClaimed;

    // ── Rate snapshots ────────────────────────────────────────────────────────
    // Tracks revenuePerShare over time so we can compute trailing APR/APY.
    //
    // Note on interpretation: revenuePerShare is *cumulative* earnings per share
    // since genesis, not a price. APR here measures the growth rate of cumulative
    // earnings — i.e. how fast revenue is arriving relative to historical total.
    // It is NOT a return-on-investment figure (market price is unknown onchain).
    // Use it for display and comparison, not for collateral pricing.

    struct RateSnapshot {
        uint256 revenuePerShare; // value of the global accumulator at snapshot time
        uint256 timestamp;
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =========================================================================
    //                               EVENTS
    // =========================================================================

    event GenesisMint(address indexed recipient, uint256 shares);
    event RevenueDistributed(uint256 amount, uint256 newRevenuePerShare);
    event Claimed(address indexed holder, uint256 amount);
    event RateSnapshotTaken(uint256 revenuePerShare, uint256 timestamp);

    // =========================================================================
    //                             CONSTRUCTOR
    // =========================================================================

    constructor(
        IERC20  _usdc,
        string memory _name,
        string memory _symbol,
        address _owner
    )
        ERC20(_name, _symbol)
        Ownable(_owner)
    {
        require(address(_usdc) != address(0), "zero usdc");
        USDC = _usdc;

        // Seed snapshot ring buffer at zero (no revenue yet)
        recentSnapshots[0] = RateSnapshot({ revenuePerShare: 0, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime   = block.timestamp;
    }

    // =========================================================================
    //                            GENESIS MINT
    // =========================================================================

    /**
     * @notice Mint the entire fixed share supply in one shot.
     *         Can only be called once, by the owner (the factory).
     *
     * @param recipient  Who receives the shares. Defaults to msg.sender
     *                   (handled at factory level) if not specified.
     * @param shares     Total shares to mint. This is the permanent maximum.
     *                   Can never be increased.
     */
    function genesisMint(address recipient, uint256 shares) external onlyOwner {
        require(!genesisComplete,        "genesis already complete");
        require(recipient != address(0), "zero recipient");
        require(shares    > 0,           "zero shares");

        genesisComplete = true;
        _mint(recipient, shares);

        emit GenesisMint(recipient, shares);
    }

    // =========================================================================
    //                             DISTRIBUTION
    // =========================================================================

    /**
     * @notice Credit any USDC that has been transferred to this contract since the last
     *         distribution, spreading it proportionally across all current shareholders.
     *
     *         Called by ProviderRevenueSplitter immediately after it transfers USDC here.
     *         Anyone may call — revenue can never get stuck.
     *
     *         Pattern: splitter does safeTransfer(address(this), amount) then calls
     *         distribute(). The function discovers the new balance automatically so
     *         no amount parameter is needed and no approval is required.
     */
    function distribute() external nonReentrant {
        // New USDC = total balance minus what is already accounted for (distributed but unclaimed).
        uint256 amount = USDC.balanceOf(address(this)) - (totalDistributed - totalClaimed);
        require(amount > 0,        "nothing to distribute");
        require(totalSupply() > 0, "no shares outstanding");

        // Increase the global accumulator proportionally.
        // SCALE prevents precision loss when amount < totalSupply.
        revenuePerShare  += (amount * SCALE) / totalSupply();
        totalDistributed += amount;

        _takeSnapshotIfNeeded();
        emit RevenueDistributed(amount, revenuePerShare);
    }

    // =========================================================================
    //                               CLAIMING
    // =========================================================================

    /**
     * @notice Withdraw all USDC owed to msg.sender.
     *         Does NOT burn shares — you keep your equity and keep earning.
     */
    function claim() external nonReentrant {
        _settle(msg.sender);

        uint256 amount = pendingClaims[msg.sender];
        require(amount > 0, "nothing to claim");

        pendingClaims[msg.sender] = 0;
        totalClaimed             += amount;

        USDC.safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    /**
     * @notice How much USDC is claimable by a holder right now.
     *         Includes both settled pending claims and unsettled accrued revenue.
     */
    function claimable(address holder) public view returns (uint256) {
        uint256 unsettled = ((revenuePerShare - checkpoint[holder]) * balanceOf(holder)) / SCALE;
        return pendingClaims[holder] + unsettled;
    }

    // =========================================================================
    //                          TRANSFER HOOK
    // =========================================================================

    /**
     * @dev Settle both sender and receiver before any balance change.
     *
     *      Why: if Alice holds 100 shares and earns 10 USDC, then transfers
     *      her shares to Bob, Bob should not be able to claim Alice's 10 USDC.
     *      Settling before the transfer credits Alice's 10 USDC to her pending
     *      balance and resets Bob's checkpoint to the current accumulator,
     *      so he only earns revenue from the moment he receives the shares.
     */
    function _update(address from, address to, uint256 amount) internal override {
        // Settle outgoing holder (skip for mint)
        if (from != address(0)) _settle(from);
        // Settle incoming holder (skip for burn — not used, but defensive)
        if (to   != address(0)) _settle(to);

        super._update(from, to, amount);
    }

    // =========================================================================
    //                           INTERNAL HELPERS
    // =========================================================================

    /**
     * @dev Crystallise any accrued revenue into the holder's pendingClaims
     *      and advance their checkpoint to the current accumulator value.
     *      Must be called before any balance change.
     */
    function _settle(address holder) internal {
        uint256 accrued = ((revenuePerShare - checkpoint[holder]) * balanceOf(holder)) / SCALE;
        if (accrued > 0) {
            pendingClaims[holder] += accrued;
        }
        checkpoint[holder] = revenuePerShare;
    }

    /**
     * @dev Scan the circular buffer backwards (newest → oldest) and return the most
     *      recent snapshot whose timestamp is at or before `targetTs`.
     *      Returns (0, 0) if no qualifying snapshot exists (history too short).
     */
    function _findSnapshotBefore(uint256 targetTs)
        internal view returns (uint256 rps, uint256 ts)
    {
        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        for (uint256 i = 0; i < available; i++) {
            uint256 idx = i <= snapshotIndex
                ? snapshotIndex - i
                : MAX_SNAPSHOTS - (i - snapshotIndex);
            RateSnapshot memory s = recentSnapshots[idx];
            if (s.timestamp <= targetTs) {
                return (s.revenuePerShare, s.timestamp);
            }
        }
        return (0, 0);
    }

    function _takeSnapshotIfNeeded() internal {
        if (block.timestamp < lastSnapshotTime + MIN_SNAPSHOT_INTERVAL) return;

        snapshotIndex = (snapshotIndex + 1) % MAX_SNAPSHOTS;
        recentSnapshots[snapshotIndex] = RateSnapshot({
            revenuePerShare: revenuePerShare,
            timestamp:       block.timestamp
        });
        totalSnapshotCount++;
        lastSnapshotTime = block.timestamp;

        emit RateSnapshotTaken(revenuePerShare, block.timestamp);
    }

    // =========================================================================
    //                            VIEW HELPERS
    // =========================================================================

    /**
     * @notice Recover ERC20 tokens accidentally sent to this contract.
     *         USDC cannot be rescued — it is the yield reserve and its balance
     *         is relied upon by distribute(). Revenue share tokens (this contract)
     *         cannot be rescued either.
     */
    function rescueERC20(IERC20 token, address to) external onlyOwner {
        require(address(token) != address(USDC), "cannot rescue USDC");
        require(address(token) != address(this),  "cannot rescue revenue share");
        require(to != address(0),                 "zero recipient");
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    /// @notice USDC currently held in this contract (claimed but not yet
    ///         withdrawn + unclaimed accrued revenue).
    function totalPending() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Decimals matches USDC (6) so share quantities feel natural.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ── Earnings metrics ──────────────────────────────────────────────────────

    /**
     * @notice Cumulative USDC earned per share since genesis (6-decimal USDC units).
     *         Equivalent to "earnings per share" (EPS) in traditional finance.
     *
     *         This is NOT a market price. Market price is determined by secondary
     *         markets and reflects expected *future* revenue. This figure captures
     *         only realised historical revenue.
     */
    function cumulativeRevenuePerShare() external view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return revenuePerShare / SCALE;
    }

    /// @notice Manually trigger a snapshot (if the minimum interval has passed).
    function takeSnapshot() external {
        _takeSnapshotIfNeeded();
    }

    function getMostRecentSnapshot() external view returns (uint256 rps, uint256 timestamp) {
        RateSnapshot memory s = recentSnapshots[snapshotIndex];
        return (s.revenuePerShare, s.timestamp);
    }

    function getSnapshotCount() external view returns (uint256) {
        return totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
    }

    function getSnapshotFromPast(uint256 snapshotsAgo)
        external view returns (uint256 rps, uint256 timestamp)
    {
        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        require(snapshotsAgo < available, "snapshot too old");

        uint256 idx = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);

        RateSnapshot memory s = recentSnapshots[idx];
        return (s.revenuePerShare, s.timestamp);
    }

    /**
     * @notice Annualised revenue growth rate over the past N days.
     *
     *         Formula: (revenuePerShare_now - revenuePerShare_then)
     *                  / revenuePerShare_then × annualised × 100
     *
     *         Interpretation: how fast cumulative earnings are growing relative
     *         to historical total. A rising APR means revenue is accelerating.
     *         Denominated in 1e8-scaled units (5_000_000 = 5.00% APR, 1_000_000 = 1.00%).
     *
     * @param  daysAgo  Look-back window in days (1–90).
     */
    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "invalid range");
        require(totalSnapshotCount > 0,        "no history");

        uint256 currentRps = revenuePerShare;
        (uint256 oldRps, uint256 oldTimestamp) = _findSnapshotBefore(block.timestamp - (daysAgo * 1 days));

        if (oldTimestamp == 0) {
            // History shorter than requested window — fall back to oldest snapshot.
            uint256 oldestIdx = totalSnapshotCount > MAX_SNAPSHOTS
                ? (snapshotIndex + 1) % MAX_SNAPSHOTS
                : 0;
            RateSnapshot memory s = recentSnapshots[oldestIdx];
            oldRps       = s.revenuePerShare;
            oldTimestamp = s.timestamp;
        }

        uint256 timeElapsed = block.timestamp - oldTimestamp;
        if (timeElapsed == 0 || oldRps == 0 || currentRps <= oldRps) return 0;

        apr = ((currentRps - oldRps) * SECONDS_PER_YEAR * 1e8) / (oldRps * timeElapsed);
    }

    /**
     * @notice Compound annual yield rate (APY) over the past N days.
     *         Approximation: ((currentRps / oldRps) ^ (year / elapsed)) - 1.
     *         Denominated in 1e8-scaled units (5_000_000 = 5.00% APY, 1_000_000 = 1.00%).
     *
     * @param  daysAgo  Look-back window in days (1–90).
     */
    function calculateAPY(uint256 daysAgo) external view returns (uint256 apy) {
        require(daysAgo > 0 && daysAgo <= 90, "invalid range");
        require(totalSnapshotCount > 0,        "no history");

        uint256 currentRps = revenuePerShare;
        (uint256 oldRps, uint256 oldTimestamp) = _findSnapshotBefore(block.timestamp - (daysAgo * 1 days));

        if (oldTimestamp == 0) {
            uint256 oldestIdx = totalSnapshotCount > MAX_SNAPSHOTS
                ? (snapshotIndex + 1) % MAX_SNAPSHOTS
                : 0;
            RateSnapshot memory s = recentSnapshots[oldestIdx];
            oldRps       = s.revenuePerShare;
            oldTimestamp = s.timestamp;
        }

        uint256 timeElapsed = block.timestamp - oldTimestamp;
        if (timeElapsed == 0 || oldRps == 0 || currentRps <= oldRps) return 0;

        // rateRatio = currentRps / oldRps (1e18-scaled for precision)
        uint256 rateRatio      = (currentRps * 1e18) / oldRps;
        uint256 periodsPerYear = SECONDS_PER_YEAR / timeElapsed;

        if (rateRatio <= 1e18) return 0;

        uint256 growth = rateRatio - 1e18;
        // apy = growth * periodsPerYear * 1e8 / 1e18
        apy = (growth * periodsPerYear * 1e8) / 1e18;
    }

    /**
     * @notice Gordon Growth Model (GGM) fair value per revenue share token.
     *
     *         Formula: P = D₁ / (r − g)
     *
     *           D₁  Annualised dividend per share, projected from the trailing
     *               30-day revenue rate. Expressed in raw USDC (6 decimals).
     *
     *           r   Investor's required annual return (discountRateBp).
     *               E.g. 1500 = 15 %.
     *
     *           g   Estimated dividend growth rate, derived entirely from
     *               onchain snapshot data: we compare the recent 7-day revenue
     *               rate against the 30-day baseline. If revenue is accelerating,
     *               g > 0. If flat or declining, g is clamped to 0 (pure annuity).
     *               GGM is undefined when r ≤ g, so the function returns 0 in
     *               that case — the token would need a lower discount rate or the
     *               growth signal is too strong to price with this model.
     *
     * @dev    Interpretation: this is a *model output*, not an oracle price.
     *         It provides a DCF anchor for secondary-market price discovery.
     *         Short history, volatile revenue, or an unrealistically low discount
     *         rate will all produce unreliable results — use with that caveat.
     *
     * @param  discountRateBp      Investor's required return in basis points (10 000 = 100 %).
     * @return fairValuePerShare   USDC fair value per share, 1e18-scaled.
     *                             Returns 0 when history is insufficient or r ≤ g.
     */
    function fairValue(uint256 discountRateBp)
        external view returns (uint256 fairValuePerShare)
    {
        if (totalSupply() == 0 || totalSnapshotCount < 2 || discountRateBp == 0) return 0;

        uint256 currentRps = revenuePerShare;
        uint256 now_       = block.timestamp;

        // ── D₁: annualised dividend per share from trailing 30d ──────────────
        (uint256 rps30, uint256 t30) = _findSnapshotBefore(now_ - 30 days);
        if (t30 == 0 || currentRps <= rps30) return 0;

        uint256 elapsed30 = now_ - t30;
        if (elapsed30 == 0) return 0;

        // revenuePerShare is SCALE-multiplied; annualDividend is raw USDC (6 dec) per share.
        uint256 rpsGrowth30    = currentRps - rps30;
        uint256 annualDividend = (rpsGrowth30 * SECONDS_PER_YEAR) / (elapsed30 * SCALE);
        if (annualDividend == 0) return 0;

        // ── g: growth rate from 7d vs 30d revenue run-rate ──────────────────
        // Compute revenue-per-second over each window; the ratio of recent to
        // baseline gives us how fast dividends are accelerating.
        uint256 growthBp = 0;
        (uint256 rps7, uint256 t7) = _findSnapshotBefore(now_ - 7 days);
        if (t7 != 0 && currentRps > rps7) {
            uint256 elapsed7 = now_ - t7;
            if (elapsed7 > 0) {
                // Rate in rps-units per second (1e6-scaled to avoid truncation)
                uint256 rate7d  = ((currentRps - rps7)  * 1e6) / elapsed7;
                uint256 rate30d = (rpsGrowth30           * 1e6) / elapsed30;
                if (rate7d > rate30d && rate30d > 0) {
                    // g (bp) = ((rate7d − rate30d) / rate30d) × 10 000
                    growthBp = ((rate7d - rate30d) * 10_000) / rate30d;
                }
            }
        }

        // ── GGM: P = D₁ / (r − g) ────────────────────────────────────────────
        if (discountRateBp <= growthBp) return 0; // model undefined; r must exceed g

        uint256 spreadBp = discountRateBp - growthBp;
        // annualDividend (6 dec USDC) × 1e18 × 10 000 / spreadBp → 1e18-scaled USDC per share
        fairValuePerShare = (annualDividend * 1e18 * 10_000) / spreadBp;
    }

    /// @notice Convenience view returning current 7-day and 30-day APRs.
    function getCurrentAPRs() external view returns (uint256 apr7d, uint256 apr30d) {
        if (totalSnapshotCount == 0) return (0, 0);
        try this.calculateAPR(7)  returns (uint256 a) { apr7d  = a; } catch { apr7d  = 0; }
        try this.calculateAPR(30) returns (uint256 a) { apr30d = a; } catch { apr30d = 0; }
    }
}
