// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IProviderRevenueShare.sol";

/**
 * @title ProviderRevenueSplitter
 * @notice Routes x402 API payment revenue (USDC) across three recipients:
 *         protocol treasury, provider treasury, and the ProviderRevenueShare
 *         dividend accumulator.
 *
 * @dev    Split configuration:
 *
 *           protocolTreasuryBp   →  protocol treasury    (USDC)
 *           providerTreasuryBp   →  provider treasury    (USDC)
 *           revenueShareBp       →  ProviderRevenueShare (dividends)
 *
 *         Constraint: protocolBp + providerBp + revenueShareBp == BP_SCALE (10_000).
 *         All basis points are immutable after deployment — a trust guarantee to RS holders
 *         that their dividend allocation can never be changed unilaterally.
 *
 *         Treasury addresses are mutable for operational reasons (wallet rotation, multisig
 *         upgrades) but carry no economic impact — they only redirect where USDC lands,
 *         not how much each recipient receives.
 *
 *         revenueShare is immutable — dividend rights cannot be redirected.
 *
 *         Revenue sent to the RS contract is a direct USDC transfer followed by a call to
 *         IProviderRevenueShare.distribute(), which credits the per-share accumulator.
 *         If distribute() reverts, USDC is safe in the RS contract and will be picked up
 *         on the next successful call (balance-sniffing pattern).
 *
 *         Anyone can call distribute() — permissionless, no funds can be stuck.
 *         The contract is stateless; every distribute() drains the full USDC balance.
 */
contract ProviderRevenueSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    uint256 public constant BP_SCALE = 10_000;

    // =============================================================
    //                         IMMUTABLES
    // =============================================================

    IERC20 public immutable USDC;

    /// @notice ProviderRevenueShare — receives revenueShareBp as dividends.
    ///         address(0) only when revenueShareBp == 0.
    ///         Immutable — dividend destination cannot be changed after deployment.
    IProviderRevenueShare public immutable revenueShare;

    /// @notice Who can update protocolTreasury (set once at deployment).
    address public immutable protocolAdmin;

    /// @notice Basis points allocated to each recipient (immutable).
    uint256 public immutable protocolTreasuryBp;
    uint256 public immutable providerTreasuryBp;
    uint256 public immutable revenueShareBp;

    // =============================================================
    //                           STATE
    // =============================================================

    /// @notice Protocol treasury — receives protocolTreasuryBp of every distribution.
    ///         Mutable by protocolAdmin (treasury rotations, multisig upgrades).
    address public protocolTreasury;

    /// @notice Provider treasury — receives providerTreasuryBp of every distribution.
    ///         Mutable by providerAdmin (wallet rotations, multisig upgrades).
    ///         address(0) when providerTreasuryBp == 0.
    address public providerTreasury;

    /// @notice Who can update providerTreasury and transfer providerAdmin rights.
    address public providerAdmin;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event Distributed(
        uint256 totalAmount,
        uint256 protocolAmount,
        uint256 providerAmount,
        uint256 revenueShareAmount
    );

    /// @notice Emitted when revenueShare.distribute() reverts after USDC has already
    ///         been transferred. The USDC is safe inside the RS contract and will be
    ///         credited on the next successful distribute() call.
    event RevenueShareDistributeFailed(uint256 amount);

    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProviderTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProviderAdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /**
     * @param _usdc                 USDC token address.
     * @param _protocolAdmin        Address allowed to update protocolTreasury.
     * @param _protocolTreasury     Initial protocol treasury address.
     * @param _protocolTreasuryBp   Protocol cut in basis points.
     * @param _providerAdmin        Address allowed to update providerTreasury and transfer admin.
     * @param _providerTreasury     Initial provider treasury address. Use address(0) if bp == 0.
     * @param _providerTreasuryBp   Provider cut in basis points.
     * @param _revenueShare         ProviderRevenueShare address. Use address(0) if bp == 0.
     * @param _revenueShareBp       Revenue share cut in basis points.
     *
     * @dev   Constraint: _protocolTreasuryBp + _providerTreasuryBp + _revenueShareBp == BP_SCALE.
     */
    constructor(
        IERC20                _usdc,
        address               _protocolAdmin,
        address               _protocolTreasury,
        uint256               _protocolTreasuryBp,
        address               _providerAdmin,
        address               _providerTreasury,
        uint256               _providerTreasuryBp,
        IProviderRevenueShare _revenueShare,
        uint256               _revenueShareBp
    ) {
        require(address(_usdc)     != address(0), "USDC zero");
        require(_protocolAdmin     != address(0), "protocol admin zero");
        require(_protocolTreasury  != address(0), "protocol treasury zero");
        require(_providerAdmin     != address(0), "provider admin zero");
        require(
            _protocolTreasuryBp + _providerTreasuryBp + _revenueShareBp == BP_SCALE,
            "bp must sum to 100%"
        );
        require(
            _providerTreasuryBp == 0 || _providerTreasury != address(0),
            "provider treasury required when bp > 0"
        );
        require(
            _revenueShareBp == 0 || address(_revenueShare) != address(0),
            "revenueShare required when bp > 0"
        );

        USDC               = _usdc;
        protocolAdmin      = _protocolAdmin;
        protocolTreasury   = _protocolTreasury;
        protocolTreasuryBp = _protocolTreasuryBp;
        providerAdmin      = _providerAdmin;
        providerTreasury   = _providerTreasury;
        providerTreasuryBp = _providerTreasuryBp;
        revenueShare       = _revenueShare;
        revenueShareBp     = _revenueShareBp;
    }

    // =============================================================
    //                        CORE LOGIC
    // =============================================================

    /**
     * @notice Distribute the contract's entire USDC balance across all recipients.
     *         Anyone may call. Revenue share portion is transferred then distribute()
     *         is called on the RS contract, crediting the per-share accumulator.
     */
    function distribute() external nonReentrant {
        uint256 balance = USDC.balanceOf(address(this));
        require(balance > 0, "no balance");

        uint256 protocolAmount     = (balance * protocolTreasuryBp) / BP_SCALE;
        uint256 providerAmount     = (balance * providerTreasuryBp) / BP_SCALE;
        uint256 revenueShareAmount = balance - protocolAmount - providerAmount; // dust-safe

        if (protocolAmount > 0) {
            USDC.safeTransfer(protocolTreasury, protocolAmount);
        }

        if (providerAmount > 0) {
            USDC.safeTransfer(providerTreasury, providerAmount);
        }

        if (revenueShareAmount > 0) {
            // Transfer USDC first — funds are safe in the RS contract regardless of
            // whether the distribute() notification succeeds.
            USDC.safeTransfer(address(revenueShare), revenueShareAmount);

            // Notify the accumulator. If this reverts, USDC is not lost — the
            // balance-sniffing pattern in revenueShare.distribute() picks up the
            // accumulated amount on the next successful call.
            try revenueShare.distribute() {} catch {
                emit RevenueShareDistributeFailed(revenueShareAmount);
            }
        }

        emit Distributed(balance, protocolAmount, providerAmount, revenueShareAmount);
    }

    // =============================================================
    //                     TREASURY MANAGEMENT
    // =============================================================

    /// @notice Update the protocol treasury address. Only callable by protocolAdmin.
    function setProtocolTreasury(address newTreasury) external {
        require(msg.sender == protocolAdmin,  "not protocol admin");
        require(newTreasury != address(0),    "zero address");
        emit ProtocolTreasuryUpdated(protocolTreasury, newTreasury);
        protocolTreasury = newTreasury;
    }

    /// @notice Update the provider treasury address. Only callable by providerAdmin.
    function setProviderTreasury(address newTreasury) external {
        require(msg.sender == providerAdmin,  "not provider admin");
        require(newTreasury != address(0) || providerTreasuryBp == 0, "zero address");
        emit ProviderTreasuryUpdated(providerTreasury, newTreasury);
        providerTreasury = newTreasury;
    }

    /// @notice Transfer providerAdmin rights to a new address. Only callable by current providerAdmin.
    function transferProviderAdmin(address newAdmin) external {
        require(msg.sender == providerAdmin, "not provider admin");
        require(newAdmin != address(0),      "zero address");
        emit ProviderAdminTransferred(providerAdmin, newAdmin);
        providerAdmin = newAdmin;
    }

    // =============================================================
    //                       VIEW HELPERS
    // =============================================================

    /// @notice USDC balance pending distribution.
    function pendingDistribution() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Full split config in a single call — useful for frontend display.
    function splitConfig()
        external
        view
        returns (
            address _protocolTreasury,
            uint256 _protocolTreasuryBp,
            address _providerTreasury,
            uint256 _providerTreasuryBp,
            address _revenueShare,
            uint256 _revenueShareBp
        )
    {
        return (
            protocolTreasury,
            protocolTreasuryBp,
            providerTreasury,
            providerTreasuryBp,
            address(revenueShare),
            revenueShareBp
        );
    }
}
