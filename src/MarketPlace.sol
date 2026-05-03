// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICollectibleCasts} from "./interfaces/ICollectibleCasts.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

contract MarketPlace is AccessControl, ReentrancyGuard, ERC721Holder {
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    /// @dev Basis points denominator (10,000 = 100%)
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable USDC;
    ICollectibleCasts public immutable COLLECTIBLES;

    uint256 public feeAccrued;
    uint16 public protocolFeeBps = 1000; // 10%
    uint256 public auctionMinBidAmount;
    uint16 public auctionMinBidIncrementBps = 1000; // 10%
    uint256 public auctionMinDuration = 1 hours;
    uint256 public auctionMaxDuration = 30 days;
    uint256 public auctionDurationExtension = 20 minutes;
    uint256 public auctionDurationExtensionThreshold = 20 minutes;

    enum AuctionState {
        None,
        Active,
        Settled,
        Cancelled
    }

    enum ListingState {
        None,
        Active,
        Purchased,
        Cancelled
    }

    struct Auction {
        address seller;
        uint256 highestBid;
        address highestBidder;
        uint256 endTime;
        AuctionState state;
    }

    struct Listing {
        address seller;
        address buyer;
        uint256 price;
        ListingState state;
    }

    uint256 public auctionCounter;
    uint256 public listingCounter;

    mapping(uint256 auctionId => Auction) public auctions;
    mapping(uint256 listingId => Listing) public listings;
    mapping(uint256 tokenId => bool) public isTokenOnSale;
    mapping(uint256 tokenId => uint256) public activeAuctionId;
    mapping(uint256 tokenId => uint256) public activeListingId;

    modifier onlyMinted(uint256 tokenId) {
        _requireMinted(tokenId);
        _;
    }

    modifier onlyNotOnSale(uint256 tokenId) {
        _requireNotOnSale(tokenId);
        _;
    }

    modifier onlyOnSale(uint256 tokenId) {
        _requireOnSale(tokenId);
        _;
    }

    function _requireMinted(uint256 tokenId) internal view {
        require(COLLECTIBLES.isMinted(tokenId), "Not Minted");
    }

    function _requireNotOnSale(uint256 tokenId) internal view {
        require(!isTokenOnSale[tokenId], "Token already on sale");
    }

    function _requireOnSale(uint256 tokenId) internal view {
        require(isTokenOnSale[tokenId], "Token not on sale");
    }

    event AuctionStarted(uint256 tokenId, uint256 auctionId, address seller, uint256 duration);
    event BidPlaced(uint256 tokenId, uint256 auctionId, address bidder, uint256 amount);
    event AuctionCancelled(uint256 tokenId, uint256 auctionId);
    event AuctionSettled(uint256 tokenId, uint256 auctionId);

    event ListingCreated(uint256 tokenId, uint256 listingId, address seller, uint256 price);
    event ListingPurchased(uint256 tokenId, uint256 listingId, uint256 endTime);
    event ListingCancelled(uint256 tokenId, uint256 listingId, uint256 endTime);

    event ProtocolFeesCollected(uint256 amount, address receiver);
    event ProtocolFeeUpdated(uint256 oldValue, uint256 newValue);
    event AuctionMinBidAmountUpdated(uint256 oldValue, uint256 newValue);
    event AuctionMinBidIncrementBpsUpdated(uint256 oldValue, uint256 newValue);
    event AuctionDurationExtensionThresholdUpdated(uint256 oldValue, uint256 newValue);
    event AuctionDurationExtensionUpdated(uint256 oldValue, uint256 newValue);

    constructor(address usdc_, uint256 usdcDecimals, address collectibles_, address admin_) {
        require(usdc_ != address(0), "Zero address: USDC");
        require(collectibles_ != address(0), "Zero address: collectibles");
        require(admin_ != address(0), "Zero address: admin");

        USDC = IERC20(usdc_);
        COLLECTIBLES = ICollectibleCasts(collectibles_);
        auctionMinBidAmount = 1 * 10 ** usdcDecimals; // 1 USDC

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function createAuction(uint256 tokenId, uint256 duration)
        external
        onlyMinted(tokenId)
        onlyNotOnSale(tokenId)
        nonReentrant
    {
        require(duration >= auctionMinDuration, "Duration too short");
        require(duration <= auctionMaxDuration, "Duration too long");

        address seller = msg.sender;

        isTokenOnSale[tokenId] = true;
        activeAuctionId[tokenId] = ++auctionCounter;

        auctions[auctionCounter] = Auction({
            seller: seller,
            highestBid: 0,
            highestBidder: address(0),
            endTime: block.timestamp + duration,
            state: AuctionState.Active
        });

        _collectNFT(tokenId, seller);

        emit AuctionStarted(tokenId, auctionCounter, seller, duration);
    }

    function placeBid(uint256 tokenId, uint256 amount) external onlyOnSale(tokenId) nonReentrant {
        address bidder = msg.sender;
        uint256 auctionId = activeAuctionId[tokenId];
        Auction storage auction = auctions[auctionId];
        uint256 expectedEndTime = auction.endTime;
        uint256 expectedMinimumBid =
            auction.highestBid + _calculatePercentageOf(auction.highestBid, auctionMinBidIncrementBps);
        if (expectedMinimumBid < auctionMinBidAmount) {
            expectedMinimumBid = auctionMinBidAmount;
        }

        require(expectedEndTime > block.timestamp, "Auction already ended");
        require(amount >= expectedMinimumBid, "Bid less than minimum");

        // Effects: update state before external calls (CEI)
        address formerHighestBidder = auction.highestBidder;
        uint256 formerHighestBid = auction.highestBid;

        if (auction.highestBidder == bidder) {
            auction.highestBid += amount;
        } else {
            auction.highestBid = amount;
            auction.highestBidder = bidder;
        }

        // extend auction endtime if bid came in too late
        uint256 timeTillAuctionDeadline = expectedEndTime - block.timestamp;
        if (timeTillAuctionDeadline < auctionDurationExtensionThreshold) {
            auction.endTime += auctionDurationExtension;
        }

        // Interactions: external calls after state updates
        _collectPayment(amount, bidder);

        if (formerHighestBidder != bidder && formerHighestBidder != address(0) && formerHighestBid > 0) {
            _pushPayment(formerHighestBidder, formerHighestBid);
        }

        emit BidPlaced(tokenId, auctionId, bidder, amount);
    }

    function cancelAuction(uint256 tokenId) external onlyOnSale(tokenId) nonReentrant {
        address caller = msg.sender;
        uint256 auctionId = activeAuctionId[tokenId];
        Auction storage auction = auctions[auctionId];

        require(auction.endTime > block.timestamp, "Auction already ended");
        require(caller == auction.seller || hasRole(MODERATOR_ROLE, caller), "Not authorized");

        // cache values before state changes
        address highestBidder = auction.highestBidder;
        uint256 highestBid = auction.highestBid;
        address seller = auction.seller;

        // Effects: update state before external calls (CEI)
        auction.state = AuctionState.Cancelled;
        auction.endTime = block.timestamp;
        activeAuctionId[tokenId] = 0;
        isTokenOnSale[tokenId] = false;

        // Interactions: return money to highest bidder
        if (highestBidder != address(0) && highestBid > 0) {
            _pushPayment(highestBidder, highestBid);
        }

        // return NFT to seller
        _pushNFT(address(this), seller, tokenId);

        emit AuctionCancelled(tokenId, auctionId);
    }

    function settleAuction(uint256 tokenId) external onlyOnSale(tokenId) nonReentrant {
        uint256 auctionId = activeAuctionId[tokenId];
        Auction storage auction = auctions[auctionId];

        require(auction.endTime < block.timestamp, "Auction has not ended");
        require(auction.state != AuctionState.Settled, "Auction already settled");

        // cache values before state changes
        uint256 highestBid = auction.highestBid;
        address highestBidder = auction.highestBidder;
        address seller = auction.seller;

        // Effects: update state before external calls (CEI)
        auction.state = AuctionState.Settled;
        activeAuctionId[tokenId] = 0;
        isTokenOnSale[tokenId] = false;

        // Interactions
        if (highestBid > 0 && highestBidder != address(0)) {
            // send out NFT to highest bidder
            _pushNFT(address(this), highestBidder, tokenId);

            // push payment to seller (not bidder)
            uint256 protocolFee = _calculatePercentageOf(highestBid, protocolFeeBps);
            uint256 amountToSettle = highestBid - protocolFee;

            feeAccrued += protocolFee;
            _pushPayment(seller, amountToSettle);
        } else {
            // no bids — return NFT to seller
            _pushNFT(address(this), seller, tokenId);
        }

        emit AuctionSettled(tokenId, auctionId);
    }

    function createListing(uint256 tokenId, uint256 price)
        external
        onlyMinted(tokenId)
        onlyNotOnSale(tokenId)
        nonReentrant
    {
        require(price > 0, "Price must be greater than zero");
        address seller = msg.sender;

        // Effects
        isTokenOnSale[tokenId] = true;
        activeListingId[tokenId] = ++listingCounter;

        listings[listingCounter] =
            Listing({seller: seller, buyer: address(0), price: price, state: ListingState.Active});

        // Interactions
        _collectNFT(tokenId, seller);

        emit ListingCreated(tokenId, listingCounter, seller, price);
    }

    function purchaseItem(uint256 tokenId) external onlyOnSale(tokenId) nonReentrant {
        address buyer = msg.sender;
        uint256 endTime = block.timestamp;

        uint256 listingId = activeListingId[tokenId];
        Listing storage listing = listings[listingId];

        require(listing.state == ListingState.Active, "Listing not active");

        uint256 price = listing.price;
        address seller = listing.seller;

        // Effects: update state before external calls (CEI)
        listing.buyer = buyer;
        listing.state = ListingState.Purchased;
        activeListingId[tokenId] = 0;
        isTokenOnSale[tokenId] = false;

        uint256 protocolFee = _calculatePercentageOf(price, protocolFeeBps);
        uint256 amountToSettle = price - protocolFee;
        feeAccrued += protocolFee;

        // Interactions
        _collectPayment(price, buyer);
        _pushNFT(address(this), buyer, tokenId);

        // push payment to seller (not buyer)
        _pushPayment(seller, amountToSettle);

        emit ListingPurchased(tokenId, listingId, endTime);
    }

    function cancelListing(uint256 tokenId) external onlyOnSale(tokenId) nonReentrant {
        address caller = msg.sender;
        uint256 endTime = block.timestamp;
        uint256 listingId = activeListingId[tokenId];
        Listing storage listing = listings[listingId];

        require(caller == listing.seller || hasRole(MODERATOR_ROLE, caller), "Not authorized");

        address seller = listing.seller;

        // Effects: update state before external calls (CEI)
        listing.state = ListingState.Cancelled;
        activeListingId[tokenId] = 0;
        isTokenOnSale[tokenId] = false;

        // Interactions: push nft back to the seller
        _pushNFT(address(this), seller, tokenId);

        emit ListingCancelled(tokenId, listingId, endTime);
    }

    function _collectPayment(uint256 amount, address payer) internal {
        require(USDC.transferFrom(payer, address(this), amount), "Failed to collect payment");
    }

    function _pushPayment(address receiver, uint256 amount) internal {
        require(USDC.transfer(receiver, amount), "Failed to push payment");
    }

    function _collectNFT(uint256 tokenId, address owner) internal {
        COLLECTIBLES.safeTransferFrom(owner, address(this), tokenId);
    }

    function _pushNFT(address owner, address receiver, uint256 tokenId) internal {
        COLLECTIBLES.transferFrom(owner, receiver, tokenId);
    }

    function _calculatePercentageOf(uint256 value, uint256 percentageBps) internal pure returns (uint256) {
        if (value == 0) return 0;
        return (percentageBps * value) / BPS_DENOMINATOR;
    }

    ///////// ADMIN /////////////

    function collectProtocolFees(address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(receiver != address(0), "Zero address: receiver");
        uint256 amount = feeAccrued;
        require(amount > 0, "No fees to collect");

        // Effects: zero out before transfer (CEI)
        feeAccrued = 0;

        // Interactions
        require(USDC.transfer(receiver, amount), "Failed to collect protocol fees");

        emit ProtocolFeesCollected(amount, receiver);
    }

    function setProtocolFee(uint16 protocolFeeBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(protocolFeeBps_ <= BPS_DENOMINATOR, "Fee exceeds 100%");
        uint16 oldValue = protocolFeeBps;
        protocolFeeBps = protocolFeeBps_;

        emit ProtocolFeeUpdated(oldValue, protocolFeeBps_);
    }

    function setAuctionMinBidAmount(uint256 auctionMinBidAmount_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldValue = auctionMinBidAmount;
        auctionMinBidAmount = auctionMinBidAmount_;

        emit AuctionMinBidAmountUpdated(oldValue, auctionMinBidAmount_);
    }

    function setAuctionDurationExtensionThreshold(uint256 auctionDurationExtensionThreshold_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 oldValue = auctionDurationExtensionThreshold;
        auctionDurationExtensionThreshold = auctionDurationExtensionThreshold_;

        emit AuctionDurationExtensionThresholdUpdated(oldValue, auctionDurationExtensionThreshold_);
    }

    function setAuctionDurationExtension(uint256 auctionDurationExtension_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldValue = auctionDurationExtension;
        auctionDurationExtension = auctionDurationExtension_;

        emit AuctionDurationExtensionUpdated(oldValue, auctionDurationExtension_);
    }

    function setAuctionMinBidIncrementBps(uint16 auctionMinBidIncrementBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(auctionMinBidIncrementBps_ <= BPS_DENOMINATOR, "Increment exceeds 100%");
        uint16 oldValue = auctionMinBidIncrementBps;
        auctionMinBidIncrementBps = auctionMinBidIncrementBps_;

        emit AuctionMinBidIncrementBpsUpdated(oldValue, auctionMinBidIncrementBps_);
    }

    function setAuctionMinDuration(uint256 auctionMinDuration_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(auctionMinDuration_ > 0, "Duration must be > 0");
        require(auctionMinDuration_ <= auctionMaxDuration, "Min exceeds max");
        auctionMinDuration = auctionMinDuration_;
    }

    function setAuctionMaxDuration(uint256 auctionMaxDuration_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(auctionMaxDuration_ >= auctionMinDuration, "Max below min");
        auctionMaxDuration = auctionMaxDuration_;
    }
}
