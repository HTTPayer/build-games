# Challenger Watcher

Autonomous challenger bot for API integrity verification on Avalanche Fuji.

Continuously monitors all registered endpoints in APIIntegrityRegistry, independently computes the x402 integrity hash, and opens a challenge on ChallengeManager when the live hash doesn't match the on-chain value.

---

## Usage

### Prerequisites

- Python 3.11+
- Contracts deployed and `contracts/broadcast/DeployAll.s.sol/43113/run-latest.json` present
- `.env` file with required variables

```bash
cd challenger_watcher
uv sync
```

### Environment Variables

Create a `.env` file:

```bash
# Required
GATEWAY_URL=https://api.avax-test.network/ext/bc/C/rpc
PRIVATE_KEY=0x...

# Optional (uses PRIVATE_KEY if not set)
PROVIDER_PRIVATE_KEY=0x...
```

### Run

**Continuous mode** (default, polls every 30 seconds):

```bash
uv run python challenger_watcher.py
```

**One-shot mode** (single cycle):

```bash
uv run python challenger_watcher.py --once
```

**Custom check interval** (seconds between re-checking the same endpoint):

```bash
uv run python challenger_watcher.py --check-interval 300
```

---

## Behaviour

- On first run: scans from the registry deploy block to discover all existing endpoints
- Each cycle: discovers newly registered endpoints, then checks each endpoint (subject to `--check-interval` cooldown per endpoint)
- Won't re-challenge an endpoint that already has a pending challenge
- Tracks pending challenges and clears them when resolved
- State is persisted to `challenger_watcher_state.json` — safe to restart at any time

---

## State File

State is saved to `challenger_watcher_state.json` (gitignored) containing:
- Last block scanned per contract
- Last check timestamp per endpoint
- Pending challenge IDs
