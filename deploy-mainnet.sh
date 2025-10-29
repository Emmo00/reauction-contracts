#!/bin/bash

# Deploy to Mainnet (Base Mainnet)
echo "Deploying to Base Mainnet..."
echo "⚠️  WARNING: This will deploy to MAINNET with real funds!"
read -p "Are you sure you want to continue? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    NETWORK=mainnet forge script script/Auction.s.sol:Deploy --rpc-url base_mainnet --broadcast --verify -vvvv
    echo "Mainnet deployment completed!"
else
    echo "Deployment cancelled."
fi