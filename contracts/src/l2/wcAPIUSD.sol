// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title wcAPIUSD — Working Capital Stablecoin
/// @notice Architecture C: The API provider deposits vault shares as collateral and
///         borrows the USDC that stablecoin users have deposited — using it as working
///         capital. Interest accrues continuously on the outstanding loan and is
///         credited to the stablecoin's exchange rate, making wcAPIUSD yield-bearing.
///
/// @dev    Mint:              user deposits USDC              → receives wcAPIUSD at 1.0
///         Redeem:            user burns wcAPIUSD              → receives USDC at appreciated rate
///         depositCollateral: provider deposits vault shares   → unlocks borrowing capacity
///         borrow:            provider draws USDC (up to LTV) → USDC leaves contract
///         repay:             provider returns USDC + interest → liquidity restored
///         liquidate:         anyone can seize collateral if LTV breached → users protected
///
///         Exchange rate = (USDC in contract + loan receivable) * 1e6 / wcAPIUSD supply
///
///         The loan receivable = principal + accrued interest.
///         When interest accrues, the receivable grows → exchange rate rises → yield.
///         Repayment swaps receivable for USDC 1:1 (rate unchanged, just more liquid).
///
///         Vault shares are COLLATERAL ONLY — they do not count toward exchange rate.
///         They are insurance: seized and redeemed for USDC if the provider defaults.
///
///         Yield source  = loan interest paid by API provider (funded by API revenue)
///         Risk          = provider default → mitigated by overcollateralisation +
///                         automatic liquidation when vault shares < LIQ threshold
///
/// @dev    Rate snapshots track exchange rate for onchain APR/APY display.
///         Adapted from GLUSD (Galaksio-OS) — same snapshot ring buffer and APR math.
contract wcAPIUSD is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                           ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    /// @notice The API provider allowed to borrow from this contract
    address public borrower;

    // =============================================================
    //                        BACKING ASSETS
    // =============================================================

    IERC4626 public immutable vault;
    IERC20   public immutable USDC;

    // =============================================================
    //                      LOAN PARAMETERS
    // =============================================================

    /// @notice Maximum USDC borrowable as a fraction of vault share collateral (70%)
    uint256 public constant LOAN_LTV_BP         = 7_000;

    /// @notice Collateral ratio below which the loan is liquidatable (80%)
    uint256 public constant LIQ_THRESHOLD_BP    = 8_000;

    /// @notice Annual interest rate on the outstanding principal (5%)
    uint256 public constant ANNUAL_INTEREST_BP  = 500;

    uint256 public constant BP_SCALE            = 10_000;
    uint256 public constant SECONDS_PER_YEAR    = 365 days;

    // =============================================================
    //                       STABLECOIN PARAMS
    // =============================================================

    uint256 public constant FEE_BP           = 50;          // 0.5% on mint and redeem
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6; // 1M wcAPIUSD cap

    // =============================================================
    //                         LOAN STATE
    // =============================================================

    struct Loan {
        uint256 principal;            // USDC outstanding (borrowed but not yet repaid)
        uint256 interestAccrued;      // USDC interest accumulated so far
        uint256 lastAccrualTimestamp; // last time interest was written to state
    }

    Loan    public loan;
    uint256 public collateralShares; // vault shares held as loan collateral

    // =============================================================
    //                     RATE SNAPSHOT SYSTEM
    //              (adapted from GLUSD by Galaksio-OS)
    // =============================================================

    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;
    uint256 public constant MAX_SNAPSHOTS          = 2160;

    struct RateSnapshot {
        uint256 rate;      // exchangeRate() at snapshot (1e6-scaled USDC per wcAPIUSD)
        uint256 timestamp;
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event Mint(address indexed user, uint256 usdcDeposited, uint256 wcMinted, uint256 fee);
    event Redeem(address indexed user, uint256 wcBurned, uint256 usdcReturned, uint256 fee);
    event CollateralDeposited(address indexed depositor, uint256 shares, uint256 usdcEquivalent);
    event CollateralWithdrawn(address indexed borrower, uint256 shares);
    event Borrowed(address indexed borrower, uint256 usdcAmount, uint256 totalPrincipal);
    event Repaid(address indexed repayer, uint256 usdcAmount, uint256 principalRemaining, uint256 interestRemaining);
    event InterestAccrued(uint256 interest, uint256 totalInterestAccrued);
    event Liquidated(address indexed liquidator, uint256 sharesSeized, uint256 usdcRecovered);
    event BorrowerUpdated(address indexed oldBorrower, address indexed newBorrower);
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(
        IERC4626 _vault,
        address  _borrower,
        address  _feeRecipient
    ) ERC20("Working Capital API USD", "wcAPIUSD") {
        require(address(_vault) != address(0), "wcAPIUSD: zero vault");
        require(_borrower != address(0),        "wcAPIUSD: zero borrower");
        require(_feeRecipient != address(0),    "wcAPIUSD: zero fee recipient");

        vault        = _vault;
        USDC         = IERC20(_vault.asset());
        borrower     = _borrower;
        admin        = msg.sender;
        pauser       = msg.sender;
        feeRecipient = _feeRecipient;

        loan.lastAccrualTimestamp = block.timestamp;

        recentSnapshots[0] = RateSnapshot({ rate: 1e6, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime   = block.timestamp;

        emit RateSnapshotTaken(1e6, block.timestamp);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // =============================================================
    //                      STABLECOIN: MINT / REDEEM
    // =============================================================

    /// @notice Deposit USDC to mint wcAPIUSD.
    ///         Deposited USDC may be borrowed by the provider — users earn interest
    ///         on their principal via exchange rate appreciation, not rebase.
    /// @param  usdcAmount  Gross USDC to deposit.
    /// @return wcMinted    Net wcAPIUSD received after fee.
    function mint(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 wcMinted)
    {
        require(usdcAmount > 0, "wcAPIUSD: zero amount");

        uint256 fee          = (usdcAmount * FEE_BP) / BP_SCALE;
        uint256 usdcAfterFee = usdcAmount - fee;

        USDC.safeTransferFrom(msg.sender, feeRecipient,  fee);
        USDC.safeTransferFrom(msg.sender, address(this), usdcAfterFee);

        uint256 supply = totalSupply();
        if (supply == 0) {
            wcMinted = usdcAfterFee;
        } else {
            _accrueInterest();
            uint256 rate = exchangeRate();
            require(rate > 0, "wcAPIUSD: invalid rate");
            wcMinted = (usdcAfterFee * 1e6) / rate;
        }

        require(wcMinted > 0,                          "wcAPIUSD: mint too small");
        require(supply + wcMinted <= MAX_TOTAL_SUPPLY,  "wcAPIUSD: supply cap");

        _mint(msg.sender, wcMinted);
        _takeSnapshotIfNeeded();

        emit Mint(msg.sender, usdcAmount, wcMinted, fee);
    }

    /// @notice Burn wcAPIUSD to redeem USDC at the appreciated exchange rate.
    ///         Reverts if the provider has outstanding borrows that haven't been repaid
    ///         and there is insufficient USDC in the contract to cover this redemption.
    ///         Use `availableLiquidity()` to check before calling.
    /// @param  wcAmount  wcAPIUSD to burn.
    /// @return usdcOut   Net USDC returned after fee.
    function redeem(uint256 wcAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        require(wcAmount > 0,                       "wcAPIUSD: zero amount");
        require(totalSupply() > 0,                  "wcAPIUSD: no supply");
        require(balanceOf(msg.sender) >= wcAmount,  "wcAPIUSD: insufficient balance");

        _accrueInterest();

        uint256 rate      = exchangeRate();
        uint256 usdcGross = (wcAmount * rate) / 1e6;
        require(usdcGross > 0, "wcAPIUSD: redeem too small");

        // Exchange rate includes loan receivable — actual USDC may be lower
        uint256 usdcAvailable = USDC.balanceOf(address(this));
        require(
            usdcGross <= usdcAvailable,
            "wcAPIUSD: insufficient liquidity, provider must repay first"
        );

        uint256 fee = (usdcGross * FEE_BP) / BP_SCALE;
        usdcOut     = usdcGross - fee;

        _burn(msg.sender, wcAmount);

        USDC.safeTransfer(feeRecipient, fee);
        USDC.safeTransfer(msg.sender,   usdcOut);

        _takeSnapshotIfNeeded();
        emit Redeem(msg.sender, wcAmount, usdcOut, fee);
    }

    // =============================================================
    //                     PROVIDER: COLLATERAL
    // =============================================================

    /// @notice Deposit vault shares as loan collateral.
    ///         Anyone may deposit on the borrower's behalf (e.g., the protocol can seed).
    /// @param  shares  Vault shares to deposit.
    function depositCollateral(uint256 shares) external nonReentrant {
        require(shares > 0, "wcAPIUSD: zero shares");

        uint256 usdcEquivalent = vault.convertToAssets(shares);
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);
        collateralShares += shares;

        emit CollateralDeposited(msg.sender, shares, usdcEquivalent);
    }

    /// @notice Withdraw vault share collateral.
    ///         Only the borrower may withdraw, and only when no loan is outstanding.
    /// @param  shares  Vault shares to withdraw.
    function withdrawCollateral(uint256 shares) external nonReentrant {
        require(msg.sender == borrower,                  "wcAPIUSD: only borrower");
        require(shares > 0 && shares <= collateralShares, "wcAPIUSD: invalid amount");

        _accrueInterest();

        uint256 totalDebt = loan.principal + loan.interestAccrued;
        require(totalDebt == 0, "wcAPIUSD: repay loan before withdrawing collateral");

        collateralShares -= shares;
        IERC20(address(vault)).safeTransfer(borrower, shares);

        emit CollateralWithdrawn(borrower, shares);
    }

    // =============================================================
    //                       PROVIDER: LOAN
    // =============================================================

    /// @notice Borrow USDC from the contract against deposited vault share collateral.
    ///         Maximum borrow = collateralValue * LOAN_LTV_BP / BP_SCALE.
    /// @param  usdcAmount  USDC to borrow.
    function borrow(uint256 usdcAmount) external nonReentrant whenNotPaused {
        require(msg.sender == borrower,              "wcAPIUSD: only borrower");
        require(usdcAmount > 0,                       "wcAPIUSD: zero amount");
        require(collateralShares > 0,                 "wcAPIUSD: no collateral deposited");

        _accrueInterest();

        uint256 colVal       = vault.convertToAssets(collateralShares);
        uint256 maxBorrow    = (colVal * LOAN_LTV_BP) / BP_SCALE;
        uint256 newPrincipal = loan.principal + usdcAmount;

        require(newPrincipal <= maxBorrow,                       "wcAPIUSD: exceeds LTV");
        require(USDC.balanceOf(address(this)) >= usdcAmount,     "wcAPIUSD: insufficient USDC in contract");

        loan.principal = newPrincipal;
        USDC.safeTransfer(borrower, usdcAmount);

        _takeSnapshotIfNeeded();
        emit Borrowed(borrower, usdcAmount, newPrincipal);
    }

    /// @notice Repay outstanding loan principal and/or interest.
    ///         Payment is applied to interest first, then principal.
    ///         Anyone may repay on behalf of the borrower.
    /// @param  usdcAmount  USDC to repay.
    function repay(uint256 usdcAmount) external nonReentrant {
        require(usdcAmount > 0, "wcAPIUSD: zero amount");

        _accrueInterest();

        uint256 totalOwed = loan.principal + loan.interestAccrued;
        require(totalOwed > 0, "wcAPIUSD: no outstanding loan");

        // Cap payment at total owed
        uint256 payment = usdcAmount > totalOwed ? totalOwed : usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), payment);

        // Apply to interest first
        if (payment >= loan.interestAccrued) {
            uint256 remainder = payment - loan.interestAccrued;
            loan.interestAccrued = 0;
            loan.principal       = remainder <= loan.principal ? loan.principal - remainder : 0;
        } else {
            loan.interestAccrued -= payment;
        }

        _takeSnapshotIfNeeded();
        emit Repaid(msg.sender, payment, loan.principal, loan.interestAccrued);
    }

    // =============================================================
    //                         LIQUIDATION
    // =============================================================

    /// @notice Liquidate the provider's position when collateral is insufficient.
    ///         Anyone can trigger this once the collateral health falls below
    ///         LIQ_THRESHOLD_BP. All vault shares are seized and redeemed for USDC,
    ///         restoring the contract's liquidity for stablecoin holders.
    ///
    /// @dev    Liquidation condition: totalDebt > collateralValue * LIQ_THRESHOLD_BP / BP_SCALE
    ///         i.e. the LTV has breached the 80% threshold (exceeds the 70% max borrow ratio
    ///         due to interest accrual or vault share price decline).
    function liquidate() external nonReentrant {
        _accrueInterest();

        uint256 colVal    = vault.convertToAssets(collateralShares);
        uint256 totalDebt = loan.principal + loan.interestAccrued;

        require(totalDebt > 0, "wcAPIUSD: no debt to liquidate");
        require(
            totalDebt > (colVal * LIQ_THRESHOLD_BP) / BP_SCALE,
            "wcAPIUSD: position is healthy"
        );

        // Seize all collateral shares and redeem for USDC
        uint256 sharesToSeize = collateralShares;
        collateralShares      = 0;
        loan.principal        = 0;
        loan.interestAccrued  = 0;

        // Redeem vault shares → USDC flows into this contract
        uint256 usdcBefore  = USDC.balanceOf(address(this));
        vault.redeem(sharesToSeize, address(this), address(this));
        uint256 usdcRecovered = USDC.balanceOf(address(this)) - usdcBefore;

        _takeSnapshotIfNeeded();
        emit Liquidated(msg.sender, sharesToSeize, usdcRecovered);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Exchange rate: USDC per wcAPIUSD (1e6-scaled).
    ///         Starts at 1e6 (1.0) and grows as interest accrues on the loan.
    ///
    ///         totalBacking = USDC in contract + loan receivable (principal + interest)
    ///         Note: vault share collateral is NOT included — it is insurance, not backing.
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;

        uint256 usdcBalance    = USDC.balanceOf(address(this));
        uint256 loanReceivable = loan.principal + loan.interestAccrued + _pendingInterest();
        uint256 totalBacking   = usdcBalance + loanReceivable;

        return (totalBacking * 1e6) / supply;
    }

    /// @notice USDC immediately available for redemption (not loaned out).
    function availableLiquidity() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Current USDC value of the collateral vault shares.
    function collateralValue() external view returns (uint256) {
        return vault.convertToAssets(collateralShares);
    }

    /// @notice Maximum additional USDC the borrower can draw right now.
    function maxBorrowable() external view returns (uint256) {
        uint256 colVal    = vault.convertToAssets(collateralShares);
        uint256 maxTotal  = (colVal * LOAN_LTV_BP) / BP_SCALE;
        uint256 pending   = loan.principal + loan.interestAccrued + _pendingInterest();
        if (maxTotal <= pending) return 0;
        return maxTotal - pending;
    }

    /// @notice Health factor of the loan (1e6-scaled; below 1e6 = liquidatable).
    function loanHealthFactor() external view returns (uint256) {
        uint256 totalDebt = loan.principal + loan.interestAccrued + _pendingInterest();
        if (totalDebt == 0) return type(uint256).max;
        uint256 colVal = vault.convertToAssets(collateralShares);
        return (colVal * LIQ_THRESHOLD_BP * 1e6) / (totalDebt * BP_SCALE);
    }

    /// @notice Whether the loan is currently liquidatable.
    function isLiquidatable() external view returns (bool) {
        uint256 totalDebt = loan.principal + loan.interestAccrued + _pendingInterest();
        if (totalDebt == 0) return false;
        uint256 colVal = vault.convertToAssets(collateralShares);
        return totalDebt > (colVal * LIQ_THRESHOLD_BP) / BP_SCALE;
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
        require(snapshotsAgo < available, "wcAPIUSD: snapshot too old");
        uint256 idx = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);
        RateSnapshot memory s = recentSnapshots[idx];
        return (s.rate, s.timestamp);
    }

    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "wcAPIUSD: invalid range");
        require(totalSnapshotCount > 0,        "wcAPIUSD: no history");

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

    /// @dev Interest not yet written to state (for real-time view functions).
    function _pendingInterest() internal view returns (uint256) {
        if (loan.principal == 0) return 0;
        uint256 elapsed = block.timestamp - loan.lastAccrualTimestamp;
        return (loan.principal * ANNUAL_INTEREST_BP * elapsed) / (BP_SCALE * SECONDS_PER_YEAR);
    }

    /// @dev Write pending interest to state. Must be called before any state mutation.
    function _accrueInterest() internal {
        uint256 pending = _pendingInterest();
        if (pending > 0) {
            loan.interestAccrued += pending;
            emit InterestAccrued(pending, loan.interestAccrued);
        }
        loan.lastAccrualTimestamp = block.timestamp;
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

    function setBorrower(address newBorrower) external {
        require(msg.sender == admin,       "wcAPIUSD: only admin");
        require(newBorrower != address(0), "wcAPIUSD: zero address");
        emit BorrowerUpdated(borrower, newBorrower);
        borrower = newBorrower;
    }

    function pause()   external { require(msg.sender == pauser, "wcAPIUSD: only pauser"); _pause(); }
    function unpause() external { require(msg.sender == pauser, "wcAPIUSD: only pauser"); _unpause(); }

    function setAdmin(address v) external {
        require(msg.sender == admin, "wcAPIUSD: only admin");
        require(v != address(0),     "wcAPIUSD: zero address");
        emit AdminUpdated(admin, v);
        admin = v;
    }

    function setPauser(address v) external {
        require(msg.sender == admin, "wcAPIUSD: only admin");
        require(v != address(0),     "wcAPIUSD: zero address");
        emit PauserUpdated(pauser, v);
        pauser = v;
    }

    function setFeeRecipient(address v) external {
        require(msg.sender == admin, "wcAPIUSD: only admin");
        require(v != address(0),     "wcAPIUSD: zero address");
        emit FeeRecipientUpdated(feeRecipient, v);
        feeRecipient = v;
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin,                  "wcAPIUSD: only admin");
        require(address(token) != address(vault),     "wcAPIUSD: cannot rescue collateral");
        require(address(token) != address(this),      "wcAPIUSD: cannot rescue wcAPIUSD");
        require(address(token) != address(USDC),      "wcAPIUSD: cannot rescue USDC");
        require(to != address(0),                     "wcAPIUSD: zero address");
        token.safeTransfer(to, amount);
    }
}
