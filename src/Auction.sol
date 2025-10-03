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
        _startAuction(tokenId, startAsk, duration);
        return auctionIdCounter;
    }

    /// @inheritdoc IAuction
    function placeBid(uint256 auctionId, uint256 amount) external whenNotPaused {
        _placeBid(auctionId, amount);
    }

    /// @inheritdoc IAuction
    function settleAuction(uint256 auctionId) external whenNotPaused {
        _settleAuction(auctionId);
    }

    /// @inheritdoc IAuction
    function cancelAuction(uint256 auctionId) external whenNotPaused {
        _cancelAuction(auctionId);
    }

    /// @inheritdoc IAuction
    function auctionState(uint256 auctionId) external view returns (AuctionState) {
        return auctions[auctionId].state;
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
            purchasedAt: 0,
            cancelledAt: 0,
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
        listing.purchasedAt = uint40(block.timestamp);
        listing.state = ListingState.Purchased;

        emit ListingPurchased(listingId, msg.sender, listing.tokenId, listing.price);
    }

    function _cancelListing(uint256 listingId) internal returns (address creator, uint256 tokenId) {
        ListingData storage listing = listings[listingId];
        if (listing.state != ListingState.Active) revert ListingNotActive();
        if (listing.creator != msg.sender) revert Unauthorized();

        // Update listing state
        listing.cancelledAt = uint40(block.timestamp);
        listing.state = ListingState.Cancelled;

        emit ListingCancelled(listingId, listing.creator);
    }

    function _startAuction(uint256 tokenId, uint256 startAsk, uint256 duration) internal {
        if (collectible.ownerOf(tokenId) != msg.sender) revert Unauthorized();

        // Transfer the NFT to the auction contract
        collectible.transferFrom(msg.sender, address(this), tokenId);

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

    function _placeBid(uint256 auctionId, uint256 amount) internal {
        AuctionData storage auction = auctions[auctionId];
        if (auction.state != AuctionState.Active) revert AuctionNotActive();
        if (block.timestamp >= auction.endAt) revert AuctionEnded();
        if (amount < auctionConfig.minBid) revert InvalidBidAmount();
        if (amount < auction.highestBid + ((auction.highestBid * auctionConfig.minBidIncrementBps) / BPS_DENOMINATOR)) {
            revert InvalidBidAmount();
        }

        // Transfer USDC from bidder to contract
        usdc.transferFrom(msg.sender, address(this), amount);

        // Refund the previous highest bidder
        if (auction.highestBidder != address(0)) {
            usdc.transfer(auction.highestBidder, auction.highestBid);
        }

        // Update auction state
        auction.highestBidder = msg.sender;
        auction.highestBid = amount;

        // Extend auction if within extension threshold
        if (auction.endAt - block.timestamp <= auctionConfig.extensionThreshold) {
            uint32 extension = auctionConfig.extension;
            if (auction.extension + extension > auctionConfig.maxExtension) {
                extension = auctionConfig.maxExtension - uint32(auction.extension);
            }
            auction.endAt += extension;
            auction.extension += extension;
            emit AuctionExtended(auctionId, auction.endAt);
        }

        emit BidPlaced(auctionId, msg.sender, amount);
    }

    function _settleAuction(uint256 auctionId) internal {
        AuctionData storage auction = auctions[auctionId];
        if (auction.state != AuctionState.Active) revert AuctionNotActive();
        if (block.timestamp < auction.endAt) revert AuctionNotEnded();

        // Update auction state
        auction.settledAt = uint40(block.timestamp);
        auction.state = AuctionState.Settled;

        if (auction.highestBidder != address(0)) {
            // Distribute funds
            _distributeFunds(auction.highestBid, auction.protocolFeeBps, auction.creator);

            // Transfer the NFT to the highest bidder
            collectible.transferFrom(address(this), auction.highestBidder, auction.tokenId);

            emit AuctionSettled(auctionId, auction.highestBidder, auction.tokenId, auction.highestBid);
        } else {
            // No bids were placed, return the NFT to the creator
            collectible.transferFrom(address(this), auction.creator, auction.tokenId);

            emit AuctionSettled(auctionId, address(0), auction.tokenId, 0);
        }
    }

    function _cancelAuction(uint256 auctionId) internal {
        AuctionData storage auction = auctions[auctionId];
        if (auction.state != AuctionState.Active) revert AuctionNotActive();
        if (auction.creator != msg.sender) revert Unauthorized();
        if (block.timestamp >= auction.endAt) revert AuctionNotEnded();

        // Update auction state
        auction.cancelledAt = uint40(block.timestamp);
        auction.state = AuctionState.Cancelled;

        // Refund the highest bidder if any
        if (auction.highestBidder != address(0)) {
            usdc.transfer(auction.highestBidder, auction.highestBid);
        }

        // Transfer the NFT back to the creator
        collectible.transferFrom(address(this), auction.creator, auction.tokenId);
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
     * @notice Distributes funds from a sale
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
}
