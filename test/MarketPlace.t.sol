// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {MarketPlace} from "../src/MarketPlace.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockCollectible} from "./mocks/MockCollectible.sol";

contract MarketPlaceTest is Test {
    MarketPlace public mp;
    MockUSDC public usdc;
    MockCollectible public nft;

    address admin = makeAddr("admin");
    address moderator = makeAddr("moderator");
    address alice = makeAddr("alice"); // seller
    address bob = makeAddr("bob"); // buyer / bidder
    address charlie = makeAddr("charlie"); // second bidder

    uint256 constant TOKEN_ID = 1;
    uint256 constant TOKEN_ID_2 = 2;
    uint256 constant AUCTION_DURATION = 2 hours;
    uint256 constant LISTING_PRICE = 100e6; // 100 USDC
    uint16 constant MAX_FEE = 2_000; // MAX_PROTOCOL_FEE_BPS (20%)

    function setUp() public {
        usdc = new MockUSDC();
        nft = new MockCollectible();
        mp = new MarketPlace(address(usdc), 6, address(nft), admin);

        // grant moderator role
        bytes32 modRole = mp.MODERATOR_ROLE();
        vm.prank(admin);
        mp.grantRole(modRole, moderator);

        // mint NFTs to alice
        nft.mint(alice, TOKEN_ID);
        nft.mint(alice, TOKEN_ID_2);

        // fund accounts with USDC
        usdc.mint(bob, 1000e6);
        usdc.mint(charlie, 1000e6);

        // approve marketplace for NFT transfers
        vm.prank(alice);
        nft.setApprovalForAll(address(mp), true);

        // approve marketplace for USDC transfers
        vm.prank(bob);
        usdc.approve(address(mp), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(mp), type(uint256).max);
    }

    // ==================== Constructor ====================

    function test_constructor_setsImmutables() public view {
        assertEq(address(mp.USDC()), address(usdc));
        assertEq(address(mp.COLLECTIBLES()), address(nft));
        assertEq(mp.auctionMinBidAmount(), 1e6);
        assertTrue(mp.hasRole(mp.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_revertsZeroUsdc() public {
        vm.expectRevert("Zero address: USDC");
        new MarketPlace(address(0), 6, address(nft), admin);
    }

    function test_constructor_revertsZeroCollectibles() public {
        vm.expectRevert("Zero address: collectibles");
        new MarketPlace(address(usdc), 6, address(0), admin);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert("Zero address: admin");
        new MarketPlace(address(usdc), 6, address(nft), address(0));
    }

    // ==================== Auction: Create ====================

    function test_createAuction_success() public {
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);

        assertEq(mp.auctionCounter(), 1);
        assertTrue(mp.isTokenOnSale(TOKEN_ID));
        assertEq(mp.activeAuctionId(TOKEN_ID), 1);
        assertEq(nft.ownerOf(TOKEN_ID), address(mp));

        (address seller,,, uint256 endTime, MarketPlace.AuctionState state,) = mp.auctions(1);
        assertEq(seller, alice);
        assertEq(endTime, block.timestamp + AUCTION_DURATION);
        assertEq(uint256(state), uint256(MarketPlace.AuctionState.Active));
    }

    function test_createAuction_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit MarketPlace.AuctionStarted(TOKEN_ID, 1, alice, AUCTION_DURATION);
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);
    }

    function test_createAuction_revertsDurationTooShort() public {
        vm.prank(alice);
        vm.expectRevert("Duration too short");
        mp.createAuction(TOKEN_ID, 30 minutes);
    }

    function test_createAuction_revertsDurationTooLong() public {
        vm.prank(alice);
        vm.expectRevert("Duration too long");
        mp.createAuction(TOKEN_ID, 31 days);
    }

    function test_createAuction_revertsNotMinted() public {
        vm.prank(alice);
        vm.expectRevert("Not Minted");
        mp.createAuction(999, AUCTION_DURATION);
    }

    function test_createAuction_revertsAlreadyOnSale() public {
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);

        vm.prank(alice);
        vm.expectRevert("Token already on sale");
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);
    }

    // ==================== Auction: Place Bid ====================

    function test_placeBid_firstBid() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 5e6);

        (, uint256 highestBid, address highestBidder,,,) = mp.auctions(1);
        assertEq(highestBid, 5e6);
        assertEq(highestBidder, bob);
        assertEq(usdc.balanceOf(bob), 1000e6 - 5e6);
    }

    function test_placeBid_outbidRefundsPrevious() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 5e6);

        uint256 bobBalBefore = usdc.balanceOf(bob);

        vm.prank(charlie);
        mp.placeBid(TOKEN_ID, 10e6);

        // bob's refund is credited (pull-payment), not pushed
        assertEq(usdc.balanceOf(bob), bobBalBefore);
        assertEq(mp.pendingWithdrawals(bob), 5e6);

        // bob withdraws
        vm.prank(bob);
        mp.withdraw(bob);
        assertEq(usdc.balanceOf(bob), bobBalBefore + 5e6);
        assertEq(mp.pendingWithdrawals(bob), 0);

        (, uint256 highestBid, address highestBidder,,,) = mp.auctions(1);
        assertEq(highestBid, 10e6);
        assertEq(highestBidder, charlie);
    }

    function test_placeBid_sameBidderReplacesTotalAndOnlyCollectsDelta() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 5e6);

        // second bid must still meet minimum (highestBid + 10% = 5.5 USDC)
        uint256 bobBalanceBeforeSecondBid = usdc.balanceOf(bob);
        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 6e6);

        (, uint256 highestBid, address highestBidder,,,) = mp.auctions(1);
        assertEq(highestBid, 6e6); // total bid is replaced, not stacked
        assertEq(highestBidder, bob);
        assertEq(usdc.balanceOf(bob), bobBalanceBeforeSecondBid - 1e6); // only delta is collected
    }

    function test_placeBid_extendsAuctionNearEnd() public {
        _createAuction();

        (,,, uint256 endTimeBefore,,) = mp.auctions(1);

        // warp to within extension threshold (20 min default)
        vm.warp(endTimeBefore - 10 minutes);

        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 5e6);

        (,,, uint256 endTimeAfter,,) = mp.auctions(1);
        assertEq(endTimeAfter, endTimeBefore + mp.auctionDurationExtension());
    }

    function test_placeBid_doesNotExtendWhenFarFromEnd() public {
        _createAuction();

        (,,, uint256 endTimeBefore,,) = mp.auctions(1);

        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 5e6);

        (,,, uint256 endTimeAfter,,) = mp.auctions(1);
        assertEq(endTimeAfter, endTimeBefore);
    }

    function test_placeBid_revertsAfterEnd() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(bob);
        vm.expectRevert("Auction already ended");
        mp.placeBid(TOKEN_ID, 5e6);
    }

    function test_placeBid_revertsBelowMinimum() public {
        _createAuction();

        vm.prank(bob);
        vm.expectRevert("Bid less than minimum");
        mp.placeBid(TOKEN_ID, 0.5e6); // below 1 USDC min
    }

    function test_placeBid_revertsBelowIncrement() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 100e6);

        // min increment is 10% of 100 = 10, so need >= 110
        vm.prank(charlie);
        vm.expectRevert("Bid less than minimum");
        mp.placeBid(TOKEN_ID, 105e6);
    }

    function test_placeBid_revertsNotOnSale() public {
        vm.prank(bob);
        vm.expectRevert("Token not on sale");
        mp.placeBid(TOKEN_ID, 5e6);
    }

    // ==================== Auction: Cancel ====================

    function test_cancelAuction_bySeller() public {
        _createAuction();

        vm.prank(alice);
        mp.cancelAuction(TOKEN_ID);

        assertFalse(mp.isTokenOnSale(TOKEN_ID));
        assertEq(mp.activeAuctionId(TOKEN_ID), 0);
        assertEq(nft.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_byModerator() public {
        _createAuction();

        vm.prank(moderator);
        mp.cancelAuction(TOKEN_ID);

        assertFalse(mp.isTokenOnSale(TOKEN_ID));
        assertEq(nft.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_refundsBidder() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 10e6);

        uint256 bobBefore = usdc.balanceOf(bob);

        // once a bid exists, only a moderator may cancel (M-2)
        vm.prank(moderator);
        mp.cancelAuction(TOKEN_ID);

        // refund is credited via pull-payment
        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(mp.pendingWithdrawals(bob), 10e6);

        vm.prank(bob);
        mp.withdraw(bob);
        assertEq(usdc.balanceOf(bob), bobBefore + 10e6);
        assertEq(nft.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_sellerCannotCancelWithBids() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 10e6);

        vm.prank(alice);
        vm.expectRevert("Cannot cancel auction with bids");
        mp.cancelAuction(TOKEN_ID);
    }

    function test_cancelAuction_noBidsReturnsNft() public {
        _createAuction();

        vm.prank(alice);
        mp.cancelAuction(TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_revertsUnauthorized() public {
        _createAuction();

        vm.prank(bob);
        vm.expectRevert("Not authorized");
        mp.cancelAuction(TOKEN_ID);
    }

    function test_cancelAuction_revertsAfterEnd() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert("Auction already ended");
        mp.cancelAuction(TOKEN_ID);
    }

    function test_cancelAuction_emitsEvent() public {
        _createAuction();

        vm.expectEmit(true, true, true, true);
        emit MarketPlace.AuctionCancelled(TOKEN_ID, 1);
        vm.prank(alice);
        mp.cancelAuction(TOKEN_ID);
    }

    // ==================== Auction: Settle ====================

    function test_settleAuction_withBids() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 100e6);
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        uint256 aliceBefore = usdc.balanceOf(alice);

        mp.settleAuction(TOKEN_ID);

        // NFT goes to winner
        assertEq(nft.ownerOf(TOKEN_ID), bob);
        // seller proceeds credited via pull-payment (90% after 10% fee)
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        // protocol fee accrued
        assertEq(mp.feeAccrued(), 10e6);
        // state cleaned up
        assertFalse(mp.isTokenOnSale(TOKEN_ID));
        assertEq(mp.activeAuctionId(TOKEN_ID), 0);
    }

    function test_settleAuction_noBidsReturnsNft() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        mp.settleAuction(TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), alice);
        assertEq(mp.feeAccrued(), 0);
    }

    function test_settleAuction_revertsBeforeEnd() public {
        _createAuction();

        vm.expectRevert("Auction has not ended");
        mp.settleAuction(TOKEN_ID);
    }

    function test_settleAuction_revertsAlreadySettled() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(TOKEN_ID);

        vm.expectRevert("Token not on sale");
        mp.settleAuction(TOKEN_ID);
    }

    function test_settleAuction_emitsEvent() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.expectEmit(true, true, true, true);
        emit MarketPlace.AuctionSettled(TOKEN_ID, 1);
        mp.settleAuction(TOKEN_ID);
    }

    // ==================== Listing: Create ====================

    function test_createListing_success() public {
        vm.prank(alice);
        mp.createListing(TOKEN_ID, LISTING_PRICE);

        assertEq(mp.listingCounter(), 1);
        assertTrue(mp.isTokenOnSale(TOKEN_ID));
        assertEq(mp.activeListingId(TOKEN_ID), 1);
        assertEq(nft.ownerOf(TOKEN_ID), address(mp));

        (address seller,, uint256 price, MarketPlace.ListingState state,) = mp.listings(1);
        assertEq(seller, alice);
        assertEq(price, LISTING_PRICE);
        assertEq(uint256(state), uint256(MarketPlace.ListingState.Active));
    }

    function test_createListing_revertsZeroPrice() public {
        vm.prank(alice);
        vm.expectRevert("Price must be greater than zero");
        mp.createListing(TOKEN_ID, 0);
    }

    function test_createListing_revertsNotMinted() public {
        vm.prank(alice);
        vm.expectRevert("Not Minted");
        mp.createListing(999, LISTING_PRICE);
    }

    function test_createListing_revertsAlreadyOnSale() public {
        vm.prank(alice);
        mp.createListing(TOKEN_ID, LISTING_PRICE);

        vm.prank(alice);
        vm.expectRevert("Token already on sale");
        mp.createListing(TOKEN_ID, LISTING_PRICE);
    }

    function test_createListing_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit MarketPlace.ListingCreated(TOKEN_ID, 1, alice, LISTING_PRICE);
        vm.prank(alice);
        mp.createListing(TOKEN_ID, LISTING_PRICE);
    }

    // ==================== Listing: Purchase ====================

    function test_purchaseItem_success() public {
        _createListing();

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        mp.purchaseItem(TOKEN_ID);

        // NFT to buyer
        assertEq(nft.ownerOf(TOKEN_ID), bob);
        // seller proceeds credited via pull-payment (90 USDC after 10% fee on 100)
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        // buyer paid 100 USDC
        assertEq(usdc.balanceOf(bob), bobBefore - LISTING_PRICE);
        // fee accrued
        assertEq(mp.feeAccrued(), 10e6);
        // state cleaned
        assertFalse(mp.isTokenOnSale(TOKEN_ID));
    }

    function test_purchaseItem_revertsNotOnSale() public {
        vm.prank(bob);
        vm.expectRevert("Token not on sale");
        mp.purchaseItem(TOKEN_ID);
    }

    function test_purchaseItem_emitsEvent() public {
        _createListing();

        vm.expectEmit(true, true, false, false);
        emit MarketPlace.ListingPurchased(TOKEN_ID, 1, block.timestamp);
        vm.prank(bob);
        mp.purchaseItem(TOKEN_ID);
    }

    // ==================== Listing: Cancel ====================

    function test_cancelListing_bySeller() public {
        _createListing();

        vm.prank(alice);
        mp.cancelListing(TOKEN_ID);

        assertFalse(mp.isTokenOnSale(TOKEN_ID));
        assertEq(nft.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelListing_byModerator() public {
        _createListing();

        vm.prank(moderator);
        mp.cancelListing(TOKEN_ID);

        assertFalse(mp.isTokenOnSale(TOKEN_ID));
        assertEq(nft.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelListing_revertsUnauthorized() public {
        _createListing();

        vm.prank(bob);
        vm.expectRevert("Not authorized");
        mp.cancelListing(TOKEN_ID);
    }

    function test_cancelListing_emitsEvent() public {
        _createListing();

        vm.expectEmit(true, true, false, false);
        emit MarketPlace.ListingCancelled(TOKEN_ID, 1, block.timestamp);
        vm.prank(alice);
        mp.cancelListing(TOKEN_ID);
    }

    // ==================== Admin: Protocol Fees ====================

    function test_collectProtocolFees_success() public {
        // generate fees via a listing purchase
        _createListing();
        vm.prank(bob);
        mp.purchaseItem(TOKEN_ID);

        address treasury = makeAddr("treasury");
        uint256 fees = mp.feeAccrued();
        assertGt(fees, 0);

        vm.prank(admin);
        mp.collectProtocolFees(treasury);

        assertEq(usdc.balanceOf(treasury), fees);
        assertEq(mp.feeAccrued(), 0);
    }

    function test_collectProtocolFees_revertsNoFees() public {
        vm.prank(admin);
        vm.expectRevert("No fees to collect");
        mp.collectProtocolFees(makeAddr("treasury"));
    }

    function test_collectProtocolFees_revertsZeroReceiver() public {
        // generate some fees first
        _createListing();
        vm.prank(bob);
        mp.purchaseItem(TOKEN_ID);

        vm.prank(admin);
        vm.expectRevert("Zero address: receiver");
        mp.collectProtocolFees(address(0));
    }

    function test_collectProtocolFees_revertsNonAdmin() public {
        vm.prank(bob);
        vm.expectRevert();
        mp.collectProtocolFees(bob);
    }

    // ==================== Admin: Setters ====================

    function test_setProtocolFee() public {
        vm.prank(admin);
        mp.setProtocolFee(500); // 5%
        assertEq(mp.protocolFeeBps(), 500);
    }

    function test_setProtocolFee_revertsOverMax() public {
        vm.prank(admin);
        vm.expectRevert("Fee exceeds maximum");
        mp.setProtocolFee(2_001); // above MAX_PROTOCOL_FEE_BPS (20%)
    }

    function test_setAuctionMinBidAmount() public {
        vm.prank(admin);
        mp.setAuctionMinBidAmount(5e6);
        assertEq(mp.auctionMinBidAmount(), 5e6);
    }

    function test_setAuctionMinBidIncrementBps() public {
        vm.prank(admin);
        mp.setAuctionMinBidIncrementBps(500);
        assertEq(mp.auctionMinBidIncrementBps(), 500);
    }

    function test_setAuctionMinBidIncrementBps_revertsOver100() public {
        vm.prank(admin);
        vm.expectRevert("Increment exceeds 100%");
        mp.setAuctionMinBidIncrementBps(10_001);
    }

    function test_setAuctionDurationExtension() public {
        vm.prank(admin);
        mp.setAuctionDurationExtension(10 minutes);
        assertEq(mp.auctionDurationExtension(), 10 minutes);
    }

    function test_setAuctionDurationExtensionThreshold() public {
        vm.prank(admin);
        mp.setAuctionDurationExtensionThreshold(30 minutes);
        assertEq(mp.auctionDurationExtensionThreshold(), 30 minutes);
    }

    function test_setAuctionMinDuration() public {
        vm.prank(admin);
        mp.setAuctionMinDuration(2 hours);
        assertEq(mp.auctionMinDuration(), 2 hours);
    }

    function test_setAuctionMinDuration_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("Duration must be > 0");
        mp.setAuctionMinDuration(0);
    }

    function test_setAuctionMinDuration_revertsExceedsMax() public {
        vm.prank(admin);
        vm.expectRevert("Min exceeds max");
        mp.setAuctionMinDuration(31 days);
    }

    function test_setAuctionMaxDuration() public {
        vm.prank(admin);
        mp.setAuctionMaxDuration(60 days);
        assertEq(mp.auctionMaxDuration(), 60 days);
    }

    function test_setAuctionMaxDuration_revertsBelowMin() public {
        vm.prank(admin);
        vm.expectRevert("Max below min");
        mp.setAuctionMaxDuration(30 minutes);
    }

    function test_admin_setters_revertNonAdmin() public {
        vm.startPrank(bob);
        vm.expectRevert();
        mp.setProtocolFee(0);
        vm.expectRevert();
        mp.setAuctionMinBidAmount(0);
        vm.expectRevert();
        mp.setAuctionMinBidIncrementBps(0);
        vm.expectRevert();
        mp.setAuctionDurationExtension(0);
        vm.expectRevert();
        mp.setAuctionDurationExtensionThreshold(0);
        vm.expectRevert();
        mp.setAuctionMinDuration(1);
        vm.expectRevert();
        mp.setAuctionMaxDuration(1 hours);
        vm.stopPrank();
    }

    // ==================== Integration / E2E ====================

    function test_fullAuctionFlow() public {
        // Alice creates auction
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);

        // Bob bids 50
        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 50e6);

        // Charlie outbids with 100
        vm.prank(charlie);
        mp.placeBid(TOKEN_ID, 100e6);

        // Bob's outbid refund is credited (pull-payment); claim it
        assertEq(usdc.balanceOf(bob), 1000e6 - 50e6);
        assertEq(mp.pendingWithdrawals(bob), 50e6);
        vm.prank(bob);
        mp.withdraw(bob);
        assertEq(usdc.balanceOf(bob), 1000e6);

        // Fast-forward past end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // Anyone settles
        mp.settleAuction(TOKEN_ID);

        // Charlie wins NFT
        assertEq(nft.ownerOf(TOKEN_ID), charlie);
        // Alice's proceeds credited (100 - 10% fee); claim them
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        assertEq(mp.feeAccrued(), 10e6);

        // Admin collects fees
        address treasury = makeAddr("treasury");
        vm.prank(admin);
        mp.collectProtocolFees(treasury);
        assertEq(usdc.balanceOf(treasury), 10e6);
    }

    function test_fullListingFlow() public {
        // Alice lists
        vm.prank(alice);
        mp.createListing(TOKEN_ID, LISTING_PRICE);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // Bob buys
        vm.prank(bob);
        mp.purchaseItem(TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), bob);
        // seller proceeds credited via pull-payment
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        assertEq(mp.feeAccrued(), 10e6);
    }

    function test_relistAfterCancel() public {
        // Create and cancel auction
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);
        vm.prank(alice);
        mp.cancelAuction(TOKEN_ID);

        // Should be able to create a listing for the same token
        vm.prank(alice);
        mp.createListing(TOKEN_ID, LISTING_PRICE);

        assertTrue(mp.isTokenOnSale(TOKEN_ID));
        assertEq(nft.ownerOf(TOKEN_ID), address(mp));
    }

    function test_multipleAuctionsSequential() public {
        // First auction settled with no bids
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), alice);

        // Alice can auction again
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);
        assertEq(mp.auctionCounter(), 2);
    }

    // ==================== Withdraw (pull-payment) ====================

    function test_withdraw_revertsNothingToWithdraw() public {
        vm.prank(bob);
        vm.expectRevert("Nothing to withdraw");
        mp.withdraw(bob);
    }

    function test_withdraw_revertsZeroReceiver() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 5e6);
        vm.prank(charlie);
        mp.placeBid(TOKEN_ID, 10e6);

        vm.prank(bob);
        vm.expectRevert("Zero address: receiver");
        mp.withdraw(address(0));
    }

    function test_withdraw_emitsEvent() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 5e6);
        vm.prank(charlie);
        mp.placeBid(TOKEN_ID, 10e6);

        vm.expectEmit(true, false, false, true);
        emit MarketPlace.Withdrawal(bob, bob, 5e6);
        vm.prank(bob);
        mp.withdraw(bob);
    }

    // ==================== Fee snapshot (M-3) ====================

    function test_feeSnapshot_listingUsesRateAtCreation() public {
        // list at the default 10% fee
        _createListing();

        // admin lowers the fee afterwards; in-flight listing must keep its 10%
        vm.prank(admin);
        mp.setProtocolFee(0);

        vm.prank(bob);
        mp.purchaseItem(TOKEN_ID);

        // fee charged is the snapshotted 10%, not the new 0%
        assertEq(mp.feeAccrued(), 10e6);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
    }

    function test_feeSnapshot_auctionUsesRateAtCreation() public {
        _createAuction();

        // raise fee mid-auction; settlement must use the rate at creation (10%)
        vm.prank(admin);
        mp.setProtocolFee(MAX_FEE);

        vm.prank(bob);
        mp.placeBid(TOKEN_ID, 100e6);
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(TOKEN_ID);

        assertEq(mp.feeAccrued(), 10e6); // 10% snapshot, not 20%
        assertEq(mp.pendingWithdrawals(alice), 90e6);
    }

    // ==================== Helpers ====================

    function _createAuction() internal {
        vm.prank(alice);
        mp.createAuction(TOKEN_ID, AUCTION_DURATION);
    }

    function _createListing() internal {
        vm.prank(alice);
        mp.createListing(TOKEN_ID, LISTING_PRICE);
    }
}
