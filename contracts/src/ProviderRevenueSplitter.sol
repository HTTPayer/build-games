// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IProviderRevenueShare {
    /// @notice Credit any USDC already transferred to the contract since last distribution.
    function distribute() external;
}

/**
 * @title ProviderRevenueSplitter
 * @notice Routes x402 API payment revenue (USDC) across four recipients:
 *         protocol treasury, optional provider treasury, optional revenue share
 *         contract, and the revenue vault.
 *
 * @dev    Split configuration (all immutable after deployment):
 *
 *           protocolTreasuryBp   →  protocol treasury    (USDC, required)
 *           providerTreasuryBp   →  provider treasury    (USDC, optional)
 *           revenueShareBp       →  ProviderRevenueShare (dividends, optional)
 *           vaultBp              →  ProviderRevenueVault (computed remainder)
 *
 *         Constraint: protocolBp + providerBp + revenueShareBp < BP_SCALE
 *
 *         Revenue sent to the vault is a direct USDC transfer — NOT a vault.deposit().
 *         This increases the vault's totalAssets() without minting new shares, so
 *         existing share prices rise with each distribution.
 *
 *         Revenue sent to the revenue share contract is a direct USDC transfer followed
 *         by a call to IProviderRevenueShare.distribute(), which credits the accumulator.
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

    /// @notice Protocol treasury — receives protocolTreasuryBp of every distribution.
    address public immutable protocolTreasury;

    /// @notice Provider treasury — receives providerTreasuryBp of every distribution.
    ///         address(0) when providerTreasuryBp == 0.
    address public immutable providerTreasury;

    /// @notice ProviderRevenueShare — receives revenueShareBp as dividends.
    ///         address(0) when revenueShareBp == 0.
    IProviderRevenueShare public immutable revenueShare;

    /// @notice The ProviderRevenueVault — receives the computed vaultBp remainder.
    address public immutable vault;

    uint256 public immutable protocolTreasuryBp;
    uint256 public immutable providerTreasuryBp;
    uint256 public immutable revenueShareBp;

    /// @notice Vault's share of each distribution (remainder after all other cuts).
    function vaultBp() public view returns (uint256) {
        return BP_SCALE - protocolTreasuryBp - providerTreasuryBp - revenueShareBp;
    }

    // =============================================================
    //                           EVENTS
    // =============================================================

    event Distributed(
        uint256 totalAmount,
        uint256 protocolAmount,
        uint256 providerAmount,
        uint256 revenueShareAmount,
        uint256 vaultAmount
    );

    /// @notice Emitted when revenueShare.distribute() reverts after USDC has already
    ///         been transferred. The USDC is safe inside the revenueShare contract and
    ///         will be credited automatically on the next successful distribute() call
    ///         (balance-sniffing pattern picks up the accumulated amount).
    event RevenueShareDistributeFailed(uint256 amount);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /**
     * @param _usdc                 USDC token address.
     * @param _protocolTreasury     Protocol treasury address (required).
     * @param _protocolTreasuryBp   Protocol cut in basis points.
     * @param _providerTreasury     Provider treasury address. Use address(0) if bp == 0.
     * @param _providerTreasuryBp   Provider cut in basis points.
     * @param _revenueShare         ProviderRevenueShare address. Use address(0) if bp == 0.
     * @param _revenueShareBp       Revenue share cut in basis points.
     * @param _vault                ProviderRevenueVault address.
     */
    constructor(
        IERC20                _usdc,
        address               _protocolTreasury,
        uint256               _protocolTreasuryBp,
        address               _providerTreasury,
        uint256               _providerTreasuryBp,
        IProviderRevenueShare _revenueShare,
        uint256               _revenueShareBp,
        address               _vault
    ) {
        uint256 _totalBp = _protocolTreasuryBp + _providerTreasuryBp + _revenueShareBp;

        require(address(_usdc)    != address(0), "USDC zero");
        require(_protocolTreasury != address(0), "protocol treasury zero");
        require(_totalBp <= BP_SCALE,            "bp exceeds 100%");
        require(
            _vault != address(0) || _totalBp == BP_SCALE,
            "vault required unless all bp is accounted for"
        );
        require(
            address(_revenueShare) != address(0) || _vault != address(0),
            "at least one of vault or revenueShare must receive revenue"
        );
        require(
            _providerTreasuryBp == 0 || _providerTreasury != address(0),
            "provider treasury address required when bp > 0"
        );
        require(
            _revenueShareBp == 0 || address(_revenueShare) != address(0),
            "revenue share address required when bp > 0"
        );

        USDC               = _usdc;
        protocolTreasury   = _protocolTreasury;
        protocolTreasuryBp = _protocolTreasuryBp;
        providerTreasury   = _providerTreasury;
        providerTreasuryBp = _providerTreasuryBp;
        revenueShare       = _revenueShare;
        revenueShareBp     = _revenueShareBp;
        vault              = _vault;
    }

    // =============================================================
    //                        CORE LOGIC
    // =============================================================

    /**
     * @notice Distribute the contract's entire USDC balance across all recipients.
     *         Anyone may call. Vault portion is transferred directly (not deposited),
     *         causing existing vault shares to appreciate without new shares being minted.
     *         Revenue share portion is transferred then distribute() is called on the
     *         contract, crediting the per-share accumulator for dividend holders.
     */
    function distribute() external nonReentrant {
        uint256 balance = USDC.balanceOf(address(this));
        require(balance > 0, "no balance");

        uint256 protocolAmount     = (balance * protocolTreasuryBp) / BP_SCALE;
        uint256 providerAmount     = (balance * providerTreasuryBp) / BP_SCALE;
        uint256 revenueShareAmount = (balance * revenueShareBp)     / BP_SCALE;
        uint256 vaultAmount        = balance - protocolAmount - providerAmount - revenueShareAmount; // dust-safe

        if (protocolAmount > 0) {
            USDC.safeTransfer(protocolTreasury, protocolAmount);
        }

        if (providerAmount > 0) {
            USDC.safeTransfer(providerTreasury, providerAmount);
        }

        if (revenueShareAmount > 0) {
            // Transfer USDC first — funds are safe in the revenueShare contract
            // regardless of whether the distribute() notification succeeds.
            USDC.safeTransfer(address(revenueShare), revenueShareAmount);

            // Notify the accumulator. If this reverts (e.g. revenueShare is paused or
            // has a temporary issue), the USDC is not lost — the balance-sniffing
            // pattern in revenueShare.distribute() will pick up the accumulated amount
            // on the next successful call. We emit an event so it's detectable offchain.
            try revenueShare.distribute() {} catch {
                emit RevenueShareDistributeFailed(revenueShareAmount);
            }
        }

        if (vaultAmount > 0 && vault != address(0)) {
            // Direct transfer — increases vault.totalAssets() and share price
            // without minting new shares.
            USDC.safeTransfer(vault, vaultAmount);
        }

        emit Distributed(balance, protocolAmount, providerAmount, revenueShareAmount, vaultAmount);
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
            uint256 _revenueShareBp,
            address _vault,
            uint256 _vaultBp
        )
    {
        return (
            protocolTreasury,
            protocolTreasuryBp,
            providerTreasury,
            providerTreasuryBp,
            address(revenueShare),
            revenueShareBp,
            vault,
            vaultBp()
        );
    }
}
