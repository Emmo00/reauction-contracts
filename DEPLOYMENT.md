# Deployment Instructions

## Setup

1. Copy the environment example file:
```bash
cp .env.example .env
```

2. Fill in your actual values in `.env`:
   - `PRIVATE_KEY`: Your deployer wallet private key
   - `TESTNET_*`: Testnet configuration (Base Sepolia)
   - `MAINNET_*`: Mainnet configuration (Base Mainnet)
   - `BASESCAN_API_KEY`: For contract verification

## Deployment

### Testnet Deployment (Base Sepolia)
```bash
# Option 1: Using the helper script
./deploy-testnet.sh

# Option 2: Direct command
NETWORK=testnet forge script script/Auction.s.sol:Deploy --rpc-url base_sepolia --broadcast --verify -vvvv
```

### Mainnet Deployment (Base Mainnet)
```bash
# Option 1: Using the helper script (with safety prompt)
./deploy-mainnet.sh

# Option 2: Direct command
NETWORK=mainnet forge script script/Auction.s.sol:Deploy --rpc-url base_mainnet --broadcast --verify -vvvv
```

## Upgrades

### Testnet Upgrade
```bash
# Update TESTNET_PROXY in .env with the proxy address first
./upgrade-testnet.sh
```

### Mainnet Upgrade
```bash
# Update MAINNET_PROXY in .env with the proxy address first
./upgrade-mainnet.sh
```

## Environment Variables Reference

| Variable | Description |
|----------|-------------|
| `NETWORK` | Set to `testnet` or `mainnet` to control deployment target |
| `PRIVATE_KEY` | Deployer wallet private key |
| `TESTNET_COLLECTIBLE` | Collectible NFT contract address on testnet |
| `TESTNET_USDC` | USDC contract address on testnet |
| `TESTNET_TREASURY` | Treasury address for testnet |
| `TESTNET_OWNER` | Contract owner address for testnet |
| `TESTNET_PROXY` | Deployed proxy address on testnet (for upgrades) |
| `MAINNET_*` | Same as testnet but for mainnet |
| `BASESCAN_API_KEY` | API key for contract verification |

## Network Configuration

The `foundry.toml` file is configured with:
- **base_sepolia**: Base Sepolia testnet
- **base_mainnet**: Base mainnet

RPC URLs are loaded from environment variables for flexibility.

## Security Notes

1. Never commit your `.env` file to version control
2. Use a separate deployer wallet with minimal funds
3. Verify all addresses before mainnet deployment
4. Test thoroughly on testnet before mainnet deployment