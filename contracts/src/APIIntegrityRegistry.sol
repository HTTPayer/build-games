// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IStakeManager.sol";

contract APIIntegrityRegistry is AccessControl, Pausable, ReentrancyGuard {

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CHECKER_ROLE = keccak256("CHECKER_ROLE");

    struct Provider {
        address owner;
        string metadataURI;
        address payoutAddress;
        address revenueSplitter;
        bool active;
        uint256 createdAt;
    }

    struct Endpoint {
        bytes32 endpointId;
        address provider;
        string path;            // Full URL (e.g., "https://api.example.com/v1/pricing")
        string method;          // HTTP method (e.g., "GET", "POST")
        bytes32 integrityHash;  // Expected hash of 402 payment metadata
        uint256 version;
        bool active;
        uint256 registeredAt;
        uint256 lastCheckedAt;
    }

    uint256 public providerCount;
    uint256 public endpointCount;
    uint256 public minimumStakeRequired;

    /// @notice Optional StakeManager — when set, registerProvider() requires the owner
    ///         to have at least minimumStakeRequired staked before they can register.
    ///         Set to address(0) to disable the check (e.g. during initial deployment
    ///         before StakeManager is deployed).
    IStakeManager public stakeManager;

    mapping(uint256 => Provider) public providers;
    mapping(bytes32 => Endpoint) public endpoints;
    mapping(address => bytes32[]) public providerEndpoints;

    event ProviderRegistered(uint256 indexed id, address indexed owner);
    event ProviderUpdated(uint256 indexed id, address indexed owner);
    event EndpointRegistered(bytes32 indexed endpointId, address indexed provider);
    event EndpointHashUpdated(bytes32 indexed endpointId, bytes32 newIntegrityHash, uint256 version);
    event EndpointChecked(bytes32 indexed endpointId, uint256 timestamp);
    event MinimumStakeUpdated(uint256 newAmount);
    event StakeManagerUpdated(address stakeManager);

    constructor(address admin, uint256 _minimumStakeRequired) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        minimumStakeRequired = _minimumStakeRequired;
    }

    function setMinimumStakeRequired(uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        minimumStakeRequired = amount;
        emit MinimumStakeUpdated(amount);
    }

    /// @notice Set or update the StakeManager. Use address(0) to disable stake gating.
    function setStakeManager(address _stakeManager)
        external
        onlyRole(ADMIN_ROLE)
    {
        stakeManager = IStakeManager(_stakeManager);
        emit StakeManagerUpdated(_stakeManager);
    }

    function registerProvider(
        address owner,
        string calldata metadataURI,
        address payoutAddress,
        address revenueSplitter
    ) external whenNotPaused nonReentrant {

        require(owner         != address(0), "zero owner");
        require(payoutAddress != address(0), "zero payout");

        // If a StakeManager is configured, enforce the minimum stake on the owner.
        // Called via the factory: owner = the deploying provider (msg.sender there).
        // Called directly:       owner should be msg.sender (self-registration).
        if (address(stakeManager) != address(0) && minimumStakeRequired > 0) {
            (uint256 staked, ) = stakeManager.stakes(owner);
            require(staked >= minimumStakeRequired, "insufficient stake");
        }

        providerCount++;

        providers[providerCount] = Provider({
            owner: owner,
            metadataURI: metadataURI,
            payoutAddress: payoutAddress,
            revenueSplitter: revenueSplitter,
            active: true,
            createdAt: block.timestamp
        });

        emit ProviderRegistered(providerCount, owner);
    }

    function updateProvider(
        uint256 id,
        string calldata metadataURI,
        address payoutAddress,
        address revenueSplitter
    ) external whenNotPaused {
        Provider storage p = providers[id];
        require(p.owner == msg.sender, "not owner");
        require(p.active,              "inactive");
        require(payoutAddress != address(0), "zero payout");

        p.metadataURI     = metadataURI;
        p.payoutAddress   = payoutAddress;
        p.revenueSplitter = revenueSplitter;

        emit ProviderUpdated(id, msg.sender);
    }

    function registerEndpoint(
        uint256 providerId,
        string calldata path,
        string calldata method,
        bytes32 integrityHash
    ) external whenNotPaused nonReentrant {

        Provider storage p = providers[providerId];
        require(p.owner == msg.sender, "not owner");
        require(p.active, "inactive");

        bytes32 endpointId = keccak256(
            abi.encodePacked(providerId, path, method)
        );
        require(endpoints[endpointId].registeredAt == 0, "already registered");

        endpointCount++;

        endpoints[endpointId] = Endpoint({
            endpointId: endpointId,
            provider: msg.sender,
            path: path,
            method: method,
            integrityHash: integrityHash,
            version: 1,
            active: true,
            registeredAt: block.timestamp,
            lastCheckedAt: block.timestamp
        });

        providerEndpoints[msg.sender].push(endpointId);

        emit EndpointRegistered(endpointId, msg.sender);
    }

    function updateEndpoint(
        bytes32 endpointId,
        bytes32 newIntegrityHash
    ) external whenNotPaused {
        Endpoint storage e = endpoints[endpointId];
        require(e.registeredAt != 0, "not registered");
        require(e.active,             "inactive");
        require(e.provider == msg.sender, "not owner");

        e.integrityHash = newIntegrityHash;
        e.version++;

        emit EndpointHashUpdated(endpointId, newIntegrityHash, e.version);
    }

    function recordCheck(bytes32 endpointId)
        external
        onlyRole(CHECKER_ROLE)
    {
        Endpoint storage e = endpoints[endpointId];
        e.lastCheckedAt = block.timestamp;
        emit EndpointChecked(endpointId, block.timestamp);
    }
}