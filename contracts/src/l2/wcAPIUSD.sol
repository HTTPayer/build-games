// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProviderRevenueShare.sol";

/// @title wcAPIUSD — Working Capital Stablecoin (RS-Token-Native)
///
/// @notice Architecture C — "Dividend Advance" product.
///
///         The API provider deposits RS tokens as collateral and borrows the USDC
///         that stablecoin users have deposited — using it as working capital.
///
///         Collateral value = RS tokens' accumulated USDC dividends (rs.claimable()).
///         Because dividends accrue continuously, borrowing capacity grows over time.
///         As dividends increase, the provider can borrow more without adding collateral.
///
///         Interest accrues on the outstanding loan principal at 5% annually.
///         Interest is credited to the exchange rate → wcAPIUSD appreciates over time.
///
/// @dev    Key differences from vault-based version:
///         - Collateral value = rs.claimable(address(this)) (not convertToAssets)
///         - Liquidation calls rs.claim() to recover USDC instead of vault.redeem()
///         - RS tokens stay in contract after liquidation; provider repays to reclaim
///         - LTV is dynamic: grows as dividends accumulate
///
///         Exchange rate = (USDC in contract + loan receivable) × 1e6 / wcAPIUSD supply
///
///         Vault shares (RS tokens) are COLLATERAL — not counted in exchange rate.
///         They serve as insurance: dividends are claimed and applied to debt on liquidation.
///
///         Rate snapshots track exchange rate for APR display.
contract wcAPIUSD is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                            ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    /// @notice The API provider allowed to borrow from this contract
    address public borrower;

    // =============================================================
    //                         BACKING ASSETS
    // =============================================================

    IProviderRevenueShare public immutable rs;
    IERC20                public immutable USDC;

    // =============================================================
    //                       LOAN PARAMETERS
    // =============================================================

    uint256 public constant LOAN_LTV_BP        = 7_000;  // 70% of dividends borrowable
    uint256 public constant LIQ_THRESHOLD_BP   = 8_000;  // 80% liquidation threshold
    uint256 public constant ANNUAL_INTEREST_BP = 500;    // 5% annual interest on principal
    uint256 public constant BP_SCALE           = 10_000;
    uint256 public constant SECONDS_PER_YEAR   = 365 days;

    // =============================================================
    //                      STABLECOIN PARAMS
    // =============================================================

    uint256 public constant FEE_BP           = 50;          // 0.5% on mint/redeem
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6; // 1M wcAPIUSD cap

    // =============================================================
    //                          LOAN STATE
    // =============================================================

    struct Loan {
        uint256 principal;            // USDC borrowed but not yet repaid
        uint256 interestAccrued;      // USDC interest accumulated so far
        uint256 lastAccrualTimestamp; // last time interest was written to state
    }

    Loan    public loan;

    /// @notice Raw RS tokens held as loan collateral
    uint256 public collateralRSShares;

    // =============================================================
    //                     RATE SNAPSHOT SYSTEM
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
    //                            EVENTS
    // =============================================================

    event Mint(address indexed user, uint256 usdcDeposited, uint256 wcMinted, uint256 fee);
    event Redeem(address indexed user, uint256 wcBurned, uint256 usdcReturned, uint256 fee);
    event CollateralDeposited(address indexed depositor, uint256 rsShares);
    event CollateralWithdrawn(address indexed borrower, uint256 rsShares);
    event Borrowed(address indexed borrower, uint256 usdcAmount, uint256 totalPrincipal);
    event Repaid(address indexed repayer, uint256 usdcAmount, uint256 principalRemaining, uint256 interestRemaining);
    event InterestAccrued(uint256 interest, uint256 totalInterestAccrued);
    event Liquidated(address indexed liquidator, uint256 usdcRecovered, uint256 debtCleared);
    event BorrowerUpdated(address indexed oldBorrower, address indexed newBorrower);
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(
        IProviderRevenueShare _rs,
        IERC20  _usdc,
        address _borrower,
        address _feeRecipient
    ) ERC20("Working Capital API USD", "wcAPIUSD") {
        require(address(_rs)   != address(0), "wcAPIUSD: zero rs");
        require(address(_usdc) != address(0), "wcAPIUSD: zero usdc");
        require(_borrower      != address(0), "wcAPIUSD: zero borrower");
        require(_feeRecipient  != address(0), "wcAPIUSD: zero fee recipient");

        rs           = _rs;
        USDC         = _usdc;
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

    function decimals() public pure override returns (uint8) { return 6; }

    // =============================================================
    //                    STABLECOIN: MINT / REDEEM
    // =============================================================

    /// @notice Deposit USDC to mint wcAPIUSD.
    ///         Deposited USDC may be borrowed by the provider.
    ///         Users earn interest via exchange rate appreciation (not rebase).
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

        if (fee > 0) USDC.safeTransferFrom(msg.sender, feeRecipient, fee);
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
    ///         Reverts if insufficient USDC in contract — provider must repay first.
    /// @param  wcAmount  wcAPIUSD to burn.
    /// @return usdcOut   Net USDC returned after fee.
    function redeem(uint256 wcAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        require(wcAmount > 0,                      "wcAPIUSD: zero amount");
        require(totalSupply() > 0,                 "wcAPIUSD: no supply");
        require(balanceOf(msg.sender) >= wcAmount, "wcAPIUSD: insufficient balance");

        _accrueInterest();

        uint256 rate      = exchangeRate();
        uint256 usdcGross = (wcAmount * rate) / 1e6;
        require(usdcGross > 0, "wcAPIUSD: redeem too small");

        require(
            USDC.balanceOf(address(this)) >= usdcGross,
            "wcAPIUSD: insufficient liquidity, provider must repay first"
        );

        uint256 fee = (usdcGross * FEE_BP) / BP_SCALE;
        usdcOut     = usdcGross - fee;

        _burn(msg.sender, wcAmount);
        if (fee > 0) USDC.safeTransfer(feeRecipient, fee);
        USDC.safeTransfer(msg.sender, usdcOut);

        _takeSnapshotIfNeeded();
        emit Redeem(msg.sender, wcAmount, usdcOut, fee);
    }

    // =============================================================
    //                    PROVIDER: COLLATERAL
    // =============================================================

    /// @notice Deposit RS tokens as loan collateral.
    ///         Anyone may deposit on the borrower's behalf.
    ///         Collateral value = rs.claimable(address(this)) — grows with dividends.
    /// @param  rsShares  Raw RS tokens to deposit.
    function depositCollateral(uint256 rsShares) external nonReentrant {
        require(rsShares > 0, "wcAPIUSD: zero shares");

        IERC20(address(rs)).safeTransferFrom(msg.sender, address(this), rsShares);
        collateralRSShares += rsShares;

        emit CollateralDeposited(msg.sender, rsShares);
    }

    /// @notice Withdraw RS tokens collateral.
    ///         Only the borrower may withdraw, and only after repaying all debt.
    /// @param  rsShares  Raw RS tokens to withdraw.
    function withdrawCollateral(uint256 rsShares) external nonReentrant {
        require(msg.sender == borrower,                    "wcAPIUSD: only borrower");
        require(rsShares > 0 && rsShares <= collateralRSShares, "wcAPIUSD: invalid amount");

        _accrueInterest();

        uint256 totalDebt = loan.principal + loan.interestAccrued;
        require(totalDebt == 0, "wcAPIUSD: repay loan before withdrawing collateral");

        collateralRSShares -= rsShares;
        IERC20(address(rs)).safeTransfer(borrower, rsShares);

        emit CollateralWithdrawn(borrower, rsShares);
    }

    // =============================================================
    //                       PROVIDER: LOAN
    // =============================================================

    /// @notice Borrow USDC from the contract against RS token dividends.
    ///         Maximum borrow = rs.claimable(address(this)) × LOAN_LTV_BP / BP_SCALE.
    ///         Borrowing capacity grows automatically as dividends accumulate.
    /// @param  usdcAmount  USDC to borrow.
    function borrow(uint256 usdcAmount) external nonReentrant whenNotPaused {
        require(msg.sender == borrower,   "wcAPIUSD: only borrower");
        require(usdcAmount > 0,            "wcAPIUSD: zero amount");
        require(collateralRSShares > 0,    "wcAPIUSD: no collateral deposited");

        _accrueInterest();

        uint256 dividendValue = rs.claimable(address(this));
        uint256 maxBorrow_    = (dividendValue * LOAN_LTV_BP) / BP_SCALE;
        uint256 newPrincipal  = loan.principal + usdcAmount;

        require(newPrincipal <= maxBorrow_,                  "wcAPIUSD: exceeds LTV");
        require(USDC.balanceOf(address(this)) >= usdcAmount, "wcAPIUSD: insufficient USDC");

        loan.principal = newPrincipal;
        USDC.safeTransfer(borrower, usdcAmount);

        _takeSnapshotIfNeeded();
        emit Borrowed(borrower, usdcAmount, newPrincipal);
    }

    /// @notice Repay outstanding loan principal and/or interest.
    ///         Payment applied to interest first, then principal.
    ///         Anyone may repay on behalf of the borrower.
    /// @param  usdcAmount  USDC to repay.
    function repay(uint256 usdcAmount) external nonReentrant {
        require(usdcAmount > 0, "wcAPIUSD: zero amount");

        _accrueInterest();

        uint256 totalOwed = loan.principal + loan.interestAccrued;
        require(totalOwed > 0, "wcAPIUSD: no outstanding loan");

        uint256 payment = usdcAmount > totalOwed ? totalOwed : usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), payment);

        // Apply to interest first
        if (payment >= loan.interestAccrued) {
            uint256 remainder  = payment - loan.interestAccrued;
            loan.interestAccrued = 0;
            loan.principal       = remainder <= loan.principal ? loan.principal - remainder : 0;
        } else {
            loan.interestAccrued -= payment;
        }

        _takeSnapshotIfNeeded();
        emit Repaid(msg.sender, payment, loan.principal, loan.interestAccrued);
    }

    // =============================================================
    //                          LIQUIDATION
    // =============================================================

    /// @notice Liquidate the provider's position when collateral is undercollateralised.
    ///
    ///         Liquidation condition:
    ///           totalDebt > rs.claimable(address(this)) * LIQ_THRESHOLD_BP / BP_SCALE
    ///
    ///         Process:
    ///           1. rs.claim() — accumulated dividends flow into this contract as USDC
    ///           2. Apply USDC to outstanding debt (principal + interest)
    ///           3. Any surplus USDC stays in contract (backing for stablecoin holders)
    ///           4. RS tokens remain in contract (provider must repay to reclaim)
    ///
    ///         Note: RS tokens are NOT sold/returned during liquidation. The provider
    ///         retains the right to withdraw RS tokens after repaying any bad debt.
    function liquidate() external nonReentrant {
        _accrueInterest();

        uint256 dividendValue = rs.claimable(address(this));
        uint256 totalDebt     = loan.principal + loan.interestAccrued;

        require(totalDebt > 0, "wcAPIUSD: no debt to liquidate");
        require(
            totalDebt > (dividendValue * LIQ_THRESHOLD_BP) / BP_SCALE,
            "wcAPIUSD: position is healthy"
        );

        // Claim all accumulated dividends → USDC flows into contract
        uint256 usdcBefore   = USDC.balanceOf(address(this));
        rs.claim(address(this));
        uint256 usdcRecovered = USDC.balanceOf(address(this)) - usdcBefore;

        // Clear as much debt as possible
        uint256 debtCleared;
        if (usdcRecovered >= totalDebt) {
            debtCleared          = totalDebt;
            loan.principal       = 0;
            loan.interestAccrued = 0;
        } else {
            // Bad debt: clear what we can, interest first
            debtCleared = usdcRecovered;
            if (usdcRecovered >= loan.interestAccrued) {
                loan.principal       -= (usdcRecovered - loan.interestAccrued);
                loan.interestAccrued  = 0;
            } else {
                loan.interestAccrued -= usdcRecovered;
            }
        }

        _takeSnapshotIfNeeded();
        emit Liquidated(msg.sender, usdcRecovered, debtCleared);
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    /// @notice Exchange rate: USDC per wcAPIUSD (1e6-scaled).
    ///         Includes loan receivable (principal + interest) in backing.
    ///         Grows as interest accrues on the loan.
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;

        uint256 usdcBal        = USDC.balanceOf(address(this));
        uint256 loanReceivable = loan.principal + loan.interestAccrued + _pendingInterest();
        uint256 totalBacking   = usdcBal + loanReceivable;

        return (totalBacking * 1e6) / supply;
    }

    /// @notice USDC available for immediate redemption.
    function availableLiquidity() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Current dividend value of the RS token collateral (USDC).
    ///         This is the dynamic borrowing capacity basis.
    function collateralValue() external view returns (uint256) {
        return rs.claimable(address(this));
    }

    /// @notice Maximum additional USDC the borrower can draw right now.
    function maxBorrowable() external view returns (uint256) {
        uint256 dividendValue = rs.claimable(address(this));
        uint256 maxTotal      = (dividendValue * LOAN_LTV_BP) / BP_SCALE;
        uint256 pending       = loan.principal + loan.interestAccrued + _pendingInterest();
        if (maxTotal <= pending) return 0;
        return maxTotal - pending;
    }

    /// @notice Health factor of the loan (1e6-scaled; < 1e6 = liquidatable).
    function loanHealthFactor() external view returns (uint256) {
        uint256 totalDebt = loan.principal + loan.interestAccrued + _pendingInterest();
        if (totalDebt == 0) return type(uint256).max;
        uint256 dividendValue = rs.claimable(address(this));
        if (dividendValue == 0) return 0;
        return (dividendValue * LIQ_THRESHOLD_BP * 1e6) / (totalDebt * BP_SCALE);
    }

    /// @notice Whether the loan is currently liquidatable.
    function isLiquidatable() external view returns (bool) {
        uint256 totalDebt = loan.principal + loan.interestAccrued + _pendingInterest();
        if (totalDebt == 0) return false;
        uint256 dividendValue = rs.claimable(address(this));
        return totalDebt > (dividendValue * LIQ_THRESHOLD_BP) / BP_SCALE;
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
    //                           INTERNAL
    // =============================================================

    function _pendingInterest() internal view returns (uint256) {
        if (loan.principal == 0) return 0;
        uint256 elapsed = block.timestamp - loan.lastAccrualTimestamp;
        return (loan.principal * ANNUAL_INTEREST_BP * elapsed) / (BP_SCALE * SECONDS_PER_YEAR);
    }

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
        require(msg.sender == admin,             "wcAPIUSD: only admin");
        require(address(token) != address(rs),   "wcAPIUSD: cannot rescue RS tokens");
        require(address(token) != address(this), "wcAPIUSD: cannot rescue wcAPIUSD");
        require(address(token) != address(USDC), "wcAPIUSD: cannot rescue USDC");
        require(to != address(0),                "wcAPIUSD: zero address");
        token.safeTransfer(to, amount);
    }
}
