# Protocol Analytics — Architecture

Event indexer → SQLite → FastAPI → Streamlit dashboard.

---

## Components

```
┌─────────────────────────────────────────────────────────┐
│  analytics_indexer.py  (background poller)              │
│  Syncs all contract events into SQLite.                 │
│  Mirrors watcher pattern — persists last_block per      │
│  contract, chunks getLogs, discovers per-provider       │
│  contracts from ProviderDeployed events.                │
└──────────────────────────┬──────────────────────────────┘
                           │ sqlite3
                    analytics.db
                           │ sqlite3
┌──────────────────────────▼──────────────────────────────┐
│  analytics_api.py  (FastAPI)                            │
│  Read-only JSON API over the SQLite database.           │
│  uvicorn analytics_api:app --port 8000                  │
└──────────────────────────┬──────────────────────────────┘
                           │ HTTP (requests / httpx)
┌──────────────────────────▼──────────────────────────────┐
│  analytics_dashboard.py  (Streamlit)                    │
│  Calls the API, renders charts and tables.              │
│  streamlit run analytics_dashboard.py                   │
└─────────────────────────────────────────────────────────┘
```

All three live in `contracts/scripts/`. The database is gitignored.

---

## File layout

```
contracts/scripts/
├── analytics_indexer.py      # event syncer
├── analytics_api.py          # FastAPI server
├── analytics_dashboard.py    # Streamlit app
├── analytics.db              # gitignored
└── analytics_state.json      # gitignored — last_block per contract
```

---

## Events indexed

| Contract | Event | Notes |
|---|---|---|
| `APIRegistryFactory` | `ProviderDeployed` | Discovers vault / splitter / revenueShare addresses |
| `APIIntegrityRegistry` | `ProviderRegistered` | Provider owner + id |
| `APIIntegrityRegistry` | `EndpointRegistered` | Path, method, integrity hash |
| `StakeManager` | `Staked` | Provider → USDC amount |
| `StakeManager` | `UnstakeRequested` | Amount + cooldown unlock timestamp |
| `StakeManager` | `Withdrawn` | Completed unstake |
| `StakeManager` | `Slashed` | Provider + challenger + amount |
| `ChallengeManager` | `ChallengeOpened` | Endpoint, hash, challenger |
| `ChallengeManager` | `ChallengeResolved` | Status (Valid / Invalid) |
| `ProviderRevenueSplitter` *(per-provider)* | `Distributed` | Total + per-bucket amounts |
| `ProviderRevenueVault` *(per-provider, ERC4626)* | `Deposit` | Sender, assets, shares |
| `ProviderRevenueVault` *(per-provider, ERC4626)* | `Withdraw` | Receiver, assets, shares |
| `ProviderRevenueShare` *(per-provider)* | `Claimed` | Holder + USDC amount |

Per-provider contract addresses are not known at deploy time — they are read from
`ProviderDeployed` events on first sync, then stored in the `providers` table and
used as log filters for subsequent passes.

---

## SQLite schema

```sql
-- Sync state
CREATE TABLE sync_state (
    contract_name TEXT PRIMARY KEY,
    last_block    INTEGER NOT NULL DEFAULT 0
);

-- Core
CREATE TABLE providers (
    id              INTEGER PRIMARY KEY,
    owner           TEXT NOT NULL,
    vault           TEXT,
    splitter        TEXT,
    revenue_share   TEXT,   -- address(0) if not deployed
    block_number    INTEGER,
    tx_hash         TEXT,
    ts              INTEGER  -- unix timestamp
);

CREATE TABLE endpoints (
    endpoint_id     TEXT PRIMARY KEY,   -- bytes32 hex
    provider_id     INTEGER,
    owner           TEXT,
    path            TEXT,
    method          TEXT,
    integrity_hash  TEXT,
    block_number    INTEGER,
    tx_hash         TEXT,
    ts              INTEGER
);

-- Staking
CREATE TABLE stakes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    address     TEXT,
    amount      INTEGER,  -- raw USDC (6 decimals)
    block_number INTEGER,
    tx_hash     TEXT,
    ts          INTEGER
);

CREATE TABLE unstake_requests (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    address     TEXT,
    amount      INTEGER,
    unlocks_at  INTEGER,
    block_number INTEGER,
    tx_hash     TEXT,
    ts          INTEGER
);

CREATE TABLE withdrawals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    address     TEXT,
    amount      INTEGER,
    block_number INTEGER,
    tx_hash     TEXT,
    ts          INTEGER
);

CREATE TABLE slashes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    provider    TEXT,
    challenger  TEXT,
    amount      INTEGER,
    block_number INTEGER,
    tx_hash     TEXT,
    ts          INTEGER
);

-- Challenges
CREATE TABLE challenges (
    id              INTEGER PRIMARY KEY,
    endpoint_id     TEXT,
    path            TEXT,
    method          TEXT,
    integrity_hash  TEXT,
    challenger      TEXT,
    status          INTEGER,  -- 0=Pending 1=Valid 2=Invalid
    opened_block    INTEGER,
    opened_tx       TEXT,
    opened_ts       INTEGER,
    resolved_block  INTEGER,
    resolved_tx     TEXT,
    resolved_ts     INTEGER
);

-- Per-provider revenue
CREATE TABLE distributions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    splitter        TEXT,
    provider_id     INTEGER,
    total           INTEGER,
    protocol_share  INTEGER,
    provider_share  INTEGER,
    vault_share     INTEGER,
    rev_share_share INTEGER,
    block_number    INTEGER,
    tx_hash         TEXT,
    ts              INTEGER
);

CREATE TABLE vault_deposits (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    vault       TEXT,
    provider_id INTEGER,
    sender      TEXT,
    owner       TEXT,
    assets      INTEGER,  -- USDC
    shares      INTEGER,
    block_number INTEGER,
    tx_hash     TEXT,
    ts          INTEGER
);

CREATE TABLE vault_withdrawals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    vault       TEXT,
    provider_id INTEGER,
    sender      TEXT,
    receiver    TEXT,
    owner       TEXT,
    assets      INTEGER,
    shares      INTEGER,
    block_number INTEGER,
    tx_hash     TEXT,
    ts          INTEGER
);

CREATE TABLE revenue_claims (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    revenue_share   TEXT,
    provider_id     INTEGER,
    holder          TEXT,
    amount          INTEGER,
    block_number    INTEGER,
    tx_hash         TEXT,
    ts              INTEGER
);
```

---

## API — endpoint reference

Base URL: `http://localhost:8000`

All amounts are returned as human-readable USDC strings (e.g. `"12.50"`) alongside
the raw integer field (e.g. `"12500000"`).

### `GET /overview`

```json
{
  "providers":                     5,
  "endpoints":                     12,
  "total_staked_usdc":             "5000.00",
  "total_staked_raw":              5000000000,
  "total_revenue_distributed_usdc":"1234.56",
  "total_revenue_distributed_raw": 1234560000,
  "vault_tvl_usdc":                "4500.00",
  "challenges": {
    "total":     10,
    "pending":   1,
    "valid":     7,
    "invalid":   2,
    "slash_rate":"20.0%"
  },
  "last_indexed_block": 52510000,
  "last_indexed_ts":    1741400000
}
```

### `GET /providers`

```json
[
  {
    "id":                            1,
    "owner":                         "0x...",
    "vault":                         "0x...",
    "splitter":                      "0x...",
    "revenue_share":                 "0x...",
    "endpoint_count":                3,
    "vault_tvl_usdc":                "1000.00",
    "total_revenue_distributed_usdc":"500.00",
    "total_revenue_distributed_raw": 500000000,
    "challenge_count":               4,
    "slash_count":                   0,
    "deployed_ts":                   1741000000
  }
]
```

### `GET /providers/{id}`

Single provider with full detail — includes all endpoints and a revenue timeline
(daily `distributions` rows for the last 30 days).

### `GET /endpoints`

Query params: `?provider_id=1`

```json
[
  {
    "endpoint_id":    "0x...",
    "provider_id":    1,
    "owner":          "0x...",
    "path":           "https://api.example.com/data",
    "method":         "GET",
    "integrity_hash": "0x...",
    "challenge_count":2,
    "last_challenge_status": "Valid",
    "registered_ts":  1741000000
  }
]
```

### `GET /endpoints/{endpoint_id}`

Single endpoint with full challenge history.

### `GET /challenges`

Query params: `?status=pending|valid|invalid`, `?provider_id=1`, `?limit=50`

```json
[
  {
    "id":             1,
    "endpoint_id":    "0x...",
    "path":           "https://api.example.com/data",
    "method":         "GET",
    "integrity_hash": "0x...",
    "challenger":     "0x...",
    "status":         "Invalid",
    "provider_id":    1,
    "opened_ts":      1741000000,
    "resolved_ts":    1741000120,
    "resolution_time_seconds": 120
  }
]
```

### `GET /staking`

```json
{
  "total_staked_usdc": "5000.00",
  "total_staked_raw":  5000000000,
  "total_slashed_usdc":"100.00",
  "stakers": [
    {
      "address":     "0x...",
      "net_staked":  4000000000,
      "net_staked_usdc": "4000.00",
      "slash_count": 0,
      "slashed_raw": 0
    }
  ]
}
```

### `GET /revenue`

Query params: `?provider_id=1`, `?days=30`

```json
{
  "total_distributed_usdc": "1234.56",
  "by_provider": [
    {
      "provider_id":     1,
      "total_usdc":      "500.00",
      "protocol_share":  "10.00",
      "vault_share":     "460.00",
      "rev_share":       "30.00",
      "provider_direct": "0.00"
    }
  ],
  "timeline": [
    { "date": "2026-03-01", "total_usdc": "123.45" },
    { "date": "2026-03-02", "total_usdc": "88.10"  }
  ]
}
```

### `GET /vault/{vault_address}`

Single vault stats: TVL, share price, deposit/withdrawal history.

### `GET /sync/status`

```json
{
  "contracts": {
    "APIRegistryFactory":    { "last_block": 52510000, "events_indexed": 5   },
    "APIIntegrityRegistry":  { "last_block": 52510000, "events_indexed": 12  },
    "StakeManager":          { "last_block": 52510000, "events_indexed": 20  },
    "ChallengeManager":      { "last_block": 52510000, "events_indexed": 10  },
    "per_provider_contracts":{ "last_block": 52510000, "events_indexed": 35  }
  }
}
```

### `POST /sync`

Triggers a manual re-sync of all events. Returns `{"status": "ok", "blocks_synced": 1200}`.
Useful to call from the Streamlit dashboard's "Refresh" button.

---

## Streamlit dashboard — page map

```
Sidebar
  ├── Last synced: <timestamp>   [Sync Now] button → POST /sync
  └── Navigation

Pages
  ├── Overview
  │     KPI row: Providers · Endpoints · USDC Staked · Revenue Distributed · Open Challenges
  │     Challenge outcome pie chart
  │     Revenue bar chart (last 30 days)
  │     Recent events feed (last 10 across all types)
  │
  ├── Providers
  │     Sortable table: id · owner · endpoints · vault TVL · revenue · challenges
  │     Click row → drill into Provider Detail
  │       Provider Detail: endpoints list, revenue timeline, challenge history
  │
  ├── Endpoints
  │     Filterable table: path · method · provider · hash · last challenge result · age
  │     Click row → full challenge history for that endpoint
  │
  ├── Challenges
  │     Status filter: All / Pending / Valid / Invalid
  │     Table + timeline chart of challenge volume
  │     Slash rate over time (line chart)
  │
  ├── Revenue
  │     Total distributed over time (area chart, stacked by provider)
  │     Per-provider breakdown (horizontal bar)
  │     Bucket split pie: vault vs rev-share vs provider direct vs protocol
  │
  └── Staking
        Total staked (gauge or big number)
        Staker table: address · net staked · slash count
        Slash history timeline
```

---

## Running locally

### Prerequisites

- Contracts deployed and `contracts/broadcast/DeployAll.s.sol/43113/run-latest.json` present
- `analytics/.env` with `GATEWAY_URL` set (Alchemy RPC for Fuji)
- Python dependencies installed:

```bash
cd analytics
uv sync
```

### Step 1 — Initial sync

```bash
cd analytics
uv run python src/analytics_indexer.py --once
```

This reads all historical events from the deploy block to the current head and
writes them into `analytics.db`. On Fuji with sparse activity this takes ~30 seconds.

### Step 2 — Start the API

```bash
cd analytics
uv run uvicorn src.analytics_api:app --port 8000 --reload
```

API is available at `http://localhost:8000`. Interactive docs at `http://localhost:8000/docs`.

### Step 3 — Start the dashboard

Open a second terminal:

```bash
cd analytics
uv run streamlit run src/analytics_dashboard.py
```

Dashboard opens at `http://localhost:8501`.

### Continuous indexer (optional, instead of Step 1)

Keeps the DB live — polls every 30 s for new blocks:

```bash
cd analytics
uv run python src/analytics_indexer.py
```

The Streamlit dashboard has a **Sync Now** button that triggers a one-shot sync
via `POST /sync` without needing the background indexer running.

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `GATEWAY_URL` | Yes | Alchemy (or any) RPC URL for Avalanche Fuji |
| `ANALYTICS_API_URL` | No | Override API base URL in dashboard (default `http://localhost:8000`) |
