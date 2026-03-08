#!/usr/bin/env node

/**
 * Integrity Hash Computation Tool
 *
 * Computes the integrity hash for API endpoint registration.
 * This hash must match what Chainlink Functions computes during verification.
 *
 * Usage:
 *   node compute-hash.js <payTo> <apiId> <amount> <currency> <chain>
 *
 * Example:
 *   node compute-hash.js \
 *     0x742d35Cc6634C0532925a3b844Bc9e7FE3d4aAfC \
 *     api.example.com/pricing \
 *     1000000 \
 *     USDC \
 *     avalanche
 */

const crypto = require('crypto');

// ============================================================================
// Configuration
// ============================================================================

const args = process.argv.slice(2);

if (args.length < 5) {
  console.error(`
Usage: node compute-hash.js <payTo> <url> <amount> <asset> <network>

Arguments:
  payTo   - Ethereum address where payments go (e.g., 0x742d35Cc...)
  url     - Full resource URL (e.g., http://localhost:4021/weather)
  amount  - Payment amount in smallest unit (e.g., 1000 for 0.001 USDC)
  asset   - Asset contract address (e.g., 0x5425890298aed601595a70AB815c96711a31Bc65)
  network - CAIP-2 network identifier (e.g., eip155:43113)

Example:
  node compute-hash.js \\
    0x0Bec71239f73D54287a32f478784170bfa6aE6fd \\
    http://localhost:4021/weather \\
    1000 \\
    0x5425890298aed601595a70AB815c96711a31Bc65 \\
    eip155:43113
`);
  process.exit(1);
}

const [payTo, url, amount, asset, network] = args;

// ============================================================================
// Validation
// ============================================================================

if (!payTo.match(/^0x[a-fA-F0-9]{40}$/)) {
  console.error(`Error: Invalid Ethereum address: ${payTo}`);
  process.exit(1);
}

// ============================================================================
// Hash Computation (must match Functions source code)
// ============================================================================

function computeIntegrityHash(payTo, url, amount, asset, network) {
  // Step 1: Normalize address to lowercase
  const normalizedPayTo = payTo.toLowerCase();

  // Step 2: Build metadata object with alphabetically sorted keys
  const metadata = {
    amount:  amount  || "",
    asset:   asset   || "",
    network: network || "",
    payTo:   normalizedPayTo,
    url:     url     || "",
  };

  // Step 3: Convert to deterministic JSON string
  const dataString = JSON.stringify(metadata, Object.keys(metadata).sort());

  console.log("─".repeat(70));
  console.log("Integrity Hash Computation");
  console.log("─".repeat(70));
  console.log("\nInput:");
  console.log("  payTo:  ", payTo);
  console.log("  url:    ", url);
  console.log("  amount: ", amount);
  console.log("  asset:  ", asset);
  console.log("  network:", network);
  console.log("\nNormalized:");
  console.log("  payTo:  ", normalizedPayTo);
  console.log("\nJSON String:");
  console.log("  ", dataString);
  console.log("");

  // Step 4: Convert string to hex
  const dataBytes = Buffer.from(dataString, 'utf8');
  const hexString = '0x' + dataBytes.toString('hex');

  console.log("Hex Data:");
  console.log("  ", hexString.slice(0, 66) + "...");
  console.log("");

  // Step 5: Compute keccak256 hash
  const hash = '0x' + crypto.createHash('sha256')
    .update(dataBytes)
    .digest('hex');

  return hash;
}

// ============================================================================
// Compute and display result
// ============================================================================

const hash = computeIntegrityHash(payTo, url, amount, asset, network);

console.log("Result:");
console.log("─".repeat(70));
console.log("\n✓ Integrity Hash:");
console.log("\n  ", hash);
console.log("\n" + "─".repeat(70));
console.log("\nNext Steps:");
console.log("  1. Use this hash when registering your endpoint");
console.log("  2. Pass it to: registry.registerEndpoint(..., integrityHash)");
console.log("  3. Chainlink Functions will verify against this hash");
console.log("\nSolidity Call:");
console.log(`
  registry.registerEndpoint(
    providerId,
    "/v1/pricing",
    "GET",
    ${hash}
  );
`);
console.log("─".repeat(70) + "\n");

// ============================================================================
// Export for programmatic use
// ============================================================================

if (require.main !== module) {
  module.exports = { computeIntegrityHash };
}
