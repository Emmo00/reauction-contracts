// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAuction} from "./interfaces/IAuction.sol";
import {ICollectibleCasts} from "./interfaces/ICollectibleCasts.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract Auction is IAuction, Ownable2Step, Pausable {
    /// @dev Basis points denominator (10,000 = 100%)
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Collectible NFT contract
    ICollectibleCasts public immutable collectible;
    /// @notice USDC token
    IERC20 public immutable usdc;

    /// @notice Protocol fee recipient address
    address public treasury;
    /// @notice Global auction configuration parameters
    AuctionConfig public auctionConfig;
    /// @notice Global listing configuration parameters
    ListingConfig public listingConfig;

    uint256 private auctionIdCounter;
    uint256 private listingIdCounter;

    /// @notice Mapping of auction ids to auction data
    mapping(uint256 => AuctionData) public auctions;
    /// @notice Mapping of listing ids to listing data
    mapping(uint256 => ListingData) public listings;

    /**
     * @notice Creates auction contract
     * @param _collectibleCast NFT contract address
     * @param _usdc USDC token address
     * @param _treasury Fee recipient
     * @param _owner Contract owner
     */
    constructor(address _collectibleCast, address _usdc, address _treasury, address _owner) Ownable(_owner) {
        if (_collectibleCast == address(0)) revert InvalidAddress();
        if (_usdc == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        collectible = ICollectibleCasts(_collectibleCast);
        usdc = IERC20(_usdc);
        treasury = _treasury;

        auctionConfig = AuctionConfig({
            minBidAmount: 1e6, // 1 USDC
            minBidIncrementBps: 1000, // 10%
            minDuration: 1 hours,
            maxDuration: 30 days,
            extension: 15 minutes,
            extensionThreshold: 15 minutes,
            protocolFeeBps: uint16(1000) // 10%
        });

        listingConfig = ListingConfig({
            minListingPrice: 1e6, // 1 USDC
            protocolFeeBps: uint16(1000) // 10%
        });
    }

    /// @inheritdoc IAuction
    function createListing(uint256 tokenId, uint256 price) external whenNotPaused returns (uint256) {
        _collectNFT(tokenId, msg.sender);
        _createListing(tokenId, price);
        return listingIdCounter;
    }

    /// @inheritdoc IAuction
    function buyListing(uint256 listingId) external whenNotPaused {
        (uint256 listingPrice, uint16 protocolFeeBps, address creator, uint256 tokenId) = _buyListing(listingId);
        _collectFunds(msg.sender, listingPrice);
        _distributeFunds(listingPrice, protocolFeeBps, creator);
        _sendNFT(tokenId, msg.sender);
    }

    /// @inheritdoc IAuction
    function cancelListing(uint256 listingId) external whenNotPaused {
        (address creator, uint256 tokenId) = _cancelListing(listingId);
        _sendNFT(tokenId, creator);
    }

    /// @inheritdoc IAuction
    function listingState(uint256 listingId) external view returns (ListingState) {
        return listings[listingId].state;
    }

    /// @inheritdoc IAuction
    function getListing(uint256 listingId) external view returns (ListingData memory) {
        return listings[listingId];
    }

    /// @inheritdoc IAuction
    function startAuction(uint256 tokenId, uint256 startAsk, uint256 duration)
        external
        whenNotPaused
        returns (uint256)
    {
        _collectNFT(tokenId, msg.sender);
        _startAuction(tokenId, startAsk, duration);

        return auctionIdCounter;
    }

    /// @inheritdoc IAuction
    function placeBid(uint256 auctionId, uint256 amount) external whenNotPaused {
        _collectFunds(msg.sender, amount);
        (address formerHighestBidder, uint256 formerHighestBid) = _placeBid(auctionId, amount);
        // Refund the previous highest bidder
        _sendFunds(formerHighestBidder, formerHighestBid);
    }

    /// @inheritdoc IAuction
    function settleAuction(uint256 auctionId) external whenNotPaused {
        (address creator, uint256 amount, uint16 protocolFeeBps, address winner, uint256 tokenId) =
            _settleAuction(auctionId);
        if (winner != address(0)) _distributeFunds(amount, protocolFeeBps, creator);
        _sendNFT(tokenId, winner); // Transfer NFT to the winner
    }

    /// @inheritdoc IAuction
    function cancelAuction(uint256 auctionId) external whenNotPaused {
        (address highestBidder, uint256 highestBid, uint256 tokenId, address creator) = _cancelAuction(auctionId);
        if (highestBidder != address(0)) _sendFunds(highestBidder, highestBid); // Refund hightest Bidder
        _sendNFT(tokenId, creator); // Transfer the NFT back to the creator
    }

    /// @inheritdoc IAuction
    function auctionState(uint256 auctionId) external view returns (AuctionState) {
        AuctionData storage auction = auctions[auctionId];

        if (block.timestamp >= auction.endTime && (auction.state == AuctionState.Active)) {
            return AuctionState.Ended;
        }
        return auction.state;
    }

    function auctionState(uint256 endTime, AuctionState state) internal view returns (AuctionState) {
        if (block.timestamp >= endTime && (state == AuctionState.Active)) {
            return AuctionState.Ended;
        }
        return state;
    }

    /// @inheritdoc IAuction
    function getAuction(uint256 auctionId) external view returns (AuctionData memory) {
        return auctions[auctionId];
    }

    /// @inheritdoc IAuction
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        address oldTreasury = treasury;

        if (oldTreasury == _treasury) return;

        treasury = _treasury;
        emit TreasurySet(oldTreasury, treasury);
    }

    /// @inheritdoc IAuction
    function setAuctionConfig(AuctionConfig calldata config) external onlyOwner {
        if (config.minBidAmount < 1e6) revert InvalidAuctionConfig();
        if (config.minBidIncrementBps > BPS_DENOMINATOR) {
            revert InvalidAuctionConfig();
        }
        if (config.minDuration < 1 hours) revert InvalidAuctionConfig();
        if (config.maxDuration > 90 days) revert InvalidAuctionConfig();
        if (config.minDuration > config.maxDuration) {
            revert InvalidAuctionConfig();
        }
        if (config.extension > config.maxDuration) {
            revert InvalidAuctionConfig();
        }
        if (config.extensionThreshold > config.maxDuration) {
            revert InvalidAuctionConfig();
        }
        if (config.protocolFeeBps > BPS_DENOMINATOR) {
            revert InvalidAuctionConfig();
        }

        auctionConfig = config;
        emit AuctionConfigSet(config);
    }

    /// @inheritdoc IAuction
    function setListingConfig(ListingConfig calldata config) external onlyOwner {
        if (config.minListingPrice == 0) revert InvalidListingConfig();
        if (config.protocolFeeBps > BPS_DENOMINATOR) {
            revert InvalidListingConfig();
        }

        listingConfig = config;
        emit ListingConfigSet(config);
    }

    /// @inheritdoc IAuction
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IAuction
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Internal function to create a new listing
     * @param tokenId Token ID of the NFT
     * @param price Sale price of the NFT
     * @dev Reverts if the price is below the minimum listing price
     */
    function _createListing(uint256 tokenId, uint256 price) internal {
        if (price < listingConfig.minListingPrice) revert InvalidListingPrice();

        // Create the listing
        listingIdCounter++;
        listings[listingIdCounter] = ListingData({
            creator: msg.sender,
            buyer: address(0),
            price: price,
            tokenId: tokenId,
            createdAt: block.timestamp,
            endTime: 0,
            protocolFeeBps: listingConfig.protocolFeeBps,
            state: ListingState.Active
        });

        emit ListingCreated(listingIdCounter, msg.sender, tokenId, price);
    }

    /**
     * @notice Internal function to buy a listing
     * @param listingId ID of the listing to buy
     * @return listingPrice Price of the listing
     * @return protocolFeeBps Protocol fee in basis points
     * @return creator Creator address to receive funds
     * @return tokenId Token ID of the NFT
     * @dev Reverts if the listing is not active or if the buyer is the creator
     */
    function _buyListing(uint256 listingId)
        internal
        returns (uint256 listingPrice, uint16 protocolFeeBps, address creator, uint256 tokenId)
    {
        ListingData storage listing = listings[listingId];
        if (listing.state != ListingState.Active) revert ListingNotActive();
        if (listing.creator == msg.sender) revert Unauthorized();

        listingPrice = listing.price;
        protocolFeeBps = listing.protocolFeeBps;
        creator = listing.creator;
        tokenId = listing.tokenId;

        // Update listing state
        listing.buyer = msg.sender;
        listing.endTime = (block.timestamp);
        listing.state = ListingState.Purchased;

        emit ListingPurchased(listingId, msg.sender, listing.tokenId, listing.price);
    }

    function _cancelListing(uint256 listingId) internal returns (address creator, uint256 tokenId) {
        ListingData storage listing = listings[listingId];

        if (listing.creator != msg.sender) revert Unauthorized();
        if (listing.state != ListingState.Active) revert ListingNotActive();

        creator = listing.creator;
        tokenId = listing.tokenId;

        // Update listing state
        listing.endTime = (block.timestamp);
        listing.state = ListingState.Cancelled;

        emit ListingCancelled(listingId, listing.creator);
    }

    function _startAuction(uint256 tokenId, uint256 startAsk, uint256 duration) internal {
        if (startAsk > 0 && startAsk < auctionConfig.minBidAmount) revert InvalidBidAmount();
        if (duration < auctionConfig.minDuration || duration > auctionConfig.maxDuration) {
            revert InvalidAuctionDuration();
        }

        // Create the auction
        auctionIdCounter++;
        auctions[auctionIdCounter] = AuctionData({
            creator: msg.sender,
            tokenId: tokenId,
            startAsk: startAsk,
            highestBidder: address(0),
            highestBid: 0,
            endTime: (block.timestamp + duration),
            bids: 0,
            extension: 0,
            protocolFeeBps: auctionConfig.protocolFeeBps,
            state: AuctionState.Active
        });

        emit AuctionStarted(auctionIdCounter, msg.sender, tokenId, block.timestamp + duration);
    }

    function _placeBid(uint256 auctionId, uint256 amount)
        internal
        returns (address formerHighestBidder, uint256 formerHighestBid)
    {
        AuctionData storage auction = auctions[auctionId];

        if (auctionState(auction.endTime, auction.state) != AuctionState.Active) revert AuctionNotActive();
        if (auction.startAsk > amount) revert InvalidBidAmount();

        // Calculate minimum acceptable bid
        uint256 incrementAmount = (auction.highestBid * auctionConfig.minBidIncrementBps) / BPS_DENOMINATOR;
        uint256 minBid = auction.highestBid + _max(auctionConfig.minBidAmount, incrementAmount);

        if (amount < minBid) revert InvalidBidAmount();

        formerHighestBidder = auction.highestBidder;
        formerHighestBid = auction.highestBid;

        // Update auction state
        auction.highestBidder = msg.sender;
        auction.highestBid = amount;

        // Extend auction if within extension threshold
        if (auction.endTime - block.timestamp <= auctionConfig.extensionThreshold) {
            uint32 extension = auctionConfig.extension;

            auction.endTime += extension;
            auction.extension += extension;
            emit AuctionExtended(auctionId, auction.endTime);
        }

        emit BidPlaced(auctionId, auction.tokenId, msg.sender, amount);
    }

    function _settleAuction(uint256 auctionId)
        internal
        returns (address creator, uint256 amount, uint16 protocolFeeBps, address winner, uint256 tokenId)
    {
        AuctionData storage auction = auctions[auctionId];

        if (auctionState(auction.endTime, auction.state) != AuctionState.Ended) revert AuctionNotEnded();

        // Update auction state
        auction.endTime = (block.timestamp);
        auction.state = AuctionState.Settled;

        creator = auction.creator;
        amount = auction.highestBid;
        protocolFeeBps = auction.protocolFeeBps;
        winner = auction.highestBidder;
        tokenId = auction.tokenId;
    }

    function _cancelAuction(uint256 auctionId)
        internal
        returns (address hightestBidder, uint256 hightestBid, uint256 tokenId, address creator)
    {
        AuctionData storage auction = auctions[auctionId];
        if (auction.creator != msg.sender) revert Unauthorized();
        if (auctionState(auction.endTime, auction.state) != AuctionState.Active) revert AuctionNotActive();

        // Update auction state
        auction.endTime = (block.timestamp);
        auction.state = AuctionState.Cancelled;

        emit AuctionCancelled(auctionId, auction.creator);
    }

    /**
     * @notice Internal function to collect an NFT from a user
     * @param tokenId Token ID of the NFT
     * @param owner Current owner of the NFT
     * @dev Reverts if the owner is not the current owner of the NFT
     */
    function _collectNFT(uint256 tokenId, address owner) internal {
        if (collectible.ownerOf(tokenId) != owner) revert Unauthorized();
        collectible.transferFrom(owner, address(this), tokenId);
    }

    /**
     * @notice Internal function to send an NFT to a user
     * @param tokenId Token ID of the NFT
     * @param to Recipient address
     */
    function _sendNFT(uint256 tokenId, address to) internal {
        collectible.transferFrom(address(this), to, tokenId);
    }

    /**
     * @notice Internal function to collect funds from a buyer
     * @param buyer Address of the buyer
     * @param amount Amount to collect
     */
    function _collectFunds(address buyer, uint256 amount) internal {
        // Transfer USDC from buyer to contract
        usdc.transferFrom(buyer, address(this), amount);
    }

    /**
     * @notice Internal function to send funds to a user
     * @param to Recipient address
     * @param amount Amount to send
     * @dev Assumes the contract has enough USDC balance to cover the amount
     */
    function _sendFunds(address to, uint256 amount) internal {
        usdc.transfer(to, amount);
    }

    /**
     * @notice Internal function to distribute funds from a sale
     * @param amount Total amount to distribute
     * @param protocolFeeBps Protocol fee in basis points
     * @param creator Creator address to receive funds
     */
    function _distributeFunds(uint256 amount, uint16 protocolFeeBps, address creator) internal {
        uint256 protocolFee = (amount * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 creatorAmount = amount - protocolFee;

        // Transfer the protocol fee to the fee recipient
        usdc.transfer(treasury, protocolFee);

        // Transfer the remaining amount to the creator
        usdc.transfer(creator, creatorAmount);
    }

    /**
     * @notice Internal function to return the maximum of two values
     * @param a First value
     * @param b Second value
     * @return Maximum value
     */
    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }
}
