# Protocol Cleanup & Production Readiness Plan

## Current State Analysis

### ✅ What's Working
- **APIIntegrityRegistry**: Clean commitment ledger with provider/endpoint registration
- **StakeManager**: Solid economic security vault with BPS-based slashing
- **ChallengeManager**: Core adversarial verification structure in place
- **Architecture**: Clean separation of concerns (Registry → Stake → Challenge)

### ❌ Critical Issues

#### 1. File Structure Problems
- `RevenueSplitter.sol` contains `ProviderRevenueSplitter` code
- `ProviderRevenueVault.sol` ALSO contains `ProviderRevenueSplitter` code (duplicate!)
- `APIRegistryFactory.sol` imports non-existent `./ProviderRevenueSplitter.sol`
- Missing actual ERC4626 vault implementation

#### 2. Contract Bugs
- **ChallengeManager.sol:157** - Calls `stakeManager.slash(provider, slashAmount)`
- **StakeManager.sol:106** - Function signature is `slash(address provider, uint256 slashBp, address challenger)`
- **MISMATCH**: ChallengeManager passes amount, StakeManager expects BPS + challenger

#### 3. Missing Implementations
- `ProviderRevenueVault` should be ERC4626 vault but file contains wrong code
- Chainlink Automation `checkUpkeep()` just returns true (no logic)
- Chainlink Automation `performUpkeep()` is empty stub
- No endpoint iteration logic for automated checks

#### 4. Integration Gaps
- Deploy script only deploys security layer (Registry/Stake/Challenge)
- Revenue layer (Factory/Vault/Splitter) not included in deployment
- No role setup for Factory in deployment
- Missing Chainlink Functions source code reference

#### 5. Testing & Documentation
- No visible test files for contracts
- No .env.example for deployment configuration
- No deployment documentation
- notes.txt contains exposed private key (SECURITY RISK)

---

## Cleanup Plan

### Phase 1: Fix File Structure
1. **Delete** duplicate `ProviderRevenueVault.sol` (wrong content)
2. **Rename** `RevenueSplitter.sol` → `ProviderRevenueSplitter.sol`
3. **Create** proper `ProviderRevenueVault.sol` (ERC4626 implementation)
4. **Fix** `APIRegistryFactory.sol` imports

### Phase 2: Fix Contract Bugs
1. **Update ChallengeManager**:
   - Add configurable `slashBp` parameter (e.g., 2000 = 20% slash)
   - Fix slash call to pass `slashBp` and `challenger` address
2. **Review StakeManager** slash distribution logic
3. **Add validation** for all critical parameters

### Phase 3: Implement Missing Features
1. **ProviderRevenueVault** (ERC4626):
   - Standard vault interface
   - Deposit/withdraw/redeem logic
   - Share price calculation based on revenue
2. **Chainlink Automation**:
   - Store array of active endpointIds
   - `checkUpkeep()` returns endpoints needing verification
   - `performUpkeep()` triggers challenges for stale endpoints
3. **Chainlink Functions Source**:
   - Add JS source code for endpoint verification
   - Document expected response format

### Phase 4: Unified Deployment
1. **Create comprehensive deployment script**:
   - Deploy security layer (Registry/Stake/Challenge)
   - Deploy revenue layer (Factory)
   - Grant all necessary roles
   - Configure parameters
   - Output all addresses
2. **Create .env.example** with all required variables
3. **Add deployment verification** step

### Phase 5: Testing
1. **Unit tests** for each contract
2. **Integration tests** for full flow:
   - Provider registration + staking
   - Endpoint registration
   - Challenge submission
   - Oracle callback + slashing
   - Revenue distribution
3. **Fork tests** on Avalanche Fuji testnet

### Phase 6: Documentation
1. **Deployment guide** (step-by-step)
2. **Architecture documentation**
3. **Contract interaction guide**
4. **Security considerations**

---

## Priority Order

### 🔴 CRITICAL (Do First)
1. Remove exposed private key from notes.txt
2. Fix slash function signature mismatch
3. Fix file structure and imports
4. Implement proper ProviderRevenueVault

### 🟡 HIGH (Do Next)
5. Implement Chainlink Automation logic
6. Create unified deployment script
7. Add .env.example and deployment docs

### 🟢 MEDIUM (Do After)
8. Add comprehensive tests
9. Add inline documentation
10. Create architecture diagrams

---

## Success Criteria

- [ ] All contracts compile without errors
- [ ] No duplicate/misnamed files
- [ ] All imports resolve correctly
- [ ] Slash function calls match signatures
- [ ] Full deployment script runs successfully
- [ ] Tests pass for critical flows
- [ ] Documentation complete for deployment
- [ ] No exposed secrets in repository
