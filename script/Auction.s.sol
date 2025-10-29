// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/Auction.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract Deploy is Script {
    struct DeploymentConfig {
        address collectible;
        address usdc;
        address treasury;
        address owner;
    }

    function getDeploymentConfig() internal view returns (DeploymentConfig memory config) {
        // Check if we're on testnet or mainnet based on environment variables
        string memory network = vm.envOr("NETWORK", string("testnet"));
        
        if (keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("mainnet"))) {
            // Mainnet configuration
            config.collectible = vm.envAddress("MAINNET_COLLECTIBLE");
            config.usdc = vm.envAddress("MAINNET_USDC");
            config.treasury = vm.envAddress("MAINNET_TREASURY");
            config.owner = vm.envAddress("MAINNET_OWNER");
        } else {
            // Testnet configuration (default)
            config.collectible = vm.envAddress("TESTNET_COLLECTIBLE");
            config.usdc = vm.envAddress("TESTNET_USDC");
            config.treasury = vm.envAddress("TESTNET_TREASURY");
            config.owner = vm.envAddress("TESTNET_OWNER");
        }
        
        console.log("Network:", network);
        console.log("Collectible:", config.collectible);
        console.log("USDC:", config.usdc);
        console.log("Treasury:", config.treasury);
        console.log("Owner:", config.owner);
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        DeploymentConfig memory config = getDeploymentConfig();

        address proxy = Upgrades.deployTransparentProxy(
            "Auction.sol",
            config.owner,
            abi.encodeCall(
                Auction.initialize,
                (config.collectible, config.usdc, config.treasury, config.owner)
            )
        );

        console.log("Auction Proxy Address:", proxy);

        vm.stopBroadcast();
    }
}

contract Upgrade is Script {
    function getProxyAddress() internal view returns (address payable) {
        string memory network = vm.envOr("NETWORK", string("testnet"));
        
        if (keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("mainnet"))) {
            return payable(vm.envAddress("MAINNET_PROXY"));
        } else {
            return payable(vm.envAddress("TESTNET_PROXY"));
        }
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address payable proxy = getProxyAddress();
        
        console.log("Upgrading proxy at:", proxy);
        
        vm.startBroadcast(deployerPrivateKey);

        Upgrades.upgradeProxy(
            proxy,
            "Auction.sol",
            ""
        );

        console.log("Upgrade completed for proxy:", proxy);

        vm.stopBroadcast();
    }
}
