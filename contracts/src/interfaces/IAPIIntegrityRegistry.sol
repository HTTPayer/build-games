// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAPIIntegrityRegistry {
    function minimumStakeRequired() external view returns (uint256);

    function endpoints(bytes32)
        external
        view
        returns (
            bytes32 endpointId,
            address provider,
            string memory path,
            string memory method,
            bytes32 integrityHash,
            uint256 version,
            bool active,
            uint256 registeredAt,
            uint256 lastCheckedAt
        );

    function registerProvider(
        address owner,
        string calldata metadataURI,
        address payoutAddress,
        address revenueSplitter
    ) external;

    function recordCheck(bytes32 endpointId) external;
}
