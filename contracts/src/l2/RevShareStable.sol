// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProviderRevenueShare.sol";

/// @title RevShareStable — RS Token Yield-Bearing Stable
///
/// @notice Architecture A — RS-token-native version.
///
///         Users deposit RS tokens → receive RevShareStable tokens.
///         RevShareStable tokens represent a claim on BOTH the RS tokens AND their
///         accumulated USDC dividends. The exchange rate (USDC per stable) starts
///         at zero and grows as dividends accumulate — it is NOT pegged to 1.0.
///
///         Mint:   deposit RS tokens → receive RevShareStable proportional to
///                 the current USDC value of those RS tokens.
///         Redeem: burn RevShareStable → receive pro-rata RS tokens AND
///                 any harvested USDC dividends for that proportional share.
///
/// @dev    Exchange rate = accumulated USDC (claimed + claimable) × 1e6 / stable supply
///         Yield source  = RS token dividends (from x402 API payments)
///         Fees          = taken as RS tokens on mint/redeem
contract RevShareStable is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                            ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    // =============================================================
    //                         COLLATERAL
    // =============================================================

    /// @notice The RS token that backs this stable
    IProviderRevenueShare public immutable rs;

    /// @notice USDC — the dividend token
    IERC20 public immutable USDC;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    uint256 public constant FEE_BP           = 50;          // 0.5% on mint and redeem
    uint256 public constant BP_SCALE         = 10_000;
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6; // 1M cap

    // =============================================================
    //                     ACCUMULATOR STATE
    // =============================================================

    /// @notice Total RS tokens held by this contract (6 dec raw units)
    uint256 public rsHeld;

    /// @notice Cumulative USDC claimed from the RS token since contract deployment
    uint256 public totalClaimedUsdc;

    // =============================================================
    //                     RATE SNAPSHOT SYSTEM
    // =============================================================

    uint256 public constant SECONDS_PER_YEAR      = 365 days;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;
    uint256 public constant MAX_SNAPSHOTS          = 2160;

    struct RateSnapshot {
        uint256 rate;      // exchangeRate() at snapshot (1e6-scaled USDC per stable)
        uint256 timestamp;
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event Mint(address indexed user, uint256 rsDeposited, uint256 stableMinted, uint256 feeRS);
    event Redeem(address indexed user, uint256 stableBurned, uint256 rsReturned, uint256 usdcReturned, uint256 feeRS);
    event Harvested(uint256 usdcClaimed);
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(
        IProviderRevenueShare _rs,
        IERC20 _usdc,
        address _feeRecipient
    ) ERC20("Revenue Share Stable", "rvsUSD") {
        require(address(_rs)   != address(0), "RSS: zero rs");
        require(address(_usdc) != address(0), "RSS: zero usdc");
        require(_feeRecipient  != address(0), "RSS: zero fee recipient");

        rs           = _rs;
        USDC         = _usdc;
        admin        = msg.sender;
        pauser       = msg.sender;
        feeRecipient = _feeRecipient;

        recentSnapshots[0] = RateSnapshot({ rate: 0, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime   = block.timestamp;
    }

    function decimals() public pure override returns (uint8) { return 6; }

    // =============================================================
    //                           CORE LOGIC
    // =============================================================

    /// @notice Deposit RS tokens to mint RevShareStable.
    ///         Minted amount is proportional to the USDC value of the deposited RS tokens
    ///         relative to the total accumulated USDC backing the current supply.
    ///         First depositor receives stable tokens equal to the RS tokens deposited.
    ///
    /// @param  rsIn  Raw RS tokens to deposit (fee deducted).
    /// @return stableMinted  Net RevShareStable received.
    function mint(uint256 rsIn)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 stableMinted)
    {
        require(rsIn > 0, "RSS: zero amount");

        uint256 feeRS   = (rsIn * FEE_BP) / BP_SCALE;
        uint256 netRS   = rsIn - feeRS;

        // Pull all RS tokens (net to contract, fee to feeRecipient)
        IERC20(address(rs)).safeTransferFrom(msg.sender, address(this), netRS);
        if (feeRS > 0) IERC20(address(rs)).safeTransferFrom(msg.sender, feeRecipient, feeRS);

        uint256 supply = totalSupply();
        if (supply == 0) {
            // First depositor: 1:1 in RS token units
            stableMinted = netRS;
        } else {
            // Mint proportional to the USDC value being added vs total backing
            // Total accumulated USDC backing = claimed + claimable (real-time)
            uint256 totalBacking = _totalAccumulatedUsdc();
            require(totalBacking > 0, "RSS: zero backing, redeem first");
            // USDC value being added ≈ proportional share of future dividends for netRS tokens
            // We use share proportion: netRS / (rsHeld + netRS) * totalBacking
            uint256 addedValue = (netRS * totalBacking) / (rsHeld + netRS);
            stableMinted = (addedValue * supply) / totalBacking;
        }

        require(stableMinted > 0,                          "RSS: mint too small");
        require(supply + stableMinted <= MAX_TOTAL_SUPPLY, "RSS: supply cap");

        rsHeld += netRS;
        _mint(msg.sender, stableMinted);
        _takeSnapshotIfNeeded();

        emit Mint(msg.sender, rsIn, stableMinted, feeRS);
    }

    /// @notice Burn RevShareStable to receive proportional RS tokens and USDC dividends.
    ///
    ///         Returns:
    ///         - rsOut:   proportional RS tokens from the locked pool
    ///         - usdcOut: proportional share of all harvested USDC in this contract
    ///
    /// @param  stableAmount  RevShareStable to burn.
    function redeem(uint256 stableAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 rsOut, uint256 usdcOut)
    {
        require(stableAmount > 0,                          "RSS: zero amount");
        require(totalSupply() > 0,                         "RSS: no supply");
        require(balanceOf(msg.sender) >= stableAmount,     "RSS: insufficient balance");

        // Harvest pending USDC before computing proportional share
        _harvest();

        uint256 supply = totalSupply();

        // Proportional RS tokens (gross → apply fee)
        uint256 grossRS = (rsHeld * stableAmount) / supply;
        uint256 feeRS   = (grossRS * FEE_BP) / BP_SCALE;
        rsOut           = grossRS - feeRS;

        // Proportional USDC (no additional fee — fee already charged on RS)
        uint256 usdcBalance = USDC.balanceOf(address(this));
        usdcOut = (usdcBalance * stableAmount) / supply;

        require(rsOut <= rsHeld, "RSS: insufficient RS");

        rsHeld -= grossRS; // deduct gross (fee goes to feeRecipient, not back to pool)
        _burn(msg.sender, stableAmount);

        if (rsOut > 0)    IERC20(address(rs)).safeTransfer(msg.sender, rsOut);
        if (feeRS > 0)    IERC20(address(rs)).safeTransfer(feeRecipient, feeRS);
        if (usdcOut > 0)  USDC.safeTransfer(msg.sender, usdcOut);

        _takeSnapshotIfNeeded();
        emit Redeem(msg.sender, stableAmount, rsOut, usdcOut, feeRS);
    }

    /// @notice Permissionless: claim pending USDC dividends from the RS token.
    function harvest() external nonReentrant {
        uint256 claimed = _harvest();
        require(claimed > 0, "RSS: nothing to harvest");
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    /// @notice Current USDC backing: claimed USDC in contract + pending claimable.
    function totalAccumulatedUsdc() external view returns (uint256) {
        return _totalAccumulatedUsdc();
    }

    /// @notice Exchange rate: USDC value per RevShareStable (1e6-scaled).
    ///         Starts at 0 and grows as dividends accumulate — NOT pegged at 1.0.
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 backing = _totalAccumulatedUsdc();
        return (backing * 1e6) / supply;
    }

    function remainingMintable() external view returns (uint256) {
        uint256 s = totalSupply();
        return s >= MAX_TOTAL_SUPPLY ? 0 : MAX_TOTAL_SUPPLY - s;
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
        require(snapshotsAgo < available, "RSS: snapshot too old");
        uint256 idx = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);
        RateSnapshot memory s = recentSnapshots[idx];
        return (s.rate, s.timestamp);
    }

    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "RSS: invalid range");
        require(totalSnapshotCount > 0,        "RSS: no history");

        uint256 currentRate = exchangeRate();
        uint256 targetTs    = block.timestamp - (daysAgo * 1 days);
        (uint256 oldRate, uint256 oldTs) = _findSnapshot(targetTs);

        uint256 elapsed = block.timestamp - oldTs;
        if (elapsed == 0 || oldRate == 0 || currentRate <= oldRate) return 0;

        apr = ((currentRate - oldRate) * SECONDS_PER_YEAR * 1e8) / (oldRate * elapsed);
    }

    function getCurrentAPRs() external view returns (uint256 apr7d, uint256 apr30d) {
        if (totalSnapshotCount == 0) return (0, 0);
        try this.calculateAPR(7)  returns (uint256 a) { apr7d  = a; } catch { apr7d  = 0; }
        try this.calculateAPR(30) returns (uint256 a) { apr30d = a; } catch { apr30d = 0; }
    }

    // =============================================================
    //                           INTERNAL
    // =============================================================

    /// @dev Total USDC backing = USDC already in contract + pending claimable.
    function _totalAccumulatedUsdc() internal view returns (uint256) {
        return USDC.balanceOf(address(this)) + rs.claimable(address(this));
    }

    function _harvest() internal returns (uint256 claimed) {
        claimed = rs.claimable(address(this));
        if (claimed == 0) return 0;
        rs.claim(address(this));
        totalClaimedUsdc += claimed;
        emit Harvested(claimed);
    }

    function _takeSnapshotIfNeeded() internal {
        if (block.timestamp < lastSnapshotTime + MIN_SNAPSHOT_INTERVAL) return;
        if (totalSupply() == 0) return;

        uint256 rate  = exchangeRate();
        snapshotIndex = (snapshotIndex + 1) % MAX_SNAPSHOTS;
        recentSnapshots[snapshotIndex] = RateSnapshot({ rate: rate, timestamp: block.timestamp });
        totalSnapshotCount++;
        lastSnapshotTime = block.timestamp;

        emit RateSnapshotTaken(rate, block.timestamp);
    }

    function _findSnapshot(uint256 targetTs) internal view returns (uint256 rate, uint256 ts) {
        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        for (uint256 i = 0; i < available; i++) {
            uint256 idx = i <= snapshotIndex
                ? snapshotIndex - i
                : MAX_SNAPSHOTS - (i - snapshotIndex);
            RateSnapshot memory s = recentSnapshots[idx];
            if (s.timestamp <= targetTs) return (s.rate, s.timestamp);
        }
        uint256 oldestIdx = totalSnapshotCount > MAX_SNAPSHOTS
            ? (snapshotIndex + 1) % MAX_SNAPSHOTS
            : 0;
        RateSnapshot memory oldest = recentSnapshots[oldestIdx];
        return (oldest.rate, oldest.timestamp);
    }

    // =============================================================
    //                             ADMIN
    // =============================================================

    function pause()   external { require(msg.sender == pauser, "RSS: only pauser"); _pause(); }
    function unpause() external { require(msg.sender == pauser, "RSS: only pauser"); _unpause(); }

    function setAdmin(address v) external {
        require(msg.sender == admin, "RSS: only admin");
        require(v != address(0), "RSS: zero address");
        emit AdminUpdated(admin, v);
        admin = v;
    }

    function setPauser(address v) external {
        require(msg.sender == admin, "RSS: only admin");
        require(v != address(0), "RSS: zero address");
        emit PauserUpdated(pauser, v);
        pauser = v;
    }

    function setFeeRecipient(address v) external {
        require(msg.sender == admin, "RSS: only admin");
        require(v != address(0), "RSS: zero address");
        emit FeeRecipientUpdated(feeRecipient, v);
        feeRecipient = v;
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin,             "RSS: only admin");
        require(address(token) != address(rs),   "RSS: cannot rescue RS tokens");
        require(address(token) != address(this), "RSS: cannot rescue stable");
        require(to != address(0),                "RSS: zero address");
        token.safeTransfer(to, amount);
    }
}
