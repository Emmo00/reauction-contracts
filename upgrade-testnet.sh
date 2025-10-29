#!/bin/bash

# Upgrade Testnet Contract
echo "Upgrading contract on Base Sepolia (Testnet)..."
NETWORK=testnet forge script script/Auction.s.sol:Upgrade --rpc-url base_sepolia --broadcast --verify -vvvv

echo "Testnet upgrade completed!"