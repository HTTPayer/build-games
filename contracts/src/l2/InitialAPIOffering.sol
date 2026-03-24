// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProviderRevenueShare.sol";

/// @title InitialAPIOffering (IAO) — RS-Token-Native Version
///
/// @notice Crowdfund API development; backers receive RS tokens (a perpetual
///         revenue share) instead of vault shares.
///
/// @dev    Key simplification over the vault-based version:
///         - No harvest() function needed — backers hold RS tokens directly
///         - No MasterChef accumulator — RS token handles dividend accounting
///         - Backers call rs.claim() themselves to collect USDC dividends
///         - IAO tokens are simply RS token claim tickets
///
///         Lifecycle:
///
///         ┌─ FUNDRAISING ─────────────────────────────────────────────────────┐
///         │  Anyone deposits USDC → receives IAO tokens at fixed price.       │
///         │  Goal must be reached before deadline or IAO is cancelled.        │
///         └───────────────────────────────────────────────────────────────────┘
///                  │ finalize() — goal met                │ cancel() — goal not met
///                  ▼                                      ▼
///         ┌─ ACTIVE ───────────────┐            ┌─ CANCELLED ──────────────┐
///         │  USDC sent to provider.│            │  Backers call refund()   │
///         │  RS tokens held here.  │            │  to recover USDC.        │
///         │  Backers call claim()  │            └──────────────────────────┘
///         │  to receive RS tokens. │
///         │  Hold RS tokens to     │
///         │  earn USDC dividends.  │
///         └────────────────────────┘
///
///         Revenue routing: the provider pre-allocates RS tokens to this contract
///         at deployment (or transfers them before finalize()). On finalize(),
///         the RS tokens are confirmed held and USDC goes to provider.
///
///         After claiming RS tokens, backers call rs.claim() directly on the
///         RS token to receive their USDC dividends — no intermediary needed.
contract InitialAPIOffering is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                           CONSTANTS
    // =============================================================

    uint256 public constant BP_SCALE = 10_000;

    // =============================================================
    //                            CONFIG
    // =============================================================

    IERC20                public immutable USDC;
    IProviderRevenueShare public immutable rs;

    address public immutable provider;    // receives raised USDC on finalize
    uint256 public immutable fundingGoal; // USDC required to activate
    uint256 public immutable deadline;    // cancel after this if goal unmet
    uint256 public immutable tokenPrice;  // USDC per IAO token (6-dec units)
    uint256 public immutable maxSupply;   // IAO tokens available (= fundingGoal / tokenPrice)

    /// @notice RS tokens pre-allocated to this IAO (set at deployment).
    ///         Must be transferred to this contract before or at finalize().
    uint256 public immutable rsAllocated;

    // =============================================================
    //                         PHASE STATE
    // =============================================================

    enum Phase { Fundraising, Active, Cancelled }
    Phase public phase;

    uint256 public totalRaised;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event Contributed(address indexed backer, uint256 usdcAmount, uint256 iaoTokens);
    event Finalized(uint256 totalRaised, uint256 usdcSentToProvider, uint256 rsHeld);
    event Cancelled(uint256 totalRaised);
    event Refunded(address indexed backer, uint256 usdcAmount);
    event RSClaimed(address indexed backer, uint256 rsReceived);

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(
        IERC20                _usdc,
        IProviderRevenueShare _rs,
        address               _provider,
        uint256               _fundingGoal,
        uint256               _deadline,
        uint256               _tokenPrice,
        uint256               _rsAllocated,
        string memory         _name,
        string memory         _symbol
    ) ERC20(_name, _symbol) {
        require(address(_usdc)  != address(0), "IAO: zero USDC");
        require(address(_rs)    != address(0), "IAO: zero RS");
        require(_provider       != address(0), "IAO: zero provider");
        require(_fundingGoal     > 0,          "IAO: zero goal");
        require(_deadline        > block.timestamp, "IAO: deadline in past");
        require(_tokenPrice      > 0,          "IAO: zero price");
        require(_rsAllocated     > 0,          "IAO: zero RS allocation");
        require(_fundingGoal % _tokenPrice == 0, "IAO: goal not divisible by price");

        USDC        = _usdc;
        rs          = _rs;
        provider    = _provider;
        fundingGoal = _fundingGoal;
        deadline    = _deadline;
        tokenPrice  = _tokenPrice;
        rsAllocated = _rsAllocated;
        maxSupply   = _fundingGoal / _tokenPrice;
        phase       = Phase.Fundraising;
    }

    function decimals() public pure override returns (uint8) { return 6; }

    // =============================================================
    //                     PHASE 1: FUNDRAISING
    // =============================================================

    /// @notice Deposit USDC to receive IAO tokens at the fixed token price.
    ///         The amount must be an exact multiple of tokenPrice.
    /// @param  usdcAmount  USDC to contribute (must be multiple of tokenPrice).
    function contribute(uint256 usdcAmount) external nonReentrant {
        require(phase == Phase.Fundraising,          "IAO: not fundraising");
        require(block.timestamp <= deadline,          "IAO: deadline passed");
        require(usdcAmount > 0,                       "IAO: zero amount");
        require(usdcAmount % tokenPrice == 0,         "IAO: not a multiple of token price");

        uint256 tokens = usdcAmount / tokenPrice;
        require(totalSupply() + tokens <= maxSupply,  "IAO: exceeds cap");

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        totalRaised += usdcAmount;

        _mint(msg.sender, tokens);
        emit Contributed(msg.sender, usdcAmount, tokens);
    }

    /// @notice Advance to Active phase once the funding goal is met.
    ///         RS tokens must already be held by this contract (pre-transferred by provider).
    ///         Transfers all raised USDC to the provider. Callable by anyone.
    function finalize() external nonReentrant {
        require(phase == Phase.Fundraising, "IAO: not fundraising");
        require(totalRaised >= fundingGoal, "IAO: goal not reached");

        uint256 rsBalance = IERC20(address(rs)).balanceOf(address(this));
        require(rsBalance >= rsAllocated,   "IAO: insufficient RS tokens deposited");

        phase = Phase.Active;

        uint256 usdcAmount = USDC.balanceOf(address(this));
        USDC.safeTransfer(provider, usdcAmount);

        emit Finalized(totalRaised, usdcAmount, rsBalance);
    }

    /// @notice Cancel the IAO if the deadline passed without reaching the goal.
    ///         Enables refunds. Callable by anyone.
    function cancel() external {
        require(phase == Phase.Fundraising,  "IAO: not fundraising");
        require(block.timestamp > deadline,   "IAO: deadline not reached");
        require(totalRaised < fundingGoal,    "IAO: goal was reached, call finalize()");

        phase = Phase.Cancelled;
        emit Cancelled(totalRaised);
    }

    /// @notice Reclaim USDC contribution if the IAO was cancelled.
    function refund() external nonReentrant {
        require(phase == Phase.Cancelled, "IAO: not cancelled");

        uint256 balance = balanceOf(msg.sender);
        require(balance > 0, "IAO: no balance to refund");

        uint256 usdcAmount = balance * tokenPrice;
        _burn(msg.sender, balance);

        USDC.safeTransfer(msg.sender, usdcAmount);
        emit Refunded(msg.sender, usdcAmount);
    }

    // =============================================================
    //                   PHASE 2: RS TOKEN CLAIM
    // =============================================================

    /// @notice Claim RS tokens proportional to IAO token balance.
    ///
    ///         Burn IAO tokens → receive RS tokens.
    ///         Backers then hold RS tokens directly and call rs.claim() at any time
    ///         to receive their share of USDC dividends — no intermediary needed.
    ///
    /// @param  iaoAmount  IAO tokens to burn.
    /// @return rsReceived  RS tokens received.
    function claimRS(uint256 iaoAmount)
        external
        nonReentrant
        returns (uint256 rsReceived)
    {
        require(phase == Phase.Active,              "IAO: not active");
        require(iaoAmount > 0,                       "IAO: zero amount");
        require(balanceOf(msg.sender) >= iaoAmount,  "IAO: insufficient balance");

        // Proportional RS tokens: iaoAmount / maxSupply * rsAllocated
        rsReceived = (iaoAmount * rsAllocated) / maxSupply;
        require(rsReceived > 0, "IAO: too small");

        _burn(msg.sender, iaoAmount);

        IERC20(address(rs)).safeTransfer(msg.sender, rsReceived);
        emit RSClaimed(msg.sender, rsReceived);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice RS tokens claimable by `user` based on current IAO balance.
    function claimableRS(address user) external view returns (uint256) {
        uint256 balance = balanceOf(user);
        if (balance == 0) return 0;
        return (balance * rsAllocated) / maxSupply;
    }

    /// @notice USDC remaining until the funding goal is met.
    function remainingToGoal() external view returns (uint256) {
        if (totalRaised >= fundingGoal) return 0;
        return fundingGoal - totalRaised;
    }

    /// @notice RS tokens currently held by this contract.
    function rsBalance() external view returns (uint256) {
        return IERC20(address(rs)).balanceOf(address(this));
    }
}
