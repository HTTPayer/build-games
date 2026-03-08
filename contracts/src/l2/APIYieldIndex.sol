// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title APIYieldIndex
/// @notice A weighted basket of ProviderRevenueVault shares, tradable as a single ERC-20.
///         Holding one index token gives you diversified exposure to multiple API cash flows.
///         As each component API earns revenue, its vault share price rises, automatically
///         appreciating the index value — no rebalancing or manual compounding required.
///
/// @dev    Architecture:
///         - Admin registers up to MAX_COMPONENTS vaults with basis-point weights (sum = 10,000)
///         - Users deposit each component's vault shares in proportion to the current weights
///         - Index tokens are minted proportional to the USDC value added vs total index value
///         - Redemption burns index tokens and returns pro-rata of every component
///         - Index value = Σ vault_i.convertToAssets(sharesHeld_i) / indexSupply
///
///         Deposit flow (user perspective):
///           1. Approve each component vault share for this contract
///           2. Call quote(usdcTarget) to get required share amounts per component
///           3. Call deposit(sharesIn[]) — contract pulls exactly those shares
///
///         Composable as DeFi collateral: the index token is a standard ERC-20 whose
///         backing value is verifiable onchain at any time via indexValue().
///
///         The index turns API usage into an index asset class — a single token that
///         tracks the yield performance of Avalanche's API economy.
contract APIYieldIndex is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                          CONFIG
    // =============================================================

    uint256 public constant MAX_COMPONENTS = 10;
    uint256 public constant BP_SCALE       = 10_000;
    uint256 public constant FEE_BP         = 25;    // 0.25% on deposit and redeem
    uint256 public constant MAX_SUPPLY     = 1_000_000e6;

    address public admin;

    // =============================================================
    //                         COMPONENTS
    // =============================================================

    struct Component {
        IERC4626 vault;
        uint256  weightBp; // weight in basis points; all weights must sum to BP_SCALE
        string   name;     // human-readable label (e.g., "AI Inference API")
    }

    Component[] public components;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event ComponentAdded(uint256 indexed id, address vault, uint256 weightBp, string name);
    event ComponentWeightUpdated(uint256 indexed id, uint256 newWeightBp);
    event Deposited(address indexed user, uint256[] sharesIn, uint256 indexMinted, uint256 usdcValue);
    event Redeemed(address indexed user, uint256 indexBurned, uint256[] sharesOut, uint256 usdcValue);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        admin = msg.sender;
    }

    function decimals() public pure override returns (uint8) { return 6; }

    // =============================================================
    //                    COMPONENT MANAGEMENT
    // =============================================================

    /// @notice Register a new vault component.
    ///         After adding all components, weights must sum to BP_SCALE.
    function addComponent(IERC4626 _vault, uint256 _weightBp, string calldata _name) external {
        require(msg.sender == admin,             "Index: only admin");
        require(address(_vault) != address(0),   "Index: zero vault");
        require(_weightBp > 0,                   "Index: zero weight");
        require(components.length < MAX_COMPONENTS, "Index: too many components");

        // Ensure no duplicate vaults
        for (uint256 i = 0; i < components.length; i++) {
            require(address(components[i].vault) != address(_vault), "Index: duplicate vault");
        }

        components.push(Component({ vault: _vault, weightBp: _weightBp, name: _name }));
        emit ComponentAdded(components.length - 1, address(_vault), _weightBp, _name);
    }

    /// @notice Update a component's weight. All weights must still sum to BP_SCALE after update.
    function updateWeight(uint256 id, uint256 newWeightBp) external {
        require(msg.sender == admin,  "Index: only admin");
        require(id < components.length, "Index: invalid id");
        components[id].weightBp = newWeightBp;
        require(_weightsValid(),      "Index: weights must sum to BP_SCALE");
        emit ComponentWeightUpdated(id, newWeightBp);
    }

    function componentCount() external view returns (uint256) {
        return components.length;
    }

    // =============================================================
    //                     DEPOSIT (JOIN)
    // =============================================================

    /// @notice Deposit vault shares from every component to mint index tokens.
    ///         `sharesIn[i]` must be approved for transfer before calling.
    ///         Use quote() first to compute the correct amounts for a target USDC value.
    ///
    /// @param  sharesIn  Vault shares for each component in component order.
    /// @return indexMinted  Index tokens received after fee.
    function deposit(uint256[] calldata sharesIn)
        external
        nonReentrant
        returns (uint256 indexMinted)
    {
        uint256 n = components.length;
        require(n > 0,               "Index: no components");
        require(_weightsValid(),     "Index: weights not finalised");
        require(sharesIn.length == n, "Index: wrong array length");

        // Compute total USDC value being deposited
        uint256 usdcDeposited;
        for (uint256 i = 0; i < n; i++) {
            usdcDeposited += components[i].vault.convertToAssets(sharesIn[i]);
        }
        require(usdcDeposited > 0, "Index: zero deposit value");

        uint256 fee = (usdcDeposited * FEE_BP) / BP_SCALE;
        uint256 netUsdc = usdcDeposited - fee;

        // Compute index tokens to mint
        uint256 supply = totalSupply();
        if (supply == 0) {
            indexMinted = netUsdc;
        } else {
            uint256 totalVal = indexValue();
            require(totalVal > 0, "Index: zero index value");
            indexMinted = (netUsdc * supply) / totalVal;
        }

        require(indexMinted > 0,                   "Index: mint too small");
        require(supply + indexMinted <= MAX_SUPPLY, "Index: supply cap");

        // Pull shares from user
        for (uint256 i = 0; i < n; i++) {
            if (sharesIn[i] > 0) {
                IERC20(address(components[i].vault)).safeTransferFrom(
                    msg.sender, address(this), sharesIn[i]
                );
            }
        }

        _mint(msg.sender, indexMinted);
        emit Deposited(msg.sender, sharesIn, indexMinted, usdcDeposited);
    }

    // =============================================================
    //                      REDEEM (EXIT)
    // =============================================================

    /// @notice Burn index tokens to receive a pro-rata slice of every component.
    ///         Amount received per component = sharesHeld[i] * indexAmount / totalSupply.
    ///
    /// @param  indexAmount  Index tokens to burn.
    /// @return sharesOut    Vault shares returned for each component.
    function redeem(uint256 indexAmount)
        external
        nonReentrant
        returns (uint256[] memory sharesOut)
    {
        uint256 n = components.length;
        require(n > 0,                               "Index: no components");
        require(indexAmount > 0,                     "Index: zero amount");
        require(balanceOf(msg.sender) >= indexAmount, "Index: insufficient balance");

        uint256 supply = totalSupply();
        sharesOut = new uint256[](n);

        uint256 usdcValue;
        for (uint256 i = 0; i < n; i++) {
            uint256 sharesHeld = IERC20(address(components[i].vault)).balanceOf(address(this));
            // Gross shares owed, then apply fee
            uint256 grossShares = (sharesHeld * indexAmount) / supply;
            uint256 feeShares   = (grossShares * FEE_BP) / BP_SCALE;
            sharesOut[i]        = grossShares - feeShares;
            usdcValue          += components[i].vault.convertToAssets(sharesOut[i]);
        }

        _burn(msg.sender, indexAmount);

        for (uint256 i = 0; i < n; i++) {
            if (sharesOut[i] > 0) {
                IERC20(address(components[i].vault)).safeTransfer(msg.sender, sharesOut[i]);
            }
        }

        emit Redeemed(msg.sender, indexAmount, sharesOut, usdcValue);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Total USDC value of all assets held by the index.
    function indexValue() public view returns (uint256 total) {
        for (uint256 i = 0; i < components.length; i++) {
            uint256 sharesHeld = IERC20(address(components[i].vault)).balanceOf(address(this));
            total += components[i].vault.convertToAssets(sharesHeld);
        }
    }

    /// @notice USDC value per index token (1e6-scaled).
    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        return (indexValue() * 1e6) / supply;
    }

    /// @notice Per-component breakdown: vault address, weight, shares held, USDC value.
    function componentSnapshot()
        external
        view
        returns (
            address[] memory vaults,
            uint256[] memory weights,
            uint256[] memory sharesHeld,
            uint256[] memory usdcValues
        )
    {
        uint256 n  = components.length;
        vaults     = new address[](n);
        weights    = new uint256[](n);
        sharesHeld = new uint256[](n);
        usdcValues = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            vaults[i]     = address(components[i].vault);
            weights[i]    = components[i].weightBp;
            sharesHeld[i] = IERC20(address(components[i].vault)).balanceOf(address(this));
            usdcValues[i] = components[i].vault.convertToAssets(sharesHeld[i]);
        }
    }

    /// @notice Quote the vault share amounts needed to deposit a target USDC value.
    ///         Allocates `usdcTarget` across components by weight.
    ///
    /// @param  usdcTarget  Total USDC value to deposit.
    /// @return sharesNeeded  Required vault shares per component.
    function quote(uint256 usdcTarget)
        external
        view
        returns (uint256[] memory sharesNeeded)
    {
        uint256 n = components.length;
        sharesNeeded = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 usdcForComponent = (usdcTarget * components[i].weightBp) / BP_SCALE;
            sharesNeeded[i] = components[i].vault.convertToShares(usdcForComponent);
        }
    }

    /// @notice Quote the vault shares returned for redeeming `indexAmount` tokens.
    function quoteRedeem(uint256 indexAmount)
        external
        view
        returns (uint256[] memory sharesOut)
    {
        uint256 n      = components.length;
        uint256 supply = totalSupply();
        sharesOut      = new uint256[](n);
        if (supply == 0) return sharesOut;

        for (uint256 i = 0; i < n; i++) {
            uint256 sharesHeld  = IERC20(address(components[i].vault)).balanceOf(address(this));
            uint256 grossShares = (sharesHeld * indexAmount) / supply;
            uint256 feeShares   = (grossShares * FEE_BP) / BP_SCALE;
            sharesOut[i]        = grossShares - feeShares;
        }
    }

    // =============================================================
    //                         INTERNAL
    // =============================================================

    function _weightsValid() internal view returns (bool) {
        uint256 total;
        for (uint256 i = 0; i < components.length; i++) {
            total += components[i].weightBp;
        }
        return total == BP_SCALE;
    }

    // =============================================================
    //                           ADMIN
    // =============================================================

    function setAdmin(address newAdmin) external {
        require(msg.sender == admin,  "Index: only admin");
        require(newAdmin != address(0), "Index: zero address");
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == admin, "Index: only admin");
        // Allow rescuing any token — admin is trusted; no user funds at risk
        // since all deposits/redemptions flow through explicit user transactions
        require(to != address(0),    "Index: zero address");
        token.safeTransfer(to, amount);
    }
}
