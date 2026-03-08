// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IStakeManager.sol";
import "./interfaces/IAPIIntegrityRegistry.sol";

/// @notice Minimal IReceiver interface — the CRE forwarder calls onReport()
interface IReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

/// @title ChallengeManager
/// @notice Allows anyone to challenge a registered API endpoint's integrity.
///         Challenges are resolved off-chain by a Chainlink CRE workflow that
///         fetches the endpoint, verifies the x402 payment metadata hash, and
///         reports the result back via onReport().
///
/// Flow:
///   1. Challenger calls openChallenge(endpointId) — pays challengeFee in USDC.
///   2. ChallengeOpened event is emitted with full endpoint data (path, method,
///      integrityHash) so the CRE workflow needs no extra RPC calls.
///   3. CRE workflow fetches the endpoint, computes SHA-256 of the x402 metadata,
///      and calls onReport() through the forwarder with (challengeId, result).
///   4. If valid (hash matches): challenger was wrong — provider keeps stake,
///      receives the challenge fee.
///   5. If invalid (hash mismatch): provider is slashed, challenger gets fee back.
contract ChallengeManager is IReceiver, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IStakeManager public immutable stakeManager;
    IAPIIntegrityRegistry public immutable registry;

    /// @notice CRE forwarder — the only address allowed to call onReport().
    address public forwarder;

    // ── Challenge config ──────────────────────────────────────────────────────

    uint256 public challengeFee = 1e6;   // 1 USDC (set low for testing)
    uint256 public slashBp      = 2_000; // 20%

    // ── Challenge state ───────────────────────────────────────────────────────

    enum Status { Pending, Valid, Invalid }

    struct Challenge {
        address challenger;
        bytes32 endpointId;
        Status  status;
    }

    uint256 public challengeCount;
    mapping(uint256 => Challenge) public challenges;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a challenge is opened.
    ///         Non-indexed fields are included in log data so the CRE workflow
    ///         can decode everything without making extra RPC calls.
    event ChallengeOpened(
        uint256 indexed id,
        bytes32 indexed endpointId,
        string  path,
        string  method,
        bytes32 integrityHash
    );

    event ChallengeResolved(uint256 indexed id, Status result);
    event ForwarderUpdated(address forwarder);

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotForwarder(address caller);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address _usdc,
        address _stakeManager,
        address _registry,
        address _forwarder
    ) Ownable(msg.sender) {
        USDC         = IERC20(_usdc);
        stakeManager = IStakeManager(_stakeManager);
        registry     = IAPIIntegrityRegistry(_registry);
        forwarder    = _forwarder;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setForwarder(address _forwarder) external onlyOwner {
        forwarder = _forwarder;
        emit ForwarderUpdated(_forwarder);
    }

    function setChallengeFee(uint256 fee) external onlyOwner { challengeFee = fee; }
    function setSlashBp(uint256 bp)       external onlyOwner { slashBp = bp; }

    // ── Challenge ─────────────────────────────────────────────────────────────

    /// @notice Open a challenge for a registered endpoint.
    ///         Pays challengeFee in USDC. The CRE workflow picks up the
    ///         ChallengeOpened event and calls back via onReport().
    function openChallenge(bytes32 endpointId) external nonReentrant {
        (
            ,
            ,
            string memory path,
            string memory method,
            bytes32 integrityHash,
            ,
            bool active,
            ,
        ) = registry.endpoints(endpointId);

        require(active,                 "inactive");
        require(bytes(path).length > 0, "no path");

        USDC.safeTransferFrom(msg.sender, address(this), challengeFee);

        challengeCount++;
        challenges[challengeCount] = Challenge({
            challenger: msg.sender,
            endpointId: endpointId,
            status:     Status.Pending
        });

        // Emit full endpoint data so the CRE workflow needs no extra RPC calls
        emit ChallengeOpened(challengeCount, endpointId, path, method, integrityHash);
    }

    // ── CRE callback ──────────────────────────────────────────────────────────

    /// @notice Called by the CRE forwarder after the integrity workflow resolves.
    ///
    ///         Report payload (ABI-encoded by the workflow):
    ///           (uint256 challengeId, uint8 result)
    ///           result: 1 = hashes match (endpoint valid), 0 = mismatch (invalid)
    ///
    /// @param metadata  CRE metadata (workflow owner, name, DON ID) — not used here.
    /// @param report    ABI-encoded (challengeId, result).
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (msg.sender != forwarder) revert NotForwarder(msg.sender);

        (uint256 challengeId, uint8 result) = abi.decode(report, (uint256, uint8));

        Challenge storage c = challenges[challengeId];
        require(c.status == Status.Pending, "already resolved");

        bool valid = result == 1;

        (
            ,
            address provider,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = registry.endpoints(c.endpointId);

        if (valid) {
            // Hashes match — endpoint is honest. Challenger was wrong.
            c.status = Status.Valid;
            USDC.safeTransfer(provider, challengeFee);
        } else {
            // Hash mismatch — endpoint is lying. Slash provider.
            c.status = Status.Invalid;
            stakeManager.slash(provider, slashBp, c.challenger);
            USDC.safeTransfer(c.challenger, challengeFee);
        }

        registry.recordCheck(c.endpointId);
        emit ChallengeResolved(challengeId, c.status);
    }
}
