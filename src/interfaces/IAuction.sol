// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICollectibleCasts} from "./ICollectibleCasts.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title IAuction
 * @author Emmo00
 * @notice Ascending escrowed USDC auction and Fixed Listing for Farcaster collectible casts
 */
interface IAuction {
    error InvalidAddress(); // Zero address provided where valid address required
    error InvalidBidAmount(); // Bid amount insufficient or invalid
    error InvalidAmount();
    error InvalidAuctionDuration(); // Auction duration outside allowed range
    error InvalidListingPrice(); // Listing price insufficient or invalid
    error InvalidAuctionConfig(); // Auction configuration parameters are invalid
    error InvalidListingConfig(); // Listing configuration parameters are invalid
    error AuctionNotActive(); // Auction is not in active state
    error ListingNotActive(); // Listing is not in active state
    error AuctionNotEnded(); // Auction is still active, cannot settle
    error Unauthorized(); // Signer is not authorized for this operation
    error PermitExpired(); // ERC20 Permit has expired
    error NFTNotMinted(); // Collectible cast NFT has not been minted
    error InsufficientWithdrawalBalance();

    /**
     * @notice Global auction configuration. Used to validate per-auction params.
     * @param minBidAmount Minimum bid amount in USDC (6 decimals)
     * @param minBidIncrementBps Minimum bid increment in basis points (bps)
     * @param minDuration Minimum auction duration (seconds)
     * @param maxDuration Maximum auction duration (seconds)
     * @param extension Time to extend auction if bid placed near end (seconds)
     * @param maxExtension Maximum total auction extension time (seconds)
     * @param extensionThreshold Time before auction end to trigger extension (seconds)
     * @param protocolFeeBps Protocol fee in basis points (bps)
     */
    struct AuctionConfig {
        uint32 minBidAmount;
        uint16 minBidIncrementBps;
        uint32 minDuration;
        uint32 maxDuration;
        uint32 extension;
        uint256 maxExtension;
        uint32 extensionThreshold;
        uint16 protocolFeeBps;
    }

    /**
     * @notice Global listing configuration. Used to validate per-listing params.
     * @param minListingPrice Minimum listing price in USDC (6 decimals)
     * @param protocolFeeBps Protocol fee in basis points (bps)
     */
    struct ListingConfig {
        uint32 minListingPrice;
        uint16 protocolFeeBps;
    }

    /**
     * @notice Auction state data
     * @param creator Auction creator address
     * @param startAsk Starting ask price (minimum bid)
     * @param tokenId Collectible cast token ID
     * @param highestBidder Current leader
     * @param highestBid Leading bid (USDC)
     * @param endTime End time (may be extended)
     * @param bids Bid count
     * @param extension Total auction extension time (seconds)
     * @param protocolFeeBps Protocol fee (bps)
     * @param state Auction state
     */
    struct AuctionData {
        address creator;
        uint256 tokenId;
        uint256 startAsk;
        address highestBidder;
        uint256 highestBid;
        uint256 endTime;
        uint32 bids;
        uint256 extension;
        uint16 protocolFeeBps;
        AuctionState state;
    }

    /**
     * @notice Listing state data
     * @param creator Listing creator (seller) address
     * @param buyer Listing buyer address
     * @param price Sale price in USDC
     * @param tokenId Collectible cast token ID
     * @param createdAt Listing creation timestamp
     * @param endTime End time of the auction
     * @param protocolFeeBps Protocol fee (bps)
     * @param state Listing state
     */
    struct ListingData {
        address creator;
        address buyer;
        uint256 price;
        uint256 tokenId;
        uint256 createdAt;
        uint256 endTime;
        uint16 protocolFeeBps;
        ListingState state;
    }

    /**
     * @notice ERC20 Permit data
     * @param deadline Permit expiration
     * @param v Signature recovery byte
     * @param r Signature r value
     * @param s Signature s value
     */
    struct PermitData {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice Auction states
     */
    enum AuctionState {
        None,
        Active,
        Ended,
        Settled,
        Cancelled
    }

    /**
     * @notice Listing states
     */
    enum ListingState {
        None,
        Active,
        Purchased,
        Cancelled
    }

    /**
     * @notice Emitted when a new listing is created
     * @param listingId Unique identifier for the listing
     * @param seller Address of the seller
     * @param tokenId Token ID of the NFT
     * @param price Sale price of the NFT
     */
    event ListingCreated(uint256 indexed listingId, address indexed seller, uint256 indexed tokenId, uint256 price);

    /**
     * @notice Emitted when a listing is purchased
     * @param listingId Unique identifier for the listing
     * @param buyer Address of the buyer
     * @param tokenId Token ID of the NFT
     * @param price Sale price of the NFT
     */
    event ListingPurchased(uint256 indexed listingId, address indexed buyer, uint256 indexed tokenId, uint256 price);

    /**
     * @notice Emitted when a listing is canceled
     * @param listingId Unique identifier for the listing
     * @param creator Address of the listing creator (seller)
     */
    event ListingCancelled(uint256 indexed listingId, address indexed creator);

    /**
     * @notice Emitted when a new auction is started
     * @param auctionId Unique identifier for the auction
     * @param creator Auction creator's address
     * @param tokenId Token ID of the NFT
     * @param endTime Auction end timestamp
     */
    event AuctionStarted(uint256 indexed auctionId, address indexed creator, uint256 indexed tokenId, uint256 endTime);

    /**
     * @notice Emitted when a bid is placed
     * @param auctionId Unique identifier of the auction
     * @param tokenId Token ID of the NFT
     * @param bidder Bidder's address
     * @param amount Bid amount in USDC
     */
    event BidPlaced(uint256 indexed auctionId, uint256 indexed tokenId, address indexed bidder, uint256 amount);

    /**
     * @notice Emitted when auction end time is extended
     * @param auctionId Unique identifier of the auction
     * @param newEndTime New auction end timestamp
     */
    event AuctionExtended(uint256 indexed auctionId, uint256 newEndTime);

    /**
     * @notice Emitted when an auction is settled
     * @param auctionId Unique identifier of the auction
     * @param winner Winner's address
     * @param tokenId Token ID of the NFT
     * @param amount Winning bid amount in USDC
     */
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 tokenId, uint256 amount);

    /**
     * @notice Emitted when an auction is cancelled
     * @param auctionId Unique identifier of the auction
     * @param creator address of the auction creator
     */
    event AuctionCancelled(uint256 indexed auctionId, address creator);

    event AuctionRefundAvailable(address indexed user, uint256 indexed auctionId, uint256 amount);

    event AuctionRefundWithdrawn(address indexed user, uint256 indexed auctionId, uint256 amount);

    /**
     * @notice Emitted when treasury address is updated
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     */
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Emitted when auction configuration is updated
     * @param config New auction configuration
     */
    event AuctionConfigSet(AuctionConfig config);

    /**
     * @notice Emitted when listing configuration is updated
     * @param config New listing configuration
     */
    event ListingConfigSet(ListingConfig config);

    /**
     * @notice Create a fixed-price listing for a collectible cast
     * @param tokenId Token ID of the collectible cast
     * @param price Sale price in USDC (6 decimals)
     * @return listingId Unique identifier for the created listing
     * @dev Caller must be the owner of the cast and have approved this contract.
     */
    function createListing(uint256 tokenId, uint256 price) external returns (uint256);

    /**
     * @notice Buy a fixed-price listing
     * @param listingId Unique identifier of the listing to purchase
     * @dev Caller must not be the seller. USDC approval required.
     */
    function buyListing(uint256 listingId) external;

    /**
     * @notice Buy a fixed-price listing using permit for USDC
     * @param listingId Unique identifier of the listing to purchase
     * @param permit Permit data for USDC
     * @dev Caller must not be the seller. USDC approval required.
     */
    function buyListingWithPermit(uint256 listingId, PermitData memory permit) external;

    /**
     * @notice Cancel an active listing
     * @param listingId Unique identifier of the listing to cancel
     * @dev Caller must be the seller. Cannot cancel if already purchased.
     */
    function cancelListing(uint256 listingId) external;

    /**
     * @notice Read listing state
     * @param listingId Listing identifier
     * @return Current state
     */
    function listingState(uint256 listingId) external view returns (ListingState);

    /**
     * @notice Get listing data
     * @param listingId Listing identifier
     * @return Listing data
     */
    function getListing(uint256 listingId) external view returns (ListingData memory);

    /**
     * @notice Start a new auction for a collectible cast
     * @param tokenId Token ID of the collectible cast
     * @param startAsk Starting ask price by the creator
     * @param duration Duration for the auction
     * @return auctionId Unique identifier for the created auction
     * @dev Caller must be the owner of the cast and have approved this contract.
     */
    function startAuction(uint256 tokenId, uint256 startAsk, uint256 duration) external returns (uint256);

    /**
     * @notice Place a bid on an active auction
     * @param auctionId Unique identifier of the auction
     * @param amount Bid amount in USDC (6 decimals)
     * @dev Caller must not be the current highest bidder. USDC approval required.
     */
    function placeBid(uint256 auctionId, uint256 amount) external;

    /**
     * @notice Place a bid on an active auction using permit for USDC
     * @param auctionId Unique identifier of the auction
     * @param amount Bid amount in USDC (6 decimals)
     * @dev Caller must not be the current highest bidder. USDC approval required.
     */
    function placeBidWithPermit(uint256 auctionId, uint256 amount, PermitData memory permit) external;

    /**
     * @notice Settle an ended auction, transferring the NFT to the winner
     * @param auctionId Unique identifier of the auction
     * @dev Can be called by anyone. Transfers NFT to highest bidder and USDC to creator.
     */
    function settleAuction(uint256 auctionId) external;

    /**
     * @notice Batch settle multiple ended auctions
     * @param auctionIds Array of auction identifiers to settle
     * @dev Can be called by anyone. Transfers NFTs to highest bidders and USDC to creators.
     */
    function batchSettleAuction(uint256[] calldata auctionIds) external;

    /**
     * @notice Cancel an active auction without bids, returning the NFT to the creator
     * @param auctionId Unique identifier of the auction
     * @dev Caller must be the auction creator. Auction must have no bids.
     */
    function cancelAuction(uint256 auctionId) external;

    /**
     * @notice Read auction state
     * @param auctionId Auction identifier
     * @return Current state
     */
    function auctionState(uint256 auctionId) external view returns (AuctionState);

    /**
     * @notice Get auction data with calculated state
     * @param auctionId Auction identifier
     * @return Auction data with current calculated state
     * @dev Returns empty struct for non-existent auctions
     */
    function getAuction(uint256 auctionId) external view returns (AuctionData memory);

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Updates protocol fee recipient
     * @param _treasury New treasury address
     * @dev Owner only
     */
    function setTreasury(address _treasury) external;

    /**
     * @notice Updates global auction configuration
     * @param _config New configuration parameters
     * @dev Owner only. Validates all parameters.
     */
    function setAuctionConfig(AuctionConfig calldata _config) external;

    /**
     * @notice Updates global listing configuration
     * @param _config New configuration parameters
     * @dev Owner only. Validates all parameters.
     */
    function setListingConfig(ListingConfig calldata _config) external;

    /**
     * @notice Pauses all auction operations
     * @dev Owner only. Emits Paused event.
     */
    function pause() external;

    /**
     * @notice Resumes all auction operations
     * @dev Owner only. Emits Unpaused event.
     */
    function unpause() external;

    // ========== PUBLIC STATE VARIABLES ==========

    /**
     * @notice Collectible NFT contract
     * @return Address of the CollectibleCasts contract
     */
    function collectible() external view returns (ICollectibleCasts);

    /**
     * @notice USDC token contract
     * @return Address of the USDC token
     */
    function usdc() external view returns (IERC20);

    /**
     * @notice Protocol fee recipient
     * @return Current treasury address
     */
    function treasury() external view returns (address);

    /**
     * @notice Withdraw pending refunds
     */
    function withdraw() external;

    /**
     * @notice Get pending withdrawal amount for a user
     * @param user Address to check
     * @return Pending withdrawal amount
     */
    function getPendingWithdrawal(address user) external view returns (uint256);
}
