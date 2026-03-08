// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title APIUSD — API Revenue Backed Stablecoin
/// @notice CDP stablecoin collateralized by ProviderRevenueVault shares (ERC4626).
///         As API revenue flows into the vault, share prices rise and health factors
///         improve — creating a stablecoin that naturally strengthens over time.
/// @dev Adapted from GLUSD (Galaksio-OS) — CDP mechanics replace the yield-accrual
///      model; rate snapshots are repurposed to track vault share price for APR/APY.
contract APIUSD is ERC20, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         ROLES
    // =============================================================

    address public admin;
    address public pauser;
    address public feeRecipient;

    // =============================================================
    //                       COLLATERAL
    // =============================================================

    /// @notice The ERC4626 vault whose shares serve as collateral
    IERC4626 public immutable vault;

    /// @notice Underlying asset of the vault (USDC)
    IERC20 public immutable USDC;

    // =============================================================
    //                     CDP CONSTANTS
    // =============================================================

    /// @notice Maximum debt ratio at which a user can mint (70%)
    uint256 public constant LTV_BP = 7_000;

    /// @notice Debt ratio at which a position becomes liquidatable (80%)
    uint256 public constant LIQ_THRESHOLD_BP = 8_000;

    /// @notice Bonus collateral awarded to liquidators (5%)
    uint256 public constant LIQ_BONUS_BP = 500;

    /// @notice One-time fee charged on each mint (0.5%)
    uint256 public constant MINT_FEE_BP = 50;

    uint256 public constant BP_SCALE = 10_000;

    /// @notice Hard cap on total APIUSD supply
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e6; // 1M APIUSD

    // =============================================================
    //                    RATE SNAPSHOT SYSTEM
    //              (adapted from GLUSD by Galaksio-OS)
    //        Tracks vault share price over time for APR/APY display
    // =============================================================

    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 30 seconds;
    uint256 public constant MAX_SNAPSHOTS = 2160;

    struct RateSnapshot {
        uint256 rate;      // vault share price (1e18-scaled USDC per share)
        uint256 timestamp;
    }

    RateSnapshot[2160] public recentSnapshots;
    uint256 public snapshotIndex;
    uint256 public totalSnapshotCount;
    uint256 public lastSnapshotTime;

    // =============================================================
    //                       CDP POSITIONS
    // =============================================================

    struct Position {
        uint256 collateralShares; // vault shares deposited as collateral
        uint256 debt;             // APIUSD owed (6 decimals, equals USDC value)
    }

    mapping(address => Position) public positions;

    // =============================================================
    //                          EVENTS
    // =============================================================

    event PositionOpened(address indexed user, uint256 collateralShares, uint256 apiusdMinted, uint256 fee);
    event CollateralAdded(address indexed user, uint256 collateralShares, uint256 newTotal);
    event CollateralRemoved(address indexed user, uint256 collateralShares, uint256 newTotal);
    event DebtIncreased(address indexed user, uint256 apiusdMinted, uint256 fee, uint256 newDebt);
    event Repaid(address indexed user, uint256 apiusdBurned, uint256 debtRemaining);
    event PositionClosed(address indexed user, uint256 collateralReturned);
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        uint256 apiusdRepaid,
        uint256 sharesSeized
    );
    event RateSnapshotTaken(uint256 rate, uint256 timestamp);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(IERC4626 _vault, address _feeRecipient) ERC20("API USD", "APIUSD") {
        require(address(_vault) != address(0), "APIUSD: zero vault");
        require(_feeRecipient != address(0), "APIUSD: zero fee recipient");

        vault = _vault;
        USDC = IERC20(_vault.asset());
        admin = msg.sender;
        pauser = msg.sender;
        feeRecipient = _feeRecipient;

        // Seed snapshot ring buffer with current share price
        uint256 initialRate = _vaultSharePrice();
        recentSnapshots[0] = RateSnapshot({ rate: initialRate, timestamp: block.timestamp });
        totalSnapshotCount = 1;
        lastSnapshotTime = block.timestamp;

        emit RateSnapshotTaken(initialRate, block.timestamp);
    }

    function decimals() public pure override returns (uint8) {
        return 6; // matches USDC
    }

    // =============================================================
    //                       CDP CORE
    // =============================================================

    /// @notice Open a new CDP position by depositing vault shares and optionally minting APIUSD.
    /// @param collateralShares  Amount of vault shares to deposit.
    /// @param apiusdToMint      APIUSD to mint (gross — fee is deducted from this amount).
    ///                          Pass 0 to lock collateral without minting yet.
    function open(uint256 collateralShares, uint256 apiusdToMint)
        external
        nonReentrant
        whenNotPaused
    {
        require(collateralShares > 0, "APIUSD: zero collateral");
        require(positions[msg.sender].collateralShares == 0, "APIUSD: position exists");

        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), collateralShares);
        positions[msg.sender].collateralShares = collateralShares;

        uint256 fee;
        if (apiusdToMint > 0) {
            fee = _mintDebt(msg.sender, apiusdToMint);
        }

        _takeSnapshotIfNeeded();
        emit PositionOpened(msg.sender, collateralShares, apiusdToMint, fee);
    }

    /// @notice Add more vault shares to an existing position.
    function addCollateral(uint256 collateralShares) external nonReentrant whenNotPaused {
        require(collateralShares > 0, "APIUSD: zero amount");
        require(positions[msg.sender].collateralShares > 0, "APIUSD: no position");

        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), collateralShares);
        positions[msg.sender].collateralShares += collateralShares;

        _takeSnapshotIfNeeded();
        emit CollateralAdded(msg.sender, collateralShares, positions[msg.sender].collateralShares);
    }

    /// @notice Withdraw vault shares from an existing position.
    /// @dev    Enforces LTV after removal — position must remain at or below 70% debt ratio.
    function removeCollateral(uint256 collateralShares) external nonReentrant whenNotPaused {
        Position storage pos = positions[msg.sender];
        require(pos.collateralShares > 0, "APIUSD: no position");
        require(collateralShares > 0 && collateralShares <= pos.collateralShares, "APIUSD: invalid amount");

        pos.collateralShares -= collateralShares;
        require(_isHealthy(pos, LTV_BP), "APIUSD: undercollateralized after removal");

        IERC20(address(vault)).safeTransfer(msg.sender, collateralShares);

        _takeSnapshotIfNeeded();
        emit CollateralRemoved(msg.sender, collateralShares, pos.collateralShares);
    }

    /// @notice Mint additional APIUSD against existing collateral.
    function mintMore(uint256 apiusdAmount) external nonReentrant whenNotPaused returns (uint256 fee) {
        require(positions[msg.sender].collateralShares > 0, "APIUSD: no position");
        fee = _mintDebt(msg.sender, apiusdAmount);

        _takeSnapshotIfNeeded();
        emit DebtIncreased(msg.sender, apiusdAmount, fee, positions[msg.sender].debt);
    }

    /// @notice Repay APIUSD debt without touching collateral.
    function repay(uint256 apiusdAmount) external nonReentrant {
        Position storage pos = positions[msg.sender];
        require(apiusdAmount > 0 && apiusdAmount <= pos.debt, "APIUSD: invalid repay amount");

        _burn(msg.sender, apiusdAmount);
        pos.debt -= apiusdAmount;

        _takeSnapshotIfNeeded();
        emit Repaid(msg.sender, apiusdAmount, pos.debt);
    }

    /// @notice Fully close a position: burns all outstanding debt and returns all collateral.
    function close() external nonReentrant {
        Position storage pos = positions[msg.sender];
        require(pos.collateralShares > 0, "APIUSD: no position");

        if (pos.debt > 0) {
            _burn(msg.sender, pos.debt);
        }

        uint256 shares = pos.collateralShares;
        delete positions[msg.sender];

        IERC20(address(vault)).safeTransfer(msg.sender, shares);

        _takeSnapshotIfNeeded();
        emit PositionClosed(msg.sender, shares);
    }

    /// @notice Liquidate an undercollateralized position.
    /// @dev    A position is liquidatable when debt > collateralValue * LIQ_THRESHOLD_BP.
    ///         Liquidator burns `repayAmount` APIUSD and receives vault shares worth
    ///         repayAmount + 5% bonus. If the bonus exceeds remaining collateral, all
    ///         remaining collateral is seized and the residual debt is cancelled.
    /// @param user        The CDP owner to liquidate.
    /// @param repayAmount APIUSD to repay (must be ≤ user's outstanding debt).
    function liquidate(address user, uint256 repayAmount) external nonReentrant whenNotPaused {
        Position storage pos = positions[user];
        require(pos.debt > 0, "APIUSD: no debt");
        require(!_isHealthy(pos, LIQ_THRESHOLD_BP), "APIUSD: position is healthy");
        require(repayAmount > 0 && repayAmount <= pos.debt, "APIUSD: invalid repay amount");

        // Shares to seize = (repayAmount + 5% bonus) converted to vault shares
        uint256 bonusUSDC = (repayAmount * LIQ_BONUS_BP) / BP_SCALE;
        uint256 sharesToSeize = vault.convertToShares(repayAmount + bonusUSDC);

        _burn(msg.sender, repayAmount);

        if (sharesToSeize >= pos.collateralShares) {
            // Bad-debt path: seize all collateral and cancel all debt
            sharesToSeize = pos.collateralShares;
            delete positions[user];
        } else {
            pos.debt -= repayAmount;
            pos.collateralShares -= sharesToSeize;
        }

        IERC20(address(vault)).safeTransfer(msg.sender, sharesToSeize);

        _takeSnapshotIfNeeded();
        emit Liquidated(msg.sender, user, repayAmount, sharesToSeize);
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    /// @dev Mints `apiusdAmount` gross — MINT_FEE_BP goes to feeRecipient, rest to user.
    ///      Debt is set to the net amount the user receives.
    function _mintDebt(address user, uint256 apiusdAmount) internal returns (uint256 fee) {
        require(apiusdAmount > 0, "APIUSD: zero mint");

        fee = (apiusdAmount * MINT_FEE_BP) / BP_SCALE;
        uint256 netMint = apiusdAmount - fee;

        require(totalSupply() + apiusdAmount <= MAX_TOTAL_SUPPLY, "APIUSD: supply cap exceeded");

        Position storage pos = positions[user];
        pos.debt += netMint;

        require(_isHealthy(pos, LTV_BP), "APIUSD: mint exceeds LTV");

        if (fee > 0) _mint(feeRecipient, fee);
        _mint(user, netMint);
    }

    /// @dev Returns true when debt ≤ collateralValue * thresholdBp / BP_SCALE.
    function _isHealthy(Position storage pos, uint256 thresholdBp) internal view returns (bool) {
        if (pos.debt == 0) return true;
        uint256 colValue = vault.convertToAssets(pos.collateralShares);
        return pos.debt <= (colValue * thresholdBp) / BP_SCALE;
    }

    /// @dev Vault share price expressed as 1e18-scaled USDC per share.
    function _vaultSharePrice() internal view returns (uint256) {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return 1e6;
        return (vault.totalAssets() * 1e18) / supply;
    }

    function _takeSnapshotIfNeeded() internal {
        if (block.timestamp < lastSnapshotTime + MIN_SNAPSHOT_INTERVAL) return;
        if (vault.totalSupply() == 0) return;

        uint256 rate = _vaultSharePrice();
        snapshotIndex = (snapshotIndex + 1) % MAX_SNAPSHOTS;
        recentSnapshots[snapshotIndex] = RateSnapshot({ rate: rate, timestamp: block.timestamp });
        totalSnapshotCount++;
        lastSnapshotTime = block.timestamp;

        emit RateSnapshotTaken(rate, block.timestamp);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Health factor for a position, scaled to 1e6 (1e6 = 1.0).
    ///         Values above 1e6 are healthy; below 1e6 are liquidatable.
    function healthFactor(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debt == 0) return type(uint256).max;
        uint256 colValue = vault.convertToAssets(pos.collateralShares);
        return (colValue * LIQ_THRESHOLD_BP * 1e6) / (pos.debt * BP_SCALE);
    }

    /// @notice USDC value of a user's deposited collateral.
    function collateralValue(address user) external view returns (uint256) {
        return vault.convertToAssets(positions[user].collateralShares);
    }

    /// @notice Maximum additional APIUSD the user can mint given current collateral.
    function maxMintable(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        uint256 colValue = vault.convertToAssets(pos.collateralShares);
        uint256 maxDebt = (colValue * LTV_BP) / BP_SCALE;
        if (maxDebt <= pos.debt) return 0;
        return maxDebt - pos.debt;
    }

    /// @notice Whether a position is currently eligible for liquidation.
    function isLiquidatable(address user) external view returns (bool) {
        Position storage pos = positions[user];
        if (pos.debt == 0) return false;
        return !_isHealthy(pos, LIQ_THRESHOLD_BP);
    }

    /// @notice Current vault share price (1e18-scaled USDC per share).
    function vaultSharePrice() external view returns (uint256) {
        return _vaultSharePrice();
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
        require(snapshotsAgo < available, "APIUSD: snapshot too old");

        uint256 targetIndex = snapshotsAgo <= snapshotIndex
            ? snapshotIndex - snapshotsAgo
            : MAX_SNAPSHOTS - (snapshotsAgo - snapshotIndex);

        RateSnapshot memory s = recentSnapshots[targetIndex];
        return (s.rate, s.timestamp);
    }

    /// @notice Annualized yield rate of the backing vault over the past N days.
    ///         Denominated in 1e8-scaled basis points (500000 = 5.00% APR).
    function calculateAPR(uint256 daysAgo) external view returns (uint256 apr) {
        require(daysAgo > 0 && daysAgo <= 90, "APIUSD: invalid range");
        require(totalSnapshotCount > 0, "APIUSD: no history");

        uint256 currentRate = _vaultSharePrice();
        uint256 targetTimestamp = block.timestamp - (daysAgo * 1 days);
        uint256 oldRate;
        uint256 oldTimestamp;
        bool found;

        uint256 available = totalSnapshotCount > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : totalSnapshotCount;
        for (uint256 i = 0; i < available; i++) {
            uint256 idx = i <= snapshotIndex
                ? snapshotIndex - i
                : MAX_SNAPSHOTS - (i - snapshotIndex);
            RateSnapshot memory s = recentSnapshots[idx];
            if (s.timestamp <= targetTimestamp) {
                oldRate = s.rate;
                oldTimestamp = s.timestamp;
                found = true;
                break;
            }
        }

        if (!found) {
            uint256 oldestIdx = totalSnapshotCount > MAX_SNAPSHOTS ? (snapshotIndex + 1) % MAX_SNAPSHOTS : 0;
            RateSnapshot memory s = recentSnapshots[oldestIdx];
            oldRate = s.rate;
            oldTimestamp = s.timestamp;
        }

        uint256 timeElapsed = block.timestamp - oldTimestamp;
        if (timeElapsed == 0 || oldRate == 0 || currentRate <= oldRate) return 0;

        uint256 rateIncrease = currentRate - oldRate;
        apr = (rateIncrease * SECONDS_PER_YEAR * 1e8) / (oldRate * timeElapsed);
    }

    /// @notice Convenience view returning 7-day and 30-day vault APRs.
    function getCurrentAPRs() external view returns (uint256 apr7d, uint256 apr30d) {
        if (totalSnapshotCount == 0) return (0, 0);
        try this.calculateAPR(7) returns (uint256 a) { apr7d = a; } catch { apr7d = 0; }
        try this.calculateAPR(30) returns (uint256 a) { apr30d = a; } catch { apr30d = 0; }
    }

    // =============================================================
    //                          ADMIN
    // =============================================================

    function pause() external {
        require(msg.sender == pauser, "APIUSD: only pauser");
        _pause();
    }

    function unpause() external {
        require(msg.sender == pauser, "APIUSD: only pauser");
        _unpause();
    }

    function setAdmin(address newAdmin) external {
        require(msg.sender == admin, "APIUSD: only admin");
        require(newAdmin != address(0), "APIUSD: zero address");
        address old = admin;
        admin = newAdmin;
        emit AdminUpdated(old, newAdmin);
    }

    function setPauser(address newPauser) external {
        require(msg.sender == admin, "APIUSD: only admin");
        require(newPauser != address(0), "APIUSD: zero address");
        address old = pauser;
        pauser = newPauser;
        emit PauserUpdated(old, newPauser);
    }

    function setFeeRecipient(address newRecipient) external {
        require(msg.sender == admin, "APIUSD: only admin");
        require(newRecipient != address(0), "APIUSD: zero address");
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Rescue tokens accidentally sent to this contract.
    ///         Cannot rescue vault shares (collateral) or APIUSD itself.
    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin, "APIUSD: only admin");
        require(address(token) != address(vault), "APIUSD: cannot rescue collateral");
        require(address(token) != address(this), "APIUSD: cannot rescue APIUSD");
        require(to != address(0), "APIUSD: zero address");
        token.safeTransfer(to, amount);
    }
}
