# Codebase Reorganization Plan

## Overview

Current structure has all protocol-interaction scripts in `contracts/scripts/`, which mixes:
- CLI tools
- SDK
- Watchers
- Analytics tools

This plan reorganizes into focused top-level directories.

---

## Proposed Directory Structure

```
build-games/
├── cli/                    # CLI tools for providers and admins
├── sdk/                    # Python SDK (currently at contracts/composed)
├── cre_watcher/           # CRE workflow trigger for challenge resolution
├── challenger_watcher/    # Autonomous challenger bot
├── analytics/             # Analytics indexer + REST API
├── abis/                  # Contract ABIs (move from root)
├── contracts/             # Solidity contracts (unchanged)
└── cre/                   # CRE workflow definitions (unchanged)
```

---

## Detailed Moves

### 1. CLI Directory (`cli/`)

**Files to move:**
| File | Purpose | New Path |
|------|---------|----------|
| `cli.py` | Main provider CLI (stake, deploy, register, challenge) | `cli/cli.py` |
| `admin_cli.py` | Protocol admin configuration | `cli/admin_cli.py` |
| `verify.py` | Snowtrace contract verification | `cli/verify.py` |
| `x402_metadata.py` | x402 integrity hash fetching | `cli/x402_metadata.py` |

**Shared utilities to create:**
- `cli/utils.py` — copy of `contracts/scripts/utils.py` with adjusted paths

**ABI path changes:**
```python
# Current (in utils.py):
_CONTRACTS_DIR = os.path.join(os.path.dirname(__file__), "..")

# After move (cli/utils.py):
_CONTRACTS_DIR = os.path.join(os.path.dirname(__file__), "..", "contracts")
```

**Imports to update in moved files:**
```python
# cli.py line 43-45:
# FROM: from utils import get_abi, send_tx
# TO:   from .utils import get_abi, send_tx

# cli.py line 48:
# FROM: from composed import ComposedClient  
# TO:   from sdk import ComposedClient (or adjust sys.path)
```

---

### 2. SDK Directory (`sdk/`)

**Files to move:**
| File | Purpose |
|------|---------|
| `contracts/composed/*` | All SDK modules (`__init__.py`, `client.py`, `types.py`, etc.) |

**ABI path changes:**
- SDK uses `from ._abis import ...` to load embedded ABIs
- Path to `contracts/out/` may need to be adjusted if SDK reads compiled artifacts
- Check `contracts/composed/_abis.py` and `contracts/composed/_addresses.py`

---

### 3. CRE Watcher (`cre_watcher/`)

**Files to move:**
| File | Purpose |
|------|---------|
| `contracts/scripts/cre_watcher.py` | Watches ChallengeManager, triggers CRE workflow |

**Dependencies:**
- `utils.py` (shared or local copy)

**ABI path changes:**
```python
# Current: sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# TO:     sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cli"))  # for utils

# BROADCAST_FILE path changes from:
#   contracts/broadcast/DeployAll.s.sol/43113/run-latest.json
# TO:
#   ../contracts/broadcast/DeployAll.s.sol/43113/run-latest.json
```

---

### 4. Challenger Watcher (`challenger_watcher/`)

**Files to move:**
| File | Purpose |
|------|---------|
| `contracts/scripts/challenger_watcher.py` | Autonomous challenger bot |

**Dependencies:**
- `utils.py` (shared or local copy)
- `x402_metadata.py` (or import from `cli/`)

**ABI path changes:** Same pattern as CRE watcher

---

### 5. Analytics (`analytics/`)

**Files to move:**
| File | Purpose |
|------|---------|
| `contracts/scripts/analytics_api.py` | FastAPI REST API |
| `contracts/scripts/analytics_indexer.py` | Event indexer to SQLite |
| `contracts/scripts/analytics.db` | SQLite database |
| `contracts/scripts/analytics_state.json` | Indexer state |

**Dependencies:**
- `utils.py` for `get_abi`, `get_contract_config`, `build_w3`, `BROADCAST_FILE`

**ABI path changes:** Same pattern as watchers

---

### 6. ABIs (`abis/`)

Currently at root `abis/`. Keep in place or move to `sdk/abis/` if SDK needs them.

---

## Shared Utility Strategy

Two options:

### Option A: Copy utils.py to each directory
- Simple but code duplication
- Each directory has its own `utils.py` with adjusted paths

### Option B: Create a shared `lib/` or `common/` directory
```
build-games/
├── lib/                   # Shared utilities
│   └── utils.py
├── cli/
├── sdk/
├── cre_watcher/
├── challenger_watcher/
└── analytics/
```

**Recommendation:** Option B is cleaner. Create `lib/utils.py` with configurable base path.

---

## Path Adjustment Reference

| Constant | Current Value | New Value |
|----------|---------------|-----------|
| `BROADCAST_FILE` | `contracts/broadcast/...` | `../contracts/broadcast/...` |
| `_CONTRACTS_DIR` | `os.path.join(_TEST_DIR, "..")` | `os.path.join(_TEST_DIR, "..", "..", "contracts")` |
| `get_abi(name)` artifact path | `contracts/out/{name}.sol/{name}.json` | `../contracts/out/{name}.sol/{name}.json` |

---

## Execution Order

1. Create new directories
2. Move SDK to `sdk/`
3. Create `lib/utils.py` with adjustable base path
4. Move CLI files to `cli/`, update imports
5. Move watchers to respective directories
6. Move analytics to `analytics/`
7. Delete old `contracts/scripts/` (after verifying no remaining files)
8. Update any CI/CD scripts that reference old paths
9. Update README references

---

## Testing After Move

```bash
# CLI
cd cli && uv run python cli.py status

# CRE watcher
cd cre_watcher && uv run python cre_watcher.py --once

# Challenger watcher  
cd challenger_watcher && uv run python challenger_watcher.py --once

# Analytics
cd analytics && uv run python analytics_indexer.py --once
uv run uvicorn analytics_api:app --reload
```