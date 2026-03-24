# PayTo Validation in Integrity Hash Workflow

## Problem Statement

Currently, the integrity hash system has a vulnerability:

1. **Registration vulnerability**: A malicious actor could register an integrity hash computed from x402 server responses that return an incorrect `payTo` address. The on-chain `registerEndpoint` function does not validate that the `payTo` in the hash matches the provider's registered `revenueSplitter`.

2. **CRE validation vulnerability**: The Chainlink CRE workflow validates that the computed integrity hash matches the registered hash, but does not independently verify that the `payTo` returned by the server matches the expected provider address.

## Current Architecture

### Integrity Hash Format
```json
{
  "amount": "1000000",
  "asset": "0x5425890298aed601595a70AB815c96711a31Bc65",
  "network": "eip155:43113",
  "payTo": "0xd5d932ab6030c76bc888dd40404835159da48611",
  "url": "https://api.example.com/v1/pricing"
}
```
- **Algorithm**: SHA-256
- **Normalization**: `payTo` is lowercased before hashing

### Data Flow

```
Provider Server (x402)
       |
       v
  registerEndpoint(providerId, path, method, integrityHash)
       |
       v
APIIntegrityRegistry.sol (stores hash)
       |
       v
ChallengeManager.openChallenge(endpointId)
       |
       v
ChallengeOpened(endpointId, path, method, integrityHash)
       |
       v
CRE Workflow: compute hash from x402 response, compare to on-chain
```

### Key Contract References

| File | Line | Purpose |
|------|------|---------|
| `APIIntegrityRegistry.sol` | 130-163 | `registerEndpoint()` - no payTo validation |
| `APIIntegrityRegistry.sol` | 14-21 | `Provider` struct with `revenueSplitter` |
| `APIIntegrityRegistry.sol` | 23-33 | `Endpoint` struct |
| `ChallengeManager.sol` | 64-70 | `ChallengeOpened` event (NO revenueSplitter) |
| `cre/integrity-workflow/main.ts` | 160 | `payTo` extraction from x402 response |

## Proposed Solution

### Part 1: On-Chain Validation (`APIIntegrityRegistry.sol`)

**Challenge**: The integrity hash is a raw SHA-256 digest - it cannot be decoded on-chain to extract the `payTo` value.

**Solution**: Add a validation function that accepts the raw payment data fields, recomputes the hash, and validates it against:
1. The provider's `revenueSplitter`
2. Optionally other fields (asset, network)

#### Option A: Add Validation in `registerEndpoint` (Recommended)

Add a new overloaded function or modify `registerEndpoint` to accept payment metadata for validation:

```solidity
function registerEndpointWithValidation(
    uint256 providerId,
    string calldata path,
    string calldata method,
    bytes32 integrityHash,
    // Additional fields for validation
    address expectedPayTo,
    address expectedAsset,
    string calldata expectedNetwork
) external whenNotPaused nonReentrant {
    // 1. Lookup provider's revenueSplitter
    Provider storage p = providers[providerId];
    
    // 2. Validate payTo matches
    require(expectedPayTo == p.revenueSplitter, "payTo must match revenueSplitter");
    
    // 3. Optional: validate asset and network
    // require(expectedAsset == USDC_ADDRESS, "invalid asset");
    // require(keccak256(bytes(expectedNetwork)) == keccak256(bytes("eip155:43113")), "invalid network");
    
    // 4. Proceed with registration...
}
```

**Pros**:
- Single transaction for registration + validation
- No additional calls needed

**Cons**:
- Increases gas costs
- Changes SDK registration API

#### Option B: Add Separate Validation Function

Add a view function that can be called before registration:

```solidity
function validateIntegrityHash(
    uint256 providerId,
    string calldata path,
    string calldata method,
    bytes calldata paymentData  // JSON-encoded payment metadata
) external view returns (bool isValid, address extractedPayTo) {
    // Parse paymentData to extract fields
    // Compute hash
    // Compare against registered hash if exists
    // Validate payTo against provider.revenueSplitter
}
```

**Pros**:
- Can be called off-chain to validate before registration
- Lower gas for registration itself

**Cons**:
- Requires two transactions (validate + register)
- More complex SDK integration

#### Option C: Change Integrity Hash Format (Most Comprehensive)

Instead of a raw SHA-256, use EIP-712 typed structured data or add a secondary hash that can be validated.

```solidity
// New approach: Pass payment data directly, contract computes hash
function registerEndpointWithData(
    uint256 providerId,
    string calldata path,
    string calldata method,
    // Payment metadata fields (not hash)
    address payTo,
    address asset,
    string calldata network,
    uint256 amount
) external whenNotPaused nonReentrant {
    // 1. Validate payTo
    require(payTo == providers[providerId].revenueSplitter, "payTo mismatch");
    
    // 2. Compute hash on-chain
    bytes32 integrityHash = keccak256(abi.encodePacked(
        '{"amount":"","asset":"","network":"","payTo":"","url":""}' // Or compute properly
        // Actually need to match exact format...
    ));
    
    // Store...
}
```

**Pros**:
- Maximum security
- Hash is always validated

**Cons**:
- Significant refactoring
- Must match x402 server hash format exactly (including JSON canonicalization)
- Gas-intensive JSON serialization on-chain

### Recommended On-Chain Approach: Option A (Modified)

Create a new function `registerEndpointValidated` that:
1. Accepts the payment metadata fields alongside the hash
2. Validates `payTo == providers[providerId].revenueSplitter`
3. Optionally validates `asset` matches USDC
4. Optionally validates `network` matches expected chain
5. Stores the hash only after validation passes

```solidity
function registerEndpointValidated(
    uint256 providerId,
    string calldata path,
    string calldata method,
    bytes32 integrityHash,
    address expectedPayTo,
    address expectedAsset,
    string calldata expectedNetwork
) external whenNotPaused nonReentrant {
    // Validate caller is provider owner
    Provider storage p = providers[providerId];
    require(p.owner == msg.sender, "not owner");
    require(p.active, "inactive");
    
    // CRITICAL: Validate payTo matches revenueSplitter
    require(expectedPayTo == p.revenueSplitter, "payTo must equal revenueSplitter");
    
    // Optional: Validate asset matches expected USDC
    // This prevents registering with wrong asset
    
    // Optional: Validate network format
    // This prevents registering with wrong chain
    
    // Proceed with endpoint registration...
}
```

### Part 2: CRE Workflow Validation (`cre/integrity-workflow/main.ts`)

**Current Flow**:
1. CRE receives `ChallengeOpened(endpointId, path, method, integrityHash)`
2. CRE fetches endpoint URL
3. CRE extracts `payTo` from x402 response
4. CRE computes hash from extracted fields
5. CRE compares computed hash to `integrityHash`

**Missing Validation**: The workflow does NOT:
- Look up the provider's registered `revenueSplitter` 
- Compare it against the `payTo` returned by the server

**Proposed Flow**:
1. CRE receives `ChallengeOpened(endpointId, path, method, integrityHash)`
2. **NEW**: Query `APIIntegrityRegistry.endpoints(endpointId)` to get `provider`
3. **NEW**: Query `APIIntegrityRegistry.providers(provider)` to get `revenueSplitter`
4. CRE fetches endpoint URL
5. CRE extracts `payTo` from x402 response
6. **NEW**: Compare `payTo` (from x402) against `revenueSplitter` (from registry)
   - If mismatch → return `result: '0'` (invalid)
7. CRE computes hash from extracted fields
8. CRE compares computed hash to `integrityHash`

**Implementation Details**:

```typescript
// In main.ts, modify onLogTrigger or add new function

// 1. First, look up the provider and revenueSplitter from registry
const endpointInfo = await registryContract.methods.endpoints(req.endpointId).call()
const providerId = await findProviderIdByEndpoint(req.endpointId) // May need registry function
const provider = await registryContract.methods.providers(providerId).call()
const expectedPayTo = provider.revenueSplitter.toLowerCase()

// 2. After extracting payTo from x402 response
const extractedPayTo = String(entry.payTo ?? '').toLowerCase()

// 3. CRITICAL: Validate payTo matches
if (extractedPayTo !== expectedPayTo) {
  runtime.log(`payTo mismatch: server=${extractedPayTo} expected=${expectedPayTo}`)
  return { challengeId: req.challengeId, result: '0' }
}
```

**Registry Changes Needed**:
The `IAPIIntegrityRegistry` interface needs to be extended to support looking up provider ID from endpoint ID, or we need to modify the `ChallengeOpened` event to include the `revenueSplitter`.

### Option 2A: Add `getProviderByEndpoint(bytes32 endpointId)` to Registry

```solidity
function getProviderByEndpoint(bytes32 endpointId) external view returns (uint256 providerId, address revenueSplitter) {
    Endpoint storage e = endpoints[endpointId];
    require(e.registeredAt != 0, "endpoint not found");
    Provider storage p = providers[e.provider];  // But Endpoint.provider is address, not uint256!
    // Issue: Endpoint.provider is address, not providerId
}
```

**Issue**: The `Endpoint` struct stores `provider: address`, not `providerId: uint256`. Need to either:
- Change `Endpoint.provider` to store `uint256 providerId`
- Add a reverse mapping from endpointId to providerId

### Option 2B: Add `endpointToProviderId` Mapping

```solidity
// In APIIntegrityRegistry.sol
mapping(bytes32 => uint256) public endpointToProviderId;

function registerEndpoint(...) {
    // ... existing logic ...
    endpointToProviderId[endpointId] = providerId;  // Add this
}
```

Then CRE can call:
```typescript
const providerId = await registryContract.methods.endpointToProviderId(endpointId).call()
const provider = await registryContract.methods.providers(providerId).call()
const revenueSplitter = provider.revenueSplitter
```

### Option 2C: Include `revenueSplitter` in `ChallengeOpened` Event

**ChallengeManager.sol** - Modify event:
```solidity
event ChallengeOpened(
    uint256 indexed id,
    bytes32 indexed endpointId,
    address indexed revenueSplitter,  // NEW
    string path,
    string method,
    bytes32 integrityHash
);
```

This way CRE receives the expected `revenueSplitter` directly in the event, avoiding extra RPC calls.

---

## Simplified Approach: Compute Hash On-Chain

### Key Insight
Instead of accepting a pre-computed hash, `registerEndpoint` accepts the raw payment metadata and computes the hash on-chain. This:
1. **Atomically validates payTo** matches revenueSplitter before storing
2. **Eliminates** the need for off-chain hash computation during registration
3. **Makes CRE simple** - just fetch stored hash, compare to server response

### Hash Computation
The on-chain hash must match the off-chain computation. Since x402 servers return JSON (not pre-hashed), CRE extracts fields and computes the hash.

**On-chain**: `keccak256(abi.encodePacked(canonicalJSON))`
**Off-chain**: `keccak(text: canonicalJSON)` (Chainlink CRE supports this)

Canonical JSON format (sorted keys, no whitespace):
```json
{"amount":"1000000","asset":"0x...","network":"eip155:43113","payTo":"0x...","url":"https://..."}
```

---

## Summary of Required Changes

### 1. `contracts/src/APIIntegrityRegistry.sol`

**Modify `registerEndpoint`** to accept payment metadata and compute hash:

```solidity
function registerEndpoint(
    uint256 providerId,
    string calldata path,
    string calldata method,
    // Payment metadata fields (instead of pre-computed hash)
    address payTo,
    address asset,
    string calldata network,
    string calldata url,
    uint256 amount  // Optional: could be excluded for flexibility
) external whenNotPaused nonReentrant {
    Provider storage p = providers[providerId];
    require(p.owner == msg.sender, "not owner");
    require(p.active, "inactive");
    
    // CRITICAL: Validate payTo matches revenueSplitter
    require(payTo == p.revenueSplitter, "payTo must equal revenueSplitter");
    
    // Compute integrity hash on-chain using keccak256
    // Match off-chain canonical JSON format
    bytes32 integrityHash = keccak256(abi.encodePacked(
        '{"amount":"',
        _uintToString(amount),
        '","asset":"',
        _addressToString(asset),
        '","network":"',
        network,
        '","payTo":"',
        _addressToStringNoChecksum(payTo),  // lowercase
        '","url":"',
        url,
        '"}'
    ));
    
    // ... rest of registration logic
}
```

**Helper functions needed**:
- `_uintToString(uint256)` - Convert uint to string
- `_addressToStringNoChecksum(address)` - Convert address to lowercase hex string
- OR use `Strings.toString()` from OpenZeppelin if already imported

**Alternative: Build string and hash in one go**:
```solidity
string memory canonical = string.concat(
    '{"amount":"', Strings.toString(amount), '","asset":"',
    Strings.toHexString(uint256(uint160(asset)), 32), '","network":"',
    network, '","payTo":"',
    Strings.toHexStringNoChecksum(payTo), '","url":"',
    url, '"}'
);
bytes32 integrityHash = keccak256(bytes(canonical));
```

### 2. `contracts/src/interfaces/IAPIIntegrityRegistry.sol`

Update interface to match new function signature:
```solidity
function registerEndpoint(
    uint256 providerId,
    string calldata path,
    string calldata method,
    address payTo,
    address asset,
    string calldata network,
    string calldata url,
    uint256 amount
) external;
```

### 3. `cre/integrity-workflow/main.ts`

**Changes**:
1. Update hash computation to use **keccak256** (instead of SHA-256)
2. Add payTo validation by querying registry

```typescript
// 1. Query registry for revenueSplitter (need to add endpointToProviderId mapping or other lookup)
const endpointInfo = await registryContract.methods.endpoints(req.endpointId).call()
// Need: providerId lookup from endpointId

// 2. Extract payTo from x402 response
const entry = accepts[0]
const extractedPayTo = String(entry.payTo ?? '').toLowerCase()

// 3. Validate payTo matches revenueSplitter
if (extractedPayTo !== expectedRevenueSplitter.toLowerCase()) {
  runtime.log(`payTo mismatch: server=${extractedPayTo} expected=${expectedRevenueSplitter}`)
  return { challengeId: req.challengeId, result: '0' }
}

// 4. Compute hash using keccak (Chainlink CRE supports this)
const metadata = {
  amount:  String(entry.amount ?? ''),
  asset:   String(entry.asset ?? ''),
  network: String(entry.network ?? ''),
  payTo:   extractedPayTo,
  url:     String(paymentData.resource?.url ?? ''),
}

// Build canonical JSON with sorted keys
const canonical = JSON.stringify(metadata, Object.keys(metadata).sort())
const computed = keccak256(Buffer.from(canonical, 'utf8'))

runtime.log(`computed=${computed}  expected=${req.integrityHash}`)
const match = computed.toLowerCase() === req.integrityHash.toLowerCase()
return { challengeId: req.challengeId, result: match ? '1' : '0' }
```

**Registry lookup challenge**: `Endpoint.provider` is an address, not providerId. Options:
1. Add `endpointToProviderId` mapping in registry
2. Have factory store `revenueSplitter` directly in Endpoint during registration
3. Modify `ChallengeOpened` event to include `revenueSplitter`

### 4. `sdk/composed/client.py`

Update `register_endpoint()` to pass payment metadata instead of pre-computed hash:

```python
def register_endpoint(
    self,
    provider_id: int,
    url: str,
    method: str = "GET",
    pay_to: str = "",
    asset: str = "",
    network: str = "",
    amount: str = "",
) -> str:
    # If metadata not provided, fetch from endpoint
    if not all([pay_to, asset, network, amount]):
        payment_data = _fetch_payment_data(url)
        pay_to = pay_to or payment_data["payTo"]
        asset = asset or payment_data["asset"]
        network = network or payment_data["network"]
        amount = amount or str(payment_data["amount"])
    
    # Convert to contract params
    pay_to_addr = self.w3.to_checksum_address(pay_to)
    asset_addr = self.w3.to_checksum_address(asset)
    
    receipt = self._send_tx(
        self._registry.functions.registerEndpoint(
            provider_id,
            path,
            method.upper(),
            pay_to_addr,
            asset_addr,
            network,
            url,
            int(amount),
        ),
    )
    # ...
```

### 5. `challenger_watcher/x402_metadata.py`

Add `fetch_payment_metadata()` function that returns raw payment data (no hashing):

```python
def fetch_payment_metadata(endpoint_url: str) -> dict:
    """
    Fetch x402 payment requirements and return raw metadata dict.
    Does NOT compute hash - caller is responsible for that.
    """
    resp = requests.get(endpoint_url)
    # ... extract fields from v1 or v2 ...
    return {
        "amount":  amount,
        "asset":   asset,
        "network": network,
        "payTo":   pay_to.lower(),
        "url":     url,
    }
```

Keep `fetch_integrity_hash` for backward compatibility (SDK uses it), but note it uses SHA-256.

### 6. `challenger_watcher/challenger_watcher.py`

Update `check_endpoint()` to:
1. Use `fetch_payment_metadata()` instead of `fetch_integrity_hash()`
2. Compute hash using keccak256 (via Web3.py)
3. Validate payTo against registry via `endpointToProviderId` lookup

```python
from web3 import Web3
from x402_metadata import fetch_payment_metadata

def check_endpoint(eid_hex: str, state: dict, check_interval: int):
    # ... existing setup ...
    
    # 1. Fetch raw payment metadata
    metadata = fetch_payment_metadata(path)
    
    # 2. Validate payTo against registry
    eid_bytes = bytes.fromhex(eid_hex.removeprefix("0x"))
    provider_id = registry.functions.endpointToProviderId(eid_bytes).call()
    provider = registry.functions.providers(provider_id).call()
    expected_pay_to = provider[3]  # revenueSplitter field
    
    if metadata["payTo"] != expected_pay_to.lower():
        print(f"    ✗ payTo MISMATCH — server={metadata['payTo']} expected={expected_pay_to}")
        # Open challenge or flag
        return
    
    # 3. Compute keccak hash
    canonical = json.dumps(metadata, sort_keys=True, separators=(",", ":"))
    computed_hash = "0x" + Web3.keccak(text=canonical).hex()
    
    # 4. Compare to on-chain
    if computed_hash.lower() == on_chain_hex.lower():
        print(f"    ✓ match")
    else:
        print(f"    ✗ MISMATCH — challenging!")
        # Open challenge
```

---

## Registry Lookup for CRE

### Option A: Add `endpointToProviderId` Mapping (Recommended)

```solidity
// APIIntegrityRegistry.sol
mapping(bytes32 => uint256) public endpointToProviderId;

function registerEndpoint(...) {
    // ... existing logic ...
    endpointToProviderId[endpointId] = providerId;
}

// IAPIIntegrityRegistry.sol
function endpointToProviderId(bytes32) external view returns (uint256);
```

Then CRE can:
```typescript
const providerId = await registryContract.methods.endpointToProviderId(endpointId).call()
const provider = await registryContract.methods.providers(providerId).call()
const revenueSplitter = provider.revenueSplitter
```

### Option B: Store revenueSplitter in Endpoint

```solidity
struct Endpoint {
    // ... existing fields ...
    address revenueSplitter;  // NEW
}
```

Simpler for CRE but duplicates data.

### Option C: Include in ChallengeOpened Event

```solidity
event ChallengeOpened(
    uint256 indexed id,
    bytes32 indexed endpointId,
    address revenueSplitter,  // NEW - no index to save gas
    string path,
    string method,
    bytes32 integrityHash
);
```

Requires ChallengeManager change.

---

## Implementation Order

1. **Phase 1**: Modify `APIIntegrityRegistry.registerEndpoint()`
   - Accept payment metadata instead of pre-computed hash
   - Validate payTo == revenueSplitter
   - Compute keccak256 hash on-chain
   - Add `endpointToProviderId` mapping for CRE access

2. **Phase 2**: Update `IAPIIntegrityRegistry.sol` interface

3. **Phase 3**: Update SDK `register_endpoint()` 
   - Pass metadata instead of hash
   - Compute hash client-side for verification (optional)

4. **Phase 4**: Update CRE workflow `main.ts`
   - Use keccak256 instead of SHA-256
   - Add payTo validation via registry query

5. **Phase 5**: Update `challenger_watcher.py`
   - Same changes as CRE workflow

---

## Security Considerations

1. **PayTo Normalization**: Always lowercase the address in canonical JSON
2. **URL Normalization**: Ensure trailing slashes, etc. are consistent
3. **Amount Format**: String representation must match exactly
4. **Network Format**: Must be exact CAIP format (e.g., "eip155:43113")
5. **Migration**: Need to handle existing registered endpoints during upgrade

---

## Backward Compatibility Strategy

During migration from SHA-256 to keccak256:
1. Keep old `registerEndpoint` for existing deployments
2. Deploy new version with keccak
3. Optionally add a flag/function to recompute hash for existing endpoints
4. Update SDK to use new signature
