// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../ProviderRevenueShare.sol";

/**
 * @title WrappedRevenueShare
 * @notice ERC-20 wrapper for ProviderRevenueShare tokens.
 *         1 wRS = 1 RS + accrued USDC yield.
 *
 * @dev    Similar to wstETH. Users deposit RS and receive wRS 1:1.
 *         USDC dividends are accumulated via harvest() and distributed
 *         proportionally when users redeem.
 *
 * Mechanism
 * ─────────
 *   1. Users deposit RS tokens via deposit() → receive wRS 1:1
 *   2. Contract holds RS forever, claims USDC dividends via harvest()
 *   3. Each wRS earns: totalUSDC / totalSupply per period
 *   4. Users redeem via redeem() → get back RS + accrued USDC
 *
 * Chainlink Integration
 * ─────────────────────
 *   - Automation: harvest() can be automation-compatible
 *   - Price Feed: exchangeRate() returns USDC value per wRS (1e8 format)
 */
contract WrappedRevenueShare is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                 CONFIG
    // ─────────────────────────────────────────────────────────────────────────────

    ProviderRevenueShare public immutable revenueShare;
    IERC20 public immutable USDC;
    address public immutable rsToken;

    uint256 public constant BPS_SCALE = 10_000;
    uint256 public withdrawFeeBps = 0;

    address public treasury;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                STORAGE
    // ─────────────────────────────────────────────────────────────────────────────

    uint256 public totalHarvested;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                 EVENTS
    // ─────────────────────────────────────────────────────────────────────────────

    event Deposit(address indexed user, uint256 rsDeposited, uint256 wrsMinted);
    event Redeem(address indexed user, uint256 wrsBurned, uint256 rsOut, uint256 usdcOut, uint256 fee);
    event Harvest(address indexed caller, uint256 usdcHarvested);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event WithdrawFeeUpdated(uint256 oldFee, uint256 newFee);

    // ─────────────────────────────────────────────────────────────────────────────
    //                               CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────────

    constructor(
        ProviderRevenueShare _revenueShare,
        address _treasury,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        require(address(_revenueShare) != address(0), "zero revenue share");
        require(_treasury != address(0), "zero treasury");

        revenueShare = _revenueShare;
        USDC = revenueShare.USDC();
        rsToken = address(_revenueShare);
        treasury = _treasury;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                CORE
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit RS tokens and receive wRS 1:1.
     *         1 wRS = 1 RS + accrued USDC yield.
     *
     * @param rsAmount Amount of RS tokens to deposit.
     * @return wrsMinted Amount of wRS minted to msg.sender.
     */
    function deposit(uint256 rsAmount) external nonReentrant returns (uint256 wrsMinted) {
        require(rsAmount > 0, "zero amount");

        IERC20(rsToken).safeTransferFrom(msg.sender, address(this), rsAmount);

        wrsMinted = rsAmount;

        _mint(msg.sender, wrsMinted);

        emit Deposit(msg.sender, rsAmount, wrsMinted);
    }

    /**
     * @notice Burn wRS and receive proportional RS + USDC.
     *         Full exit: gets your share of both underlying assets.
     *
     * @param wrsAmount Amount of wRS to burn.
     * @return rsOut    RS tokens returned.
     * @return usdcOut  USDC returned.
     */
    function redeem(uint256 wrsAmount)
        external
        nonReentrant
        returns (uint256 rsOut, uint256 usdcOut)
    {
        require(wrsAmount > 0, "zero amount");
        require(balanceOf(msg.sender) >= wrsAmount, "insufficient balance");

        uint256 supply = totalSupply();
        require(supply > 0, "no supply");

        uint256 rsBalance = IERC20(rsToken).balanceOf(address(this));
        uint256 usdcBalance = USDC.balanceOf(address(this));

        rsOut = (wrsAmount * rsBalance) / supply;
        usdcOut = (wrsAmount * usdcBalance) / supply;

        require(rsOut > 0 || usdcOut > 0, "withdraw amount too small");

        uint256 fee = (usdcOut * withdrawFeeBps) / BPS_SCALE;
        usdcOut -= fee;

        _burn(msg.sender, wrsAmount);

        if (rsOut > 0) {
            IERC20(rsToken).safeTransfer(msg.sender, rsOut);
        }
        if (fee > 0) {
            USDC.safeTransfer(treasury, fee);
        }
        if (usdcOut > 0) {
            USDC.safeTransfer(msg.sender, usdcOut);
        }

        emit Redeem(msg.sender, wrsAmount, rsOut, usdcOut, fee);
    }

    /**
     * @notice Harvest pending USDC dividends then redeem wRS for RS + USDC.
     *         Convenience function for best UX.
     *
     * @param wrsAmount Amount of wRS to redeem.
     * @return rsOut    RS tokens returned.
     * @return usdcOut  USDC returned (includes just-harvested dividends).
     */
    function harvestAndRedeem(uint256 wrsAmount)
        external
        nonReentrant
        returns (uint256 rsOut, uint256 usdcOut)
    {
        require(wrsAmount > 0, "zero amount");
        require(balanceOf(msg.sender) >= wrsAmount, "insufficient balance");

        // Harvest first
        uint256 claimable = revenueShare.claimable(address(this));
        if (claimable > 0) {
            uint256 balanceBefore = USDC.balanceOf(address(this));
            revenueShare.claim(address(this));
            uint256 harvested = USDC.balanceOf(address(this)) - balanceBefore;
            if (harvested > 0) {
                totalHarvested += harvested;
                emit Harvest(msg.sender, harvested);
            }
        }

        // Then redeem
        uint256 supply = totalSupply();
        require(supply > 0, "no supply");

        uint256 rsBalance = IERC20(rsToken).balanceOf(address(this));
        uint256 usdcBalance = USDC.balanceOf(address(this));

        rsOut = (wrsAmount * rsBalance) / supply;
        usdcOut = (wrsAmount * usdcBalance) / supply;

        require(rsOut > 0 || usdcOut > 0, "withdraw amount too small");

        uint256 fee = (usdcOut * withdrawFeeBps) / BPS_SCALE;
        usdcOut -= fee;

        _burn(msg.sender, wrsAmount);

        if (rsOut > 0) {
            IERC20(rsToken).safeTransfer(msg.sender, rsOut);
        }
        if (fee > 0) {
            USDC.safeTransfer(treasury, fee);
        }
        if (usdcOut > 0) {
            USDC.safeTransfer(msg.sender, usdcOut);
        }

        emit Redeem(msg.sender, wrsAmount, rsOut, usdcOut, fee);
    }

    /**
     * @notice Harvest accrued USDC dividends from revenue share.
     *         Chainlink Automation can call this periodically.
     *
     * @return harvested Amount of USDC harvested.
     */
    function harvest() external nonReentrant returns (uint256 harvested) {
        uint256 claimable = revenueShare.claimable(address(this));
        if (claimable == 0) return 0;

        uint256 balanceBefore = USDC.balanceOf(address(this));
        revenueShare.claim(address(this));
        uint256 balanceAfter = USDC.balanceOf(address(this));

        harvested = balanceAfter - balanceBefore;
        if (harvested > 0) {
            totalHarvested += harvested;
            emit Harvest(msg.sender, harvested);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                VIEWS
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Total RS tokens held by the vault.
     */
    function totalRS() external view returns (uint256) {
        return IERC20(rsToken).balanceOf(address(this));
    }

    /**
     * @notice Total USDC held by the vault (from harvested dividends).
     */
    function totalUSDC() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /**
     * @notice Current exchange rate: USDC per wRS, scaled by 1e6.
     *         Only reflects USDC yield, not full underlying value (RS + USDC).
     *         Use totalRS() + totalUSDC() for complete vault value.
     */
    function exchangeRate() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        return (USDC.balanceOf(address(this)) * 1e6) / supply;
    }

    /**
     * @notice USDC dividends claimable from revenue share right now.
     */
    function pendingHarvest() external view returns (uint256) {
        return revenueShare.claimable(address(this));
    }

    /**
     * @notice Total USDC harvested since contract deployment.
     */
    function totalHarvestedAmount() external view returns (uint256) {
        return totalHarvested;
    }

    /**
     * @notice Preview how much wRS you'll receive for depositing RS tokens.
     *
     * @param rsAmount Amount of RS tokens to deposit.
     * @return wrsOut Amount of wRS you'll receive.
     */
    function previewDeposit(uint256 rsAmount) external view returns (uint256 wrsOut) {
        return rsAmount;
    }

    /**
     * @notice Preview how much RS + USDC you'll receive for redeeming wRS.
     *
     * @param wrsAmount Amount of wRS to redeem.
     * @return rsOut    RS tokens you'll receive.
     * @return usdcOut USDC you'll receive.
     */
    function previewRedeem(uint256 wrsAmount) external view returns (uint256 rsOut, uint256 usdcOut) {
        if (wrsAmount == 0) return (0, 0);
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);

        uint256 rsBalance = IERC20(rsToken).balanceOf(address(this));
        uint256 usdcBalance = USDC.balanceOf(address(this));

        rsOut = (wrsAmount * rsBalance) / supply;
        usdcOut = (wrsAmount * usdcBalance) / supply;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Assets backing per wRS, scaled by 1e6.
     * @return rsPerWrs  RS per wRS (1e6 = 1 RS)
     * @return usdcPerWrs USDC per wRS (1e6 = 1 USDC)
     */
    function assetsPerShare() external view returns (uint256 rsPerWrs, uint256 usdcPerWrs) {
        uint256 supply = totalSupply();
        if (supply == 0) return (1e6, 0);
        rsPerWrs = (IERC20(rsToken).balanceOf(address(this)) * 1e6) / supply;
        usdcPerWrs = (USDC.balanceOf(address(this)) * 1e6) / supply;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                              CHAINLINK FEED
    // ─────────────────────────────────────────────────────────────────────────────

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        uint256 supply = totalSupply();
        uint256 rate = supply == 0 ? 1e6 : (USDC.balanceOf(address(this)) * 1e6) / supply;

        answer = int256(rate * 100);

        startedAt = block.timestamp - 1 hours;
        updatedAt = block.timestamp;
        answeredInRound = uint80(block.number);
        roundId = uint80(block.number);
    }

    function latestAnswer() external view returns (int256) {
        uint256 supply = totalSupply();
        uint256 rate = supply == 0 ? 1e6 : (USDC.balanceOf(address(this)) * 1e6) / supply;
        return int256(rate * 100);
    }

    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function latestRound() external view returns (uint256) {
        return block.number;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                ADMIN
    // ─────────────────────────────────────────────────────────────────────────────

    function setTreasury(address newTreasury) external {
        require(newTreasury != address(0), "zero address");
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setWithdrawFee(uint256 feeBps) external {
        require(feeBps <= 1000, "fee too high");
        uint256 old = withdrawFeeBps;
        withdrawFeeBps = feeBps;
        emit WithdrawFeeUpdated(old, feeBps);
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(to != address(0), "zero address");
        require(address(token) != rsToken, "cannot rescue RS");
        require(address(token) != address(USDC), "cannot rescue USDC");
        token.safeTransfer(to, amount);
    }
}
