"""
analytics_indexer.py — Protocol analytics indexer for Avalanche Fuji testnet.

Indexes events from APIRegistryFactory, APIIntegrityRegistry, StakeManager,
ChallengeManager, and per-provider contracts (splitter, revenue share)
into a local SQLite database.

Usage:
  uv run python analytics_indexer.py
  uv run python analytics_indexer.py --once
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dotenv import load_dotenv
from web3 import Web3

from utils import build_w3, get_abi, get_contract_config, BROADCAST_FILE

load_dotenv()

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DB_PATH: Path = Path(__file__).parent / "analytics.db"
STATE_PATH: Path = Path(__file__).parent / "analytics_state.json"

CHUNK: int = 2000
POLL_INTERVAL: int = 30
FALLBACK_DEPLOY_BLOCK: int = 52_477_983

# Cache block timestamps to avoid repeated RPC calls
_block_ts: dict[int, int] = {}

# ---------------------------------------------------------------------------
# Database schema
# ---------------------------------------------------------------------------

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    last_block INT DEFAULT 0,
    events_indexed INT DEFAULT 0
);

CREATE TABLE IF NOT EXISTS providers (
    id INT,
    owner TEXT,
    splitter TEXT,
    revenue_share TEXT,
    deployer TEXT,
    rev_share_bp INT,
    provider_bp INT,
    protocol_bp INT,
    block_number INT,
    tx_hash TEXT UNIQUE,
    ts INT
);

CREATE TABLE IF NOT EXISTS endpoints (
    endpoint_id TEXT PRIMARY KEY,
    provider_id INT,
    owner TEXT,
    path TEXT,
    method TEXT,
    integrity_hash TEXT,
    block_number INT,
    tx_hash TEXT,
    ts INT
);

CREATE TABLE IF NOT EXISTS stakes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT,
    amount INT,
    block_number INT,
    tx_hash TEXT,
    ts INT
);

CREATE TABLE IF NOT EXISTS unstake_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT,
    unlock_time INT,
    block_number INT,
    tx_hash TEXT,
    ts INT
);

CREATE TABLE IF NOT EXISTS withdrawals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT,
    amount INT,
    block_number INT,
    tx_hash TEXT,
    ts INT
);

CREATE TABLE IF NOT EXISTS slashes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT,
    slash_amount INT,
    challenger_reward INT,
    protocol_cut INT,
    block_number INT,
    tx_hash TEXT,
    ts INT
);

CREATE TABLE IF NOT EXISTS challenges (
    id INT PRIMARY KEY,
    endpoint_id TEXT,
    path TEXT,
    method TEXT,
    integrity_hash TEXT,
    challenger TEXT,
    status INT DEFAULT 0,
    opened_block INT,
    opened_tx TEXT,
    opened_ts INT,
    resolved_block INT,
    resolved_tx TEXT,
    resolved_ts INT
);

CREATE TABLE IF NOT EXISTS distributions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    splitter TEXT,
    provider_id INT,
    total INT,
    protocol_share INT,
    provider_share INT,
    rev_share_share INT,
    block_number INT,
    tx_hash TEXT,
    ts INT
);

CREATE TABLE IF NOT EXISTS revenue_claims (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    revenue_share TEXT,
    provider_id INT,
    holder TEXT,
    amount INT,
    block_number INT,
    tx_hash TEXT,
    ts INT
);
"""


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA_SQL)
    conn.commit()


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def load_state() -> dict[str, Any]:
    if STATE_PATH.exists():
        with open(STATE_PATH, encoding="utf-8") as f:
            return json.load(f)
    return {
        "core": {"last_block": 0},
        "per_provider": {"last_block": 0},
    }


def save_state(state: dict[str, Any]) -> None:
    with open(STATE_PATH, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


# ---------------------------------------------------------------------------
# Block timestamp
# ---------------------------------------------------------------------------

def get_block_ts(w3: Web3, block_number: int) -> int:
    if block_number not in _block_ts:
        block = w3.eth.get_block(block_number)
        _block_ts[block_number] = int(block["timestamp"])
    return _block_ts[block_number]


# ---------------------------------------------------------------------------
# Deploy block helper
# ---------------------------------------------------------------------------

def get_deploy_block(w3: Web3) -> int:
    try:
        with open(BROADCAST_FILE, encoding="utf-8") as f:
            txs = json.load(f)["transactions"]
        first_tx = txs[0]
        receipt = w3.eth.get_transaction_receipt(first_tx["hash"])
        return int(receipt["blockNumber"])
    except Exception:
        return FALLBACK_DEPLOY_BLOCK


# ---------------------------------------------------------------------------
# Chunked event fetch
# ---------------------------------------------------------------------------

def fetch_events(
    w3: Web3,
    contract: Any,
    event_name: str,
    from_block: int,
    to_block: int,
) -> list[Any]:
    event_obj = getattr(contract.events, event_name)
    all_events: list[Any] = []
    start = from_block
    while start <= to_block:
        end = min(start + CHUNK - 1, to_block)
        try:
            logs = event_obj.get_logs(from_block=start, to_block=end)
            all_events.extend(logs)
        except Exception as exc:
            print(f"    [warn] fetch_events {event_name} {start}-{end}: {exc}")
        start = end + 1
    return all_events


# ---------------------------------------------------------------------------
# Processors
# ---------------------------------------------------------------------------

def process_factory(
    w3: Web3,
    factory: Any,
    from_block: int,
    to_block: int,
    conn: sqlite3.Connection,
) -> int:
    events = fetch_events(w3, factory, "ProviderDeployed", from_block, to_block)
    count = 0
    for ev in events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)

        try:
            conn.execute(
                """
                INSERT OR IGNORE INTO providers
                (id, owner, splitter, revenue_share, deployer,
                 rev_share_bp, provider_bp, protocol_bp,
                 block_number, tx_hash, ts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    None,  # id filled in by ProviderRegistered join
                    Web3.to_checksum_address(args["revenueShareRecipient"]),
                    Web3.to_checksum_address(args["splitter"]),
                    Web3.to_checksum_address(args["revenueShare"]),
                    Web3.to_checksum_address(args["deployer"]),
                    int(args["revenueShareBp"]),
                    int(args["providerTreasuryBp"]),
                    int(args["protocolTreasuryBp"]),
                    block_num,
                    tx_hash,
                    ts,
                ),
            )
            count += 1
        except sqlite3.IntegrityError:
            pass  # already indexed

    conn.commit()
    return count


def process_registry(
    w3: Web3,
    registry: Any,
    from_block: int,
    to_block: int,
    conn: sqlite3.Connection,
) -> int:
    count = 0

    # ProviderRegistered — link provider id to the providers row via tx_hash
    reg_events = fetch_events(w3, registry, "ProviderRegistered", from_block, to_block)
    for ev in reg_events:
        args = ev["args"]
        tx_hash = ev["transactionHash"].hex()
        provider_id = int(args["id"])
        owner = Web3.to_checksum_address(args["owner"])

        # Update the matching providers row (same tx as ProviderDeployed)
        conn.execute(
            "UPDATE providers SET id = ?, owner = ? WHERE tx_hash = ?",
            (provider_id, owner, tx_hash),
        )
        count += 1

    # EndpointRegistered — call registry.endpoints() for full data
    ep_events = fetch_events(w3, registry, "EndpointRegistered", from_block, to_block)
    for ev in ep_events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)
        endpoint_id_bytes = args["endpointId"]
        endpoint_id_hex = "0x" + endpoint_id_bytes.hex()

        try:
            ep = registry.functions.endpoints(endpoint_id_bytes).call()
            # (endpointId, provider, path, method, integrityHash, version, active, checkedAt, createdAt)
            _, ep_provider, path, method, integrity_hash_bytes, _, _, _, _ = ep
            integrity_hash = "0x" + integrity_hash_bytes.hex()
            ep_provider_addr = Web3.to_checksum_address(ep_provider)
        except Exception as exc:
            print(f"    [warn] registry.endpoints({endpoint_id_hex}): {exc}")
            path = ""
            method = ""
            integrity_hash = ""
            ep_provider_addr = Web3.to_checksum_address(args["provider"])

        # Look up provider_id by provider address
        row = conn.execute(
            "SELECT id FROM providers WHERE owner = ?",
            (ep_provider_addr,),
        ).fetchone()
        provider_id = row[0] if row else None

        try:
            conn.execute(
                """
                INSERT OR REPLACE INTO endpoints
                (endpoint_id, provider_id, owner, path, method, integrity_hash,
                 block_number, tx_hash, ts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    endpoint_id_hex,
                    provider_id,
                    ep_provider_addr,
                    path,
                    method,
                    integrity_hash,
                    block_num,
                    tx_hash,
                    ts,
                ),
            )
            count += 1
        except sqlite3.IntegrityError:
            pass

    conn.commit()
    return count


def process_staking(
    w3: Web3,
    stake_manager: Any,
    from_block: int,
    to_block: int,
    conn: sqlite3.Connection,
) -> int:
    count = 0

    staked_events = fetch_events(w3, stake_manager, "Staked", from_block, to_block)
    for ev in staked_events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)
        conn.execute(
            """
            INSERT INTO stakes (address, amount, block_number, tx_hash, ts)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                Web3.to_checksum_address(args["provider"]),
                int(args["amount"]),
                block_num,
                tx_hash,
                ts,
            ),
        )
        count += 1

    unstake_events = fetch_events(w3, stake_manager, "UnstakeRequested", from_block, to_block)
    for ev in unstake_events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)
        conn.execute(
            """
            INSERT INTO unstake_requests (address, unlock_time, block_number, tx_hash, ts)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                Web3.to_checksum_address(args["provider"]),
                int(args["unlockTime"]),
                block_num,
                tx_hash,
                ts,
            ),
        )
        count += 1

    withdrawn_events = fetch_events(w3, stake_manager, "Withdrawn", from_block, to_block)
    for ev in withdrawn_events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)
        conn.execute(
            """
            INSERT INTO withdrawals (address, amount, block_number, tx_hash, ts)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                Web3.to_checksum_address(args["provider"]),
                int(args["amount"]),
                block_num,
                tx_hash,
                ts,
            ),
        )
        count += 1

    slashed_events = fetch_events(w3, stake_manager, "Slashed", from_block, to_block)
    for ev in slashed_events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)
        conn.execute(
            """
            INSERT INTO slashes
            (provider, slash_amount, challenger_reward, protocol_cut,
             block_number, tx_hash, ts)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                Web3.to_checksum_address(args["provider"]),
                int(args["slashAmount"]),
                int(args["challengerReward"]),
                int(args["protocolCut"]),
                block_num,
                tx_hash,
                ts,
            ),
        )
        count += 1

    conn.commit()
    return count


def process_challenges(
    w3: Web3,
    challenge_manager: Any,
    from_block: int,
    to_block: int,
    conn: sqlite3.Connection,
) -> int:
    count = 0

    opened_events = fetch_events(w3, challenge_manager, "ChallengeOpened", from_block, to_block)
    for ev in opened_events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)
        challenge_id = int(args["id"])
        endpoint_id_hex = "0x" + args["endpointId"].hex()
        path = args.get("path", "")
        method = args.get("method", "")
        integrity_hash = "0x" + args["integrityHash"].hex() if args.get("integrityHash") else ""

        # Fetch challenger from on-chain
        challenger = ""
        try:
            challenge_data = challenge_manager.functions.challenges(challenge_id).call()
            # (challenger, endpointId, status)
            challenger = Web3.to_checksum_address(challenge_data[0])
        except Exception as exc:
            print(f"    [warn] challengeManager.challenges({challenge_id}): {exc}")

        try:
            conn.execute(
                """
                INSERT OR IGNORE INTO challenges
                (id, endpoint_id, path, method, integrity_hash, challenger,
                 status, opened_block, opened_tx, opened_ts)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                """,
                (
                    challenge_id,
                    endpoint_id_hex,
                    path,
                    method,
                    integrity_hash,
                    challenger,
                    block_num,
                    tx_hash,
                    ts,
                ),
            )
            count += 1
        except sqlite3.IntegrityError:
            pass

    resolved_events = fetch_events(w3, challenge_manager, "ChallengeResolved", from_block, to_block)
    for ev in resolved_events:
        args = ev["args"]
        block_num = ev["blockNumber"]
        tx_hash = ev["transactionHash"].hex()
        ts = get_block_ts(w3, block_num)
        challenge_id = int(args["id"])
        result = int(args["result"])

        conn.execute(
            """
            UPDATE challenges
            SET status = ?, resolved_block = ?, resolved_tx = ?, resolved_ts = ?
            WHERE id = ?
            """,
            (result, block_num, tx_hash, ts, challenge_id),
        )
        count += 1

    conn.commit()
    return count


def process_per_provider(
    w3: Web3,
    from_block: int,
    to_block: int,
    conn: sqlite3.Connection,
) -> int:
    providers = conn.execute(
        "SELECT id, splitter, revenue_share FROM providers WHERE revenue_share IS NOT NULL"
    ).fetchall()

    splitter_abi = get_abi("ProviderRevenueSplitter")
    rev_share_abi = get_abi("ProviderRevenueShare")

    count = 0

    for row in providers:
        provider_id, splitter_addr, rev_share_addr = row

        # --- Splitter: Distributed ---
        try:
            splitter = w3.eth.contract(
                address=Web3.to_checksum_address(splitter_addr), abi=splitter_abi
            )
            dist_events = fetch_events(w3, splitter, "Distributed", from_block, to_block)
            for ev in dist_events:
                args = ev["args"]
                block_num = ev["blockNumber"]
                tx_hash = ev["transactionHash"].hex()
                ts = get_block_ts(w3, block_num)
                conn.execute(
                    """
                    INSERT INTO distributions
                    (splitter, provider_id, total, protocol_share, provider_share,
                     rev_share_share, block_number, tx_hash, ts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        splitter_addr,
                        provider_id,
                        int(args["totalAmount"]),
                        int(args["protocolAmount"]),
                        int(args["providerAmount"]),
                        int(args["revenueShareAmount"]),
                        block_num,
                        tx_hash,
                        ts,
                    ),
                )
                count += 1
        except Exception as exc:
            print(f"    [warn] splitter {splitter_addr} Distributed: {exc}")

        # --- Revenue Share: Claimed ---
        try:
            rev_share = w3.eth.contract(
                address=Web3.to_checksum_address(rev_share_addr), abi=rev_share_abi
            )
            claimed_events = fetch_events(w3, rev_share, "Claimed", from_block, to_block)
            for ev in claimed_events:
                args = ev["args"]
                block_num = ev["blockNumber"]
                tx_hash = ev["transactionHash"].hex()
                ts = get_block_ts(w3, block_num)
                conn.execute(
                    """
                    INSERT INTO revenue_claims
                    (revenue_share, provider_id, holder, amount, block_number, tx_hash, ts)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        rev_share_addr,
                        provider_id,
                        Web3.to_checksum_address(args["holder"]),
                        int(args["amount"]),
                        block_num,
                        tx_hash,
                        ts,
                    ),
                )
                count += 1
        except Exception as exc:
            print(f"    [warn] rev_share {rev_share_addr} Claimed: {exc}")

    conn.commit()
    return count


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

def sync_once(w3: Web3, conn: sqlite3.Connection) -> None:
    state = load_state()

    current_block = w3.eth.block_number
    deploy_block = get_deploy_block(w3)

    # --- Core contracts ---
    core_from = max(state["core"]["last_block"] + 1, deploy_block)
    core_to = current_block

    if core_from <= core_to:
        print(f"[core] syncing blocks {core_from} -> {core_to}")

        factory_abi, factory_address = get_contract_config("APIRegistryFactory")
        factory = w3.eth.contract(address=factory_address, abi=factory_abi)

        registry_abi_data = get_abi("APIIntegrityRegistry")
        registry_address = Web3.to_checksum_address(factory.functions.registry().call())
        registry = w3.eth.contract(address=registry_address, abi=registry_abi_data)

        stake_manager_abi, stake_manager_address = get_contract_config("StakeManager")
        stake_manager = w3.eth.contract(address=stake_manager_address, abi=stake_manager_abi)

        challenge_manager_abi, challenge_manager_address = get_contract_config("ChallengeManager")
        challenge_manager = w3.eth.contract(
            address=challenge_manager_address, abi=challenge_manager_abi
        )

        n = process_factory(w3, factory, core_from, core_to, conn)
        print(f"  factory: {n} events")

        n = process_registry(w3, registry, core_from, core_to, conn)
        print(f"  registry: {n} events")

        n = process_staking(w3, stake_manager, core_from, core_to, conn)
        print(f"  staking: {n} events")

        n = process_challenges(w3, challenge_manager, core_from, core_to, conn)
        print(f"  challenges: {n} events")

        # Update sync_state table
        for key in ("factory", "registry", "staking", "challenges"):
            conn.execute(
                """
                INSERT INTO sync_state (key, last_block)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET last_block = excluded.last_block
                """,
                (key, core_to),
            )
        conn.commit()

        state["core"]["last_block"] = core_to

    # --- Per-provider contracts ---
    pp_from = max(state["per_provider"]["last_block"] + 1, deploy_block)
    pp_to = current_block

    if pp_from <= pp_to:
        print(f"[per_provider] syncing blocks {pp_from} -> {pp_to}")
        n = process_per_provider(w3, pp_from, pp_to, conn)
        print(f"  per_provider: {n} events")

        conn.execute(
            """
            INSERT INTO sync_state (key, last_block)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET last_block = excluded.last_block
            """,
            ("per_provider", pp_to),
        )
        conn.commit()

        state["per_provider"]["last_block"] = pp_to

    save_state(state)
    print(f"[sync] done — current block {current_block}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="HTTPayer protocol analytics indexer")
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single sync then exit",
    )
    args = parser.parse_args()

    w3 = build_w3()

    conn = sqlite3.connect(DB_PATH)
    init_db(conn)

    print(f"DB        : {DB_PATH}")
    print(f"State     : {STATE_PATH}")
    print(f"Chain     : {w3.eth.chain_id}")
    print()

    while True:
        try:
            sync_once(w3, conn)
        except Exception as exc:
            print(f"[error] {exc}")

        if args.once:
            break

        print(f"  sleeping {POLL_INTERVAL}s…\n")
        time.sleep(POLL_INTERVAL)

    conn.close()


if __name__ == "__main__":
    main()
