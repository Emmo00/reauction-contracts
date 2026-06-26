// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/MarketPlace.sol";

contract DeployMarketPlace is Script {
    struct DeploymentConfig {
        address collectible;
        address usdc;
        uint256 usdcDecimals;
        address admin;
    }

    function getDeploymentConfig() internal view returns (DeploymentConfig memory config) {
        string memory network = vm.envOr("NETWORK", string("testnet"));

        if (keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("mainnet"))) {
            config.collectible = vm.envAddress("MAINNET_COLLECTIBLE");
            config.usdc = vm.envAddress("MAINNET_USDC");
            config.admin = vm.envAddress("MAINNET_OWNER");
            config.usdcDecimals = vm.envUint("MAINNET_USDC_DECIMALS");
        } else {
            config.collectible = vm.envAddress("TESTNET_COLLECTIBLE");
            config.usdc = vm.envAddress("TESTNET_USDC");
            config.admin = vm.envAddress("TESTNET_OWNER");
            config.usdcDecimals = vm.envUint("TESTNET_USDC_DECIMALS");
        }

        console.log("Network:", network);
        console.log("Collectible:", config.collectible);
        console.log("USDC:", config.usdc);
        console.log("Admin:", config.admin);
        console.log("USDC Decimals:", config.usdcDecimals);
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        DeploymentConfig memory config = getDeploymentConfig();

        MarketPlace marketplace = new MarketPlace(config.usdc, config.usdcDecimals, config.collectible, config.admin);

        console.log("MarketPlace deployed at:", address(marketplace));

        vm.stopBroadcast();
    }
}
