// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MultiCollectionMarketplace as Marketplace} from "../src/MultiCollectionMarketplace.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockRevertingUSDC} from "./mocks/MockRevertingUSDC.sol";
import {MockCollectible} from "./mocks/MockCollectible.sol";

contract MultiCollectionMarketplaceTest is Test {
    Marketplace internal mp;
    Marketplace internal revMp;
    MockUSDC internal usdc;
    MockRevertingUSDC internal revUsdc;
    MockCollectible internal nftA; // collection id 1
    MockCollectible internal nftB; // collection id 2

    address admin = makeAddr("admin");
    address moderator = makeAddr("moderator");
    address alice = makeAddr("alice"); // seller
    address bob = makeAddr("bob"); // buyer / bidder
    address charlie = makeAddr("charlie"); // second bidder

    uint256 constant COLLECTION_A = 1;
    uint256 constant COLLECTION_B = 2;

    uint256 constant TOKEN_ID = 1;
    uint256 constant TOKEN_ID_2 = 2;
    uint256 constant AUCTION_DURATION = 2 hours;
    uint256 constant LISTING_PRICE = 100e6; // 100 USDC
    uint16 constant MAX_FEE = 2_000; // MAX_PROTOCOL_FEE_BPS (20%)

    function setUp() public {
        usdc = new MockUSDC();
        nftA = new MockCollectible();
        nftB = new MockCollectible();

        // nftA is the initial collection (id 1); nftB registered explicitly (id 2).
        mp = new Marketplace(address(usdc), 6, admin, address(nftA));
        vm.prank(admin);
        mp.addCollection(address(nftB));
        assertEq(mp.collectionCounter(), 2);

        bytes32 modRole = mp.MODERATOR_ROLE();
        vm.prank(admin);
        mp.grantRole(modRole, moderator);

        // mint NFTs to alice
        nftA.mint(alice, TOKEN_ID);
        nftA.mint(alice, TOKEN_ID_2);
        nftB.mint(alice, TOKEN_ID);

        // fund accounts with USDC
        usdc.mint(bob, 1000e6);
        usdc.mint(charlie, 1000e6);

        // approve marketplace for NFT transfers
        vm.prank(alice);
        nftA.setApprovalForAll(address(mp), true);
        vm.prank(alice);
        nftB.setApprovalForAll(address(mp), true);

        // approve marketplace for USDC transfers
        vm.prank(bob);
        usdc.approve(address(mp), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(mp), type(uint256).max);

        // Marketplace backed by a USDC that can be made to fail outgoing transfers.
        revUsdc = new MockRevertingUSDC();
        revMp = new Marketplace(address(revUsdc), 6, admin, address(nftA));
        bytes32 revModRole = revMp.MODERATOR_ROLE();
        vm.prank(admin);
        revMp.grantRole(revModRole, moderator);
        revUsdc.mint(bob, 1000e6);
        revUsdc.mint(charlie, 1000e6);
        vm.prank(alice);
        nftA.setApprovalForAll(address(revMp), true);
        vm.prank(bob);
        revUsdc.approve(address(revMp), type(uint256).max);
        vm.prank(charlie);
        revUsdc.approve(address(revMp), type(uint256).max);
    }

    // ==================== Constructor ====================

    function test_constructor_setsImmutables() public view {
        assertEq(address(mp.USDC()), address(usdc));
        assertEq(mp.usdcDecimals(), 6);
        assertEq(mp.auctionMinBidIncrementAmount(), 1e6);
        assertEq(mp.auctionMinBidAmount(), 1e6);
        assertEq(uint256(mp.auctionMinBidIncrementBps()), 1_000);
        assertEq(uint256(mp.protocolFeeBps()), 1_000);
        assertTrue(mp.hasRole(mp.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(mp.hasRole(mp.MODERATOR_ROLE(), admin));
        assertFalse(mp.paused());
    }

    function test_constructor_addsInitialCollection() public view {
        assertEq(mp.collectionCounter(), COLLECTION_B);
        assertTrue(mp.isCollectionRegistered(address(nftA)));
        assertTrue(mp.isCollectionRegistered(address(nftB)));
        assertEq(mp.collectionIdOf(address(nftA)), COLLECTION_A);
        assertEq(mp.collectionIdOf(address(nftB)), COLLECTION_B);
        assertTrue(mp.isActiveCollection(address(nftA)));
    }

    function test_constructor_revertsZeroUsdc() public {
        vm.expectRevert(Marketplace.ZeroAddress.selector);
        new Marketplace(address(0), 6, admin, address(nftA));
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(Marketplace.ZeroAddress.selector);
        new Marketplace(address(usdc), 6, address(0), address(nftA));
    }

    function test_constructor_skipsInitialCollectionWhenZero() public {
        Marketplace empty = new Marketplace(address(usdc), 6, admin, address(0));
        assertEq(empty.collectionCounter(), 0);
    }

    // ==================== Collection Management ====================

    function test_addCollection_success() public {
        MockCollectible nftC = new MockCollectible();
        uint256 before = mp.collectionCounter();

        vm.prank(admin);
        uint256 id = mp.addCollection(address(nftC));

        assertEq(id, before + 1);
        assertEq(mp.collectionCounter(), before + 1);
        assertTrue(mp.isCollectionRegistered(address(nftC)));
        assertEq(mp.collectionIdOf(address(nftC)), id);
        assertTrue(mp.isActiveCollection(address(nftC)));
    }

    function test_addCollection_emitsEvent() public {
        MockCollectible nftC = new MockCollectible();

        vm.expectEmit(true, true, true, true);
        emit Marketplace.CollectionAdded(3, address(nftC), true);
        vm.prank(admin);
        mp.addCollection(address(nftC));
    }

    function test_addCollection_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Marketplace.ZeroAddress.selector);
        mp.addCollection(address(0));
    }

    function test_addCollection_revertsAlreadyRegistered() public {
        vm.prank(admin);
        vm.expectRevert(Marketplace.CollectionAlreadyRegistered.selector);
        mp.addCollection(address(nftA));
    }

    function test_addCollection_revertsUnsupported() public {
        // MockUSDC does not implement the ERC-721 interface
        vm.prank(admin);
        vm.expectRevert(Marketplace.UnsupportedCollection.selector);
        mp.addCollection(address(usdc));
    }

    function test_addCollection_revertsNonAdmin() public {
        MockCollectible nftC = new MockCollectible();
        vm.prank(bob);
        vm.expectRevert();
        mp.addCollection(address(nftC));
    }

    function test_setCollectionActive_deactivateAndReactivate() public {
        vm.prank(admin);
        mp.setCollectionActive(COLLECTION_A, false);
        assertFalse(mp.isActiveCollection(address(nftA)));

        vm.prank(admin);
        mp.setCollectionActive(COLLECTION_A, true);
        assertTrue(mp.isActiveCollection(address(nftA)));
    }

    function test_setCollectionActive_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Marketplace.CollectionStatusChanged(COLLECTION_A, address(nftA), false);
        vm.prank(admin);
        mp.setCollectionActive(COLLECTION_A, false);
    }

    function test_setCollectionActive_revertsNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(Marketplace.CollectionNotRegistered.selector);
        mp.setCollectionActive(99, false);
    }

    function test_setCollectionActive_revertsNonAdmin() public {
        vm.prank(bob);
        vm.expectRevert();
        mp.setCollectionActive(COLLECTION_A, false);
    }

    function test_getCollection() public view {
        (address token, bool active) = mp.getCollection(COLLECTION_A);
        assertEq(token, address(nftA));
        assertTrue(active);
    }

    function test_getCollection_revertsNotRegistered() public {
        vm.expectRevert(Marketplace.CollectionNotRegistered.selector);
        mp.getCollection(0);
    }

    function test_isActiveCollection_unregisteredReturnsFalse() public view {
        assertFalse(mp.isActiveCollection(address(usdc)));
    }

    // ==================== Multi-collection namespacing ====================

    function test_sameTokenCanBeOnSaleInTwoCollections() public {
        // alice lists TOKEN_ID in collection A and auctions TOKEN_ID in collection B
        vm.prank(alice);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);

        vm.prank(alice);
        mp.createAuction(COLLECTION_B, TOKEN_ID, AUCTION_DURATION);

        assertTrue(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertTrue(mp.isTokenOnSale(COLLECTION_B, TOKEN_ID));

        // settle B's auction without disturbing A's listing
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(COLLECTION_B, TOKEN_ID);

        assertTrue(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertFalse(mp.isTokenOnSale(COLLECTION_B, TOKEN_ID));
    }

    function test_activeAuctionIndependentPerCollection() public {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
        vm.prank(alice);
        mp.createAuction(COLLECTION_B, TOKEN_ID, AUCTION_DURATION);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
        vm.prank(bob);
        mp.placeBid(COLLECTION_B, TOKEN_ID, 9e6);

        (, uint256 bidA,,,,) = mp.auctions(1);
        (, uint256 bidB,,,,) = mp.auctions(2);
        assertEq(bidA, 5e6);
        assertEq(bidB, 9e6);
    }

    // ==================== Auction: Create ====================

    function test_createAuction_success() public {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);

        assertEq(mp.auctionCounter(), 1);
        assertTrue(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(mp.activeAuctionId(COLLECTION_A, TOKEN_ID), 1);
        assertEq(nftA.ownerOf(TOKEN_ID), address(mp));

        (address seller,,, uint256 endTime, Marketplace.AuctionState state,) = mp.auctions(1);
        assertEq(seller, alice);
        assertEq(endTime, block.timestamp + AUCTION_DURATION);
        assertEq(uint256(state), uint256(Marketplace.AuctionState.Active));
    }

    function test_createAuction_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Marketplace.AuctionStarted(COLLECTION_A, TOKEN_ID, 1, alice, AUCTION_DURATION);
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
    }

    function test_createAuction_revertsDurationTooShort() public {
        vm.prank(alice);
        vm.expectRevert(Marketplace.AuctionTooShort.selector);
        mp.createAuction(COLLECTION_A, TOKEN_ID, 30 minutes);
    }

    function test_createAuction_revertsDurationTooLong() public {
        vm.prank(alice);
        vm.expectRevert(Marketplace.AuctionTooLong.selector);
        // default max duration is 6 months (30 days * 6); 181 days exceeds it
        mp.createAuction(COLLECTION_A, TOKEN_ID, 181 days);
    }

    function test_createAuction_revertsNotOwner() public {
        // bob owns no NFT; the safeTransferFrom escrow call reverts
        vm.prank(bob);
        vm.expectRevert();
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
    }

    function test_createAuction_revertsInactiveCollection() public {
        vm.prank(admin);
        mp.setCollectionActive(COLLECTION_A, false);

        vm.prank(alice);
        vm.expectRevert(Marketplace.CollectionInactive.selector);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
    }

    function test_createAuction_revertsUnregisteredCollection() public {
        vm.prank(alice);
        vm.expectRevert(Marketplace.CollectionNotRegistered.selector);
        mp.createAuction(99, TOKEN_ID, AUCTION_DURATION);
    }

    function test_createAuction_revertsAlreadyOnSale() public {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
        vm.prank(alice);
        vm.expectRevert(Marketplace.TokenAlreadyOnSale.selector);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
    }

    // ==================== Auction: Place Bid ====================

    function test_placeBid_firstBid() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);

        (, uint256 highestBid, address highestBidder,,,) = mp.auctions(1);
        assertEq(highestBid, 5e6);
        assertEq(highestBidder, bob);
        assertEq(usdc.balanceOf(bob), 1000e6 - 5e6);
    }

    function test_placeBid_outbidRefundsPrevious() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);

        uint256 bobBalBefore = usdc.balanceOf(bob);

        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 10e6);

        // bob's refund is credited (pull-payment), not pushed
        assertEq(usdc.balanceOf(bob), bobBalBefore);
        assertEq(mp.pendingWithdrawals(bob), 5e6);

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
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);

        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 6e6);

        (, uint256 highestBid, address highestBidder,,,) = mp.auctions(1);
        assertEq(highestBid, 6e6);
        assertEq(highestBidder, bob);
        assertEq(usdc.balanceOf(bob), bobBalBefore - 1e6);
    }

    function test_placeBid_extendsAuctionNearEnd() public {
        _createAuction();

        (,,, uint256 endTimeBefore,,) = mp.auctions(1);
        vm.warp(endTimeBefore - 10 minutes);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);

        (,,, uint256 endTimeAfter,,) = mp.auctions(1);
        assertEq(endTimeAfter, endTimeBefore + mp.auctionDurationExtension());
    }

    function test_placeBid_doesNotExtendWhenFarFromEnd() public {
        _createAuction();

        (,,, uint256 endTimeBefore,,) = mp.auctions(1);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);

        (,,, uint256 endTimeAfter,,) = mp.auctions(1);
        assertEq(endTimeAfter, endTimeBefore);
    }

    function test_placeBid_revertsAfterEnd() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(bob);
        vm.expectRevert(Marketplace.AuctionAlreadyEnded.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
    }

    function test_placeBid_revertsBelowMinimum() public {
        _createAuction();

        vm.prank(bob);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 0.5e6);
    }

    function test_placeBid_revertsBelowIncrement() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 100e6);

        vm.prank(charlie);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 105e6);
    }

    function test_placeBid_revertsNotOnSale() public {
        vm.prank(bob);
        vm.expectRevert(Marketplace.TokenNotOnSale.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
    }

    // ==================== Auction: Bid increment (fixed $1 or 10%) ====================

    function test_bidIncrement_initialBidAtMinimumSucceeds() public {
        _createAuction();

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 1e6);

        (, uint256 highestBid,,,,) = mp.auctions(1);
        assertEq(highestBid, 1e6);
    }

    function test_bidIncrement_initialBidBelowMinimumReverts() public {
        _createAuction();

        vm.prank(bob);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 1e6 - 1);
    }

    function test_bidIncrement_table() public {
        // highestBid => minimum next bid (in USDC base units)
        uint256[2][7] memory cases = [
            [uint256(1e6), uint256(2e6)],
            [uint256(5e6), uint256(6e6)],
            [uint256(9e6), uint256(10e6)],
            [uint256(10e6), uint256(11e6)],
            [uint256(20e6), uint256(22e6)],
            [uint256(50e6), uint256(55e6)],
            [uint256(100e6), uint256(110e6)]
        ];

        uint256 tokenId = 10;
        for (uint256 i = 0; i < cases.length; i++) {
            nftA.mint(alice, tokenId);
            _assertNextMinimum(tokenId, cases[i][0], cases[i][1]);
            tokenId++;
        }
    }

    function test_bidIncrement_tenPercentAppliesAboveTenUsdc() public {
        // At 11 USDC the 10% (1.1 USDC) exceeds the fixed $1, so min next = 12.1 USDC.
        nftA.mint(alice, 100);
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, 100, AUCTION_DURATION);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, 100, 11e6);

        vm.prank(charlie);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, 100, 12e6);

        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, 100, 12_100_000);
    }

    function test_bidIncrement_customMinBidAmountAppliesToInitialBidOnly() public {
        vm.prank(admin);
        mp.setAuctionMinBidAmount(5e6);
        _createAuction();

        // First bid must meet the configured minimum (no accidental +10%).
        vm.prank(bob);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 1e6);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
    }

    function test_bidIncrement_ignoresMinBidAmountForLaterBids() public {
        vm.prank(admin);
        mp.setAuctionMinBidAmount(20e6);
        _createAuction();

        // First bid at the raised minimum.
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 20e6);

        // Later bids use max($1, 10%) of the highest bid, not the raised floor:
        // minimum next = 20e6 + max(1e6, 2e6) = 22e6. A 21e6 bid must revert.
        vm.prank(charlie);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 21e6);

        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 22e6);
    }

    // ==================== Auction: Increment percentage config ====================

    function test_setAuctionMinBidIncrementBps_success() public {
        vm.expectEmit(true, true, true, true);
        emit Marketplace.AuctionMinBidIncrementBpsUpdated(1_000, 2_000);
        vm.prank(admin);
        mp.setAuctionMinBidIncrementBps(2_000);

        assertEq(uint256(mp.auctionMinBidIncrementBps()), 2_000);
    }

    function test_setAuctionMinBidIncrementBps_revertsOver100Percent() public {
        vm.prank(admin);
        vm.expectRevert(Marketplace.IncrementTooHigh.selector);
        mp.setAuctionMinBidIncrementBps(10_001);
    }

    function test_setAuctionMinBidIncrementBps_revertsNonAdmin() public {
        vm.prank(bob);
        vm.expectRevert();
        mp.setAuctionMinBidIncrementBps(2_000);
    }

    function test_bidIncrement_usesConfiguredPercentage() public {
        vm.prank(admin);
        mp.setAuctionMinBidIncrementBps(2_000); // 20%

        nftA.mint(alice, 200);
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, 200, AUCTION_DURATION);

        // First bid at the fixed $1 floor.
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, 200, 1e6);

        // 20% of 1 USDC (0.2) < $1, so the $1 floor still applies: min next = 2 USDC.
        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, 200, 2e6);

        // At 100 USDC, 20% (20 USDC) exceeds $1: min next = 120 USDC.
        nftA.mint(alice, 201);
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, 201, AUCTION_DURATION);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, 201, 100e6);

        vm.prank(charlie);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, 201, 110e6);

        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, 201, 120e6);
    }

    // ==================== Auction: Cancel ====================

    function test_cancelAuction_bySeller() public {
        _createAuction();

        vm.prank(alice);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);

        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(mp.activeAuctionId(COLLECTION_A, TOKEN_ID), 0);
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_byModerator() public {
        _createAuction();

        vm.prank(moderator);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);

        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_refundsBidder() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 10e6);

        uint256 bobBefore = usdc.balanceOf(bob);

        // once a bid exists, only a moderator may cancel
        vm.prank(moderator);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);

        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(mp.pendingWithdrawals(bob), 10e6);

        vm.prank(bob);
        mp.withdraw(bob);
        assertEq(usdc.balanceOf(bob), bobBefore + 10e6);
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_sellerCannotCancelWithBids() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 10e6);

        vm.prank(alice);
        vm.expectRevert(Marketplace.Unauthorized.selector);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);
    }

    function test_cancelAuction_revertsUnauthorized() public {
        _createAuction();

        vm.prank(bob);
        vm.expectRevert(Marketplace.Unauthorized.selector);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);
    }

    function test_cancelAuction_revertsAfterEnd() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(Marketplace.AuctionAlreadyEnded.selector);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);
    }

    function test_cancelAuction_emitsEvent() public {
        _createAuction();

        vm.expectEmit(true, true, true, true);
        emit Marketplace.AuctionCancelled(COLLECTION_A, TOKEN_ID, 1);
        vm.prank(alice);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);
    }

    // ==================== Auction: Settle ====================

    function test_settleAuction_withBids() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 100e6);
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        uint256 aliceBefore = usdc.balanceOf(alice);

        mp.settleAuction(COLLECTION_A, TOKEN_ID);

        assertEq(nftA.ownerOf(TOKEN_ID), bob);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        assertEq(mp.feeAccrued(), 10e6);
        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(mp.activeAuctionId(COLLECTION_A, TOKEN_ID), 0);
    }

    function test_settleAuction_noBidsReturnsNft() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        mp.settleAuction(COLLECTION_A, TOKEN_ID);

        assertEq(nftA.ownerOf(TOKEN_ID), alice);
        assertEq(mp.feeAccrued(), 0);
    }

    function test_settleAuction_revertsBeforeEnd() public {
        _createAuction();

        vm.expectRevert(Marketplace.AuctionNotEnded.selector);
        mp.settleAuction(COLLECTION_A, TOKEN_ID);
    }

    function test_settleAuction_revertsAlreadySettled() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(COLLECTION_A, TOKEN_ID);

        vm.expectRevert(Marketplace.TokenNotOnSale.selector);
        mp.settleAuction(COLLECTION_A, TOKEN_ID);
    }

    function test_settleAuction_emitsEvent() public {
        _createAuction();
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.expectEmit(true, true, true, true);
        emit Marketplace.AuctionSettled(COLLECTION_A, TOKEN_ID, 1);
        mp.settleAuction(COLLECTION_A, TOKEN_ID);
    }

    // ==================== Listing: Create ====================

    function test_createListing_success() public {
        vm.prank(alice);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);

        assertEq(mp.listingCounter(), 1);
        assertTrue(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(mp.activeListingId(COLLECTION_A, TOKEN_ID), 1);
        assertEq(nftA.ownerOf(TOKEN_ID), address(mp));

        (address seller,, uint256 price, Marketplace.ListingState state,) = mp.listings(1);
        assertEq(seller, alice);
        assertEq(price, LISTING_PRICE);
        assertEq(uint256(state), uint256(Marketplace.ListingState.Active));
    }

    function test_createListing_revertsZeroPrice() public {
        vm.prank(alice);
        vm.expectRevert(Marketplace.InvalidPrice.selector);
        mp.createListing(COLLECTION_A, TOKEN_ID, 0);
    }

    function test_createListing_revertsInactiveCollection() public {
        vm.prank(admin);
        mp.setCollectionActive(COLLECTION_A, false);

        vm.prank(alice);
        vm.expectRevert(Marketplace.CollectionInactive.selector);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);
    }

    function test_createListing_revertsAlreadyOnSale() public {
        vm.prank(alice);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);
        vm.prank(alice);
        vm.expectRevert(Marketplace.TokenAlreadyOnSale.selector);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);
    }

    function test_createListing_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Marketplace.ListingCreated(COLLECTION_A, TOKEN_ID, 1, alice, LISTING_PRICE);
        vm.prank(alice);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);
    }

    // ==================== Listing: Purchase ====================

    function test_purchaseItem_success() public {
        _createListing();

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);

        assertEq(nftA.ownerOf(TOKEN_ID), bob);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        assertEq(usdc.balanceOf(bob), bobBefore - LISTING_PRICE);
        assertEq(mp.feeAccrued(), 10e6);
        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
    }

    function test_purchaseItem_revertsNotOnSale() public {
        vm.prank(bob);
        vm.expectRevert(Marketplace.TokenNotOnSale.selector);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);
    }

    function test_purchaseItem_emitsEvent() public {
        _createListing();

        vm.expectEmit(true, true, true, true);
        emit Marketplace.ListingPurchased(COLLECTION_A, TOKEN_ID, 1, bob, LISTING_PRICE);
        vm.prank(bob);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);
    }

    // ==================== Listing: Cancel ====================

    function test_cancelListing_bySeller() public {
        _createListing();

        vm.prank(alice);
        mp.cancelListing(COLLECTION_A, TOKEN_ID);

        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelListing_byModerator() public {
        _createListing();

        vm.prank(moderator);
        mp.cancelListing(COLLECTION_A, TOKEN_ID);

        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelListing_revertsUnauthorized() public {
        _createListing();

        vm.prank(bob);
        vm.expectRevert(Marketplace.Unauthorized.selector);
        mp.cancelListing(COLLECTION_A, TOKEN_ID);
    }

    function test_cancelListing_emitsEvent() public {
        _createListing();

        vm.expectEmit(true, true, true, true);
        emit Marketplace.ListingCancelled(COLLECTION_A, TOKEN_ID, 1);
        vm.prank(alice);
        mp.cancelListing(COLLECTION_A, TOKEN_ID);
    }

    // ==================== Cross-type misuse (M-1 regression) ====================
    // Document current behavior: the wrong function reverts via the sentinel id-0
    // default struct. No funds are at risk. Update if a SaleType enum is added.

    function test_purchaseOnAuction_revertsTokenNotOnSale() public {
        _createAuction();

        vm.prank(bob);
        vm.expectRevert(Marketplace.TokenNotOnSale.selector);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);
    }

    function test_settleOnListing_revertsAuctionNotActive() public {
        _createListing();

        vm.expectRevert(Marketplace.AuctionNotActive.selector);
        mp.settleAuction(COLLECTION_A, TOKEN_ID);
    }

    function test_cancelListingOnAuctionToken_revertsTokenNotOnSale() public {
        _createAuction();

        vm.prank(alice);
        vm.expectRevert(Marketplace.TokenNotOnSale.selector);
        mp.cancelListing(COLLECTION_A, TOKEN_ID);
    }

    function test_cancelAuctionOnListingToken_revertsAuctionNotActive() public {
        _createListing();

        vm.prank(alice);
        vm.expectRevert(Marketplace.AuctionNotActive.selector);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);
    }

    function test_placeBidOnListingToken_revertsAuctionNotActive() public {
        _createListing();

        vm.prank(bob);
        vm.expectRevert(Marketplace.AuctionNotActive.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
    }

    // ==================== Admin: Protocol Fees ====================

    function test_collectProtocolFees_success() public {
        _buy();

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
        vm.expectRevert(Marketplace.NoFeesToCollect.selector);
        mp.collectProtocolFees(makeAddr("treasury"));
    }

    function test_collectProtocolFees_revertsZeroReceiver() public {
        _buy();

        vm.prank(admin);
        vm.expectRevert(Marketplace.ZeroAddress.selector);
        mp.collectProtocolFees(address(0));
    }

    function test_collectProtocolFees_revertsNonAdmin() public {
        vm.prank(bob);
        vm.expectRevert();
        mp.collectProtocolFees(bob);
    }

    // ==================== Withdraw (pull-payment) ====================

    function test_withdraw_revertsNothingToWithdraw() public {
        vm.prank(bob);
        vm.expectRevert(Marketplace.NothingToWithdraw.selector);
        mp.withdraw(bob);
    }

    function test_withdraw_revertsZeroReceiver() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 10e6);

        vm.prank(bob);
        vm.expectRevert(Marketplace.ZeroAddress.selector);
        mp.withdraw(address(0));
    }

    function test_withdraw_emitsEvent() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 10e6);

        vm.expectEmit(true, true, false, true);
        emit Marketplace.Withdrawal(bob, bob, 5e6);
        vm.prank(bob);
        mp.withdraw(bob);
    }

    // ==================== Withdraw: retryable restore on failed transfer ====================

    function test_withdraw_restoresBalanceThenSucceedsRetry() public {
        // Alice auctions, Bob bids 50, Charlie overtops 100 -> Bob owed 50.
        vm.prank(alice);
        revMp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
        vm.prank(bob);
        revMp.placeBid(COLLECTION_A, TOKEN_ID, 50e6);
        vm.prank(charlie);
        revMp.placeBid(COLLECTION_A, TOKEN_ID, 100e6);

        assertEq(revMp.pendingWithdrawals(bob), 50e6);

        // Make outgoing transfers fail; the withdrawal must revert and restore credit.
        revUsdc.failTransfers(true);
        vm.prank(bob);
        vm.expectRevert(Marketplace.TransferFailed.selector);
        revMp.withdraw(bob);
        assertEq(revMp.pendingWithdrawals(bob), 50e6); // restored, retryable

        // Once transfers work again, Bob can withdraw.
        revUsdc.failTransfers(false);
        vm.prank(bob);
        revMp.withdraw(bob);
        assertEq(revMp.pendingWithdrawals(bob), 0);
        assertEq(revUsdc.balanceOf(bob), 1000e6); // 1000 minted - 50 bid + 50 refund
    }

    function test_collectProtocolFees_restoresOnFailedTransfer() public {
        // Generate fees on the reverting-USDC marketplace.
        vm.prank(alice);
        revMp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);
        vm.prank(bob);
        revMp.purchaseItem(COLLECTION_A, TOKEN_ID);
        assertEq(revMp.feeAccrued(), 10e6);

        address treasury = makeAddr("treasury");
        revUsdc.failTransfers(true);
        vm.prank(admin);
        vm.expectRevert(Marketplace.TransferFailed.selector);
        revMp.collectProtocolFees(treasury);
        assertEq(revMp.feeAccrued(), 10e6); // restored

        revUsdc.failTransfers(false);
        vm.prank(admin);
        revMp.collectProtocolFees(treasury);
        assertEq(revMp.feeAccrued(), 0);
        assertEq(revUsdc.balanceOf(treasury), 10e6);
    }

    // ==================== Deactivated collection: existing positions survive ====================

    function test_deactivateCollection_doesNotStrandListing() public {
        _createListing();

        vm.prank(admin);
        mp.setCollectionActive(COLLECTION_A, false);

        vm.prank(bob);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);

        assertEq(nftA.ownerOf(TOKEN_ID), bob);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
    }

    function test_deactivateCollection_cannotCreateNewListing() public {
        vm.prank(admin);
        mp.setCollectionActive(COLLECTION_A, false);

        vm.prank(alice);
        vm.expectRevert(Marketplace.CollectionInactive.selector);
        mp.createListing(COLLECTION_A, TOKEN_ID_2, LISTING_PRICE);
    }

    // ==================== Integration / E2E ====================

    function test_fullAuctionFlow() public {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 50e6);

        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 100e6);

        assertEq(usdc.balanceOf(bob), 1000e6 - 50e6);
        assertEq(mp.pendingWithdrawals(bob), 50e6);
        vm.prank(bob);
        mp.withdraw(bob);
        assertEq(usdc.balanceOf(bob), 1000e6);

        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        uint256 aliceBefore = usdc.balanceOf(alice);

        mp.settleAuction(COLLECTION_A, TOKEN_ID);

        assertEq(nftA.ownerOf(TOKEN_ID), charlie);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        assertEq(mp.feeAccrued(), 10e6);

        address treasury = makeAddr("treasury");
        vm.prank(admin);
        mp.collectProtocolFees(treasury);
        assertEq(usdc.balanceOf(treasury), 10e6);
    }

    function test_fullListingFlow() public {
        vm.prank(alice);
        mp.createListing(COLLECTION_B, TOKEN_ID, LISTING_PRICE);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(bob);
        mp.purchaseItem(COLLECTION_B, TOKEN_ID);

        assertEq(nftB.ownerOf(TOKEN_ID), bob);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
        vm.prank(alice);
        mp.withdraw(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + 90e6);
        assertEq(mp.feeAccrued(), 10e6);
    }

    function test_relistAfterCancel() public {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
        vm.prank(alice);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);

        vm.prank(alice);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);

        assertTrue(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(nftA.ownerOf(TOKEN_ID), address(mp));
    }

    function test_multipleAuctionsSequential() public {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(COLLECTION_A, TOKEN_ID);
        assertEq(nftA.ownerOf(TOKEN_ID), alice);

        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
        assertEq(mp.auctionCounter(), 2);
    }

    // ==================== Fee snapshot (M-3) ====================

    function test_feeSnapshot_listingUsesRateAtCreation() public {
        _createListing();

        vm.prank(admin);
        mp.setProtocolFee(0);

        vm.prank(bob);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);

        assertEq(mp.feeAccrued(), 10e6);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
    }

    function test_feeSnapshot_auctionUsesRateAtCreation() public {
        _createAuction();

        vm.prank(admin);
        mp.setProtocolFee(MAX_FEE);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 100e6);
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(COLLECTION_A, TOKEN_ID);

        assertEq(mp.feeAccrued(), 10e6);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
    }

    // ==================== Pause: control ====================

    function test_pause_admin() public {
        vm.expectEmit(true, true, true, true);
        emit Pausable.Paused(admin);
        vm.prank(admin);
        mp.pause();
        assertTrue(mp.paused());
    }

    function test_pause_revertsNonAdmin() public {
        vm.prank(bob);
        vm.expectRevert();
        mp.pause();
        assertFalse(mp.paused());
    }

    function test_unpause_admin() public {
        vm.prank(admin);
        mp.pause();

        vm.expectEmit(true, true, true, true);
        emit Pausable.Unpaused(admin);
        vm.prank(admin);
        mp.unpause();
        assertFalse(mp.paused());
    }

    function test_unpause_revertsNonAdmin() public {
        _pause();

        vm.prank(bob);
        vm.expectRevert();
        mp.unpause();
        assertTrue(mp.paused());
    }

    function test_pause_revertsWhenAlreadyPaused() public {
        _pause();

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mp.pause();
    }

    function test_unpause_revertsWhenNotPaused() public {
        vm.prank(admin);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        mp.unpause();
    }

    // ==================== Pause: new activity blocked ====================

    function test_createListing_revertsWhenPaused() public {
        _pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);
    }

    function test_purchaseItem_revertsWhenPaused() public {
        _createListing();
        _pause();

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);
    }

    function test_createAuction_revertsWhenPaused() public {
        _pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
    }

    function test_placeBid_revertsWhenPaused() public {
        _createAuction();
        _pause();

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
    }

    // ==================== Pause: recovery still available ====================

    function test_cancelListing_worksWhilePaused() public {
        _createListing();
        _pause();

        vm.prank(alice);
        mp.cancelListing(COLLECTION_A, TOKEN_ID);

        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_worksWhilePaused() public {
        _createAuction();
        _pause();

        vm.prank(alice);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);

        assertFalse(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_cancelAuction_refundsBidderWhilePaused() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 10e6);
        _pause();

        vm.prank(moderator);
        mp.cancelAuction(COLLECTION_A, TOKEN_ID);

        assertEq(mp.pendingWithdrawals(bob), 10e6);
        assertEq(nftA.ownerOf(TOKEN_ID), alice);
    }

    function test_settleAuction_worksWhilePaused() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 100e6);
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        _pause();

        mp.settleAuction(COLLECTION_A, TOKEN_ID);

        assertEq(nftA.ownerOf(TOKEN_ID), bob);
        assertEq(mp.pendingWithdrawals(alice), 90e6);
    }

    function test_withdraw_worksWhilePaused() public {
        _createAuction();
        vm.prank(bob);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 5e6);
        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, TOKEN_ID, 10e6);
        _pause();

        vm.prank(bob);
        mp.withdraw(bob);

        assertEq(mp.pendingWithdrawals(bob), 0);
        assertEq(usdc.balanceOf(bob), 1000e6);
    }

    function test_collectProtocolFees_worksWhilePaused() public {
        _buy();
        _pause();

        address treasury = makeAddr("treasury");
        uint256 fees = mp.feeAccrued();
        vm.prank(admin);
        mp.collectProtocolFees(treasury);

        assertEq(usdc.balanceOf(treasury), fees);
        assertEq(mp.feeAccrued(), 0);
    }

    function test_unpause_restoresFunctionality() public {
        _pause();
        vm.prank(admin);
        mp.unpause();

        _createListing();
        assertTrue(mp.isTokenOnSale(COLLECTION_A, TOKEN_ID));

        vm.prank(bob);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);
        assertEq(nftA.ownerOf(TOKEN_ID), bob);
    }

    // ==================== Helpers ====================

    function _createAuction() internal {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, TOKEN_ID, AUCTION_DURATION);
    }

    function _createListing() internal {
        vm.prank(alice);
        mp.createListing(COLLECTION_A, TOKEN_ID, LISTING_PRICE);
    }

    function _buy() internal {
        _createListing();
        vm.prank(bob);
        mp.purchaseItem(COLLECTION_A, TOKEN_ID);
    }

    function _pause() internal {
        vm.prank(admin);
        mp.pause();
    }

    function _assertNextMinimum(uint256 tokenId, uint256 highest, uint256 minimumNext) internal {
        vm.prank(alice);
        mp.createAuction(COLLECTION_A, tokenId, AUCTION_DURATION);

        vm.prank(bob);
        mp.placeBid(COLLECTION_A, tokenId, highest);

        // One base unit below the required minimum must revert.
        vm.prank(charlie);
        vm.expectRevert(Marketplace.BidTooLow.selector);
        mp.placeBid(COLLECTION_A, tokenId, minimumNext - 1);

        // The exact minimum must succeed.
        vm.prank(charlie);
        mp.placeBid(COLLECTION_A, tokenId, minimumNext);

        uint256 auctionId = mp.activeAuctionId(COLLECTION_A, tokenId);
        (, uint256 newHighest,,,,) = mp.auctions(auctionId);
        assertEq(newHighest, minimumNext);

        // Free the token for the next case by settling.
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        mp.settleAuction(COLLECTION_A, tokenId);
    }
}
