// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProviderRevenueShare.sol";

/// @title APIYieldIndex — Weighted Basket of RS Tokens
///
/// @notice A diversified index of ProviderRevenueShare tokens from multiple APIs.
///         Holding one index token gives exposure to multiple API revenue streams.
///         As each component earns dividends, the index value grows — no rebalancing needed.
///
/// @dev    Architecture (RS-token-native):
///         - Admin registers up to MAX_COMPONENTS RS tokens with basis-point weights (sum = 10,000)
///         - Index value = Σ dividends earned by each component (claimed + claimable)
///         - Users deposit proportional RS tokens → get index tokens
///         - Redeem: receive proportional RS tokens from each component + share of harvested USDC
///
///         MasterChef accumulator tracks total harvested USDC across all components.
///         Per-component claimable adds real-time pending dividends to index value.
///
///         Deposit flow:
///           1. Call quote(usdcTarget) to get required RS amounts per component
///           2. Approve each RS token
///           3. Call deposit(rsAmounts[])
contract APIYieldIndex is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                           CONFIG
    // =============================================================

    uint256 public constant MAX_COMPONENTS = 10;
    uint256 public constant BP_SCALE       = 10_000;
    uint256 public constant FEE_BP         = 25;        // 0.25% on deposit and redeem
    uint256 public constant MAX_SUPPLY     = 1_000_000e6;

    address public admin;

    // =============================================================
    //                          COMPONENTS
    // =============================================================

    struct Component {
        IProviderRevenueShare rs;
        uint256 weightBp;  // basis point weight; all weights must sum to BP_SCALE
        string  name;      // human-readable label (e.g., "AI Inference API")
    }

    Component[] public components;

    // =============================================================
    //                      USDC ACCUMULATOR
    // =============================================================

    /// @notice Total USDC harvested across all components and stored in this contract
    uint256 public totalHarvestedUsdc;

    /// @notice USDC token (shared across all RS tokens — they all distribute the same USDC)
    IERC20 public immutable USDC;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event ComponentAdded(uint256 indexed id, address rs, uint256 weightBp, string name);
    event ComponentWeightUpdated(uint256 indexed id, uint256 newWeightBp);
    event Deposited(address indexed user, uint256[] rsAmountsIn, uint256 indexMinted, uint256 usdcValue);
    event Redeemed(address indexed user, uint256 indexBurned, uint256[] rsAmountsOut, uint256 usdcReturned);
    event Harvested(uint256 usdcClaimed);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(IERC20 _usdc, string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
    {
        require(address(_usdc) != address(0), "Index: zero usdc");
        USDC  = _usdc;
        admin = msg.sender;
    }

    function decimals() public pure override returns (uint8) { return 6; }

    // =============================================================
    //                     COMPONENT MANAGEMENT
    // =============================================================

    /// @notice Register a new RS token component.
    ///         After adding all components, weights must sum to BP_SCALE.
    function addComponent(
        IProviderRevenueShare _rs,
        uint256 _weightBp,
        string calldata _name
    ) external {
        require(msg.sender == admin,              "Index: only admin");
        require(address(_rs) != address(0),       "Index: zero rs");
        require(_weightBp > 0,                    "Index: zero weight");
        require(components.length < MAX_COMPONENTS, "Index: too many components");

        for (uint256 i = 0; i < components.length; i++) {
            require(address(components[i].rs) != address(_rs), "Index: duplicate rs");
        }

        components.push(Component({ rs: _rs, weightBp: _weightBp, name: _name }));
        emit ComponentAdded(components.length - 1, address(_rs), _weightBp, _name);
    }

    /// @notice Update a component's weight. All weights must sum to BP_SCALE.
    function updateWeight(uint256 id, uint256 newWeightBp) external {
        require(msg.sender == admin,   "Index: only admin");
        require(id < components.length, "Index: invalid id");
        components[id].weightBp = newWeightBp;
        require(_weightsValid(),       "Index: weights must sum to BP_SCALE");
        emit ComponentWeightUpdated(id, newWeightBp);
    }

    function componentCount() external view returns (uint256) { return components.length; }

    // =============================================================
    //                       DEPOSIT (JOIN)
    // =============================================================

    /// @notice Deposit RS tokens from every component to mint index tokens.
    ///         Use quote() first to compute the correct amounts for a target USDC value.
    ///
    /// @param  rsAmountsIn  RS token amounts for each component in component order.
    /// @return indexMinted  Index tokens received after fee.
    function deposit(uint256[] calldata rsAmountsIn)
        external
        nonReentrant
        returns (uint256 indexMinted)
    {
        uint256 n = components.length;
        require(n > 0,                  "Index: no components");
        require(_weightsValid(),         "Index: weights not finalised");
        require(rsAmountsIn.length == n, "Index: wrong array length");

        // Harvest all pending USDC before computing index value
        _harvestAll();

        // Compute USDC value of deposit using live RS dividend data
        // Since RS tokens don't have a market price onchain, we proxy value by
        // assuming each RS token contributes dividend value ∝ its claimable USDC.
        // For equal weighting, all components should contribute in proportion to weights.
        uint256 supply = totalSupply();
        uint256 depositUsdcValue = _computeDepositValue(rsAmountsIn);
        require(depositUsdcValue > 0, "Index: zero deposit value");

        uint256 fee     = (depositUsdcValue * FEE_BP) / BP_SCALE;
        uint256 netUsdc = depositUsdcValue - fee;

        if (supply == 0) {
            indexMinted = netUsdc;
        } else {
            uint256 totalVal = indexValue();
            require(totalVal > 0, "Index: zero index value");
            indexMinted = (netUsdc * supply) / totalVal;
        }

        require(indexMinted > 0,                   "Index: mint too small");
        require(supply + indexMinted <= MAX_SUPPLY, "Index: supply cap");

        // Pull RS tokens from user
        for (uint256 i = 0; i < n; i++) {
            if (rsAmountsIn[i] > 0) {
                IERC20(address(components[i].rs)).safeTransferFrom(
                    msg.sender, address(this), rsAmountsIn[i]
                );
            }
        }

        _mint(msg.sender, indexMinted);
        emit Deposited(msg.sender, rsAmountsIn, indexMinted, depositUsdcValue);
    }

    // =============================================================
    //                       REDEEM (EXIT)
    // =============================================================

    /// @notice Burn index tokens to receive pro-rata RS tokens from each component
    ///         plus a proportional share of any harvested USDC held by the contract.
    ///
    /// @param  indexAmount  Index tokens to burn.
    /// @return rsAmountsOut  RS tokens returned per component.
    function redeem(uint256 indexAmount)
        external
        nonReentrant
        returns (uint256[] memory rsAmountsOut)
    {
        uint256 n = components.length;
        require(n > 0,                              "Index: no components");
        require(indexAmount > 0,                    "Index: zero amount");
        require(balanceOf(msg.sender) >= indexAmount, "Index: insufficient balance");

        _harvestAll();

        uint256 supply      = totalSupply();
        rsAmountsOut        = new uint256[](n);
        uint256 usdcBalance = USDC.balanceOf(address(this));

        // Proportional USDC
        uint256 usdcOut = (usdcBalance * indexAmount) / supply;

        for (uint256 i = 0; i < n; i++) {
            uint256 rsHeld    = IERC20(address(components[i].rs)).balanceOf(address(this));
            uint256 grossRS   = (rsHeld * indexAmount) / supply;
            uint256 feeRS     = (grossRS * FEE_BP) / BP_SCALE;
            rsAmountsOut[i]   = grossRS - feeRS;
        }

        _burn(msg.sender, indexAmount);

        for (uint256 i = 0; i < n; i++) {
            if (rsAmountsOut[i] > 0) {
                IERC20(address(components[i].rs)).safeTransfer(msg.sender, rsAmountsOut[i]);
            }
        }

        if (usdcOut > 0) USDC.safeTransfer(msg.sender, usdcOut);

        emit Redeemed(msg.sender, indexAmount, rsAmountsOut, usdcOut);
    }

    // =============================================================
    //                           HARVEST
    // =============================================================

    /// @notice Permissionless: claim USDC dividends from all RS token components.
    function harvest() external nonReentrant {
        uint256 claimed = _harvestAll();
        require(claimed > 0, "Index: nothing to harvest");
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    /// @notice Total USDC value backed by this index.
    ///         = USDC already harvested in contract + pending claimable from all RS tokens.
    function indexValue() public view returns (uint256 total) {
        total = USDC.balanceOf(address(this));
        for (uint256 i = 0; i < components.length; i++) {
            total += components[i].rs.claimable(address(this));
        }
    }

    /// @notice USDC value per index token (1e6-scaled).
    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (indexValue() * 1e6) / supply;
    }

    /// @notice Per-component breakdown.
    function componentSnapshot()
        external
        view
        returns (
            address[] memory rsTokens,
            uint256[] memory weights,
            uint256[] memory rsHeld,
            uint256[] memory usdcClaimable
        )
    {
        uint256 n   = components.length;
        rsTokens    = new address[](n);
        weights     = new uint256[](n);
        rsHeld      = new uint256[](n);
        usdcClaimable = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            rsTokens[i]      = address(components[i].rs);
            weights[i]       = components[i].weightBp;
            rsHeld[i]        = IERC20(address(components[i].rs)).balanceOf(address(this));
            usdcClaimable[i] = components[i].rs.claimable(address(this));
        }
    }

    /// @notice Quote RS amounts needed to deposit a target USDC value.
    ///         Allocates usdcTarget across components by weight.
    ///         Returns raw RS token amounts assuming 1 RS token ≈ 1 unit of weight capacity.
    ///         Callers should verify amounts via componentSnapshot().
    /// @param  usdcTarget  Target USDC value to add to the index.
    function quote(uint256 usdcTarget) external view returns (uint256[] memory rsNeeded) {
        uint256 n = components.length;
        rsNeeded = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            // Allocate USDC by weight, then convert to RS tokens
            // Since RS tokens don't have a fixed USDC price onchain,
            // we use the proportion of current RS held × weightBp as a heuristic.
            rsNeeded[i] = (usdcTarget * components[i].weightBp) / BP_SCALE;
        }
    }

    /// @notice Quote RS amounts returned for redeeming `indexAmount` tokens.
    function quoteRedeem(uint256 indexAmount) external view returns (uint256[] memory rsOut) {
        uint256 n      = components.length;
        uint256 supply = totalSupply();
        rsOut          = new uint256[](n);
        if (supply == 0) return rsOut;

        for (uint256 i = 0; i < n; i++) {
            uint256 rsHeld   = IERC20(address(components[i].rs)).balanceOf(address(this));
            uint256 grossRS  = (rsHeld * indexAmount) / supply;
            uint256 feeRS    = (grossRS * FEE_BP) / BP_SCALE;
            rsOut[i]         = grossRS - feeRS;
        }
    }

    // =============================================================
    //                           INTERNAL
    // =============================================================

    function _harvestAll() internal returns (uint256 totalClaimed) {
        for (uint256 i = 0; i < components.length; i++) {
            uint256 claimable = components[i].rs.claimable(address(this));
            if (claimable > 0) {
                components[i].rs.claim();
                totalClaimed += claimable;
            }
        }
        if (totalClaimed > 0) {
            totalHarvestedUsdc += totalClaimed;
            emit Harvested(totalClaimed);
        }
    }

    /// @dev Proxy for USDC value of a deposit: use the proportional share of index value.
    ///      Each component contributes its weight-adjusted RS amount.
    function _computeDepositValue(uint256[] memory rsAmountsIn)
        internal
        view
        returns (uint256 usdcValue)
    {
        // Total RS tokens held per component before deposit
        // Deposit value ∝ ratio of added RS to existing RS, weighted by component dividend yield
        for (uint256 i = 0; i < components.length; i++) {
            uint256 currentRS = IERC20(address(components[i].rs)).balanceOf(address(this));
            uint256 claimable = components[i].rs.claimable(address(this));
            // Per-component dividend rate: claimable / currentRS (if any held)
            if (currentRS > 0) {
                // Value added = rsAmountsIn * (claimable / currentRS)
                usdcValue += (rsAmountsIn[i] * claimable) / currentRS;
            } else {
                // No existing RS held: use raw RS amount as proxy value (1 RS ≈ 1 USDC unit)
                usdcValue += rsAmountsIn[i];
            }
        }
    }

    function _weightsValid() internal view returns (bool) {
        uint256 total;
        for (uint256 i = 0; i < components.length; i++) {
            total += components[i].weightBp;
        }
        return total == BP_SCALE;
    }

    // =============================================================
    //                             ADMIN
    // =============================================================

    function setAdmin(address newAdmin) external {
        require(msg.sender == admin,     "Index: only admin");
        require(newAdmin != address(0),  "Index: zero address");
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin, "Index: only admin");
        require(to != address(0),    "Index: zero address");
        token.safeTransfer(to, amount);
    }
}
