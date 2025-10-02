// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";

contract AuctionTest is Test {
    Auction public auction;

    function setUp() public {
        auction = new Auction();
    }

    function test_Increment() public {
        assertEq(1, 1);
    }

    function testFuzz_SetNumber(uint256 x) public {
        assertEq(x, x);
    }
}
