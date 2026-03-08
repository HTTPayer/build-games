// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title MockUSDC
 * @notice Test/mock USDC token with 6 decimals.
 *         Mint and burn are restricted to MINTER_ROLE (granted to admin at deployment).
 *         Drop-in replacement for real USDC in local and Fuji testnet deployments.
 */
contract MockUSDC is ERC20, AccessControl {

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address admin) ERC20("USD Coin", "USDC") {
        require(admin != address(0), "zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    /// @notice Returns 6 to match real USDC decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint `amount` USDC to `to`. Caller must have MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn `amount` USDC from `from`. Caller must have MINTER_ROLE.
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }
}
