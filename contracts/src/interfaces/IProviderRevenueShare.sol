// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IProviderRevenueShare
/// @notice Interface for the fixed-supply dividend accumulator RS token.
///         Revenue flows in via distribute(); holders claim USDC dividends
///         without burning their shares. Transfer hooks settle both parties
///         so buyers never claim revenue earned before they owned shares.
interface IProviderRevenueShare is IERC20 {
    /// @notice Accumulated but unclaimed USDC for `account`.
    function claimable(address account) external view returns (uint256);

    /// @notice Transfer all claimable USDC owed to msg.sender.
    /// @param to  Optional recipient. Defaults to msg.sender.
    function claim(address to) external;

    /// @notice Cumulative USDC earned per whole share since genesis.
    ///         Raw USDC units (1e6 = 1 USDC) per whole share (1e6 raw tokens).
    function cumulativeRevenuePerShare() external view returns (uint256);

    /// @notice Total USDC distributed into this contract over its lifetime.
    function totalDistributed() external view returns (uint256);

    /// @notice Total USDC claimed by all holders over the lifetime of the contract.
    function totalClaimed() external view returns (uint256);

    /// @notice USDC currently held in this contract (pending claims).
    function totalPending() external view returns (uint256);

    /// @notice Current 7-day and 30-day APRs (1e8-scaled basis points).
    function getCurrentAPRs() external view returns (uint256 apr7d, uint256 apr30d);

    /// @notice Whether the one-shot genesis mint has been completed.
    function genesisComplete() external view returns (bool);

    /// @notice Credit any unaccounted USDC balance as new revenue.
    ///         Called by ProviderRevenueSplitter after transferring USDC here.
    function distribute() external;
}
