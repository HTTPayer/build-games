// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IStakeManager {
    function slash(
        address provider,
        uint256 slashBp,
        address challenger
    ) external;

    /// @notice Returns the stake info for a provider.
    function stakes(address provider)
        external
        view
        returns (uint256 amount, uint256 unlockTimestamp);
}
