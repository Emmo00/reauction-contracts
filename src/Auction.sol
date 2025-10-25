// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAuction} from "./interfaces/IAuction.sol";
import {ICollectibleCasts} from "./interfaces/ICollectibleCasts.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC721Holder} from "openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract Auction is IAuction, Ownable2Step, Pausable, ReentrancyGuard, ERC721Holder {
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
    /// @notice Mapping for tracking pending withdrawals
    mapping(address => uint256) public pendingWithdrawals;

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
        if (_owner == address(0)) revert InvalidAddress();

        collectible = ICollectibleCasts(_collectibleCast);
        usdc = IERC20(_usdc);
        treasury = _treasury;

        auctionConfig = AuctionConfig({
            minBidAmount: 1e6, // 1 USDC
            minBidIncrementBps: 1000, // 10%
            minDuration: 1 hours,
            maxDuration: 30 days,
            extension: 15 minutes,
            maxExtension: 52 weeks,
            extensionThreshold: 15 minutes,
            protocolFeeBps: uint16(1000) // 10%
        });

        listingConfig = ListingConfig({
            minListingPrice: 1e6, // 1 USDC
            protocolFeeBps: uint16(1000) // 10%
        });
    }

    /// @inheritdoc IAuction
    function createListing(uint256 tokenId, uint256 price) external whenNotPaused nonReentrant returns (uint256) {
        if (price < listingConfig.minListingPrice) revert InvalidListingPrice();
        _collectNFT(tokenId, msg.sender);
        _createListing(tokenId, price);
        return listingIdCounter;
    }

    /// @inheritdoc IAuction
    function buyListing(uint256 listingId) external whenNotPaused nonReentrant {
        (uint256 listingPrice, uint16 protocolFeeBps, address creator, uint256 tokenId) = _buyListing(listingId);
        require(_collectFunds(msg.sender, listingPrice), "Payment failed");
        _distributeFunds(listingPrice, protocolFeeBps, creator);
        _sendNFT(tokenId, msg.sender);
    }

    /// @inheritdoc IAuction
    function buyListingWithPermit(uint256 listingId, PermitData memory permit) external whenNotPaused nonReentrant {
        (uint256 listingPrice, uint16 protocolFeeBps, address creator, uint256 tokenId) = _buyListing(listingId);
        require(_collectFundsWithPermit(msg.sender, listingPrice, permit), "Payment failed");
        _distributeFunds(listingPrice, protocolFeeBps, creator);
        _sendNFT(tokenId, msg.sender);
    }

    /// @inheritdoc IAuction
    function cancelListing(uint256 listingId) external whenNotPaused nonReentrant {
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
    function startAuction(uint256 tokenId, uint256 duration)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (duration < auctionConfig.minDuration || duration > auctionConfig.maxDuration) {
            revert InvalidAuctionDuration();
        }

        _collectNFT(tokenId, msg.sender);
        _createAuction(tokenId, duration);

        emit AuctionStarted(auctionIdCounter, msg.sender, tokenId, block.timestamp + duration);

        return auctionIdCounter;
    }

    /// @inheritdoc IAuction
    function placeBid(uint256 auctionId, uint256 amount) external whenNotPaused nonReentrant {
        uint256 pendingBalance = pendingWithdrawals[msg.sender];
        uint256 amountFromPending = pendingBalance >= amount ? amount : pendingBalance;
        uint256 amountToCollect = amount - amountFromPending;

        // Collect additional funds if needed
        if (amountToCollect > 0) {
            require(_collectFunds(msg.sender, amountToCollect), "Payment failed");
        }

        // Use pending withdrawals if available
        if (amountFromPending > 0) {
            _decreasePendingWithdrawal(msg.sender, amountFromPending);
        }

        (address formerHighestBidder, uint256 formerHighestBid) = _placeBid(auctionId, amount);

        // Refund the previous highest bidder
        if (formerHighestBidder != address(0) && formerHighestBid > 0) {
            _increasePendingWithdrawal(formerHighestBidder, formerHighestBid);
            emit AuctionRefundAvailable(formerHighestBidder, auctionId, formerHighestBid);
        }
    }

    /// @inheritdoc IAuction
    function placeBidWithPermit(uint256 auctionId, uint256 amount, PermitData memory permit)
        external
        whenNotPaused
        nonReentrant
    {
        uint256 pendingBalance = pendingWithdrawals[msg.sender];
        uint256 amountFromPending = pendingBalance >= amount ? amount : pendingBalance;
        uint256 amountToCollect = amount - amountFromPending;

        // Collect additional funds if needed
        if (amountToCollect > 0) {
            require(_collectFundsWithPermit(msg.sender, amountToCollect, permit), "Payment failed");
        }

        // Use pending withdrawals if available
        if (amountFromPending > 0) {
            _decreasePendingWithdrawal(msg.sender, amountFromPending);
        }

        (address formerHighestBidder, uint256 formerHighestBid) = _placeBid(auctionId, amount);

        // Refund the previous highest bidder
        if (formerHighestBidder != address(0) && formerHighestBid > 0) {
            _increasePendingWithdrawal(formerHighestBidder, formerHighestBid);
            emit AuctionRefundAvailable(formerHighestBidder, auctionId, formerHighestBid);
        }
    }

    /// @inheritdoc IAuction
    function settleAuction(uint256 auctionId) external whenNotPaused nonReentrant {
        (address creator, uint256 amount, uint16 protocolFeeBps, address winner, uint256 tokenId) =
            _settleAuction(auctionId);
        if (winner != address(0)) {
            _distributeFunds(amount, protocolFeeBps, creator);
            _sendNFT(tokenId, winner); // Transfer NFT to the winner
        } else {
            // No bids were placed, return NFT to creator
            _sendNFT(tokenId, creator);
        }
    }

    /// @inheritdoc IAuction
    function batchSettleAuction(uint256[] calldata auctionIds) external whenNotPaused nonReentrant {
        for (uint256 i = 0; i < auctionIds.length; i++) {
            uint256 auctionId = auctionIds[i];
            (address creator, uint256 amount, uint16 protocolFeeBps, address winner, uint256 tokenId) =
                _settleAuction(auctionId);
            if (winner != address(0)) {
                _distributeFunds(amount, protocolFeeBps, creator);
                _sendNFT(tokenId, winner); // Transfer NFT to the winner
            } else {
                // No bids were placed, return NFT to creator
                _sendNFT(tokenId, creator);
            }
        }
    }

    /// @inheritdoc IAuction
    function cancelAuction(uint256 auctionId) external whenNotPaused nonReentrant {
        (address highestBidder, uint256 highestBid, uint256 tokenId, address creator) = _cancelAuction(auctionId);
        if (highestBidder != address(0)) {
            // Refund the highest bidder
            _increasePendingWithdrawal(highestBidder, highestBid);

            emit AuctionRefundAvailable(highestBidder, auctionId, highestBid);
        }
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

    function _getAuctionState(uint256 endTime, AuctionState state) internal view returns (AuctionState) {
        if (block.timestamp >= endTime && (state == AuctionState.Active)) {
            return AuctionState.Ended;
        }
        return state;
    }

    /// @inheritdoc IAuction
    function getAuction(uint256 auctionId) external view returns (AuctionData memory) {
        AuctionData storage auction = auctions[auctionId];
        AuctionState currentState = _getAuctionState(auction.endTime, auction.state);
        return AuctionData({
            creator: auction.creator,
            tokenId: auction.tokenId,
            highestBidder: auction.highestBidder,
            highestBid: auction.highestBid,
            endTime: auction.endTime,
            bids: auction.bids,
            extension: auction.extension,
            protocolFeeBps: auction.protocolFeeBps,
            state: currentState
        });
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
        if (config.minBidAmount < 1e6) revert InvalidAuctionConfig(); // Minimum 1 USDC
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

    /// @inheritdoc IAuction
    function withdraw() external whenNotPaused nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert InsufficientWithdrawalBalance();

        _decreasePendingWithdrawal(msg.sender, amount);
        require(_sendFunds(msg.sender, amount), "Transfer failed");

        emit AuctionRefundWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IAuction
    function getPendingWithdrawal(address user) external view returns (uint256) {
        return pendingWithdrawals[user];
    }

    /**
     * @notice Internal function to create a new listing
     * @param tokenId Token ID of the NFT
     * @param price Sale price of the NFT
     * @dev Reverts if the price is below the minimum listing price
     */
    function _createListing(uint256 tokenId, uint256 price) internal {
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
        listing.endTime = block.timestamp;
        listing.state = ListingState.Purchased;

        emit ListingPurchased(listingId, msg.sender, listing.creator, listing.tokenId, listing.price);
    }

    function _cancelListing(uint256 listingId) internal returns (address creator, uint256 tokenId) {
        ListingData storage listing = listings[listingId];

        if (listing.creator != msg.sender) revert Unauthorized();
        if (listing.state != ListingState.Active) revert ListingNotActive();

        creator = listing.creator;
        tokenId = listing.tokenId;

        // Update listing state
        listing.endTime = block.timestamp;
        listing.state = ListingState.Cancelled;

        emit ListingCancelled(listingId, listing.creator, listing.tokenId);
    }

    function _createAuction(uint256 tokenId, uint256 duration) internal {
        // Create the auction
        auctionIdCounter++;
        auctions[auctionIdCounter] = AuctionData({
            creator: msg.sender,
            tokenId: tokenId,
            highestBidder: address(0),
            highestBid: 0,
            endTime: block.timestamp + duration,
            bids: 0,
            extension: 0,
            protocolFeeBps: auctionConfig.protocolFeeBps,
            state: AuctionState.Active
        });
    }

    function _placeBid(uint256 auctionId, uint256 amount)
        internal
        returns (address formerHighestBidder, uint256 formerHighestBid)
    {
        AuctionData storage auction = auctions[auctionId];

        if (_getAuctionState(auction.endTime, auction.state) != AuctionState.Active) revert AuctionNotActive();

        // Calculate minimum acceptable bid
        uint256 incrementAmount = (auction.highestBid * auctionConfig.minBidIncrementBps) / BPS_DENOMINATOR;
        uint256 minBid = auction.highestBid + _max(auctionConfig.minBidAmount, incrementAmount);

        if (amount < minBid) revert InvalidBidAmount();

        formerHighestBidder = auction.highestBidder;
        formerHighestBid = auction.highestBid;

        // Update auction state
        auction.highestBidder = msg.sender;
        auction.highestBid = amount;
        auction.bids++;

        // Extend auction if within extension threshold
        if (
            auction.endTime - block.timestamp <= auctionConfig.extensionThreshold
                && auction.extension < auctionConfig.maxExtension
        ) {
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

        if (_getAuctionState(auction.endTime, auction.state) != AuctionState.Ended) revert AuctionNotEnded();

        // Update auction state
        auction.endTime = block.timestamp;
        auction.state = AuctionState.Settled;

        creator = auction.creator;
        amount = auction.highestBid;
        protocolFeeBps = auction.protocolFeeBps;
        winner = auction.highestBidder;
        tokenId = auction.tokenId;

        emit AuctionSettled(auctionId, auction.creator, winner, tokenId, amount);
    }

    function _cancelAuction(uint256 auctionId)
        internal
        returns (address highestBidder, uint256 highestBid, uint256 tokenId, address creator)
    {
        AuctionData storage auction = auctions[auctionId];
        if (auction.creator != msg.sender) revert Unauthorized();
        if (_getAuctionState(auction.endTime, auction.state) != AuctionState.Active) revert AuctionNotActive();

        highestBidder = auction.highestBidder;
        highestBid = auction.highestBid;
        tokenId = auction.tokenId;
        creator = auction.creator;

        // Update auction state
        auction.endTime = block.timestamp;
        auction.state = AuctionState.Cancelled;

        emit AuctionCancelled(auctionId, auction.creator, auction.tokenId);
    }

    /**
     * @notice Internal function to collect an NFT from a user
     * @param tokenId Token ID of the NFT
     * @param owner Current owner of the NFT
     * @dev Reverts if the owner is not the current owner of the NFT
     */
    function _collectNFT(uint256 tokenId, address owner) internal {
        if (collectible.isMinted(tokenId) == false) revert NFTNotMinted();
        if (collectible.ownerOf(tokenId) != owner) revert Unauthorized();
        collectible.transferFrom(owner, address(this), tokenId);
    }

    /**
     * @notice Internal function to send an NFT to a user
     * @param tokenId Token ID of the NFT
     * @param to Recipient address
     */
    function _sendNFT(uint256 tokenId, address to) internal {
        if (collectible.ownerOf(tokenId) != address(this)) {
            revert Unauthorized();
        }
        collectible.transferFrom(address(this), to, tokenId);
    }

    /**
     * @notice Internal function to collect funds from a buyer
     * @param buyer Address of the buyer
     * @param amount Amount to collect
     */
    function _collectFunds(address buyer, uint256 amount) internal returns (bool) {
        // Transfer USDC from buyer to contract
        return usdc.transferFrom(buyer, address(this), amount);
    }

    /**
     * @notice Internal function to collect funds from a buyer using permit
     * @param buyer Address of the buyer
     * @param amount Amount to collect
     * @param permit Permit data for USDC
     */
    function _collectFundsWithPermit(address buyer, uint256 amount, PermitData memory permit) internal returns (bool) {
        if (permit.deadline < block.timestamp) revert PermitExpired();
        IERC20Permit(address(usdc)).permit(buyer, address(this), amount, permit.deadline, permit.v, permit.r, permit.s);
        // Transfer USDC from buyer to contract
        return usdc.transferFrom(buyer, address(this), amount);
    }

    /**
     * @notice Internal function to increase pending withdrawal balance
     * @param user Address of the user
     * @param amountIncrease Amount to increase
     */
    function _increasePendingWithdrawal(address user, uint256 amountIncrease) internal {
        if (amountIncrease <= 0) revert InvalidAmount();
        if (user == address(0)) revert InvalidAddress();

        pendingWithdrawals[user] += amountIncrease;
    }

    /**
     * @notice Internal function to decrease pending withdrawal balance
     * @param user Address of the user
     * @param amountDecrease Amount to decrease
     */
    function _decreasePendingWithdrawal(address user, uint256 amountDecrease) internal {
        if (amountDecrease <= 0) revert InvalidAmount();
        if (user == address(0)) revert InvalidAddress();

        uint256 currentBalance = pendingWithdrawals[user];
        if (amountDecrease > currentBalance) {
            revert InsufficientWithdrawalBalance();
        }

        pendingWithdrawals[user] = currentBalance - amountDecrease;
    }

    /**
     * @notice Internal function to send funds to a user
     * @param to Recipient address
     * @param amount Amount to send
     * @dev Assumes the contract has enough USDC balance to cover the amount
     */
    function _sendFunds(address to, uint256 amount) internal returns (bool) {
        if (amount > 0) return usdc.transfer(to, amount);
        return true;
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
        if (protocolFee > 0) {
            require(usdc.transfer(treasury, protocolFee), "Transfer to treasury failed");
        }

        // Transfer the remaining amount to the creator
        require(usdc.transfer(creator, creatorAmount), "Transfer to creator failed");
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
