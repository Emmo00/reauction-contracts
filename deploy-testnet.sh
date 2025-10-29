#!/bin/bash

# Deploy to Testnet (Base Sepolia)
echo "Deploying to Base Sepolia (Testnet)..."
NETWORK=testnet forge script script/Auction.s.sol:Deploy --rpc-url base_sepolia --broadcast --verify -vvvv

echo "Testnet deployment completed!"