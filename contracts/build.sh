#!/bin/bash
# Build wrapper for HTTPayer protocol contracts.
# Runs forge build then extracts ABIs for SDK/scripts consumption.

set -e

cd "$(dirname "$0")"

echo "==> Building contracts with forge..."
forge build "$@"

echo "==> Extracting ABIs..."
python ../scripts/extract_abis.py

echo "==> Done"
