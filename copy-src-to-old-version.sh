#!/bin/bash

# Script to copy src directory structure to src/old and rename Auction to AuctionOld in the copy
# Author: Generated script
# Date: $(date)

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
TARGET_DIR="$SCRIPT_DIR/src/old"

echo "Starting copy operation..."
echo "Source directory: $SRC_DIR"
echo "Target directory: $TARGET_DIR"

# Check if src directory exists
if [ ! -d "$SRC_DIR" ]; then
    echo "Error: Source directory '$SRC_DIR' does not exist!"
    exit 1
fi

# Create target directory if it doesn't exist
if [ ! -d "$TARGET_DIR" ]; then
    echo "Creating target directory: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

# Copy all files and directories from src to src/old
# Exclude the old directory itself to avoid recursive copying
echo "Copying files..."
rsync -av --exclude='old' "$SRC_DIR/" "$TARGET_DIR/"

# Rename Auction.sol to AuctionOld.sol in the copied version
if [ -f "$TARGET_DIR/Auction.sol" ]; then
    echo "Renaming Auction.sol to AuctionOld.sol in old directory..."
    mv "$TARGET_DIR/Auction.sol" "$TARGET_DIR/AuctionOld.sol"
    
    # Update contract name inside the copied file
    if command -v sed &> /dev/null; then
        echo "Updating contract name from 'contract Auction' to 'contract AuctionOld' in copied file..."
        sed -i 's/contract Auction/contract AuctionOld/g' "$TARGET_DIR/AuctionOld.sol"
    else
        echo "Warning: sed not available, contract name not updated in file contents"
    fi
fi

echo "Copy operation completed successfully!"
echo "Files copied to: $TARGET_DIR"
echo "Original files remain in: $SRC_DIR"

# List the contents of the target directory
echo ""
echo "Contents of $TARGET_DIR:"
find "$TARGET_DIR" -type f | sort