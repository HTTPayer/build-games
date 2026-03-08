// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title yAPIUSD — API Revenue Yield-Bearing Stablecoin (GLUSD Mirror)
/// @notice Architecture B: Users deposit USDC and earn yield passively.
///         The API provider (treasury) seeds the contract with vault shares.
///         As API revenue flows into the vault, share prices rise, growing
///         the contract's total USDC-equivalent backing and pushing the
///         exchange rate upward — making every yAPIUSD worth more over time.
///
/// @dev    Mint:                user deposits USDC        → receives yAPIUSD at current rate
///         Redeem:              user burns yAPIUSD         → receives USDC at appreciated rate
///         depositVaultShares:  treasury deposits shares   → boosts exchange rate (yield engine)
///
///         Exchange rate = (USDC in contract + vault.convertToAssets(vault shares held)) * 1e6
///                         ────────────────────────────────────────────────────────────────────
///                                              yAPIUSD total supply
///
///         Yield source  = vault share price appreciation (from x402 API revenue)
///         USDC in/out   = always liquid, simple user experience
///
///         When redemption USDC is short, the contract redeems vault shares from
///         the backing vault to cover the shortfall — fully automated.
///
///         Closely mirrors GLUSD (Galaksio-OS): `depositVaultShares` replaces
///         GLUSD's `depositFees`, and the yield source is share price appreciation
///         rather than explicit USDC treasury deposits.
contract yAPIUSD is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                           ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    /// @notice Addresses authorised to seed vault shares (API providers / protocol)
    mapping(address => bool) public isTreasury;

    // =============================================================
    //                        BACKING ASSETS
    // =============================================================

    /// @notice The ERC4626 vault whose shares serve as the yield engine
    IERC4626 public immutable vault;

    /// @notice Underlying stable asset (USDC) — principal in/out token
    IERC20 public immutable USDC;

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    uint256 public constant FEE_BP           = 50;           // 0.5% on mint and redeem
    uint256 public constant BP_SCALE         = 10_000;
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6;  // 1M yAPIUSD cap

    // =============================================================
    //                     RATE SNAPSHOT SYSTEM
    //              (adapted from GLUSD by Galaksio-OS)
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
    //                           EVENTS
    // =============================================================

    event Mint(address indexed user, uint256 usdcDeposited, uint256 yMinted, uint256 fee);
    event Redeem(address indexed user, uint256 yBurned, uint256 usdcReturned, uint256 fee);
    event VaultSharesDeposited(address indexed treasury, uint256 shares, uint256 usdcEquivalent);
    event TreasuryUpdated(address indexed account, bool approved);
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(
        IERC4626 _vault,
        address  _initialTreasury,
        address  _feeRecipient
    ) ERC20("API USD Yield", "yAPIUSD") {
        require(address(_vault) != address(0),    "yAPIUSD: zero vault");
        require(_initialTreasury != address(0),    "yAPIUSD: zero treasury");
        require(_feeRecipient != address(0),       "yAPIUSD: zero fee recipient");

        vault        = _vault;
        USDC         = IERC20(_vault.asset());
        admin        = msg.sender;
        pauser       = msg.sender;
        feeRecipient = _feeRecipient;

        isTreasury[_initialTreasury] = true;
        emit TreasuryUpdated(_initialTreasury, true);

        uint256 initialRate = 1e6;
        recentSnapshots[0] = RateSnapshot({ rate: initialRate, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime   = block.timestamp;

        emit RateSnapshotTaken(initialRate, block.timestamp);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // =============================================================
    //                          CORE LOGIC
    // =============================================================

    /// @notice Deposit USDC to mint yAPIUSD at the current exchange rate.
    ///         Exchange rate starts at 1.0 and grows as API revenue accrues.
    /// @param  usdcAmount  Gross USDC to deposit (fee deducted before minting).
    /// @return yMinted     Net yAPIUSD received.
    function mint(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 yMinted)
    {
        require(usdcAmount > 0, "yAPIUSD: zero amount");

        uint256 fee           = (usdcAmount * FEE_BP) / BP_SCALE;
        uint256 usdcAfterFee  = usdcAmount - fee;

        // Transfer fee and principal separately
        USDC.safeTransferFrom(msg.sender, feeRecipient,    fee);
        USDC.safeTransferFrom(msg.sender, address(this),   usdcAfterFee);

        // Compute shares against pre-deposit rate to protect existing holders
        uint256 supply = totalSupply();
        if (supply == 0) {
            yMinted = usdcAfterFee;
        } else {
            // Rate now reflects the newly deposited USDC — fair and manipulation-resistant
            uint256 rate = exchangeRate();
            require(rate > 0, "yAPIUSD: invalid rate");
            yMinted = (usdcAfterFee * 1e6) / rate;
        }

        require(yMinted > 0, "yAPIUSD: mint too small");
        require(supply + yMinted <= MAX_TOTAL_SUPPLY, "yAPIUSD: supply cap");

        _mint(msg.sender, yMinted);
        _takeSnapshotIfNeeded();

        emit Mint(msg.sender, usdcAmount, yMinted, fee);
    }

    /// @notice Burn yAPIUSD to redeem USDC at the current (appreciated) exchange rate.
    ///         If the contract's raw USDC balance is insufficient, vault shares are
    ///         automatically redeemed from the backing vault to cover the shortfall.
    /// @param  yAmount  yAPIUSD to burn.
    /// @return usdcOut  Net USDC returned after fee.
    function redeem(uint256 yAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        require(yAmount > 0,                         "yAPIUSD: zero amount");
        require(totalSupply() > 0,                   "yAPIUSD: no supply");
        require(balanceOf(msg.sender) >= yAmount,    "yAPIUSD: insufficient balance");

        uint256 rate      = exchangeRate();
        uint256 usdcGross = (yAmount * rate) / 1e6;
        require(usdcGross > 0, "yAPIUSD: redeem too small");

        uint256 fee = (usdcGross * FEE_BP) / BP_SCALE;
        usdcOut     = usdcGross - fee;

        // Cover any shortfall by redeeming vault shares
        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcGross > usdcBalance) {
            uint256 shortfall = usdcGross - usdcBalance;
            _redeemVaultSharesForUsdc(shortfall);
        }

        require(USDC.balanceOf(address(this)) >= usdcGross, "yAPIUSD: insufficient reserves");

        _burn(msg.sender, yAmount);

        USDC.safeTransfer(feeRecipient, fee);
        USDC.safeTransfer(msg.sender,   usdcOut);

        _takeSnapshotIfNeeded();
        emit Redeem(msg.sender, yAmount, usdcOut, fee);
    }

    /// @notice Treasury-only: deposit vault shares to grow the backing pool.
    ///         As the vault's share price rises, this increases totalAssets and
    ///         pushes the exchange rate up — this is where yield comes from.
    /// @param  shares  Amount of vault shares to deposit.
    function depositVaultShares(uint256 shares) external nonReentrant {
        require(isTreasury[msg.sender],  "yAPIUSD: only treasury");
        require(shares > 0,               "yAPIUSD: zero shares");

        uint256 usdcEquivalent = vault.convertToAssets(shares);
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);

        _takeSnapshotIfNeeded();
        emit VaultSharesDeposited(msg.sender, shares, usdcEquivalent);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Total USDC-equivalent backing: raw USDC + vault shares converted to USDC.
    function totalAssets() public view returns (uint256) {
        uint256 rawUsdc      = USDC.balanceOf(address(this));
        uint256 vaultShares  = IERC20(address(vault)).balanceOf(address(this));
        uint256 sharesAsUsdc = vault.convertToAssets(vaultShares);
        return rawUsdc + sharesAsUsdc;
    }

    /// @notice Current exchange rate: USDC per yAPIUSD (1e6-scaled).
    ///         Starts at 1e6 (1.0) and increases as API revenue accrues.
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        return (totalAssets() * 1e6) / supply;
    }

    function vaultStatus()
        external
        view
        returns (uint256 rawUsdc, uint256 vaultShares, uint256 vaultSharesAsUsdc, uint256 ySupply)
    {
        rawUsdc          = USDC.balanceOf(address(this));
        vaultShares      = IERC20(address(vault)).balanceOf(address(this));
        vaultSharesAsUsdc = vault.convertToAssets(vaultShares);
        ySupply          = totalSupply();
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
    //                          INTERNAL
    // =============================================================

    /// @dev Redeem vault shares to cover a USDC shortfall during user redemptions.
    function _redeemVaultSharesForUsdc(uint256 usdcNeeded) internal {
        uint256 vaultShares = IERC20(address(vault)).balanceOf(address(this));
        require(vaultShares > 0, "yAPIUSD: no vault shares to redeem");

        // Use vault.withdraw to pull exactly usdcNeeded (ERC4626 handles share math)
        uint256 maxWithdrawable = vault.maxWithdraw(address(this));
        uint256 toWithdraw = usdcNeeded > maxWithdrawable ? maxWithdrawable : usdcNeeded;

        vault.withdraw(toWithdraw, address(this), address(this));
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
            if (s.timestamp <= targetTs) return (s.rate, s.timestamp);
        }
        uint256 oldestIdx = totalSnapshotCount > MAX_SNAPSHOTS ? (snapshotIndex + 1) % MAX_SNAPSHOTS : 0;
        RateSnapshot memory oldest = recentSnapshots[oldestIdx];
        return (oldest.rate, oldest.timestamp);
    }

    // =============================================================
    //                           ADMIN
    // =============================================================

    function addTreasury(address account) external {
        require(msg.sender == admin,         "yAPIUSD: only admin");
        require(account != address(0),        "yAPIUSD: zero address");
        isTreasury[account] = true;
        emit TreasuryUpdated(account, true);
    }

    function removeTreasury(address account) external {
        require(msg.sender == admin,           "yAPIUSD: only admin");
        require(isTreasury[account],           "yAPIUSD: not a treasury");
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
        require(msg.sender == admin,                      "yAPIUSD: only admin");
        require(address(token) != address(vault),         "yAPIUSD: cannot rescue vault shares");
        require(address(token) != address(this),          "yAPIUSD: cannot rescue yAPIUSD");
        require(address(token) != address(USDC),          "yAPIUSD: cannot rescue USDC");
        require(to != address(0),                         "yAPIUSD: zero address");
        token.safeTransfer(to, amount);
    }
}
