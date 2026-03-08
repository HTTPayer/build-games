// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./MockUSDC.sol";

/**
 * @title MockUSDCSwap
 * @notice 1:1 swap between real testnet USDC and MockUSDC.
 *
 *         Allows anyone holding real Fuji testnet USDC to swap into MockUSDC
 *         for use with protocol contracts deployed against MockUSDC, and swap
 *         back out at any time.
 *
 *         This contract must be granted MINTER_ROLE on MockUSDC after deployment.
 *
 *         swapIn:  real USDC in  → MockUSDC minted out  (1:1)
 *         swapOut: MockUSDC in   → real USDC out        (1:1, subject to reserve)
 */
contract MockUSDCSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for MockUSDC;

    IERC20    public immutable realUSDC;
    MockUSDC  public immutable mockUSDC;

    event SwappedIn(address indexed user, uint256 amount);
    event SwappedOut(address indexed user, uint256 amount);

    constructor(IERC20 _realUSDC, MockUSDC _mockUSDC) {
        require(address(_realUSDC) != address(0),  "zero realUSDC");
        require(address(_mockUSDC) != address(0),  "zero mockUSDC");
        realUSDC = _realUSDC;
        mockUSDC = _mockUSDC;
    }

    /**
     * @notice Deposit real testnet USDC, receive MockUSDC 1:1.
     * @param amount Amount of real USDC to swap in (6 decimals).
     */
    function swapIn(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        realUSDC.safeTransferFrom(msg.sender, address(this), amount);
        mockUSDC.mint(msg.sender, amount);
        emit SwappedIn(msg.sender, amount);
    }

    /**
     * @notice Deposit MockUSDC, receive real testnet USDC 1:1.
     * @param amount Amount of MockUSDC to swap out (6 decimals).
     */
    function swapOut(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        require(realUSDC.balanceOf(address(this)) >= amount, "insufficient reserve");
        mockUSDC.burn(msg.sender, amount);
        realUSDC.safeTransfer(msg.sender, amount);
        emit SwappedOut(msg.sender, amount);
    }

    /// @notice Real USDC held in reserve, available for swapOut.
    function reserve() external view returns (uint256) {
        return realUSDC.balanceOf(address(this));
    }
}
