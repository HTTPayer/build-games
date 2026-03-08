// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title InitialAPIOffering (IAO)
/// @notice Kickstarter + equity crowdfunding + DeFi yield for software APIs.
///
///         A developer presells a % of their API's future revenue before launch.
///         Backers fund development by purchasing IAO tokens. If the API succeeds,
///         vault shares accumulate inside this contract and backers claim them pro-rata.
///         Success is verifiable onchain — every x402 call equals revenue equals yield.
///
/// @dev    Lifecycle:
///
///         ┌─ FUNDRAISING ─────────────────────────────────────────────────────┐
///         │  Anyone deposits USDC → receives IAO tokens at a fixed price.     │
///         │  Goal must be reached before deadline or the IAO is cancelled.    │
///         └───────────────────────────────────────────────────────────────────┘
///                  │ finalize() — goal met                │ cancel() — goal not met
///                  ▼                                      ▼
///         ┌─ ACTIVE ───────────────┐            ┌─ CANCELLED ──────────────┐
///         │  Provider receives     │            │  Backers call refund()   │
///         │  USDC. API launches.   │            │  to recover USDC.        │
///         │  Revenue flows via     │            └──────────────────────────┘
///         │  distributeRevenue().  │
///         │  harvest() converts    │
///         │  USDC → vault shares.  │
///         │  claim() distributes   │
///         │  shares to backers.    │
///         └────────────────────────┘
///
///         Revenue distribution uses the MasterChef accumulator pattern so claiming
///         is O(1) regardless of how many distributions have occurred, and IAO tokens
///         remain fully transferable with correct reward accounting on every transfer.
///
///         Revenue routing: configure the ProviderRevenueSplitter to send `revenueShareBp`
///         of every distribution to this contract's address. Anyone may then call
///         `harvest()` to convert the accumulated USDC into vault shares.
contract InitialAPIOffering is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    uint256 public constant BP_SCALE  = 10_000;
    uint256 public constant PRECISION = 1e18; // accumulator scaling factor

    // =============================================================
    //                           CONFIG
    // =============================================================

    IERC20   public immutable USDC;
    IERC4626 public immutable vault;

    address  public immutable provider;     // receives raised USDC on finalize
    uint256  public immutable fundingGoal;  // USDC required to activate
    uint256  public immutable deadline;     // Unix timestamp; cancel after this if goal unmet
    uint256  public immutable tokenPrice;   // USDC per IAO token (6-decimal USDC units)
    uint256  public immutable maxSupply;    // total IAO tokens available (= fundingGoal / tokenPrice)

    // =============================================================
    //                         PHASE STATE
    // =============================================================

    enum Phase { Fundraising, Active, Cancelled }
    Phase public phase;

    uint256 public totalRaised; // USDC raised so far

    // =============================================================
    //                    REWARD ACCUMULATOR
    //          (MasterChef pattern — O(1) claiming)
    // =============================================================

    /// @dev Cumulative vault shares earned per IAO token * PRECISION.
    ///      Increases each time harvest() is called.
    uint256 public accSharesPerToken;

    /// @dev Per-user snapshot of accSharesPerToken * balance at last update.
    ///      Settles pending shares before any balance change.
    mapping(address => uint256) public rewardDebt;

    /// @dev Settled vault shares waiting to be claimed.
    mapping(address => uint256) public pendingClaim;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event Contributed(address indexed backer, uint256 usdcAmount, uint256 iaoTokens);
    event Finalized(uint256 totalRaised, uint256 usdcSentToProvider);
    event Cancelled(uint256 totalRaised);
    event Refunded(address indexed backer, uint256 usdcAmount);
    event Harvested(uint256 usdcDeposited, uint256 sharesReceived);
    event Claimed(address indexed backer, uint256 sharesReceived);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(
        IERC20   _usdc,
        IERC4626 _vault,
        address  _provider,
        uint256  _fundingGoal,
        uint256  _deadline,
        uint256  _tokenPrice,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        require(address(_usdc)   != address(0), "IAO: zero USDC");
        require(address(_vault)  != address(0), "IAO: zero vault");
        require(_provider        != address(0), "IAO: zero provider");
        require(_fundingGoal      > 0,          "IAO: zero goal");
        require(_deadline         > block.timestamp, "IAO: deadline in past");
        require(_tokenPrice       > 0,          "IAO: zero price");
        require(_fundingGoal % _tokenPrice == 0,"IAO: goal not divisible by price");

        USDC        = _usdc;
        vault       = _vault;
        provider    = _provider;
        fundingGoal = _fundingGoal;
        deadline    = _deadline;
        tokenPrice  = _tokenPrice;
        maxSupply   = _fundingGoal / _tokenPrice;
        phase       = Phase.Fundraising;
    }

    function decimals() public pure override returns (uint8) { return 6; }

    // =============================================================
    //                      PHASE 1: FUNDRAISING
    // =============================================================

    /// @notice Deposit USDC to receive IAO tokens at the fixed token price.
    ///         The amount must be an exact multiple of `tokenPrice`.
    /// @param  usdcAmount  USDC to contribute (must be a multiple of tokenPrice).
    function contribute(uint256 usdcAmount) external nonReentrant {
        require(phase == Phase.Fundraising,            "IAO: not in fundraising phase");
        require(block.timestamp <= deadline,           "IAO: deadline passed");
        require(usdcAmount > 0,                        "IAO: zero amount");
        require(usdcAmount % tokenPrice == 0,          "IAO: not a multiple of token price");

        uint256 tokens = usdcAmount / tokenPrice;
        require(totalSupply() + tokens <= maxSupply,   "IAO: exceeds cap");

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        totalRaised += usdcAmount;

        _settleRewards(msg.sender); // reward debt is 0 at mint, but keep consistent
        _mint(msg.sender, tokens);

        emit Contributed(msg.sender, usdcAmount, tokens);
    }

    /// @notice Advance the IAO to Active phase once the funding goal is met.
    ///         Transfers all raised USDC to the provider. Callable by anyone.
    function finalize() external nonReentrant {
        require(phase == Phase.Fundraising,      "IAO: not in fundraising phase");
        require(totalRaised >= fundingGoal,      "IAO: goal not reached");

        phase = Phase.Active;

        uint256 amount = USDC.balanceOf(address(this));
        USDC.safeTransfer(provider, amount);

        emit Finalized(totalRaised, amount);
    }

    /// @notice Cancel the IAO if the deadline has passed without reaching the goal.
    ///         Enables refunds. Callable by anyone.
    function cancel() external {
        require(phase == Phase.Fundraising,       "IAO: not in fundraising phase");
        require(block.timestamp > deadline,        "IAO: deadline not reached");
        require(totalRaised < fundingGoal,         "IAO: goal was reached, call finalize()");

        phase = Phase.Cancelled;
        emit Cancelled(totalRaised);
    }

    /// @notice Reclaim USDC contribution if the IAO was cancelled.
    function refund() external nonReentrant {
        require(phase == Phase.Cancelled, "IAO: not cancelled");

        uint256 balance = balanceOf(msg.sender);
        require(balance > 0, "IAO: no balance to refund");

        uint256 usdcAmount = balance * tokenPrice;

        _settleRewards(msg.sender);
        _burn(msg.sender, balance);
        pendingClaim[msg.sender] = 0; // no vault shares on refund

        USDC.safeTransfer(msg.sender, usdcAmount);
        emit Refunded(msg.sender, usdcAmount);
    }

    // =============================================================
    //                    PHASE 2: REVENUE ACCRUAL
    // =============================================================

    /// @notice Convert any USDC received from the splitter into vault shares.
    ///         Updates the accumulator so all current IAO holders earn proportionally.
    ///         Callable by anyone — permissionless harvest.
    function harvest() external nonReentrant {
        require(phase == Phase.Active, "IAO: not active");

        uint256 usdcBalance = USDC.balanceOf(address(this));
        require(usdcBalance > 0, "IAO: nothing to harvest");
        require(totalSupply() > 0, "IAO: no IAO tokens outstanding");

        // Deposit USDC into the vault, receive vault shares
        USDC.forceApprove(address(vault), usdcBalance);
        uint256 sharesBefore = IERC20(address(vault)).balanceOf(address(this));
        vault.deposit(usdcBalance, address(this));
        uint256 newShares = IERC20(address(vault)).balanceOf(address(this)) - sharesBefore;

        // Distribute new shares to all current IAO token holders via the accumulator
        accSharesPerToken += (newShares * PRECISION) / totalSupply();

        emit Harvested(usdcBalance, newShares);
    }

    /// @notice Claim accumulated vault shares.
    ///         Vault shares are yield-bearing — holding them continues earning API revenue.
    function claim() external nonReentrant {
        require(phase == Phase.Active, "IAO: not active");

        _settleRewards(msg.sender);

        uint256 shares = pendingClaim[msg.sender];
        require(shares > 0, "IAO: nothing to claim");

        pendingClaim[msg.sender] = 0;
        rewardDebt[msg.sender]   = (accSharesPerToken * balanceOf(msg.sender)) / PRECISION;

        IERC20(address(vault)).safeTransfer(msg.sender, shares);
        emit Claimed(msg.sender, shares);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Vault shares claimable by `user` right now.
    function claimable(address user) external view returns (uint256) {
        uint256 balance  = balanceOf(user);
        if (balance == 0) return pendingClaim[user];
        uint256 pending  = (accSharesPerToken * balance) / PRECISION - rewardDebt[user];
        return pendingClaim[user] + pending;
    }

    /// @notice USDC value of `user`'s claimable vault shares at current share price.
    function claimableUsdc(address user) external view returns (uint256) {
        uint256 balance  = balanceOf(this.claimable.selector == bytes4(0) ? address(0) : user);
        uint256 shares   = (accSharesPerToken * balance) / PRECISION
                           - rewardDebt[user]
                           + pendingClaim[user];
        return vault.convertToAssets(shares);
    }

    /// @notice USDC remaining until the funding goal is met.
    function remainingToGoal() external view returns (uint256) {
        if (totalRaised >= fundingGoal) return 0;
        return fundingGoal - totalRaised;
    }

    /// @notice Total USDC value of all vault shares accumulated for IAO holders.
    function totalAccumulatedValue() external view returns (uint256) {
        uint256 sharesHeld = IERC20(address(vault)).balanceOf(address(this));
        return vault.convertToAssets(sharesHeld);
    }

    // =============================================================
    //                        INTERNAL
    // =============================================================

    /// @dev Settle any pending rewards for `user` into pendingClaim before balance changes.
    function _settleRewards(address user) internal {
        uint256 balance = balanceOf(user);
        if (balance > 0) {
            uint256 pending = (accSharesPerToken * balance) / PRECISION - rewardDebt[user];
            if (pending > 0) pendingClaim[user] += pending;
        }
        rewardDebt[user] = (accSharesPerToken * balance) / PRECISION;
    }

    /// @dev OZ v5 hook — fires on mint, burn, and transfer.
    ///      Settles rewards for both sender and receiver before balances change.
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) _settleRewards(from);
        if (to   != address(0)) _settleRewards(to);

        super._update(from, to, amount);

        // Recalculate debt against new balances
        if (from != address(0)) rewardDebt[from] = (accSharesPerToken * balanceOf(from)) / PRECISION;
        if (to   != address(0)) rewardDebt[to]   = (accSharesPerToken * balanceOf(to))   / PRECISION;
    }
}
