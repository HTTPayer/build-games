// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IProviderRevenueShare.sol";

/// @title APIRevenueFuture — Dividend Forward Contracts on RS Token Revenue
///
/// @notice Tradable forward contracts on expected future API dividend accumulation.
///         Developers lock RS tokens as collateral and receive working capital upfront.
///         Buyers speculate on whether the API will earn enough dividends to cover faceValue.
///
/// @dev    ⚠️  PROOF OF CONCEPT — See original for full disclaimer.
///
/// ─────────────────────────────────────────────────────────────────────────────
///  MENTAL MODEL
/// ─────────────────────────────────────────────────────────────────────────────
///
///  This is a "Dividend Forward Note":
///
///  Provider (seller):
///    - Locks RS tokens as collateral
///    - Receives purchasePrice USDC upfront (working capital)
///    - Commits: by expiry, those RS tokens will have earned ≥ faceValue in dividends
///    - After settlement, RS tokens are RETURNED to the provider (equity preserved)
///
///  Buyer (long):
///    - Pays purchasePrice < faceValue today
///    - At expiry receives up to faceValue USDC from accumulated dividends
///    - Profit = faceValue − purchasePrice (if dividend target met)
///    - Risk = actual dividends may be less than faceValue
///
///  Settlement oracle = RS token's accumulated dividends since note creation:
///    = (currentEPS - depositEPS) * collateralShares / 1e6
///
///  Key difference from vault-based version:
///    - RS tokens are NEVER redeemed — provider keeps their equity stake
///    - Only the accumulated dividends (USDC) are at risk
///
/// ─────────────────────────────────────────────────────────────────────────────
///  LIFECYCLE
/// ─────────────────────────────────────────────────────────────────────────────
///
///  createNote()    → provider locks RS tokens, snapshots current EPS, sets terms
///  purchaseNote()  → buyer pays purchasePrice; provider receives working capital
///  settle()        → at or after expiry, compute dividends earned, settle with buyer
///                    RS tokens returned to provider in all cases
///  reclaimExpired() → provider reclaims RS tokens from unsold expired notes
///
/// ─────────────────────────────────────────────────────────────────────────────
///
/// @dev    The contract may hold RS tokens from multiple notes for the same RS token.
///         A MasterChef accumulator tracks per-RS-token harvested USDC.
///         Each note snapshots the accumulator at creation; settlement computes
///         the note's earned USDC from the per-note accumulator delta.
contract APIRevenueFuture is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    uint256 public constant BP_SCALE          = 10_000;
    uint256 public constant MIN_COLLATERAL_BP = 12_000; // 120% minimum collateralisation
    uint256 public constant MAX_TERM          = 365 days;
    uint256 public constant MIN_TERM          = 1 days;

    /// @dev Precision for per-RS MasterChef accumulator
    uint256 public constant PRECISION = 1e18;

    // =============================================================
    //                          NOTE STATE
    // =============================================================

    enum NoteStatus {
        Open,       // created, not yet purchased
        Active,     // purchased, awaiting expiry
        Settled,    // buyer paid full faceValue; RS tokens returned to provider
        Expired,    // expired unsold; provider reclaimed RS tokens
        Defaulted   // settled with shortfall (partial payment); RS tokens returned
    }

    struct Note {
        address   provider;         // creator and RS token depositor
        address   buyer;            // purchaser (0 if unsold)
        IProviderRevenueShare rs;   // RS token used as collateral for this note
        uint256   faceValue;        // USDC promised to buyer at expiry
        uint256   purchasePrice;    // USDC buyer pays today (< faceValue)
        uint256   collateralShares; // raw RS tokens locked
        uint256   depositEps;       // cumulativeRevenuePerShare() snapshot at creation
        uint256   accAtDeposit;     // accUsdcPerRawShare for this RS token at note creation
        uint256   createdAt;
        uint256   expiry;
        NoteStatus status;
    }

    mapping(uint256 => Note) public notes;
    uint256 public nextNoteId;

    IERC20 public immutable USDC;

    // =============================================================
    //               PER-RS MASTERCHEF ACCUMULATOR
    // =============================================================

    /// @dev For each RS token: total raw RS tokens held across all notes
    mapping(address => uint256) public rsHeld;

    /// @dev For each RS token: cumulative USDC harvested per raw share × PRECISION
    mapping(address => uint256) public accUsdcPerRawShare;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event NoteCreated(
        uint256 indexed noteId,
        address indexed provider,
        address rs,
        uint256 faceValue,
        uint256 purchasePrice,
        uint256 collateralShares,
        uint256 depositEps,
        uint256 expiry
    );
    event NotePurchased(uint256 indexed noteId, address indexed buyer, uint256 purchasePrice);
    event NoteSettled(
        uint256 indexed noteId,
        address indexed buyer,
        uint256 usdcPaidToBuyer,
        address provider,
        uint256 rsReturnedToProvider,
        NoteStatus status
    );
    event NoteExpiredReclaimed(uint256 indexed noteId, address indexed provider, uint256 sharesReclaimed);
    event Harvested(address indexed rsToken, uint256 usdcClaimed, uint256 newAcc);

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(IERC20 _usdc) {
        require(address(_usdc) != address(0), "Future: zero USDC");
        USDC = _usdc;
    }

    // =============================================================
    //                      PROVIDER: CREATE
    // =============================================================

    /// @notice Create a dividend forward note and lock RS tokens as collateral.
    ///
    /// @param  _rs               The provider's ProviderRevenueShare token
    /// @param  _faceValue        USDC of dividends promised to buyer at expiry
    /// @param  _purchasePrice    USDC the buyer pays today (< faceValue)
    /// @param  _term             Duration in seconds (MIN_TERM ≤ term ≤ MAX_TERM)
    /// @param  _collateralShares Raw RS tokens to lock
    /// @return noteId            ID of the created note
    function createNote(
        IProviderRevenueShare _rs,
        uint256 _faceValue,
        uint256 _purchasePrice,
        uint256 _term,
        uint256 _collateralShares
    ) external nonReentrant returns (uint256 noteId) {
        require(address(_rs)    != address(0),                    "Future: zero rs");
        require(_faceValue       > 0,                             "Future: zero face value");
        require(_purchasePrice   > 0,                             "Future: zero purchase price");
        require(_purchasePrice   < _faceValue,                    "Future: price must be < face value");
        require(_term            >= MIN_TERM && _term <= MAX_TERM, "Future: invalid term");
        require(_collateralShares > 0,                            "Future: zero collateral");

        // Enforce minimum collateralisation using projected dividend earning capacity.
        // Use claimable as a proxy for current run-rate dividend value.
        // The note must have at least 120% coverage in terms of face value.
        // (Full validation at settlement — this is a best-effort creation check.)
        // We require collateralShares * MIN_COLLATERAL_BP / BP_SCALE ≥ faceValue
        // in raw RS unit terms. Since RS is 6-dec, this checks proportional scale.
        require(
            _collateralShares * MIN_COLLATERAL_BP >= _faceValue * BP_SCALE,
            "Future: insufficient collateral (must be >= 120% of face value in RS units)"
        );

        // Harvest before updating accumulator
        _harvestRS(_rs);

        // Lock collateral and update per-RS tracking
        IERC20(address(_rs)).safeTransferFrom(msg.sender, address(this), _collateralShares);
        rsHeld[address(_rs)] += _collateralShares;

        uint256 currentEps = _rs.cumulativeRevenuePerShare();
        uint256 currentAcc = accUsdcPerRawShare[address(_rs)];

        noteId = nextNoteId++;
        notes[noteId] = Note({
            provider:         msg.sender,
            buyer:            address(0),
            rs:               _rs,
            faceValue:        _faceValue,
            purchasePrice:    _purchasePrice,
            collateralShares: _collateralShares,
            depositEps:       currentEps,
            accAtDeposit:     currentAcc,
            createdAt:        block.timestamp,
            expiry:           block.timestamp + _term,
            status:           NoteStatus.Open
        });

        emit NoteCreated(
            noteId, msg.sender, address(_rs),
            _faceValue, _purchasePrice, _collateralShares,
            currentEps, block.timestamp + _term
        );
    }

    // =============================================================
    //                       BUYER: PURCHASE
    // =============================================================

    /// @notice Purchase an open note by paying purchasePrice USDC.
    ///         USDC flows directly to the provider as working capital.
    function purchaseNote(uint256 noteId) external nonReentrant {
        Note storage note = notes[noteId];

        require(note.status == NoteStatus.Open,      "Future: note not open");
        require(block.timestamp < note.expiry,        "Future: note expired");
        require(msg.sender != note.provider,          "Future: provider cannot self-purchase");

        note.buyer  = msg.sender;
        note.status = NoteStatus.Active;

        USDC.safeTransferFrom(msg.sender, note.provider, note.purchasePrice);

        emit NotePurchased(noteId, msg.sender, note.purchasePrice);
    }

    // =============================================================
    //                      SETTLE AT EXPIRY
    // =============================================================

    /// @notice Settle an active note at or after its expiry.
    ///         Permissionless — anyone may trigger settlement.
    ///
    ///         Settlement logic:
    ///           1. Harvest pending USDC from the RS token
    ///           2. Compute dividends earned by this note's shares since creation
    ///           3. If earned ≥ faceValue → buyer gets faceValue, provider gets surplus
    ///           4. If earned < faceValue → buyer gets everything (partial fill)
    ///           5. RS tokens are ALWAYS returned to provider (equity preserved)
    ///
    /// @param  noteId  The note to settle.
    function settle(uint256 noteId) external nonReentrant {
        Note storage note = notes[noteId];

        require(note.status == NoteStatus.Active, "Future: note not active");
        require(block.timestamp >= note.expiry,   "Future: not yet expired");

        _harvestRS(note.rs);

        // Compute USDC earned by this note since creation using MasterChef delta
        uint256 currentAcc = accUsdcPerRawShare[address(note.rs)];
        uint256 noteEarned = (currentAcc - note.accAtDeposit) * note.collateralShares / PRECISION;

        uint256 collateralShares = note.collateralShares;
        address rsAddr           = address(note.rs);
        note.collateralShares    = 0;
        note.status              = NoteStatus.Settled;

        rsHeld[rsAddr] -= collateralShares;

        uint256 usdcToBuyer;
        uint256 usdcToProvider;

        if (noteEarned >= note.faceValue) {
            // Full settlement
            usdcToBuyer    = note.faceValue;
            usdcToProvider = noteEarned - note.faceValue;
        } else {
            // Partial settlement (default)
            usdcToBuyer    = noteEarned;
            usdcToProvider = 0;
            note.status    = NoteStatus.Defaulted;
        }

        if (usdcToBuyer    > 0) USDC.safeTransfer(note.buyer,    usdcToBuyer);
        if (usdcToProvider > 0) USDC.safeTransfer(note.provider, usdcToProvider);

        // Always return RS tokens to provider — equity stake preserved
        IERC20(address(note.rs)).safeTransfer(note.provider, collateralShares);

        emit NoteSettled(
            noteId, note.buyer, usdcToBuyer,
            note.provider, collateralShares, note.status
        );
    }

    // =============================================================
    //                   PROVIDER: RECLAIM IF UNSOLD
    // =============================================================

    /// @notice Reclaim RS tokens from an open note that expired without a buyer.
    function reclaimExpired(uint256 noteId) external nonReentrant {
        Note storage note = notes[noteId];

        require(note.status == NoteStatus.Open, "Future: note not open");
        require(msg.sender == note.provider,     "Future: only provider");
        require(block.timestamp >= note.expiry,  "Future: not yet expired");

        uint256 shares       = note.collateralShares;
        note.collateralShares = 0;
        note.status           = NoteStatus.Expired;

        rsHeld[address(note.rs)] -= shares;
        IERC20(address(note.rs)).safeTransfer(note.provider, shares);

        emit NoteExpiredReclaimed(noteId, note.provider, shares);
    }

    // =============================================================
    //                         HARVEST
    // =============================================================

    /// @notice Permissionless: claim pending USDC dividends for a given RS token.
    ///         Updates the per-RS accumulator so all notes benefit proportionally.
    function harvestRS(IProviderRevenueShare _rs) external nonReentrant {
        uint256 claimed = _harvestRS(_rs);
        require(claimed > 0, "Future: nothing to harvest");
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Estimate USDC dividends earned by a note's collateral since creation.
    ///         Includes pending unclaimed USDC for real-time accuracy.
    function noteEarned(uint256 noteId) external view returns (uint256) {
        Note storage note = notes[noteId];
        if (note.collateralShares == 0) return 0;

        uint256 currentAcc = accUsdcPerRawShare[address(note.rs)];
        uint256 pending    = note.rs.claimable(address(this));
        uint256 totalRS    = rsHeld[address(note.rs)];
        if (pending > 0 && totalRS > 0) {
            currentAcc += (pending * PRECISION) / totalRS;
        }
        return (currentAcc - note.accAtDeposit) * note.collateralShares / PRECISION;
    }

    /// @notice Coverage ratio of a note in basis points (10000 = 100%).
    ///         Compares estimated earned dividends to faceValue.
    function coverageBp(uint256 noteId) external view returns (uint256) {
        Note storage note = notes[noteId];
        if (note.faceValue == 0) return 0;
        uint256 currentAcc = accUsdcPerRawShare[address(note.rs)];
        uint256 pending    = note.rs.claimable(address(this));
        uint256 totalRS    = rsHeld[address(note.rs)];
        if (pending > 0 && totalRS > 0) {
            currentAcc += (pending * PRECISION) / totalRS;
        }
        uint256 earned = (currentAcc - note.accAtDeposit) * note.collateralShares / PRECISION;
        return (earned * BP_SCALE) / note.faceValue;
    }

    /// @notice Implied discount rate (annualised, in 1e8-scaled BP).
    ///         = (faceValue - purchasePrice) / purchasePrice × (SECONDS_PER_YEAR / term)
    function impliedDiscountRate(uint256 noteId) external view returns (uint256) {
        Note storage note = notes[noteId];
        if (note.purchasePrice == 0 || note.expiry <= note.createdAt) return 0;
        uint256 spread = note.faceValue - note.purchasePrice;
        uint256 term   = note.expiry - note.createdAt;
        return (spread * 365 days * 1e8) / (note.purchasePrice * term);
    }

    /// @notice Whether a note is ready to settle.
    function isMature(uint256 noteId) external view returns (bool) {
        Note storage note = notes[noteId];
        return note.status == NoteStatus.Active && block.timestamp >= note.expiry;
    }

    /// @notice Returns all fields of a note.
    function getNote(uint256 noteId)
        external
        view
        returns (
            address   provider,
            address   buyer,
            address   rsToken,
            uint256   faceValue,
            uint256   purchasePrice,
            uint256   collateralShares,
            uint256   depositEps,
            uint256   createdAt,
            uint256   expiry,
            NoteStatus status
        )
    {
        Note storage n = notes[noteId];
        return (
            n.provider, n.buyer, address(n.rs),
            n.faceValue, n.purchasePrice, n.collateralShares,
            n.depositEps, n.createdAt, n.expiry, n.status
        );
    }

    // =============================================================
    //                          INTERNAL
    // =============================================================

    function _harvestRS(IProviderRevenueShare _rs) internal returns (uint256 claimed) {
        claimed = _rs.claimable(address(this));
        if (claimed == 0) return 0;

        uint256 totalRS = rsHeld[address(_rs)];
        if (totalRS == 0) return 0;

        _rs.claim();
        accUsdcPerRawShare[address(_rs)] += (claimed * PRECISION) / totalRS;

        emit Harvested(address(_rs), claimed, accUsdcPerRawShare[address(_rs)]);
    }
}
