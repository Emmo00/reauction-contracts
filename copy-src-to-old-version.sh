#!/bin/bash

# Script to copy src directory structure to src/old
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

# Alternative method using cp (commented out)
# cp -r "$SRC_DIR"/* "$TARGET_DIR/" 2>/dev/null || true
# But we need to exclude old directory manually

echo "Copy operation completed successfully!"
echo "Files copied to: $TARGET_DIR"

# List the contents of the target directory
echo ""
echo "Contents of $TARGET_DIR:"
find "$TARGET_DIR" -type f | sort