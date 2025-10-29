#!/bin/bash

# Upgrade Mainnet Contract
echo "Upgrading contract on Base Mainnet..."
echo "⚠️  WARNING: This will upgrade the MAINNET contract!"
read -p "Are you sure you want to continue? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    NETWORK=mainnet forge script script/Auction.s.sol:Upgrade --rpc-url base_mainnet --broadcast --verify -vvvv
    echo "Mainnet upgrade completed!"
else
    echo "Upgrade cancelled."
fi