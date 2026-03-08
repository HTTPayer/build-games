// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAPIIntegrityRegistry.sol";

contract StakeManager is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    IERC20 public immutable USDC;
    IAPIIntegrityRegistry public immutable registry;
    address public treasury;

    uint256 public constant BP_SCALE = 10000;
    uint256 public withdrawCooldown = 7 days;
    uint256 public protocolSlashBp = 1000; // 10% of slash goes to treasury

    struct StakeInfo {
        uint256 amount;
        uint256 unlockTimestamp;
    }

    mapping(address => StakeInfo) public stakes;

    event Staked(address indexed provider, uint256 amount);
    event UnstakeRequested(address indexed provider, uint256 unlockTime);
    event Withdrawn(address indexed provider, uint256 amount);
    event Slashed(
        address indexed provider,
        uint256 slashAmount,
        uint256 challengerReward,
        uint256 protocolCut
    );

    constructor(
        address _usdc,
        address _registry,
        address _treasury,
        address admin
    ) {
        require(_usdc != address(0), "zero usdc");
        require(_registry != address(0), "zero registry");
        require(_treasury != address(0), "zero treasury");

        USDC = IERC20(_usdc);
        registry = IAPIIntegrityRegistry(_registry);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // =============================
    // STAKING
    // =============================

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        stakes[msg.sender].amount += amount;
        stakes[msg.sender].unlockTimestamp = 0;

        emit Staked(msg.sender, amount);
    }

    function requestUnstake(uint256 amount) external {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount >= amount, "insufficient");

        s.unlockTimestamp = block.timestamp + withdrawCooldown;

        emit UnstakeRequested(msg.sender, s.unlockTimestamp);
    }

    function withdraw(uint256 amount) external nonReentrant {
        StakeInfo storage s = stakes[msg.sender];

        require(block.timestamp >= s.unlockTimestamp, "cooldown");
        require(s.amount >= amount, "insufficient");

        s.amount -= amount;

        require(
            s.amount == 0 ||
            s.amount >= registry.minimumStakeRequired(),
            "below minimum"
        );

        USDC.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    // =============================
    // SLASHING
    // =============================

    function slash(
        address provider,
        uint256 slashBp,
        address challenger
    ) external nonReentrant onlyRole(SLASHER_ROLE)
    {
        require(slashBp > 0 && slashBp <= BP_SCALE, "invalid bp");

        StakeInfo storage s = stakes[provider];
        require(s.amount > 0, "no stake");

        uint256 slashAmount = (s.amount * slashBp) / BP_SCALE;

        if (slashAmount > s.amount) {
            slashAmount = s.amount;
        }

        s.amount -= slashAmount;

        uint256 protocolCut = (slashAmount * protocolSlashBp) / BP_SCALE;
        uint256 challengerReward = slashAmount - protocolCut;

        if (protocolCut > 0) {
            USDC.safeTransfer(treasury, protocolCut);
        }

        if (challengerReward > 0) {
            USDC.safeTransfer(challenger, challengerReward);
        }

        emit Slashed(provider, slashAmount, challengerReward, protocolCut);
    }

    // =============================
    // ADMIN
    // =============================

    function setTreasury(address _treasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        treasury = _treasury;
    }

    function setProtocolSlashBp(uint256 bp)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(bp <= BP_SCALE, "too high");
        protocolSlashBp = bp;
    }

    function setWithdrawCooldown(uint256 cooldown)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        withdrawCooldown = cooldown;
    }
}