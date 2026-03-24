# WrappedRevenueShare (wRS) Specification

## Overview

A non-rebasing ERC-20 wrapper for ProviderRevenueShare tokens. Like wstETH wraps stETH, wRS wraps the revenue share token and provides:
- Non-rebasing (price per token increases, not token count)
- Chainlink Automation integration for passive harvesting
- Built-in Chainlink price feed for DeFi integration

## Mechanism

```
User deposits RS → receives wRS (1:1 initially)

Flow:
1. User calls deposit(uint256 rsAmount) → receives wRS
2. Contract holds RS tokens, earns USDC dividends via claim()
3. USDC accumulates in contract (not distributed to holders)
4. exchangeRate() increases: USDC balance / wRS totalSupply
5. User redeems wRS → gets USDC at current rate (minus fee)
```

## Core Functions

### deposit(uint256 rsAmount) → wrsMinted
- Deposit RS tokens, receive wRS 1:1 initially
- RS is transferred to this contract, held forever (yield source)

### withdraw(uint256 wrsAmount) → usdcOut
- Burn wRS, receive USDC at current exchange rate
- Small withdrawal fee goes to treasury

### harvest() (Chainlink Automation compatible)
- Call `revenueShare.claim()` to pull accrued USDC
- Updates exchange rate for all holders

### exchangeRate() → uint256 (view)
- USDC balance per wRS, scaled by 1e6
- Starts at 1e6 (1:1), increases as dividends accumulate

## Chainlink Integration

### Automation (Upkeep)
- `harvest()` function can be automation-compatible
- Callable by Automation to periodically claim dividends
- Returns true if claimable > 0

### Price Feed (ChainlinkAggregator)
- `latestRoundData()` returns exchange rate as USD price
- Answer format: 1e8 (e.g., 1.05 USD = 105000000)
- Uses exchangeRate() internally

## Differences from APIRevenueStable

| Feature | APIRevenueStable | wRS |
|---------|------------------|-----|
| Wraps | USDC | RS tokens |
| Mint/Redeem | USDC ↔ Stable | RS ↔ wRS |
| Fee | 0.5% on mint/redeem | Optional on withdraw |
| Initial rate | 1:1 USDC | 1:1 RS |
| Price feed | Custom snapshots | Direct exchange rate |

## Contract Interface

```solidity
interface IWrappedRevenueShare {
    function deposit(uint256 rsAmount) external returns (uint256 wrsMinted);
    function withdraw(uint256 wrsAmount) external returns (uint256 usdcOut);
    function harvest() external returns (uint256 harvested);
    function exchangeRate() external view returns (uint256);
    function revenueShare() external view returns (ProviderRevenueShare);
    function USDC() external view returns (IERC20);
}
```