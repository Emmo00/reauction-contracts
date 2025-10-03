// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAuction} from "./interfaces/IAuction.sol";
import {ICollectibleCasts} from "./interfaces/ICollectibleCasts.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract Auction is IAuction, Ownable2Step, Pausable {
    /// @dev Basis points denominator (10,000 = 100%)
    uint256 internal constant BPS_DENOMINATOR = 10_000;

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
    constructor(
        address _collectibleCast,
        address _usdc,
        address _treasury,
        address _owner
    ) Ownable(_owner) {
        if (_collectibleCast == address(0)) revert InvalidAddress();
        if (_usdc == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        collectible = ICollectibleCasts(_collectibleCast);
        usdc = IERC20(_usdc);
        treasury = _treasury;

        auctionConfig = AuctionConfig({
            minBidAmount: uint32(1e6),
            minAuctionDuration: uint32(1 hours),
            maxAuctionDuration: uint32(30 days),
            maxExtension: uint32(24 hours),
            minBid: uint64(1e6),
            minBidIncrementBps: uint16(100), // 1%
            protocolFeeBps: uint16(1000), // 10%
            duration: uint32(1 hours),
            extension: uint32(5 minutes),
            extensionThreshold: uint32(30 seconds) // TODO: adjust before deployment
        });

        listingConfig = ListingConfig({
            minListingPrice: 1e6, // 1 USDC
            protocolFeeBps: uint16(1000) // 10%
        });
    }

    /// @inheritdoc IAuction
    function createListing(
        uint256 tokenId,
        uint256 price
    ) external whenNotPaused returns (uint256) {
        _createListing(tokenId, price);
        return listingIdCounter;
    }

    /// @inheritdoc IAuction
    function buyListing(uint256 listingId) external whenNotPaused {
        _buyListing(listingId);
    }

    /// @inheritdoc IAuction
    function cancelListing(uint256 listingId) external whenNotPaused {
        _cancelListing(listingId);
    }

    /// @inheritdoc IAuction
    function listingState(
        uint256 listingId
    ) external view returns (ListingState) {
        return listings[listingId].state;
    }

    /// @inheritdoc IAuction
    function getListing(
        uint256 listingId
    ) external view returns (ListingData memory) {
        return listings[listingId];
    }

    /// @inheritdoc IAuction
    function startAuction(
        uint256 tokenId,
        uint32 duration
    ) external whenNotPaused returns (uint256) {
        _startAuction(tokenId, duration);
        return auctionIdCounter;
    }

    /// @inheritdoc IAuction
    function placeBid(
        uint256 auctionId,
        uint256 amount
    ) external whenNotPaused {
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
    function auctionState(
        uint256 auctionId
    ) external view returns (AuctionState) {
        return auctions[auctionId].state;
    }

    /// @inheritdoc IAuction
    function getAuction(
        uint256 auctionId
    ) external view returns (AuctionData memory) {
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
    function setAuctionConfig(
        AuctionConfig calldata config
    ) external onlyOwner {
        if (config.minBidAmount == 0) revert InvalidAuctionConfig();
        if (config.minAuctionDuration < 5 minutes) revert InvalidAuctionConfig();
        if (config.maxAuctionDuration < config.minAuctionDuration)
            revert InvalidAuctionConfig();
        if (config.maxExtension < config.extension) revert InvalidAuctionConfig();
        if (config.minBid == 0) revert InvalidAuctionConfig();
        if (config.minBidIncrementBps == 0 || config.minBidIncrementBps > BPS_DENOMINATOR)
            revert InvalidAuctionConfig();
        if (config.protocolFeeBps > BPS_DENOMINATOR) revert InvalidAuctionConfig();
        if (config.duration < config.minAuctionDuration || config.duration > config.maxAuctionDuration)
            revert InvalidAuctionConfig();
        if (config.extension > config.maxExtension) revert InvalidAuctionConfig();
        if (config.extensionThreshold > config.extension) revert InvalidAuctionConfig();

        auctionConfig = config;
        emit AuctionConfigSet(config);
    }

    /// @inheritdoc IAuction
    function setListingConfig(
        ListingConfig calldata config
    ) external onlyOwner {
        if (config.minListingPrice == 0) revert InvalidListingConfig();
        if (config.protocolFeeBps > BPS_DENOMINATOR) revert InvalidListingConfig();

        listingConfig = config;
        emit ListingConfigSet(config);
    }

    /**
     * @notice Internal function to create a new listing
     * @param tokenId Token ID of the NFT
     * @param price Sale price of the NFT
     */
    function _createListing(uint256 tokenId, uint256 price) internal {
        if (collectible.ownerOf(tokenId) != msg.sender) revert Unauthorized();
        if (price < listingConfig.minListingPrice) revert InvalidListingPrice();

        // Transfer the NFT to the auction contract
        collectible.transferFrom(msg.sender, address(this), tokenId);

        // Create the listing
        listingIdCounter++;
        listings[listingIdCounter] = ListingData({
            creator: msg.sender,
            buyer: address(0),
            price: price,
            tokenId: tokenId,
            createdAt: uint40(block.timestamp),
            purchasedAt: 0,
            cancelledAt: 0,
            protocolFeeBps: listingConfig.maxProtocolFeeBps,
            state: ListingState.Active
        });

        emit ListingCreated(listingIdCounter, msg.sender, tokenId, price);
    }

    function _buyListing(uint256 listingId) internal {
        ListingData storage listing = listings[listingId];
        if (listing.state != ListingState.Active) revert ListingNotActive();

        // Transfer USDC from buyer to contract
        usdc.transferFrom(msg.sender, address(this), listing.price);

        // Update listing state
        listing.buyer = msg.sender;
        listing.purchasedAt = uint40(block.timestamp);
        listing.state = ListingState.Purchased;

        // Distribute funds
        _distributeFunds(
            listing.price,
            listing.protocolFeeBps,
            listing.creator
        );

        // Transfer the NFT to the buyer
        collectible.transferFrom(address(this), msg.sender, listing.tokenId);

        emit ListingPurchased(
            listingId,
            msg.sender,
            listing.tokenId,
            listing.price
        );
    }

    function _cancelListing(uint256 listingId) internal {
        ListingData storage listing = listings[listingId];
        if (listing.state != ListingState.Active) revert ListingNotActive();
        if (listing.creator != msg.sender) revert Unauthorized();

        // Update listing state
        listing.cancelledAt = uint40(block.timestamp);
        listing.state = ListingState.Cancelled;

        // Transfer the NFT back to the creator
        collectible.transferFrom(
            address(this),
            listing.creator,
            listing.tokenId
        );
        emit ListingCancelled(listingId, listing.creator);
    }

    /**
     * @notice Distributes funds from a sale
     * @param amount Total amount to distribute
     * @param protocolFeeBps Protocol fee in basis points
     * @param creator Creator address to receive funds
     */
    function _distributeFunds(
        uint256 amount,
        uint16 protocolFeeBps,
        address creator
    ) internal {
        uint256 protocolFee = (amount * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 creatorAmount = amount - protocolFee;

        // Transfer the protocol fee to the fee recipient
        usdc.transfer(treasury, protocolFee);

        // Transfer the remaining amount to the creator
        usdc.transfer(creator, creatorAmount);
    }
}
