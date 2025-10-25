// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "../src/Auction.sol";

contract DeployProxy is Script {
    address collectible = 0xf73Ea33263307A45d73B91a51d9eB99d185025Bc; // 0xc011ec7ca575d4f0a2eda595107ab104c7af7a09
    address usdc = 0xa3d69B7217B096709170f6fc50535e6aBc084f3A;
    address treasury = 0x7b054580aEA6B6cbdF30BbbE84777bae623F4d1e;

    function run() external {
        vm.startBroadcast();

        // Deploy implementation
        Auction impl = new Auction();

        // Deploy ProxyAdmin
        ProxyAdmin admin = new ProxyAdmin(msg.sender);

        // Encode initializer call
        bytes memory data = abi.encodeWithSelector(
            Auction.initialize.selector,
            collectible, // NFT contract
            usdc, // USDC token
            treasury, // Treasury address
            msg.sender // Owner
        );

        // Deploy transparent proxy
        new TransparentUpgradeableProxy(address(impl), address(admin), data);

        vm.stopBroadcast();
    }
}
