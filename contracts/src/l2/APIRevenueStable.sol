// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../ProviderRevenueShare.sol";

/**
 * @title APIRevenueStable
 * @notice Yield-bearing stablecoin backed by USDC and powered by API revenue dividends.
 *
 * @dev    Adapted from GLUSD (Galaksio-OS). The treasury/depositFees model is replaced
 *         by a permissionless harvest() that calls claim() on a ProviderRevenueShare
 *         contract. This contract holds revenue share tokens; as API payments flow through
 *         the splitter and into the revenue share accumulator, anyone can call harvest()
 *         to pull the accrued USDC dividends into this contract's reserves, raising the
 *         exchange rate for all stable holders.
 *
 * Mechanism
 * ─────────
 *   1. This contract is given ProviderRevenueShare tokens at genesis
 *      (set this contract as revenueShareRecipient in the factory, or transfer shares
 *      after deployment). These tokens are the perpetual yield source — never burned.
 *
 *   2. As x402 payments flow through ProviderRevenueSplitter → ProviderRevenueShare,
 *      USDC accumulates claimable() for this contract's share allocation.
 *
 *   3. Anyone calls harvest(). This contract calls revenueShare.claim(), pulling
 *      accrued USDC into address(this). USDC.balanceOf(this) rises; totalSupply()
 *      is unchanged; exchangeRate() increases.
 *
 *   4. Users who hold this stablecoin passively benefit — their tokens are worth
 *      more USDC over time without any action required.
 *
 *   5. New users can mint() by depositing USDC at the current (appreciated) rate,
 *      or redeem() to exit at any time.
 *
 * Exchange rate
 * ─────────────
 *   rate = USDC.balanceOf(address(this)) * 1e6 / totalSupply()
 *
 *   Starts at 1.000000 (1 USDC per stable token). Rises monotonically as dividends
 *   are harvested. Never decreases — fees on mint/redeem go to feeRecipient, not
 *   back into the reserve pool.
 *
 * Differences from GLUSD
 * ──────────────────────
 *   - No treasury whitelist. Yield source is the immutable revenueShare address.
 *   - harvest() replaces depositFees(). Permissionless, no role required.
 *   - Exchange rate is computed from pre-deposit balance during mint(), not post-deposit
 *     (GLUSD computes rate after the USDC lands, which inflates the denominator and
 *     under-mints shares for the depositor — corrected here).
 *   - Name/symbol are configurable at deploy (no hardcoded "GLUSD").
 *   - No MAX_TOTAL_SUPPLY cap (the reserve is always fully backed; cap would be arbitrary).
 */
contract APIRevenueStable is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    //                               ROLES
    // =========================================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    // =========================================================================
    //                            YIELD SOURCE
    // =========================================================================

    /// @notice The ProviderRevenueShare contract this stable harvests dividends from.
    ///         This contract must hold revenue share tokens to earn dividends.
    ProviderRevenueShare public immutable revenueShare;

    /// @notice Underlying reserve asset (USDC). Sourced from revenueShare.USDC().
    IERC20 public immutable USDC;

    // =========================================================================
    //                             CONSTANTS
    // =========================================================================

    /// @notice Mint/redeem fee in basis points (0.5%).
    uint256 public constant FEE_BP = 50;

    uint256 public constant BP_SCALE = 10_000;

    /// @notice Seconds in a year — used for APR/APY calculations.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Minimum time between rate snapshots (30 seconds).
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;

    /// @notice Circular buffer size — 90 days at 1 snapshot per hour.
    uint256 public constant MAX_SNAPSHOTS = 2160;

    // =========================================================================
    //                           RATE SNAPSHOTS
    //                    (adapted from GLUSD by Galaksio-OS)
    //            Circular buffer tracking exchange rate history for APR/APY
    // =========================================================================

    struct RateSnapshot {
        uint256 rate;      // Exchange rate (USDC per stable, scaled by 1e6)
        uint256 timestamp; // Block timestamp
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =========================================================================
    //                               EVENTS
    // =========================================================================

    event Mint(address indexed user, uint256 usdcDeposited, uint256 stableMinted, uint256 fee);
    event Redeem(address indexed user, uint256 stableBurned, uint256 usdcReturned, uint256 fee);
    event Harvested(address indexed caller, uint256 usdcHarvested);
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =========================================================================
    //                             CONSTRUCTOR
    // =========================================================================

    /**
     * @param _revenueShare  ProviderRevenueShare this contract harvests from.
     *                       After deployment, transfer revenue share tokens to this
     *                       contract's address so it accrues dividends.
     * @param _feeRecipient  Address that receives mint/redeem fees.
     * @param _name          ERC20 name (e.g. "My API Revenue Stable").
     * @param _symbol        ERC20 symbol (e.g. "marsUSD").
     */
    constructor(
        ProviderRevenueShare _revenueShare,
        address              _feeRecipient,
        string memory        _name,
        string memory        _symbol
    )
        ERC20(_name, _symbol)
    {
        require(address(_revenueShare) != address(0), "zero revenue share");
        require(_feeRecipient          != address(0), "zero fee recipient");

        revenueShare = _revenueShare;
        USDC         = _revenueShare.USDC();
        admin        = msg.sender;
        pauser       = msg.sender;
        feeRecipient = _feeRecipient;

        // Seed snapshot ring buffer at the 1:1 initial rate
        recentSnapshots[0] = RateSnapshot({ rate: 1e6, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime   = block.timestamp;

        emit RateSnapshotTaken(1e6, block.timestamp);
    }

    // =========================================================================
    //                          EXCHANGE RATE
    // =========================================================================

    /// @notice Current exchange rate: USDC per stable token, scaled by 1e6.
    ///         Starts at 1e6 (1:1). Rises as dividends are harvested.
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        return (USDC.balanceOf(address(this)) * 1e6) / supply;
    }

    // =========================================================================
    //                              HARVEST
    // =========================================================================

    /**
     * @notice Pull any accrued USDC dividends from the revenue share contract
     *         into this contract's reserves. Raises the exchange rate for all holders.
     *
     *         Permissionless — anyone can call this. Bots, keepers, or users can
     *         trigger a harvest at any time. Returns silently if nothing is claimable.
     */
    function harvest() external nonReentrant {
        uint256 claimable = revenueShare.claimable(address(this));
        if (claimable == 0) return;

        uint256 balanceBefore = USDC.balanceOf(address(this));
        revenueShare.claim();
        uint256 harvested = USDC.balanceOf(address(this)) - balanceBefore;

        if (harvested > 0) {
            _takeSnapshotIfNeeded();
            emit Harvested(msg.sender, harvested);
        }
    }

    // =========================================================================
    //                            MINT / REDEEM
    // =========================================================================

    /**
     * @notice Mint stable tokens by depositing USDC at the current exchange rate.
     *         A 0.5% fee is deducted and sent to feeRecipient.
     *
     * @param  usdcAmount  Gross USDC to deposit (including fee). Caller must approve
     *                     this contract for this amount.
     * @return stableMinted  Net stable tokens minted to msg.sender.
     */
    function mint(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 stableMinted)
    {
        require(usdcAmount > 0, "zero amount");

        uint256 fee      = (usdcAmount * FEE_BP) / BP_SCALE;
        uint256 afterFee = usdcAmount - fee;

        // Snapshot reserve state BEFORE the deposit lands so the rate is not
        // inflated by the incoming USDC (fixes a known GLUSD mint calculation issue).
        uint256 supply      = totalSupply();
        uint256 reservePre  = USDC.balanceOf(address(this));

        USDC.safeTransferFrom(msg.sender, feeRecipient,   fee);
        USDC.safeTransferFrom(msg.sender, address(this), afterFee);

        // Shares = deposit * supply / reserves  (ERC4626-style, avoids rate inflation)
        if (supply == 0) {
            stableMinted = afterFee; // first mint is 1:1
        } else {
            stableMinted = (afterFee * supply) / reservePre;
        }

        require(stableMinted > 0, "mint amount too small");

        _mint(msg.sender, stableMinted);
        _takeSnapshotIfNeeded();

        emit Mint(msg.sender, usdcAmount, stableMinted, fee);
    }

    /**
     * @notice Redeem stable tokens for USDC at the current exchange rate.
     *         A 0.5% fee is deducted from the USDC returned.
     *
     * @param  stableAmount  Stable tokens to burn.
     * @return usdcOut       Net USDC returned to msg.sender (after fee).
     */
    function redeem(uint256 stableAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        require(stableAmount > 0,                      "zero amount");
        require(balanceOf(msg.sender) >= stableAmount, "insufficient balance");

        uint256 supply   = totalSupply();
        uint256 reserves = USDC.balanceOf(address(this));

        uint256 usdcGross = (stableAmount * reserves) / supply;
        require(usdcGross > 0, "redeem amount too small");

        uint256 fee = (usdcGross * FEE_BP) / BP_SCALE;
        usdcOut     = usdcGross - fee;

        // Burn first (checks-effects-interactions)
        _burn(msg.sender, stableAmount);

        USDC.safeTransfer(feeRecipient, fee);
        USDC.safeTransfer(msg.sender,   usdcOut);

        _takeSnapshotIfNeeded();

        emit Redeem(msg.sender, stableAmount, usdcOut, fee);
    }

    // =========================================================================
    //                          RATE SNAPSHOTS
    // =========================================================================

    /// @notice Manually trigger a rate snapshot (if enough time has passed).
    function takeSnapshot() external {
        _takeSnapshotIfNeeded();
    }

    function _takeSnapshotIfNeeded() internal {
        if (block.timestamp < lastSnapshotTime + MIN_SNAPSHOT_INTERVAL) return;
        if (totalSupply() == 0) return;

        uint256 rate = exchangeRate();
        snapshotIndex = (snapshotIndex + 1) % MAX_SNAPSHOTS;
        recentSnapshots[snapshotIndex] = RateSnapshot({ rate: rate, timestamp: block.timestamp });
        totalSnapshotCount++;
        lastSnapshotTime = block.timestamp;

        emit RateSnapshotTaken(rate, block.timestamp);
    }

    // =========================================================================
    //                           VIEW HELPERS
    // =========================================================================

    function decimals() public pure override returns (uint8) { return 6; }

    /// @notice USDC currently held in reserves.
    function totalReserves() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice USDC dividends claimable from the revenue share right now.
    function pendingHarvest() external view returns (uint256) {
        return revenueShare.claimable(address(this));
    }

    function getMostRecentSnapshot() external view returns (uint256 rate, uint256 timestamp) {
        RateSnapshot memory s = recentSnapshots[snapshotIndex];
        return (s.rate, s.timestamp);
    }

    function getSnapshotCount() external view returns (uint256) {
        return totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
    }

    function getSnapshotFromPast(uint256 snapshotsAgo)
        external view returns (uint256 rate, uint256 timestamp)
    {
        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        require(snapshotsAgo < available, "snapshot too old");

        uint256 idx = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);

        RateSnapshot memory s = recentSnapshots[idx];
        return (s.rate, s.timestamp);
    }

    /**
     * @notice Annualised yield rate over the past N days.
     *         Returns 0 if the rate has not increased (no yield yet).
     *         Denominated in 1e8-scaled basis points (500000 = 5.00% APR).
     */
    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "invalid range");
        require(totalSnapshotCount > 0,        "no history");

        uint256 currentRate     = exchangeRate();
        uint256 targetTimestamp = block.timestamp - (daysAgo * 1 days);
        uint256 oldRate;
        uint256 oldTimestamp;
        bool    found;

        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        for (uint256 i = 0; i < available; i++) {
            uint256 idx = i <= snapshotIndex
                ? snapshotIndex - i
                : MAX_SNAPSHOTS - (i - snapshotIndex);
            RateSnapshot memory s = recentSnapshots[idx];
            if (s.timestamp <= targetTimestamp) {
                oldRate      = s.rate;
                oldTimestamp = s.timestamp;
                found        = true;
                break;
            }
        }

        if (!found) {
            uint256 oldestIdx = totalSnapshotCount > MAX_SNAPSHOTS
                ? (snapshotIndex + 1) % MAX_SNAPSHOTS
                : 0;
            RateSnapshot memory s = recentSnapshots[oldestIdx];
            oldRate      = s.rate;
            oldTimestamp = s.timestamp;
        }

        uint256 timeElapsed = block.timestamp - oldTimestamp;
        if (timeElapsed == 0 || oldRate == 0 || currentRate <= oldRate) return 0;

        uint256 rateIncrease = currentRate - oldRate;
        apr = (rateIncrease * SECONDS_PER_YEAR * 1e8) / (oldRate * timeElapsed);
    }

    /// @notice Convenience view returning 7-day and 30-day APRs.
    function getCurrentAPRs() external view returns (uint256 apr7d, uint256 apr30d) {
        if (totalSnapshotCount == 0) return (0, 0);
        try this.calculateAPR(7)  returns (uint256 a) { apr7d  = a; } catch { apr7d  = 0; }
        try this.calculateAPR(30) returns (uint256 a) { apr30d = a; } catch { apr30d = 0; }
    }

    // =========================================================================
    //                               ADMIN
    // =========================================================================

    function pause() external {
        require(msg.sender == pauser, "only pauser");
        _pause();
    }

    function unpause() external {
        require(msg.sender == pauser, "only pauser");
        _unpause();
    }

    function setAdmin(address newAdmin) external {
        require(msg.sender == admin,    "only admin");
        require(newAdmin != address(0), "zero address");
        address old = admin;
        admin = newAdmin;
        emit AdminUpdated(old, newAdmin);
    }

    function setPauser(address newPauser) external {
        require(msg.sender == admin,     "only admin");
        require(newPauser != address(0), "zero address");
        address old = pauser;
        pauser = newPauser;
        emit PauserUpdated(old, newPauser);
    }

    function setFeeRecipient(address newRecipient) external {
        require(msg.sender == admin,        "only admin");
        require(newRecipient != address(0), "zero address");
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     *         Cannot rescue USDC (reserves) or revenue share tokens (yield source).
     */
    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin,                           "only admin");
        require(address(token) != address(USDC),              "cannot rescue reserves");
        require(address(token) != address(revenueShare),      "cannot rescue yield source");
        require(to != address(0),                             "zero address");
        token.safeTransfer(to, amount);
    }
}
