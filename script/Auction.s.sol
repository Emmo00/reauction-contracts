// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/Auction.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract Deploy is Script {
    address collectible = 0x7F8cF2c1FB0A710d71173049816Fd96b4a708d81;
    address usdc = 0xa3d69B7217B096709170f6fc50535e6aBc084f3A;
    address treasury = 0x7b054580aEA6B6cbdF30BbbE84777bae623F4d1e;

    function run() external {
        vm.startBroadcast();

        address proxy = Upgrades.deployTransparentProxy(
            "Auction.sol",
            msg.sender,
            abi.encodeCall(
                Auction.initialize,
                (collectible, usdc, treasury, msg.sender)
            )
        );

        console.log("Proxy Address:", proxy);

        vm.stopBroadcast();
    }
}

contract Upgrade is Script {
    address payable proxy = payable(0xD648cdF47e9534B2FCfb18C1E94CA9AAff07BA0E);

    function run() external {
        vm.startBroadcast();

        Upgrades.upgradeProxy(
            proxy,
            "Auction.sol",
            ""
        );

        vm.stopBroadcast();
    }
}
