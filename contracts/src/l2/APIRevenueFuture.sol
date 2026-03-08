// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title APIRevenueFuture — API Revenue Forward Contracts (Proof of Concept)
///
/// @notice Tradable contracts on expected future API yield.
///         Developers lock in a guaranteed fixed income. Investors speculate on adoption.
///         Creates a permissionless price discovery market for API growth expectations.
///
/// @dev    ⚠️  PROOF OF CONCEPT — Not production-ready. Intended to demonstrate the
///             mechanics of futures/forwards on verifiable onchain revenue streams.
///             Requires further work: margin calls, partial fills, secondary trading,
///             oracle redundancy, and a formal liquidation mechanism.
///
/// ─────────────────────────────────────────────────────────────────────────────
///  MENTAL MODEL
/// ─────────────────────────────────────────────────────────────────────────────
///
///  This is a **Revenue Forward Note**, not a traditional futures contract:
///
///  Provider (seller):
///    - Posts vault shares as collateral (worth ≥ faceValue at inception)
///    - Receives `purchasePrice` USDC upfront (working capital)
///    - Commits to delivering `faceValue` USDC worth of API revenue by expiry
///    - Benefit: certainty of income regardless of actual adoption curve
///
///  Buyer (long):
///    - Pays `purchasePrice` < `faceValue` today
///    - At expiry receives up to `faceValue` USDC from collateral redemption
///    - Profit = faceValue − purchasePrice  (if revenue target is met)
///    - Risk = actual API revenue may fall short; collateral may not fully cover
///
///  Settlement oracle = vault.previewRedeem(collateralShares)
///    - The collateral vault shares accumulate value as API revenue flows in
///    - If share value ≥ faceValue at expiry → buyer receives full faceValue
///    - If share value < faceValue at expiry → buyer receives whatever the
///      collateral is worth (partial fill; provider bears shortfall risk)
///
///  Price discovery:
///    - purchasePrice is set by the provider at note creation
///    - The spread (faceValue − purchasePrice) / faceValue implies the
///      market's implied discount rate / growth expectation for that API
///    - Rising purchasePrice (secondary market) = market believes in growth
///
/// ─────────────────────────────────────────────────────────────────────────────
///  LIFECYCLE
/// ─────────────────────────────────────────────────────────────────────────────
///
///  createNote()   → provider locks collateral, sets terms
///  purchaseNote() → buyer pays purchasePrice, provider receives working capital
///  settle()       → at or after expiry, anyone triggers settlement
///                   buyer receives faceValue (or all collateral if short)
///                   remaining collateral returned to provider
///
/// ─────────────────────────────────────────────────────────────────────────────
contract APIRevenueFuture is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    uint256 public constant BP_SCALE           = 10_000;

    /// @notice Minimum collateralisation ratio at note creation (120%)
    uint256 public constant MIN_COLLATERAL_BP  = 12_000;

    /// @notice Maximum term length — 1 year
    uint256 public constant MAX_TERM           = 365 days;

    /// @notice Minimum term length — 1 day
    uint256 public constant MIN_TERM           = 1 days;

    // =============================================================
    //                         NOTE STATE
    // =============================================================

    enum NoteStatus {
        Open,       // created, not yet purchased
        Active,     // purchased, awaiting expiry
        Settled,    // buyer paid, collateral returned
        Expired,    // expired unpurchased; provider reclaimed collateral
        Defaulted   // settled with shortfall (partial payment to buyer)
    }

    struct Note {
        address   provider;          // creator and collateral poster
        address   buyer;             // address that purchased the note (0 if unsold)
        IERC4626  vault;             // revenue vault backing this note
        uint256   faceValue;         // USDC promised to buyer at expiry
        uint256   purchasePrice;     // USDC buyer pays today (< faceValue)
        uint256   collateralShares;  // vault shares locked as security
        uint256   createdAt;         // creation timestamp
        uint256   expiry;            // settlement deadline
        NoteStatus status;
    }

    mapping(uint256 => Note) public notes;
    uint256 public nextNoteId;

    IERC20 public immutable USDC;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event NoteCreated(
        uint256 indexed noteId,
        address indexed provider,
        address vault,
        uint256 faceValue,
        uint256 purchasePrice,
        uint256 collateralShares,
        uint256 expiry
    );
    event NotePurchased(uint256 indexed noteId, address indexed buyer, uint256 purchasePrice);
    event NoteSettled(
        uint256 indexed noteId,
        address indexed buyer,
        uint256 usdcPaid,
        uint256 collateralReturnedToProvider,
        NoteStatus status
    );
    event NoteExpiredReclaimed(uint256 indexed noteId, address indexed provider, uint256 sharesReclaimed);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(IERC20 _usdc) {
        require(address(_usdc) != address(0), "Future: zero USDC");
        USDC = _usdc;
    }

    // =============================================================
    //                       PROVIDER: CREATE
    // =============================================================

    /// @notice Create a revenue forward note and lock vault shares as collateral.
    ///
    /// @param  _vault            The provider's ProviderRevenueVault
    /// @param  _faceValue        USDC promised to buyer at expiry
    /// @param  _purchasePrice    USDC the buyer pays today (must be < faceValue)
    /// @param  _term             Duration in seconds (MIN_TERM ≤ term ≤ MAX_TERM)
    /// @param  _collateralShares Vault shares to lock; value must be ≥ faceValue * MIN_COLLATERAL_BP / BP_SCALE
    /// @return noteId            ID of the created note
    function createNote(
        IERC4626 _vault,
        uint256  _faceValue,
        uint256  _purchasePrice,
        uint256  _term,
        uint256  _collateralShares
    ) external nonReentrant returns (uint256 noteId) {
        require(address(_vault)  != address(0),                       "Future: zero vault");
        require(_faceValue        > 0,                                 "Future: zero face value");
        require(_purchasePrice    > 0,                                 "Future: zero purchase price");
        require(_purchasePrice    < _faceValue,                        "Future: price must be < face value");
        require(_term             >= MIN_TERM && _term <= MAX_TERM,    "Future: invalid term");
        require(_collateralShares > 0,                                 "Future: zero collateral");

        // Enforce minimum collateralisation at creation
        uint256 collateralUsdc = _vault.convertToAssets(_collateralShares);
        require(
            collateralUsdc * BP_SCALE >= _faceValue * MIN_COLLATERAL_BP,
            "Future: insufficient collateral (must be >= 120% of face value)"
        );

        // Lock collateral
        IERC20(address(_vault)).safeTransferFrom(msg.sender, address(this), _collateralShares);

        noteId = nextNoteId++;
        notes[noteId] = Note({
            provider:         msg.sender,
            buyer:            address(0),
            vault:            _vault,
            faceValue:        _faceValue,
            purchasePrice:    _purchasePrice,
            collateralShares: _collateralShares,
            createdAt:        block.timestamp,
            expiry:           block.timestamp + _term,
            status:           NoteStatus.Open
        });

        emit NoteCreated(
            noteId,
            msg.sender,
            address(_vault),
            _faceValue,
            _purchasePrice,
            _collateralShares,
            block.timestamp + _term
        );
    }

    // =============================================================
    //                        BUYER: PURCHASE
    // =============================================================

    /// @notice Purchase an open note by paying `purchasePrice` USDC.
    ///         USDC is transferred directly to the provider as working capital.
    ///         The buyer is now entitled to `faceValue` USDC at expiry.
    ///
    /// @param  noteId  The note to purchase.
    function purchaseNote(uint256 noteId) external nonReentrant {
        Note storage note = notes[noteId];

        require(note.status == NoteStatus.Open,      "Future: note not open");
        require(block.timestamp < note.expiry,        "Future: note expired");
        require(msg.sender != note.provider,          "Future: provider cannot self-purchase");

        note.buyer  = msg.sender;
        note.status = NoteStatus.Active;

        // Purchase price flows directly to the provider as working capital
        USDC.safeTransferFrom(msg.sender, note.provider, note.purchasePrice);

        emit NotePurchased(noteId, msg.sender, note.purchasePrice);
    }

    // =============================================================
    //                       SETTLE AT EXPIRY
    // =============================================================

    /// @notice Settle an active note at or after its expiry.
    ///         Callable by anyone — permissionless settlement.
    ///
    ///         Settlement logic:
    ///           1. Redeem all collateral shares → USDC
    ///           2. If USDC ≥ faceValue → buyer gets faceValue; provider gets surplus
    ///           3. If USDC < faceValue → buyer gets everything (shortfall absorbed by provider)
    ///
    ///         The collateral vault shares appreciate as API revenue flows in.
    ///         A provider who hits their revenue target will have enough collateral
    ///         value to cover faceValue. The spread is the provider's retained upside.
    ///
    /// @param  noteId  The note to settle.
    function settle(uint256 noteId) external nonReentrant {
        Note storage note = notes[noteId];

        require(note.status == NoteStatus.Active,    "Future: note not active");
        require(block.timestamp >= note.expiry,       "Future: not yet expired");

        uint256 collateralShares = note.collateralShares;
        note.collateralShares    = 0;
        note.status              = NoteStatus.Settled; // optimistic; may downgrade to Defaulted

        // Redeem all collateral vault shares → USDC into this contract
        uint256 usdcBefore  = USDC.balanceOf(address(this));
        note.vault.redeem(collateralShares, address(this), address(this));
        uint256 usdcRecovered = USDC.balanceOf(address(this)) - usdcBefore;

        uint256 usdcToBuyer;
        uint256 usdcToProvider;

        if (usdcRecovered >= note.faceValue) {
            // Full settlement: buyer gets faceValue, provider keeps the upside
            usdcToBuyer      = note.faceValue;
            usdcToProvider   = usdcRecovered - note.faceValue;
        } else {
            // Partial settlement (default): buyer receives all recovered USDC
            usdcToBuyer      = usdcRecovered;
            usdcToProvider   = 0;
            note.status      = NoteStatus.Defaulted;
        }

        if (usdcToBuyer    > 0) USDC.safeTransfer(note.buyer,    usdcToBuyer);
        if (usdcToProvider > 0) USDC.safeTransfer(note.provider, usdcToProvider);

        emit NoteSettled(noteId, note.buyer, usdcToBuyer, usdcToProvider, note.status);
    }

    // =============================================================
    //                  PROVIDER: RECLAIM IF UNSOLD
    // =============================================================

    /// @notice Reclaim collateral from an Open note that expired without a buyer.
    ///         Only the original provider may call this.
    function reclaimExpired(uint256 noteId) external nonReentrant {
        Note storage note = notes[noteId];

        require(note.status == NoteStatus.Open,      "Future: note not open");
        require(msg.sender == note.provider,          "Future: only provider");
        require(block.timestamp >= note.expiry,       "Future: not yet expired");

        uint256 shares        = note.collateralShares;
        note.collateralShares = 0;
        note.status           = NoteStatus.Expired;

        IERC20(address(note.vault)).safeTransfer(note.provider, shares);
        emit NoteExpiredReclaimed(noteId, note.provider, shares);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /// @notice Current USDC value of a note's locked collateral.
    ///         Compare against faceValue to gauge coverage ratio.
    function collateralValue(uint256 noteId) external view returns (uint256) {
        Note storage note = notes[noteId];
        if (note.collateralShares == 0) return 0;
        return note.vault.convertToAssets(note.collateralShares);
    }

    /// @notice Collateralisation ratio as basis points (10000 = 100%, 12000 = 120%).
    ///         Falls below 10000 when the vault share value drops under faceValue.
    function collateralisationBp(uint256 noteId) external view returns (uint256) {
        Note storage note = notes[noteId];
        if (note.faceValue == 0) return 0;
        uint256 colUsdc = note.vault.convertToAssets(note.collateralShares);
        return (colUsdc * BP_SCALE) / note.faceValue;
    }

    /// @notice Implied discount rate (annualised, in BP * 100).
    ///         = (faceValue - purchasePrice) / purchasePrice × (SECONDS_PER_YEAR / term)
    ///         Analogous to yield-to-maturity on a zero-coupon bond.
    function impliedDiscountRate(uint256 noteId) external view returns (uint256) {
        Note storage note = notes[noteId];
        if (note.purchasePrice == 0 || note.expiry <= note.createdAt) return 0;

        uint256 spread   = note.faceValue - note.purchasePrice;
        uint256 term     = note.expiry - note.createdAt;
        uint256 yearBp   = (spread * 365 days * 1e8) / (note.purchasePrice * term);
        return yearBp;
    }

    /// @notice Returns all fields of a note.
    function getNote(uint256 noteId)
        external
        view
        returns (
            address   provider,
            address   buyer,
            address   vault,
            uint256   faceValue,
            uint256   purchasePrice,
            uint256   collateralShares,
            uint256   createdAt,
            uint256   expiry,
            NoteStatus status
        )
    {
        Note storage n = notes[noteId];
        return (
            n.provider, n.buyer, address(n.vault),
            n.faceValue, n.purchasePrice, n.collateralShares,
            n.createdAt, n.expiry, n.status
        );
    }

    /// @notice Whether a note is ready to settle.
    function isMature(uint256 noteId) external view returns (bool) {
        Note storage note = notes[noteId];
        return note.status == NoteStatus.Active && block.timestamp >= note.expiry;
    }
}
