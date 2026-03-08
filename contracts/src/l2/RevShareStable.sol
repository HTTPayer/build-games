// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title RevShareStable — Pure Vault Share Yield-Bearing Stablecoin
/// @notice Architecture A: Users deposit ProviderRevenueVault shares directly.
///         The stablecoin's exchange rate appreciates as API revenue flows into the
///         backing vault, making every token worth more USDC over time.
///
/// @dev    Mint:   deposit vault shares → receive RevShareStable at current rate
///         Redeem: burn RevShareStable  → receive vault shares at current rate
///
///         Exchange rate = vault.convertToAssets(sharesHeld) * 1e6 / totalSupply
///         Yield source  = vault share price appreciation (from x402 API payments)
///
///         Fees are denominated in vault shares (consistent with in/out token).
///         Rate snapshots track exchange rate for onchain APR/APY display.
///
///         Adapted from GLUSD (Galaksio-OS) — same snapshot/APR machinery,
///         vault shares replace raw USDC as the collateral token.
contract RevShareStable is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                           ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    // =============================================================
    //                        COLLATERAL
    // =============================================================

    /// @notice The ERC4626 vault whose shares back this stablecoin
    IERC4626 public immutable vault;

    /// @notice Underlying asset of the vault (USDC) — used for decimal reference
    IERC20 public immutable USDC;

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    uint256 public constant FEE_BP       = 50;          // 0.5% on mint and redeem
    uint256 public constant BP_SCALE     = 10_000;
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6; // 1M cap

    // =============================================================
    //                     RATE SNAPSHOT SYSTEM
    //              (adapted from GLUSD by Galaksio-OS)
    // =============================================================

    uint256 public constant SECONDS_PER_YEAR      = 365 days;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;
    uint256 public constant MAX_SNAPSHOTS          = 2160;

    struct RateSnapshot {
        uint256 rate;      // exchangeRate() at snapshot time (1e6-scaled)
        uint256 timestamp;
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event Mint(address indexed user, uint256 sharesDeposited, uint256 stableMinted, uint256 feeShares);
    event Redeem(address indexed user, uint256 stableBurned, uint256 sharesReturned, uint256 feeShares);
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(IERC4626 _vault, address _feeRecipient) ERC20("Revenue Share Stable", "rvsUSD") {
        require(address(_vault) != address(0), "RSS: zero vault");
        require(_feeRecipient != address(0), "RSS: zero fee recipient");

        vault = _vault;
        USDC = IERC20(_vault.asset());
        admin = msg.sender;
        pauser = msg.sender;
        feeRecipient = _feeRecipient;

        uint256 initialRate = _exchangeRate(0, 0);
        recentSnapshots[0] = RateSnapshot({ rate: initialRate, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime = block.timestamp;

        emit RateSnapshotTaken(initialRate, block.timestamp);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // =============================================================
    //                          CORE LOGIC
    // =============================================================

    /// @notice Deposit vault shares to mint RevShareStable tokens.
    /// @param  sharesIn  Amount of vault shares to deposit (includes fee).
    /// @return stableMinted  Net stable tokens received after fee.
    function mint(uint256 sharesIn)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 stableMinted)
    {
        require(sharesIn > 0, "RSS: zero amount");

        uint256 feeShares = (sharesIn * FEE_BP) / BP_SCALE;
        uint256 netShares = sharesIn - feeShares;

        // Compute USDC value of net shares at current vault price
        uint256 usdcValue = vault.convertToAssets(netShares);

        // Exchange rate BEFORE deposit (avoids inflating against yourself)
        uint256 supply = totalSupply();
        if (supply == 0) {
            stableMinted = usdcValue;
        } else {
            uint256 rate = exchangeRate();
            require(rate > 0, "RSS: invalid rate");
            stableMinted = (usdcValue * 1e6) / rate;
        }

        require(stableMinted > 0, "RSS: mint too small");
        require(supply + stableMinted <= MAX_TOTAL_SUPPLY, "RSS: supply cap");

        // Pull all shares from user — net to contract, fee to feeRecipient
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), netShares);
        if (feeShares > 0) {
            IERC20(address(vault)).safeTransferFrom(msg.sender, feeRecipient, feeShares);
        }

        _mint(msg.sender, stableMinted);
        _takeSnapshotIfNeeded();

        emit Mint(msg.sender, sharesIn, stableMinted, feeShares);
    }

    /// @notice Burn RevShareStable tokens to redeem underlying vault shares.
    /// @param  stableAmount  Amount of RevShareStable to burn.
    /// @return sharesOut  Net vault shares returned after fee.
    function redeem(uint256 stableAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 sharesOut)
    {
        require(stableAmount > 0, "RSS: zero amount");
        require(totalSupply() > 0, "RSS: no supply");
        require(balanceOf(msg.sender) >= stableAmount, "RSS: insufficient balance");

        uint256 rate = exchangeRate();

        // USDC value owed → convert to gross vault shares
        uint256 usdcGross = (stableAmount * rate) / 1e6;
        uint256 sharesGross = vault.convertToShares(usdcGross);
        require(sharesGross > 0, "RSS: redeem too small");
        require(sharesGross <= IERC20(address(vault)).balanceOf(address(this)), "RSS: insufficient shares");

        uint256 feeShares = (sharesGross * FEE_BP) / BP_SCALE;
        sharesOut = sharesGross - feeShares;

        _burn(msg.sender, stableAmount);

        IERC20(address(vault)).safeTransfer(msg.sender, sharesOut);
        if (feeShares > 0) {
            IERC20(address(vault)).safeTransfer(feeRecipient, feeShares);
        }

        _takeSnapshotIfNeeded();
        emit Redeem(msg.sender, stableAmount, sharesOut, feeShares);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Current exchange rate: USDC value per RevShareStable (1e6-scaled).
    ///         Starts at 1e6 (1.0) and increases as API revenue accrues to the vault.
    function exchangeRate() public view returns (uint256) {
        return _exchangeRate(
            IERC20(address(vault)).balanceOf(address(this)),
            totalSupply()
        );
    }

    function vaultStatus() external view returns (uint256 sharesHeld, uint256 usdcValue, uint256 supply) {
        sharesHeld = IERC20(address(vault)).balanceOf(address(this));
        usdcValue  = vault.convertToAssets(sharesHeld);
        supply     = totalSupply();
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

    function getSnapshotFromPast(uint256 snapshotsAgo) external view returns (uint256 rate, uint256 timestamp) {
        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        require(snapshotsAgo < available, "RSS: snapshot too old");
        uint256 idx = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);
        RateSnapshot memory s = recentSnapshots[idx];
        return (s.rate, s.timestamp);
    }

    /// @notice Annualized yield of the backing vault over the past N days.
    ///         Denominated in 1e8-scaled BP (500000 = 5.00% APR).
    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "RSS: invalid range");
        require(totalSnapshotCount > 0, "RSS: no history");

        uint256 currentRate = exchangeRate();
        uint256 targetTs = block.timestamp - (daysAgo * 1 days);
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
    //                        INTERNAL
    // =============================================================

    function _exchangeRate(uint256 sharesHeld, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return 1e6;
        uint256 usdcValue = vault.convertToAssets(sharesHeld);
        return (usdcValue * 1e6) / supply;
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

    function _findSnapshot(uint256 targetTs) internal view returns (uint256 rate, uint256 ts) {
        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        for (uint256 i = 0; i < available; i++) {
            uint256 idx = i <= snapshotIndex
                ? snapshotIndex - i
                : MAX_SNAPSHOTS - (i - snapshotIndex);
            RateSnapshot memory s = recentSnapshots[idx];
            if (s.timestamp <= targetTs) {
                return (s.rate, s.timestamp);
            }
        }
        // Fallback: oldest snapshot
        uint256 oldestIdx = totalSnapshotCount > MAX_SNAPSHOTS ? (snapshotIndex + 1) % MAX_SNAPSHOTS : 0;
        RateSnapshot memory oldest = recentSnapshots[oldestIdx];
        return (oldest.rate, oldest.timestamp);
    }

    // =============================================================
    //                           ADMIN
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
        require(msg.sender == admin, "RSS: only admin");
        require(address(token) != address(vault), "RSS: cannot rescue vault shares");
        require(address(token) != address(this),  "RSS: cannot rescue stable");
        require(to != address(0), "RSS: zero address");
        token.safeTransfer(to, amount);
    }
}
