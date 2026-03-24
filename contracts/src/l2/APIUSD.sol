// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProviderRevenueShare.sol";

/// @title APIUSD — CDP Stablecoin Backed by RS Token Dividend Accumulation
///
/// @notice Users deposit ProviderRevenueShare (RS) tokens as collateral.
///         Collateral value equals the USDC dividends those tokens have earned
///         since deposit, tracked via a MasterChef-style USDC accumulator.
///         APIUSD is minted against this collateral at 70% LTV.
///
/// @dev    Dividend accounting (EPS-snapshot / MasterChef pattern):
///           earned(user) = (accUsdcPerRawShare - pos.rewardDebt) * pos.rsShares / PRECISION
///
///         Liquidation seizes ONLY dividends (USDC) — RS tokens are returned to the
///         original owner, preserving their equity stake in the API revenue stream.
///
///         Rate snapshots track accUsdcPerRawShare over time for APR display.
contract APIUSD is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                           ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    // =============================================================
    //                         COLLATERAL
    // =============================================================

    /// @notice The RS token whose accumulated dividends serve as collateral
    IProviderRevenueShare public immutable rs;

    /// @notice USDC — the dividend token paid out by RS
    IERC20 public immutable USDC;

    // =============================================================
    //                        CDP CONSTANTS
    // =============================================================

    uint256 public constant LTV_BP           = 7_000;        // 70% max borrow ratio
    uint256 public constant LIQ_THRESHOLD_BP = 8_000;        // 80% liquidation threshold
    uint256 public constant LIQ_BONUS_BP     = 500;          // 5% liquidator bonus
    uint256 public constant MINT_FEE_BP      = 50;           // 0.5% mint fee
    uint256 public constant BP_SCALE         = 10_000;
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6;  // 1M APIUSD hard cap

    /// @dev Precision scaling for the MasterChef USDC accumulator
    uint256 public constant PRECISION = 1e18;

    // =============================================================
    //                     ACCUMULATOR STATE
    // =============================================================

    /// @notice Total raw RS tokens currently held by this contract (6 dec units)
    uint256 public totalRSHeld;

    /// @notice Cumulative USDC harvested per raw RS token, scaled by PRECISION.
    ///         Increases monotonically each time _harvest() is called.
    uint256 public accUsdcPerRawShare;

    // =============================================================
    //                       CDP POSITIONS
    // =============================================================

    struct Position {
        uint256 rsShares;   // raw RS tokens deposited (6 dec; 1e6 = 1 whole share)
        uint256 debt;       // APIUSD outstanding
        /// @dev MasterChef reward debt:
        ///      earnedAtAnyTime = accUsdcPerRawShare * rsShares / PRECISION - rewardDebt
        uint256 rewardDebt;
    }

    mapping(address => Position) public positions;

    // =============================================================
    //                     RATE SNAPSHOT SYSTEM
    //    Tracks accUsdcPerRawShare over time to compute trailing APR
    // =============================================================

    uint256 public constant SECONDS_PER_YEAR      = 365 days;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;
    uint256 public constant MAX_SNAPSHOTS          = 2160;

    struct RateSnapshot {
        uint256 rate;      // accUsdcPerRawShare at this point in time
        uint256 timestamp;
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event PositionOpened(address indexed user, uint256 rsShares, uint256 apiusdMinted, uint256 fee);
    event CollateralAdded(address indexed user, uint256 rsShares, uint256 newTotal);
    event CollateralRemoved(address indexed user, uint256 rsShares, uint256 newTotal);
    event DebtIncreased(address indexed user, uint256 apiusdMinted, uint256 fee, uint256 newDebt);
    event Repaid(address indexed user, uint256 apiusdBurned, uint256 debtRemaining);
    event PositionClosed(address indexed user, uint256 rsSharesReturned);
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        uint256 debtCancelled,
        uint256 usdcSeized,
        uint256 liquidatorBonus
    );
    event Harvested(uint256 usdcGained, uint256 newAccUsdcPerRawShare);
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(
        IProviderRevenueShare _rs,
        IERC20 _usdc,
        address _feeRecipient
    ) ERC20("API USD", "APIUSD") {
        require(address(_rs)   != address(0), "APIUSD: zero rs");
        require(address(_usdc) != address(0), "APIUSD: zero usdc");
        require(_feeRecipient  != address(0), "APIUSD: zero fee recipient");

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
    //                          CDP CORE
    // =============================================================

    /// @notice Open a CDP: deposit RS tokens, optionally mint APIUSD.
    /// @param rsShares     Raw RS tokens to deposit as collateral.
    /// @param apiusdToMint Gross APIUSD to mint (fee deducted). 0 = lock only.
    function open(uint256 rsShares, uint256 apiusdToMint)
        external
        nonReentrant
        whenNotPaused
    {
        require(rsShares > 0,                         "APIUSD: zero collateral");
        require(positions[msg.sender].rsShares == 0,  "APIUSD: position exists");

        _harvest();

        IERC20(address(rs)).safeTransferFrom(msg.sender, address(this), rsShares);
        totalRSHeld += rsShares;

        positions[msg.sender] = Position({
            rsShares:   rsShares,
            debt:       0,
            rewardDebt: (accUsdcPerRawShare * rsShares) / PRECISION
        });

        uint256 fee;
        if (apiusdToMint > 0) {
            fee = _mintDebt(msg.sender, apiusdToMint);
        }

        _takeSnapshotIfNeeded();
        emit PositionOpened(msg.sender, rsShares, apiusdToMint, fee);
    }

    /// @notice Add more RS tokens to an existing position.
    function addCollateral(uint256 rsShares) external nonReentrant whenNotPaused {
        require(rsShares > 0,                         "APIUSD: zero amount");
        require(positions[msg.sender].rsShares > 0,   "APIUSD: no position");

        _harvest();

        Position storage pos = positions[msg.sender];
        // Preserve already-earned USDC by recalculating rewardDebt after balance change
        uint256 currentEarned = _positionEarned(pos);
        uint256 newShares     = pos.rsShares + rsShares;

        IERC20(address(rs)).safeTransferFrom(msg.sender, address(this), rsShares);
        totalRSHeld  += rsShares;
        pos.rsShares  = newShares;
        // New rewardDebt: set such that earned remains currentEarned
        pos.rewardDebt = (accUsdcPerRawShare * newShares) / PRECISION - currentEarned;

        _takeSnapshotIfNeeded();
        emit CollateralAdded(msg.sender, rsShares, newShares);
    }

    /// @notice Withdraw RS tokens from an existing position.
    ///         Must remain healthy at LTV after removal.
    function removeCollateral(uint256 rsShares) external nonReentrant whenNotPaused {
        Position storage pos = positions[msg.sender];
        require(pos.rsShares > 0,                          "APIUSD: no position");
        require(rsShares > 0 && rsShares <= pos.rsShares,  "APIUSD: invalid amount");

        _harvest();

        uint256 currentEarned = _positionEarned(pos);
        uint256 newShares     = pos.rsShares - rsShares;
        totalRSHeld  -= rsShares;
        pos.rsShares  = newShares;

        if (newShares == 0) {
            pos.rewardDebt = 0;
        } else {
            uint256 gross = (accUsdcPerRawShare * newShares) / PRECISION;
            pos.rewardDebt = gross > currentEarned ? gross - currentEarned : 0;
        }

        // Health check uses collateral value which calls _positionEarned internally
        require(
            pos.debt == 0 || _positionEarned(pos) >= (pos.debt * BP_SCALE) / LTV_BP,
            "APIUSD: undercollateralized after removal"
        );

        IERC20(address(rs)).safeTransfer(msg.sender, rsShares);

        _takeSnapshotIfNeeded();
        emit CollateralRemoved(msg.sender, rsShares, newShares);
    }

    /// @notice Mint additional APIUSD against existing collateral.
    function mintMore(uint256 apiusdAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 fee)
    {
        require(positions[msg.sender].rsShares > 0, "APIUSD: no position");
        _harvest();
        fee = _mintDebt(msg.sender, apiusdAmount);
        _takeSnapshotIfNeeded();
        emit DebtIncreased(msg.sender, apiusdAmount, fee, positions[msg.sender].debt);
    }

    /// @notice Repay APIUSD debt.
    function repay(uint256 apiusdAmount) external nonReentrant {
        Position storage pos = positions[msg.sender];
        require(apiusdAmount > 0 && apiusdAmount <= pos.debt, "APIUSD: invalid repay amount");

        _burn(msg.sender, apiusdAmount);
        pos.debt -= apiusdAmount;

        _takeSnapshotIfNeeded();
        emit Repaid(msg.sender, apiusdAmount, pos.debt);
    }

    /// @notice Fully close a position: repay all debt and reclaim all RS tokens.
    function close() external nonReentrant {
        Position storage pos = positions[msg.sender];
        require(pos.rsShares > 0, "APIUSD: no position");

        if (pos.debt > 0) {
            _burn(msg.sender, pos.debt);
        }

        uint256 shares = pos.rsShares;
        totalRSHeld   -= shares;
        delete positions[msg.sender];

        IERC20(address(rs)).safeTransfer(msg.sender, shares);

        _takeSnapshotIfNeeded();
        emit PositionClosed(msg.sender, shares);
    }

    /// @notice Liquidate an undercollateralised position.
    ///
    ///         Only the accumulated USDC dividends are seized. The RS tokens are
    ///         returned to the original owner — their equity stake is preserved.
    ///         Liquidator must hold sufficient APIUSD to burn the full debt.
    ///
    /// @param user  The CDP owner to liquidate.
    function liquidate(address user) external nonReentrant whenNotPaused {
        require(user != address(0), "APIUSD: zero user");

        _harvest();

        Position storage pos = positions[user];
        require(pos.debt > 0, "APIUSD: no debt");

        uint256 colVal = _positionEarnedView(pos);
        require(pos.debt > (colVal * LIQ_THRESHOLD_BP) / BP_SCALE, "APIUSD: position is healthy");

        uint256 debt     = pos.debt;
        uint256 rsShares = pos.rsShares;
        uint256 earned   = _positionEarned(pos);

        totalRSHeld -= rsShares;
        delete positions[user];

        // Liquidator burns the full debt
        _burn(msg.sender, debt);

        // Liquidator receives a 5% bonus from the earned USDC
        uint256 bonus;
        uint256 usdcSeized;
        if (earned >= debt) {
            bonus     = (debt * LIQ_BONUS_BP) / BP_SCALE;
            if (debt + bonus > earned) bonus = earned - debt;
            usdcSeized = debt + bonus;
        } else {
            // Bad debt: liquidator gets all earned, remaining debt is socialised
            usdcSeized = earned;
            bonus      = 0;
        }

        if (usdcSeized > 0) {
            USDC.safeTransfer(msg.sender, usdcSeized);
        }

        // RS tokens returned to original owner
        IERC20(address(rs)).safeTransfer(user, rsShares);

        _takeSnapshotIfNeeded();
        emit Liquidated(msg.sender, user, debt, usdcSeized, bonus);
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    /// @dev Pull any claimable USDC from the RS token and credit the accumulator.
    function _harvest() internal {
        uint256 claimable = rs.claimable(address(this));
        if (claimable == 0 || totalRSHeld == 0) return;

        rs.claim(address(this));
        accUsdcPerRawShare += (claimable * PRECISION) / totalRSHeld;

        emit Harvested(claimable, accUsdcPerRawShare);
    }

    /// @dev USDC earned by a position (uses current on-chain accUsdcPerRawShare).
    ///      Modifies nothing — safe to call from views if totalRSHeld is in storage.
    function _positionEarned(Position storage pos) internal view returns (uint256) {
        return (accUsdcPerRawShare * pos.rsShares) / PRECISION - pos.rewardDebt;
    }

    /// @dev Like _positionEarned but includes pending unclaimed USDC for real-time views.
    function _positionEarnedView(Position storage pos) internal view returns (uint256) {
        uint256 currentAcc = accUsdcPerRawShare;
        uint256 pending    = rs.claimable(address(this));
        if (pending > 0 && totalRSHeld > 0) {
            currentAcc += (pending * PRECISION) / totalRSHeld;
        }
        return (currentAcc * pos.rsShares) / PRECISION - pos.rewardDebt;
    }

    /// @dev Mint apiusdAmount gross; MINT_FEE_BP goes to feeRecipient.
    function _mintDebt(address user, uint256 apiusdAmount) internal returns (uint256 fee) {
        require(apiusdAmount > 0, "APIUSD: zero mint");

        fee = (apiusdAmount * MINT_FEE_BP) / BP_SCALE;
        uint256 netMint = apiusdAmount - fee;

        require(totalSupply() + apiusdAmount <= MAX_TOTAL_SUPPLY, "APIUSD: supply cap");

        Position storage pos = positions[user];
        pos.debt += netMint;

        uint256 colVal = _positionEarned(pos);
        require(pos.debt <= (colVal * LTV_BP) / BP_SCALE, "APIUSD: mint exceeds LTV");

        if (fee > 0) _mint(feeRecipient, fee);
        _mint(user, netMint);
    }

    function _takeSnapshotIfNeeded() internal {
        if (block.timestamp < lastSnapshotTime + MIN_SNAPSHOT_INTERVAL) return;

        snapshotIndex = (snapshotIndex + 1) % MAX_SNAPSHOTS;
        recentSnapshots[snapshotIndex] = RateSnapshot({
            rate:      accUsdcPerRawShare,
            timestamp: block.timestamp
        });
        totalSnapshotCount++;
        lastSnapshotTime = block.timestamp;

        emit RateSnapshotTaken(accUsdcPerRawShare, block.timestamp);
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    /// @notice Real-time USDC collateral value for a user's position.
    function collateralValue(address user) external view returns (uint256) {
        return _positionEarnedView(positions[user]);
    }

    /// @notice Health factor (1e6-scaled; < 1e6 = liquidatable).
    function healthFactor(address user) external view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.debt == 0) return type(uint256).max;
        uint256 colVal = _positionEarnedView(pos);
        if (colVal == 0) return 0;
        return (colVal * LIQ_THRESHOLD_BP * 1e6) / (pos.debt * BP_SCALE);
    }

    /// @notice Maximum additional APIUSD mintable at current LTV.
    function maxMintable(address user) external view returns (uint256) {
        Position storage pos = positions[user];
        uint256 colVal  = _positionEarnedView(pos);
        uint256 maxDebt = (colVal * LTV_BP) / BP_SCALE;
        if (maxDebt <= pos.debt) return 0;
        return maxDebt - pos.debt;
    }

    /// @notice Whether a position is currently liquidatable.
    function isLiquidatable(address user) external view returns (bool) {
        Position storage pos = positions[user];
        if (pos.debt == 0) return false;
        uint256 colVal = _positionEarnedView(pos);
        return pos.debt > (colVal * LIQ_THRESHOLD_BP) / BP_SCALE;
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
        require(snapshotsAgo < available, "APIUSD: snapshot too old");
        uint256 idx = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);
        RateSnapshot memory s = recentSnapshots[idx];
        return (s.rate, s.timestamp);
    }

    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "APIUSD: invalid range");
        require(totalSnapshotCount > 0,        "APIUSD: no history");

        uint256 currentRate = accUsdcPerRawShare;
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

    function pause()   external { require(msg.sender == pauser, "APIUSD: only pauser"); _pause(); }
    function unpause() external { require(msg.sender == pauser, "APIUSD: only pauser"); _unpause(); }

    function setAdmin(address v) external {
        require(msg.sender == admin, "APIUSD: only admin");
        require(v != address(0),     "APIUSD: zero address");
        emit AdminUpdated(admin, v);
        admin = v;
    }

    function setPauser(address v) external {
        require(msg.sender == admin, "APIUSD: only admin");
        require(v != address(0),     "APIUSD: zero address");
        emit PauserUpdated(pauser, v);
        pauser = v;
    }

    function setFeeRecipient(address v) external {
        require(msg.sender == admin, "APIUSD: only admin");
        require(v != address(0),     "APIUSD: zero address");
        emit FeeRecipientUpdated(feeRecipient, v);
        feeRecipient = v;
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin,             "APIUSD: only admin");
        require(address(token) != address(rs),   "APIUSD: cannot rescue RS tokens");
        require(address(token) != address(this), "APIUSD: cannot rescue APIUSD");
        require(to != address(0),                "APIUSD: zero address");
        token.safeTransfer(to, amount);
    }
}
