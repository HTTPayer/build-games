#!/usr/bin/env node
/**
 * Dry-run Chainlink verification locally.
 *
 * Simulates exactly what functions-source-minimal.js does on the DON:
 *   1. Fetch the endpoint URL
 *   2. Detect v1 (body) vs v2 (PAYMENT-REQUIRED header)
 *   3. Extract amount, asset, network, payTo, url
 *   4. Compute SHA-256 of sorted compact JSON
 *   5. Compare with expected hash → PASS / FAIL
 *
 * Usage:
 *   node dry-run.js <url> [expectedHash] [method]
 *
 * Examples:
 *   # Just compute the hash (no comparison)
 *   node dry-run.js http://localhost:4021/weather
 *
 *   # Compare against a known hash
 *   node dry-run.js http://localhost:4021/weather 0xabc123...
 *
 *   # POST endpoint
 *   node dry-run.js http://localhost:4021/weather 0xabc123... POST
 */

const https = require('https');
const http  = require('http');
const crypto = require('crypto');

const [,, url, expectedHash, method = 'GET'] = process.argv;

if (!url) {
  console.error('Usage: node dry-run.js <url> [expectedHash] [method]');
  process.exit(1);
}

// ── Fetch ─────────────────────────────────────────────────────────────────────

function fetchUrl(url, method) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith('https') ? https : http;
    const req = lib.request(url, { method, headers: { Accept: 'application/json' } }, (res) => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.end();
  });
}

// ── Hash (mirrors functions-source-minimal.js exactly) ───────────────────────

function computeHash(metadata) {
  const dataString = JSON.stringify(metadata, Object.keys(metadata).sort());
  const hash = '0x' + crypto.createHash('sha256').update(dataString, 'utf8').digest('hex');
  return { dataString, hash };
}

// ── Main ──────────────────────────────────────────────────────────────────────

(async () => {
  console.log('='.repeat(60));
  console.log('Chainlink Functions Dry Run');
  console.log('='.repeat(60));
  console.log(`url    : ${url}`);
  console.log(`method : ${method}`);
  if (expectedHash) console.log(`expect : ${expectedHash.toLowerCase()}`);
  console.log('');

  // Fetch
  let res;
  try {
    res = await fetchUrl(url, method);
  } catch (e) {
    console.error('Fetch failed:', e.message);
    process.exit(1);
  }
  console.log(`status : ${res.status}`);

  // Detect v1 vs v2
  const paymentHeader = res.headers['payment-required'] || res.headers['PAYMENT-REQUIRED'];
  let data;
  if (paymentHeader) {
    console.log('version: 2 (PAYMENT-REQUIRED header)');
    data = JSON.parse(Buffer.from(paymentHeader, 'base64').toString('utf8'));
  } else {
    console.log('version: 1 (body)');
    try {
      data = JSON.parse(res.body.toString('utf8'));
    } catch (e) {
      console.error('Could not parse body as JSON:', e.message);
      process.exit(1);
    }
  }

  if (!data?.accepts?.[0]) {
    console.error('Missing accepts[0] in payload');
    process.exit(1);
  }

  const entry = data.accepts[0];
  const metadata = {
    amount:  String(entry.amount  ?? ''),
    asset:   String(entry.asset   ?? ''),
    network: String(entry.network ?? ''),
    payTo:   String(entry.payTo   ?? '').toLowerCase(),
    url:     String(data.resource?.url ?? ''),
  };

  console.log('');
  console.log('Metadata:');
  for (const [k, v] of Object.entries(metadata)) console.log(`  ${k.padEnd(8)}: ${v}`);

  // Hash
  const { dataString, hash: computed } = computeHash(metadata);
  console.log('');
  console.log('JSON    :', dataString);
  console.log('computed:', computed);

  // Compare
  console.log('');
  if (expectedHash) {
    const match = computed === expectedHash.toLowerCase();
    console.log('='.repeat(60));
    console.log(match ? 'PASS - hash matches' : 'FAIL - hash mismatch');
    console.log('='.repeat(60));
    if (!match) {
      console.log('expected:', expectedHash.toLowerCase());
      console.log('computed:', computed);
      process.exit(1);
    }
  } else {
    console.log('='.repeat(60));
    console.log('Hash (use this when registering):');
    console.log(computed);
    console.log('='.repeat(60));
  }
})();
