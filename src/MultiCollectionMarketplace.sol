// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/**
 * @title MultiCollectionMarketplace
 * @notice Fixed-price listings and English auctions for multiple ERC-721
 *         collections using a single marketplace contract.
 *
 * @dev
 * - Collections are registered on-chain by the DEFAULT_ADMIN_ROLE.
 * - Each collection receives a unique collectionId.
 * - Collection IDs are used to namespace all token/listing/auction state.
 * - Collection addresses are never removed; they can only be deactivated.
 * - Deactivating a collection prevents new listings/auctions but does not
 *   strand existing marketplace positions.
 * - USDC proceeds and refunds use pull payments.
 * - Protocol fees are snapshotted when a listing/auction is created.
 */
contract MultiCollectionMarketplace is AccessControl, ReentrancyGuard, ERC721Holder {
    // =============================================================
    //                           ROLES
    // =============================================================

    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    /// @dev Basis points denominator. 10,000 = 100%.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Protocol fee cannot exceed 20%.
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 2_000;

    // =============================================================
    //                           IMMUTABLES
    // =============================================================

    IERC20 public immutable USDC;

    // =============================================================
    //                          COLLECTIONS
    // =============================================================

    struct Collection {
        address token;
        bool active;
    }

    /// @dev Collection IDs start at 1. Zero is reserved as "invalid".
    uint256 public collectionCounter;

    mapping(uint256 collectionId => Collection) public collections;

    /// @dev True once an ERC-721 address has been registered.
    mapping(address token => bool) public isCollectionRegistered;

    /// @dev Returns the collection ID belonging to a registered address.
    mapping(address token => uint256) public collectionIdOf;

    // =============================================================
    //                           AUCTIONS
    // =============================================================

    enum AuctionState {
        None,
        Active,
        Settled,
        Cancelled
    }

    struct Auction {
        address seller;
        uint256 highestBid;
        address highestBidder;
        uint256 endTime;
        AuctionState state;
        uint16 feeBps;
    }

    uint256 public auctionCounter;

    mapping(uint256 auctionId => Auction) public auctions;

    /**
     * @dev collectionId => tokenId => active auction ID.
     */
    mapping(uint256 collectionId => mapping(uint256 tokenId => uint256)) public activeAuctionId;

    // =============================================================
    //                           LISTINGS
    // =============================================================

    enum ListingState {
        None,
        Active,
        Purchased,
        Cancelled
    }

    struct Listing {
        address seller;
        address buyer;
        uint256 price;
        ListingState state;
        uint16 feeBps;
    }

    uint256 public listingCounter;

    mapping(uint256 listingId => Listing) public listings;

    /**
     * @dev collectionId => tokenId => active listing ID.
     */
    mapping(uint256 collectionId => mapping(uint256 tokenId => uint256)) public activeListingId;

    // =============================================================
    //                         SALE STATUS
    // =============================================================

    /**
     * @dev A token is considered on sale if either a listing or auction
     *      is active.
     */
    mapping(uint256 collectionId => mapping(uint256 tokenId => bool)) public isTokenOnSale;

    // =============================================================
    //                       PAYMENT ACCOUNTING
    // =============================================================

    /// @dev USDC owed to users through pull payments.
    mapping(address account => uint256) public pendingWithdrawals;

    /// @dev Protocol fees accumulated but not yet withdrawn.
    uint256 public feeAccrued;

    // =============================================================
    //                         CONFIGURATION
    // =============================================================

    uint16 public protocolFeeBps = 1_000; // 10%

    uint256 public auctionMinBidAmount;

    uint16 public auctionMinBidIncrementBps = 1_000; // 10%

    uint256 public auctionMinDuration = 1 hours;

    uint256 public auctionMaxDuration = 30 days * 6; // 6 months

    uint256 public auctionDurationExtension = 20 minutes;

    uint256 public auctionDurationExtensionThreshold = 20 minutes;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event CollectionAdded(uint256 indexed collectionId, address indexed collection, bool active);

    event CollectionStatusChanged(uint256 indexed collectionId, address indexed collection, bool active);

    event AuctionStarted(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint256 indexed auctionId,
        address seller,
        uint256 duration
    );

    event BidPlaced(
        uint256 indexed collectionId, uint256 indexed tokenId, uint256 indexed auctionId, address bidder, uint256 amount
    );

    event AuctionCancelled(uint256 indexed collectionId, uint256 indexed tokenId, uint256 indexed auctionId);

    event AuctionSettled(uint256 indexed collectionId, uint256 indexed tokenId, uint256 indexed auctionId);

    event ListingCreated(
        uint256 indexed collectionId, uint256 indexed tokenId, uint256 indexed listingId, address seller, uint256 price
    );

    event ListingPurchased(
        uint256 indexed collectionId, uint256 indexed tokenId, uint256 indexed listingId, address buyer, uint256 price
    );

    event ListingCancelled(uint256 indexed collectionId, uint256 indexed tokenId, uint256 indexed listingId);

    event PaymentCredited(address indexed account, uint256 amount);

    event Withdrawal(address indexed account, address indexed receiver, uint256 amount);

    event ProtocolFeesCollected(uint256 amount, address indexed receiver);

    event ProtocolFeeUpdated(uint256 oldValue, uint256 newValue);

    event AuctionMinBidAmountUpdated(uint256 oldValue, uint256 newValue);

    event AuctionMinBidIncrementBpsUpdated(uint256 oldValue, uint256 newValue);

    event AuctionDurationExtensionThresholdUpdated(uint256 oldValue, uint256 newValue);

    event AuctionDurationExtensionUpdated(uint256 oldValue, uint256 newValue);

    event AuctionMinDurationUpdated(uint256 oldValue, uint256 newValue);

    event AuctionMaxDurationUpdated(uint256 oldValue, uint256 newValue);

    // =============================================================
    //                           ERRORS
    // =============================================================

    error ZeroAddress();

    error InvalidCollection();

    error CollectionAlreadyRegistered();

    error CollectionInactive();

    error CollectionNotRegistered();

    error TokenAlreadyOnSale();

    error TokenNotOnSale();

    error InvalidPrice();

    error InvalidDuration();

    error AuctionTooShort();

    error AuctionTooLong();

    error AuctionAlreadyEnded();

    error AuctionNotEnded();

    error AuctionNotActive();

    error BidTooLow();

    error Unauthorized();

    error NothingToWithdraw();

    error FeeTooHigh();

    error IncrementTooHigh();

    error DurationConfigurationInvalid();

    error TransferFailed();

    error UnsupportedCollection();

    error NoFeesToCollect();

    // =============================================================
    //                          MODIFIERS
    // =============================================================

    modifier onlyCollection(uint256 collectionId) {
        _requireCollection(collectionId);
        _;
    }

    modifier onlyActiveCollection(uint256 collectionId) {
        _requireActiveCollection(collectionId);
        _;
    }

    modifier onlyNotOnSale(uint256 collectionId, uint256 tokenId) {
        if (isTokenOnSale[collectionId][tokenId]) {
            revert TokenAlreadyOnSale();
        }
        _;
    }

    modifier onlyOnSale(uint256 collectionId, uint256 tokenId) {
        if (!isTokenOnSale[collectionId][tokenId]) {
            revert TokenNotOnSale();
        }
        _;
    }

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /**
     * @param usdc_ ERC-20 token used for all marketplace payments.
     * @param usdcDecimals_ Number of decimals used by USDC on the target chain.
     * @param admin_ Initial DEFAULT_ADMIN_ROLE holder.
     * @param initialCollection_ Optional initial ERC-721 collection.
     */
    constructor(address usdc_, uint256 usdcDecimals_, address admin_, address initialCollection_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        USDC = IERC20(usdc_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MODERATOR_ROLE, admin_);

        auctionMinBidAmount = 1 * 10 ** usdcDecimals_;

        if (initialCollection_ != address(0)) {
            _addCollection(initialCollection_);
        }
    }

    // =============================================================
    //                      COLLECTION MANAGEMENT
    // =============================================================

    /**
     * @notice Register a new ERC-721 collection.
     * @dev Collection IDs begin at 1.
     */
    function addCollection(address collection) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 collectionId) {
        collectionId = _addCollection(collection);
    }

    /**
     * @notice Enable or disable a registered collection.
     *
     * @dev
     * Disabling a collection only prevents new listings and auctions.
     * Existing listings and auctions can still be completed or cancelled.
     */
    function setCollectionActive(uint256 collectionId, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Collection storage collection = collections[collectionId];

        if (collection.token == address(0)) {
            revert CollectionNotRegistered();
        }

        collection.active = active;

        emit CollectionStatusChanged(collectionId, collection.token, active);
    }

    /**
     * @notice Returns collection information.
     */
    function getCollection(uint256 collectionId) external view returns (address token, bool active) {
        Collection memory collection = collections[collectionId];

        if (collection.token == address(0)) {
            revert CollectionNotRegistered();
        }

        return (collection.token, collection.active);
    }

    /**
     * @notice Returns whether an address is an active registered collection.
     */
    function isActiveCollection(address collection) external view returns (bool) {
        if (!isCollectionRegistered[collection]) {
            return false;
        }

        return collections[collectionIdOf[collection]].active;
    }

    function _addCollection(address collection) internal returns (uint256 collectionId) {
        if (collection == address(0)) {
            revert ZeroAddress();
        }

        if (isCollectionRegistered[collection]) {
            revert CollectionAlreadyRegistered();
        }

        // ERC-721 interface verification.
        try IERC165(collection).supportsInterface(type(IERC721).interfaceId) returns (bool supported) {
            if (!supported) {
                revert UnsupportedCollection();
            }
        } catch {
            revert UnsupportedCollection();
        }

        collectionId = ++collectionCounter;

        collections[collectionId] = Collection({token: collection, active: true});

        isCollectionRegistered[collection] = true;
        collectionIdOf[collection] = collectionId;

        emit CollectionAdded(collectionId, collection, true);
    }

    function _requireCollection(uint256 collectionId) internal view returns (Collection storage collection) {
        collection = collections[collectionId];

        if (collection.token == address(0)) {
            revert CollectionNotRegistered();
        }
    }

    function _requireActiveCollection(uint256 collectionId) internal view returns (Collection storage collection) {
        collection = _requireCollection(collectionId);

        if (!collection.active) {
            revert CollectionInactive();
        }
    }

    // =============================================================
    //                           AUCTIONS
    // =============================================================

    /**
     * @notice Create an English auction for an NFT.
     *
     * @dev The NFT is escrowed by this contract before the transaction ends.
     */
    function createAuction(uint256 collectionId, uint256 tokenId, uint256 duration)
        external
        onlyActiveCollection(collectionId)
        onlyNotOnSale(collectionId, tokenId)
        nonReentrant
    {
        if (duration < auctionMinDuration) {
            revert AuctionTooShort();
        }

        if (duration > auctionMaxDuration) {
            revert AuctionTooLong();
        }

        address seller = msg.sender;

        uint256 auctionId = ++auctionCounter;

        isTokenOnSale[collectionId][tokenId] = true;
        activeAuctionId[collectionId][tokenId] = auctionId;

        auctions[auctionId] = Auction({
            seller: seller,
            highestBid: 0,
            highestBidder: address(0),
            endTime: block.timestamp + duration,
            state: AuctionState.Active,
            feeBps: protocolFeeBps
        });

        _collectNft(collectionId, tokenId, seller);

        emit AuctionStarted(collectionId, tokenId, auctionId, seller, duration);
    }

    /**
     * @notice Place or increase a bid on an active auction.
     */
    function placeBid(uint256 collectionId, uint256 tokenId, uint256 amount)
        external
        onlyOnSale(collectionId, tokenId)
        nonReentrant
    {
        uint256 auctionId = activeAuctionId[collectionId][tokenId];

        Auction storage auction = auctions[auctionId];

        if (auction.state != AuctionState.Active) {
            revert AuctionNotActive();
        }

        uint256 expectedEndTime = auction.endTime;

        if (expectedEndTime <= block.timestamp) {
            revert AuctionAlreadyEnded();
        }

        uint256 minimumBid = auction.highestBid + _calculatePercentageOf(auction.highestBid, auctionMinBidIncrementBps);

        if (minimumBid < auctionMinBidAmount) {
            minimumBid = auctionMinBidAmount;
        }

        if (amount < minimumBid) {
            revert BidTooLow();
        }

        address bidder = msg.sender;

        address formerHighestBidder = auction.highestBidder;

        uint256 formerHighestBid = auction.highestBid;

        uint256 amountToCollect = amount;

        /*
         * If the current highest bidder raises their own bid,
         * only collect the difference.
         */
        if (formerHighestBidder == bidder) {
            amountToCollect = amount - formerHighestBid;
        } else {
            auction.highestBidder = bidder;
        }

        auction.highestBid = amount;

        uint256 timeRemaining = expectedEndTime - block.timestamp;

        if (timeRemaining < auctionDurationExtensionThreshold) {
            auction.endTime += auctionDurationExtension;
        }

        // Effects above, external interactions below.
        _collectPayment(amountToCollect, bidder);

        /*
         * Refund the previous highest bidder through pull payment.
         */
        if (formerHighestBidder != address(0) && formerHighestBidder != bidder && formerHighestBid > 0) {
            _creditPayment(formerHighestBidder, formerHighestBid);
        }

        emit BidPlaced(collectionId, tokenId, auctionId, bidder, amount);
    }

    /**
     * @notice Cancel an active auction.
     *
     * @dev
     * - Seller may cancel only before the first bid.
     * - Moderator may cancel an auction with bids.
     */
    function cancelAuction(uint256 collectionId, uint256 tokenId)
        external
        onlyOnSale(collectionId, tokenId)
        nonReentrant
    {
        uint256 auctionId = activeAuctionId[collectionId][tokenId];

        Auction storage auction = auctions[auctionId];

        if (auction.state != AuctionState.Active) {
            revert AuctionNotActive();
        }

        if (auction.endTime <= block.timestamp) {
            revert AuctionAlreadyEnded();
        }

        address caller = msg.sender;

        address highestBidder = auction.highestBidder;

        uint256 highestBid = auction.highestBid;

        address seller = auction.seller;

        if (highestBidder != address(0)) {
            if (!hasRole(MODERATOR_ROLE, caller)) {
                revert Unauthorized();
            }
        } else {
            if (caller != seller && !hasRole(MODERATOR_ROLE, caller)) {
                revert Unauthorized();
            }
        }

        auction.state = AuctionState.Cancelled;
        auction.endTime = block.timestamp;

        activeAuctionId[collectionId][tokenId] = 0;
        isTokenOnSale[collectionId][tokenId] = false;

        if (highestBidder != address(0) && highestBid > 0) {
            _creditPayment(highestBidder, highestBid);
        }

        _pushNft(collectionId, tokenId, seller);

        emit AuctionCancelled(collectionId, tokenId, auctionId);
    }

    /**
     * @notice Settle an auction after it has ended.
     *
     * @dev Anyone may settle.
     */
    function settleAuction(uint256 collectionId, uint256 tokenId)
        external
        onlyOnSale(collectionId, tokenId)
        nonReentrant
    {
        uint256 auctionId = activeAuctionId[collectionId][tokenId];

        Auction storage auction = auctions[auctionId];

        if (auction.state != AuctionState.Active) {
            revert AuctionNotActive();
        }

        if (auction.endTime >= block.timestamp) {
            revert AuctionNotEnded();
        }

        uint256 highestBid = auction.highestBid;

        address highestBidder = auction.highestBidder;

        address seller = auction.seller;

        uint16 feeBps = auction.feeBps;

        auction.state = AuctionState.Settled;

        activeAuctionId[collectionId][tokenId] = 0;
        isTokenOnSale[collectionId][tokenId] = false;

        if (highestBid > 0 && highestBidder != address(0)) {
            _pushNft(collectionId, tokenId, highestBidder);

            uint256 protocolFee = _calculatePercentageOf(highestBid, feeBps);

            uint256 sellerAmount = highestBid - protocolFee;

            feeAccrued += protocolFee;

            _creditPayment(seller, sellerAmount);
        } else {
            _pushNft(collectionId, tokenId, seller);
        }

        emit AuctionSettled(collectionId, tokenId, auctionId);
    }

    // =============================================================
    //                           LISTINGS
    // =============================================================

    /**
     * @notice Create a fixed-price listing.
     */
    function createListing(uint256 collectionId, uint256 tokenId, uint256 price)
        external
        onlyActiveCollection(collectionId)
        onlyNotOnSale(collectionId, tokenId)
        nonReentrant
    {
        if (price == 0) {
            revert InvalidPrice();
        }

        address seller = msg.sender;

        uint256 listingId = ++listingCounter;

        isTokenOnSale[collectionId][tokenId] = true;
        activeListingId[collectionId][tokenId] = listingId;

        listings[listingId] = Listing({
            seller: seller, buyer: address(0), price: price, state: ListingState.Active, feeBps: protocolFeeBps
        });

        _collectNft(collectionId, tokenId, seller);

        emit ListingCreated(collectionId, tokenId, listingId, seller, price);
    }

    /**
     * @notice Purchase an active fixed-price listing.
     */
    function purchaseItem(uint256 collectionId, uint256 tokenId)
        external
        onlyOnSale(collectionId, tokenId)
        nonReentrant
    {
        uint256 listingId = activeListingId[collectionId][tokenId];

        Listing storage listing = listings[listingId];

        if (listing.state != ListingState.Active) {
            revert TokenNotOnSale();
        }

        address buyer = msg.sender;

        uint256 price = listing.price;

        address seller = listing.seller;

        uint16 feeBps = listing.feeBps;

        listing.buyer = buyer;
        listing.state = ListingState.Purchased;

        activeListingId[collectionId][tokenId] = 0;
        isTokenOnSale[collectionId][tokenId] = false;

        uint256 protocolFee = _calculatePercentageOf(price, feeBps);

        uint256 sellerAmount = price - protocolFee;

        feeAccrued += protocolFee;

        _collectPayment(price, buyer);

        _pushNft(collectionId, tokenId, buyer);

        _creditPayment(seller, sellerAmount);

        emit ListingPurchased(collectionId, tokenId, listingId, buyer, price);
    }

    /**
     * @notice Cancel a fixed-price listing.
     */
    function cancelListing(uint256 collectionId, uint256 tokenId)
        external
        onlyOnSale(collectionId, tokenId)
        nonReentrant
    {
        uint256 listingId = activeListingId[collectionId][tokenId];

        Listing storage listing = listings[listingId];

        if (listing.state != ListingState.Active) {
            revert TokenNotOnSale();
        }

        address caller = msg.sender;

        if (caller != listing.seller && !hasRole(MODERATOR_ROLE, caller)) {
            revert Unauthorized();
        }

        address seller = listing.seller;

        listing.state = ListingState.Cancelled;

        activeListingId[collectionId][tokenId] = 0;
        isTokenOnSale[collectionId][tokenId] = false;

        _pushNft(collectionId, tokenId, seller);

        emit ListingCancelled(collectionId, tokenId, listingId);
    }

    // =============================================================
    //                         PAYMENTS
    // =============================================================

    function _collectPayment(uint256 amount, address payer) internal {
        if (!USDC.transferFrom(payer, address(this), amount)) {
            revert TransferFailed();
        }
    }

    /**
     * @dev Records USDC owed to an account.
     */
    function _creditPayment(address account, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        pendingWithdrawals[account] += amount;

        emit PaymentCredited(account, amount);
    }

    /**
     * @notice Withdraw USDC owed to msg.sender.
     *
     * @param receiver Address that receives the USDC.
     */
    function withdraw(address receiver) external nonReentrant {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        uint256 amount = pendingWithdrawals[msg.sender];

        if (amount == 0) {
            revert NothingToWithdraw();
        }

        pendingWithdrawals[msg.sender] = 0;

        if (!USDC.transfer(receiver, amount)) {
            /*
             * Restore accounting if the token transfer fails.
             * This makes the operation retryable.
             */
            pendingWithdrawals[msg.sender] = amount;

            revert TransferFailed();
        }

        emit Withdrawal(msg.sender, receiver, amount);
    }

    // =============================================================
    //                         NFT ESCROW
    // =============================================================

    function _collectNft(uint256 collectionId, uint256 tokenId, address owner) internal {
        address collection = collections[collectionId].token;

        IERC721(collection).safeTransferFrom(owner, address(this), tokenId);
    }

    function _pushNft(uint256 collectionId, uint256 tokenId, address receiver) internal {
        address collection = collections[collectionId].token;

        IERC721(collection).transferFrom(address(this), receiver, tokenId);
    }

    // =============================================================
    //                         MATH
    // =============================================================

    function _calculatePercentageOf(uint256 value, uint256 percentageBps) internal pure returns (uint256) {
        if (value == 0) {
            return 0;
        }

        return (value * percentageBps) / BPS_DENOMINATOR;
    }

    // =============================================================
    //                       ADMIN: FEES
    // =============================================================

    /**
     * @notice Withdraw accumulated protocol fees.
     */
    function collectProtocolFees(address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        uint256 amount = feeAccrued;

        if (amount == 0) {
            revert NoFeesToCollect();
        }

        feeAccrued = 0;

        if (!USDC.transfer(receiver, amount)) {
            feeAccrued = amount;
            revert TransferFailed();
        }

        emit ProtocolFeesCollected(amount, receiver);
    }

    /**
     * @notice Set the protocol fee for future listings/auctions.
     *
     * @dev Existing positions retain their snapshotted fee.
     */
    function setProtocolFee(uint16 protocolFeeBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) {
            revert FeeTooHigh();
        }

        uint16 oldValue = protocolFeeBps;

        protocolFeeBps = protocolFeeBps_;

        emit ProtocolFeeUpdated(oldValue, protocolFeeBps_);
    }

    // =============================================================
    //                   ADMIN: AUCTION SETTINGS
    // =============================================================

    function setAuctionMinBidAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldValue = auctionMinBidAmount;

        auctionMinBidAmount = amount;

        emit AuctionMinBidAmountUpdated(oldValue, amount);
    }

    function setAuctionMinBidIncrementBps(uint16 incrementBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (incrementBps > BPS_DENOMINATOR) {
            revert IncrementTooHigh();
        }

        uint16 oldValue = auctionMinBidIncrementBps;

        auctionMinBidIncrementBps = incrementBps;

        emit AuctionMinBidIncrementBpsUpdated(oldValue, incrementBps);
    }

    function setAuctionDurationExtensionThreshold(uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldValue = auctionDurationExtensionThreshold;

        auctionDurationExtensionThreshold = threshold;

        emit AuctionDurationExtensionThresholdUpdated(oldValue, threshold);
    }

    function setAuctionDurationExtension(uint256 extension) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldValue = auctionDurationExtension;

        auctionDurationExtension = extension;

        emit AuctionDurationExtensionUpdated(oldValue, extension);
    }

    function setAuctionMinDuration(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration == 0) {
            revert DurationConfigurationInvalid();
        }

        if (duration > auctionMaxDuration) {
            revert DurationConfigurationInvalid();
        }

        uint256 oldValue = auctionMinDuration;

        auctionMinDuration = duration;

        emit AuctionMinDurationUpdated(oldValue, duration);
    }

    function setAuctionMaxDuration(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration < auctionMinDuration) {
            revert DurationConfigurationInvalid();
        }

        uint256 oldValue = auctionMaxDuration;

        auctionMaxDuration = duration;

        emit AuctionMaxDurationUpdated(oldValue, duration);
    }
}
