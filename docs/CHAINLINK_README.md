# Chainlink Functions Source Code

This directory contains the JavaScript source code that runs on Chainlink Functions to verify API endpoint integrity.

## Files

### `functions-source.js` (Verbose)
Full version with detailed logging for debugging and testing.

**Use for:**
- Development and testing
- Debugging integration issues
- Understanding the verification process

**Features:**
- Step-by-step console logging
- Detailed error messages
- Shows all intermediate values

### `functions-source-minimal.js` (Production)
Minimal version optimized for gas efficiency.

**Use for:**
- Production deployment
- Lower gas costs
- Faster execution

**Features:**
- No verbose logging
- Optimized for speed
- ~50% less gas than verbose version

---

## How It Works

### Input (from smart contract)

```javascript
args[0] = "https://api.example.com/v1/pricing"  // Endpoint URL
args[1] = "GET"                                  // HTTP method
args[2] = "0xabc123..."                          // Expected integrity hash
```

### Process

1. **Fetch endpoint** - Makes HTTP request to the URL
2. **Verify 402** - Checks response is `402 Payment Required`
3. **Extract metadata** - Parses `payTo`, `apiId`, `amount`, `currency`, `chain`
4. **Compute hash** - Creates deterministic hash of metadata
5. **Compare** - Matches computed hash vs expected hash
6. **Return** - Returns `1` (valid) or `0` (invalid)

### Output (to smart contract)

```javascript
return Functions.encodeUint256(1);  // Valid
// or
return Functions.encodeUint256(0);  // Invalid
```

---

## Testing Locally

### Option 1: Chainlink Functions Playground

1. Visit https://functions.chain.link/playground
2. Copy `functions-source.js` contents
3. Set arguments:
   ```json
   [
     "https://api.example.com/v1/pricing",
     "GET",
     "0x742d35cc6634c0532925a3b844bc9e7fe3d4aafc0f4e7b6fdb6b80e56c0ca8c5"
   ]
   ```
4. Click "Run"
5. Check console output

### Option 2: Local Node.js Testing

Create `test-local.js`:

```javascript
const crypto = require('crypto');

// Mock API response
const mockResponse = {
  status: 402,
  data: {
    payTo: "0x742d35Cc6634C0532925a3b844Bc9e7FE3d4aAfC",
    apiId: "api.example.com/pricing",
    amount: "1000000",
    currency: "USDC",
    chain: "avalanche"
  }
};

// Simulate Functions
const Functions = {
  makeHttpRequest: async () => mockResponse,
  encodeUint256: (val) => val,
  keccak256: (data) => {
    return '0x' + crypto.createHash('sha3-256')
      .update(Buffer.from(data.slice(2), 'hex'))
      .digest('hex');
  }
};

// Mock ethers
const ethers = {
  utils: {
    keccak256: Functions.keccak256
  }
};

// Mock args
const args = [
  "https://api.example.com/v1/pricing",
  "GET",
  "0x742d35cc6634c0532925a3b844bc9e7fe3d4aafc0f4e7b6fdb6b80e56c0ca8c5"
];

// Run your functions-source.js code here
// ... (paste the contents)

console.log("Result:", result);
```

Run:
```bash
node test-local.js
```

---

## Computing Expected Hash

To compute the expected hash for registration, use this helper:

### Solidity Helper

```solidity
// contracts/test/helpers/IntegrityHashHelper.sol
pragma solidity 0.8.30;

contract IntegrityHashHelper {
    function computeIntegrityHash(
        address payTo,
        string calldata apiId,
        string calldata amount,
        string calldata currency,
        string calldata chain
    ) external pure returns (bytes32) {
        // Must match JavaScript hashing logic
        string memory dataString = string(abi.encodePacked(
            '{"apiId":"', apiId, '",',
            '"amount":"', amount, '",',
            '"chain":"', chain, '",',
            '"currency":"', currency, '",',
            '"payTo":"', _toLower(payTo), '"}'
        ));

        return keccak256(bytes(dataString));
    }

    function _toLower(address addr) internal pure returns (string memory) {
        bytes memory addrBytes = abi.encodePacked(addr);
        bytes memory result = new bytes(42);
        result[0] = '0';
        result[1] = 'x';

        for (uint i = 0; i < 20; i++) {
            uint8 b = uint8(addrBytes[i]);
            result[2 + i*2] = _char(b / 16);
            result[3 + i*2] = _char(b % 16);
        }

        return string(result);
    }

    function _char(uint8 b) internal pure returns (bytes1) {
        if (b < 10) return bytes1(b + 0x30);
        return bytes1(b + 0x57); // lowercase a-f
    }
}
```

### JavaScript Helper

```javascript
// chainlink/compute-hash.js
const ethers = require('ethers');

function computeIntegrityHash(payTo, apiId, amount, currency, chain) {
  const metadata = {
    payTo: payTo.toLowerCase(),
    apiId: apiId || "",
    amount: amount || "",
    currency: currency || "",
    chain: chain || ""
  };

  const dataString = JSON.stringify(metadata, Object.keys(metadata).sort());
  const dataBytes = new TextEncoder().encode(dataString);

  let hexString = "0x";
  for (let i = 0; i < dataBytes.length; i++) {
    hexString += dataBytes[i].toString(16).padStart(2, '0');
  }

  return ethers.utils.keccak256(hexString);
}

// Example usage
const hash = computeIntegrityHash(
  "0x742d35Cc6634C0532925a3b844Bc9e7FE3d4aAfC",
  "api.example.com/pricing",
  "1000000",
  "USDC",
  "avalanche"
);

console.log("Integrity Hash:", hash);
```

Run:
```bash
node chainlink/compute-hash.js
```

---

## Deployment Checklist

- [ ] Test in Functions Playground
- [ ] Verify hash computation matches
- [ ] Test with your actual API endpoint
- [ ] Choose version (verbose for testing, minimal for production)
- [ ] Upload to IPFS (optional but recommended)
- [ ] Configure in ChallengeManager

---

## Troubleshooting

### Hash Mismatch

**Problem:** Functions always returns `0` (invalid)

**Solutions:**
1. Verify JSON key ordering is alphabetical
2. Ensure `payTo` is lowercase
3. Check all fields are strings (not numbers)
4. Test hash computation independently

### Timeout

**Problem:** Functions times out after 5 seconds

**Solutions:**
1. Check endpoint URL is accessible
2. Verify endpoint responds quickly (<2s)
3. Ensure endpoint returns 402 (not redirects)

### Invalid Response

**Problem:** Endpoint doesn't return 402

**Solutions:**
1. Verify endpoint implements x402 protocol
2. Check endpoint URL is correct
3. Test endpoint manually with curl:
   ```bash
   curl -i https://api.example.com/v1/pricing
   ```

---

## Gas Optimization Tips

1. **Use minimal version** in production
2. **Minimize metadata fields** - only include necessary fields
3. **Cache hash computation** - compute once, use for all endpoints
4. **Batch verification** - verify multiple endpoints in one call (future)

---

## Security Considerations

### Hash Collision

Keccak256 provides 256-bit security. Collision is computationally infeasible.

### Response Manipulation

Functions runs in isolated environment. API cannot manipulate the JavaScript execution.

### Deterministic Ordering

Alphabetical key sorting ensures consistent hashing regardless of JSON serialization order.

### Address Normalization

Lowercase normalization prevents `0xABC...` vs `0xabc...` mismatches.

---

## Versioning

When updating the source code:

1. **Test thoroughly** in playground first
2. **Compute test hashes** with new version
3. **Deploy to testnet** and verify
4. **Only then update production**

Changes to hashing logic will invalidate all existing registered endpoints!

---

## Future Enhancements

Potential improvements:

1. **Batch verification** - verify multiple endpoints in one call
2. **Signature verification** - verify signed 402 responses
3. **Historical checks** - verify endpoint hasn't changed over time
4. **Rate limiting detection** - handle 429 responses
5. **Retry logic** - retry failed requests

---

## Support

Questions? Check:
- [CHAINLINK_INTEGRATION.md](../CHAINLINK_INTEGRATION.md) - Full integration guide
- [Chainlink Functions Docs](https://docs.chain.link/chainlink-functions)
- [Functions Playground](https://functions.chain.link/playground)
