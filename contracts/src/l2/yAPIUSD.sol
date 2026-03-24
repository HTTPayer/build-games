// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProviderRevenueShare.sol";

/// @title yAPIUSD — Yield-Bearing Stablecoin Backed by RS Token Dividends
///
/// @notice Architecture B — RS-token-native version.
///
///         Treasury deposits RS tokens as the yield engine (permanently locked).
///         Users deposit USDC → receive yAPIUSD at the current exchange rate.
///         As the RS tokens earn dividends, the exchange rate rises automatically,
///         making every yAPIUSD worth more USDC over time.
///
/// @dev    Exchange rate = (USDC in contract + rs.claimable(address(this))) * 1e6
///                         ────────────────────────────────────────────────────
///                                        yAPIUSD total supply
///
///         The claimable() term makes the rate update continuously between harvests.
///         harvest() is permissionless — call it to crystallise pending USDC.
///
///         RS tokens are NEVER redeemed. They remain locked as the permanent
///         yield engine. Only USDC dividends flow in/out.
contract yAPIUSD is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                            ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    /// @notice Addresses authorised to deposit RS tokens (treasury / provider)
    mapping(address => bool) public isTreasury;

    // =============================================================
    //                         BACKING ASSETS
    // =============================================================

    /// @notice The RS token that generates yield via USDC dividends
    IProviderRevenueShare public immutable rs;

    /// @notice USDC — the stable in/out token for users
    IERC20 public immutable USDC;

    // =============================================================
    //                           CONSTANTS
    // =============================================================

    uint256 public constant FEE_BP           = 50;           // 0.5% on mint and redeem
    uint256 public constant BP_SCALE         = 10_000;
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6;  // 1M yAPIUSD cap

    // =============================================================
    //                     RATE SNAPSHOT SYSTEM
    // =============================================================

    uint256 public constant SECONDS_PER_YEAR      = 365 days;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;
    uint256 public constant MAX_SNAPSHOTS          = 2160;

    struct RateSnapshot {
        uint256 rate;      // exchangeRate() at snapshot (1e6-scaled USDC per yAPIUSD)
        uint256 timestamp;
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =============================================================
    //                     INFORMATIONAL STATE
    // =============================================================

    /// @notice Total RS tokens locked as the yield engine (informational only)
    uint256 public rsHeld;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event Mint(address indexed user, uint256 usdcDeposited, uint256 yMinted, uint256 fee);
    event Redeem(address indexed user, uint256 yBurned, uint256 usdcReturned, uint256 fee);
    event RSDeposited(address indexed treasury, uint256 shares);
    event Harvested(uint256 usdcClaimed);
    event TreasuryUpdated(address indexed account, bool approved);
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
        address _initialTreasury,
        address _feeRecipient
    ) ERC20("API USD Yield", "yAPIUSD") {
        require(address(_rs)   != address(0), "yAPIUSD: zero rs");
        require(address(_usdc) != address(0), "yAPIUSD: zero usdc");
        require(_initialTreasury != address(0), "yAPIUSD: zero treasury");
        require(_feeRecipient    != address(0), "yAPIUSD: zero fee recipient");

        rs           = _rs;
        USDC         = _usdc;
        admin        = msg.sender;
        pauser       = msg.sender;
        feeRecipient = _feeRecipient;

        isTreasury[_initialTreasury] = true;
        emit TreasuryUpdated(_initialTreasury, true);

        recentSnapshots[0] = RateSnapshot({ rate: 1e6, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime   = block.timestamp;

        emit RateSnapshotTaken(1e6, block.timestamp);
    }

    function decimals() public pure override returns (uint8) { return 6; }

    // =============================================================
    //                           CORE LOGIC
    // =============================================================

    /// @notice Deposit USDC to mint yAPIUSD at the current exchange rate.
    ///         Exchange rate appreciates as RS dividends accrue.
    /// @param  usdcAmount  Gross USDC to deposit (fee deducted before minting).
    /// @return yMinted     Net yAPIUSD received.
    function mint(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 yMinted)
    {
        require(usdcAmount > 0, "yAPIUSD: zero amount");

        uint256 fee          = (usdcAmount * FEE_BP) / BP_SCALE;
        uint256 usdcAfterFee = usdcAmount - fee;

        if (fee > 0) USDC.safeTransferFrom(msg.sender, feeRecipient, fee);
        USDC.safeTransferFrom(msg.sender, address(this), usdcAfterFee);

        uint256 supply = totalSupply();
        if (supply == 0) {
            yMinted = usdcAfterFee;
        } else {
            uint256 rate = exchangeRate();
            require(rate > 0, "yAPIUSD: invalid rate");
            yMinted = (usdcAfterFee * 1e6) / rate;
        }

        require(yMinted > 0,                          "yAPIUSD: mint too small");
        require(supply + yMinted <= MAX_TOTAL_SUPPLY,  "yAPIUSD: supply cap");

        _mint(msg.sender, yMinted);
        _takeSnapshotIfNeeded();

        emit Mint(msg.sender, usdcAmount, yMinted, fee);
    }

    /// @notice Burn yAPIUSD to redeem USDC at the current (appreciated) exchange rate.
    ///         If the contract has insufficient USDC, harvest() is called automatically.
    ///         If still insufficient after harvest, reverts — call harvest() first.
    /// @param  yAmount  yAPIUSD to burn.
    /// @return usdcOut  Net USDC returned after fee.
    function redeem(uint256 yAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        require(yAmount > 0,                       "yAPIUSD: zero amount");
        require(totalSupply() > 0,                 "yAPIUSD: no supply");
        require(balanceOf(msg.sender) >= yAmount,  "yAPIUSD: insufficient balance");

        uint256 rate      = exchangeRate();
        uint256 usdcGross = (yAmount * rate) / 1e6;
        require(usdcGross > 0, "yAPIUSD: redeem too small");

        uint256 fee = (usdcGross * FEE_BP) / BP_SCALE;
        usdcOut     = usdcGross - fee;

        // Auto-harvest if USDC balance is insufficient
        uint256 usdcBal = USDC.balanceOf(address(this));
        if (usdcGross > usdcBal) {
            _harvest();
            usdcBal = USDC.balanceOf(address(this));
        }

        require(
            usdcBal >= usdcGross,
            "yAPIUSD: insufficient liquidity, call harvest() first"
        );

        _burn(msg.sender, yAmount);
        if (fee > 0) USDC.safeTransfer(feeRecipient, fee);
        USDC.safeTransfer(msg.sender, usdcOut);

        _takeSnapshotIfNeeded();
        emit Redeem(msg.sender, yAmount, usdcOut, fee);
    }

    /// @notice Treasury: deposit RS tokens to grow the yield engine.
    ///         RS tokens are permanently locked — they serve as the dividend generator.
    ///         Depositing more RS tokens increases the rate at which dividends flow in.
    /// @param  shares  Raw RS tokens to deposit.
    function depositRS(uint256 shares) external nonReentrant {
        require(isTreasury[msg.sender], "yAPIUSD: only treasury");
        require(shares > 0,              "yAPIUSD: zero shares");

        IERC20(address(rs)).safeTransferFrom(msg.sender, address(this), shares);
        rsHeld += shares;

        _takeSnapshotIfNeeded();
        emit RSDeposited(msg.sender, shares);
    }

    /// @notice Permissionless: claim pending USDC dividends from the RS token.
    ///         USDC flows into the contract, increasing available liquidity
    ///         (exchange rate is already reflected via exchangeRate()).
    function harvest() external nonReentrant {
        uint256 claimed = _harvest();
        require(claimed > 0, "yAPIUSD: nothing to harvest");
    }

    // =============================================================
    //                         VIEW FUNCTIONS
    // =============================================================

    /// @notice Current exchange rate: USDC per yAPIUSD (1e6-scaled).
    ///         Includes pending unclaimed USDC so the rate is always real-time.
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        uint256 usdcBacking = USDC.balanceOf(address(this)) + rs.claimable(address(this));
        if (usdcBacking == 0) return 1e6;
        return (usdcBacking * 1e6) / supply;
    }

    function totalAssets() external view returns (uint256) {
        return USDC.balanceOf(address(this)) + rs.claimable(address(this));
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
        require(snapshotsAgo < available, "yAPIUSD: snapshot too old");
        uint256 idx = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);
        RateSnapshot memory s = recentSnapshots[idx];
        return (s.rate, s.timestamp);
    }

    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "yAPIUSD: invalid range");
        require(totalSnapshotCount > 0,        "yAPIUSD: no history");

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

    function _harvest() internal returns (uint256 claimed) {
        claimed = rs.claimable(address(this));
        if (claimed == 0) return 0;
        rs.claim(address(this));
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

    function addTreasury(address account) external {
        require(msg.sender == admin,   "yAPIUSD: only admin");
        require(account != address(0), "yAPIUSD: zero address");
        isTreasury[account] = true;
        emit TreasuryUpdated(account, true);
    }

    function removeTreasury(address account) external {
        require(msg.sender == admin,   "yAPIUSD: only admin");
        require(isTreasury[account],   "yAPIUSD: not a treasury");
        isTreasury[account] = false;
        emit TreasuryUpdated(account, false);
    }

    function pause()   external { require(msg.sender == pauser, "yAPIUSD: only pauser"); _pause(); }
    function unpause() external { require(msg.sender == pauser, "yAPIUSD: only pauser"); _unpause(); }

    function setAdmin(address v) external {
        require(msg.sender == admin, "yAPIUSD: only admin");
        require(v != address(0),     "yAPIUSD: zero address");
        emit AdminUpdated(admin, v);
        admin = v;
    }

    function setPauser(address v) external {
        require(msg.sender == admin, "yAPIUSD: only admin");
        require(v != address(0),     "yAPIUSD: zero address");
        emit PauserUpdated(pauser, v);
        pauser = v;
    }

    function setFeeRecipient(address v) external {
        require(msg.sender == admin, "yAPIUSD: only admin");
        require(v != address(0),     "yAPIUSD: zero address");
        emit FeeRecipientUpdated(feeRecipient, v);
        feeRecipient = v;
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin,             "yAPIUSD: only admin");
        require(address(token) != address(rs),   "yAPIUSD: cannot rescue RS tokens");
        require(address(token) != address(this), "yAPIUSD: cannot rescue yAPIUSD");
        require(address(token) != address(USDC), "yAPIUSD: cannot rescue USDC");
        require(to != address(0),                "yAPIUSD: zero address");
        token.safeTransfer(to, amount);
    }
}
