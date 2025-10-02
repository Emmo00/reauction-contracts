// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Auction} from "../src/Auction.sol";

contract AuctionScript is Script {
    Auction public auction;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        auction = new Auction();

        vm.stopBroadcast();
    }
}
