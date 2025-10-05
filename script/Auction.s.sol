// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Auction} from "../src/Auction.sol";

contract AuctionScript is Script {
    function setUp() public {}

    function run() public {
        address collectible = 0xf73Ea33263307A45d73B91a51d9eB99d185025Bc; // 0xc011ec7ca575d4f0a2eda595107ab104c7af7a09
        address usdc = 0xa3d69B7217B096709170f6fc50535e6aBc084f3A;
        address treasury = 0x7b054580aEA6B6cbdF30BbbE84777bae623F4d1e;
        address owner = 0x96ae31C307bF441431EAe7906da7714E058C0641;

        vm.startBroadcast();
        Auction auction = new Auction(collectible, usdc, treasury, owner);
        vm.stopBroadcast();

        console.log("Auction deployed at:", address(auction));
    }
}
