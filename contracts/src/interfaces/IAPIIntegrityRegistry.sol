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

    function providers(uint256)
        external
        view
        returns (
            address owner,
            string memory metadataURI,
            address payoutAddress,
            address revenueSplitter,
            bool active,
            uint256 createdAt
        );

    function endpointToProviderId(bytes32 endpointId) external view returns (uint256);

    function providerEndpoints(address provider, uint256 index) external view returns (bytes32);

    function registerProvider(
        address owner,
        string calldata metadataURI,
        address payoutAddress,
        address revenueSplitter
    ) external;

    function registerEndpoint(
        uint256 providerId,
        string calldata path,
        string calldata method,
        address payTo,
        address asset,
        string calldata network,
        string calldata url,
        uint256 amount
    ) external;

    function updateEndpoint(
        bytes32 endpointId,
        address payTo,
        address asset,
        string calldata network,
        string calldata url,
        uint256 amount
    ) external;

    function recordCheck(bytes32 endpointId) external;
}
