"""
challenger_watcher.py — Autonomous challenger bot.

Continuously monitors all registered endpoints in APIIntegrityRegistry,
independently computes the x402 integrity hash, and opens a challenge on
ChallengeManager when the live hash doesn't match the on-chain value.

Behaviour:
  - On first run: scans from the registry deploy block to discover all existing endpoints
  - Each cycle: discovers newly registered endpoints, then checks each endpoint
    (subject to --check-interval cooldown per endpoint)
  - Won't re-challenge an endpoint that already has a pending challenge
  - Tracks pending challenges and clears them when resolved
  - State is persisted — safe to restart at any time

Usage:
  uv run python challenger_watcher.py
  uv run python challenger_watcher.py --once
  uv run python challenger_watcher.py --check-interval 300
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dotenv import load_dotenv
from web3.logs import DISCARD

from src.utils import (
    get_contract_config, get_abi, build_w3, build_account,
    send_tx, ERC20_ABI, BROADCAST_FILE,
)
from src.x402_metadata import fetch_integrity_hash

load_dotenv()

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

POLL_INTERVAL  = 30   # seconds between poll cycles
CHECK_INTERVAL = 300  # default seconds between re-checking the same endpoint
CHUNK = 2000          # max blocks per get_logs request

STATE_FILE = Path(__file__).parent / "challenger_watcher_state.json"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

w3      = build_w3()
account = build_account(w3, role="provider")

cm_abi, cm_address          = get_contract_config("ChallengeManager")
factory_abi, factory_address = get_contract_config("APIRegistryFactory")

cm      = w3.eth.contract(address=cm_address,      abi=cm_abi)
factory = w3.eth.contract(address=factory_address, abi=factory_abi)

usdc_address = factory.functions.USDC().call()
usdc         = w3.eth.contract(address=usdc_address, abi=ERC20_ABI)

registry_abi     = get_abi("APIIntegrityRegistry")
registry_address = factory.functions.registry().call()
registry         = w3.eth.contract(
    address=w3.to_checksum_address(registry_address), abi=registry_abi
)

# ---------------------------------------------------------------------------
# Deployment block helper
# ---------------------------------------------------------------------------

def get_deploy_block(contract_name: str) -> int:
    with open(BROADCAST_FILE, encoding="utf-8") as f:
        txs = json.load(f)["transactions"]
    deploy_tx = next(
        (tx for tx in txs
         if tx.get("transactionType") == "CREATE" and tx.get("contractName") == contract_name),
        None,
    )
    if not deploy_tx:
        raise RuntimeError(f"No CREATE tx found for {contract_name} in broadcast")
    receipt = w3.eth.get_transaction_receipt(deploy_tx["hash"])
    return receipt["blockNumber"]

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def load_state() -> dict:
    if STATE_FILE.exists():
        with open(STATE_FILE) as f:
            return json.load(f)
    return {
        "endpoints_scanned_to": 0,   # last block scanned for EndpointRegistered events
        "known_endpoints":      [],  # list of all known endpointId hex strings
        "last_checked":         {},  # endpointId -> unix timestamp of last check
        "pending":              {},  # endpointId -> challenge_id (unresolved challenges)
    }


def save_state(state: dict):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

# ---------------------------------------------------------------------------
# Endpoint discovery
# ---------------------------------------------------------------------------

def sync_new_endpoints(state: dict):
    """Scan for newly registered endpoints since last scan and add to known list."""
    current_block = w3.eth.block_number
    from_block    = state["endpoints_scanned_to"] + 1
    if from_block > current_block:
        return 0

    all_events = []
    start = from_block
    while start <= current_block:
        end = min(start + CHUNK - 1, current_block)
        try:
            chunk = registry.events.EndpointRegistered.get_logs(
                from_block=start, to_block=end,
            )
            all_events.extend(chunk)
        except Exception as exc:
            print(f"  [warn] get_logs {start}-{end}: {exc}")
        start = end + 1

    added = 0
    for ev in all_events:
        eid_hex = "0x" + ev["args"]["endpointId"].hex()
        if eid_hex not in state["known_endpoints"]:
            state["known_endpoints"].append(eid_hex)
            added += 1
            print(f"  [new endpoint] {eid_hex}")

    state["endpoints_scanned_to"] = current_block
    return added

# ---------------------------------------------------------------------------
# Pending challenge resolution
# ---------------------------------------------------------------------------

def resolve_pending(state: dict):
    """Check on-chain status of pending challenges and remove resolved ones."""
    if not state["pending"]:
        return

    resolved = []
    for eid_hex, cid in state["pending"].items():
        c           = cm.functions.challenges(cid).call()
        # (challenger, endpointId, status)  0=Pending 1=Valid 2=Invalid
        status_name = ["Pending", "Valid", "Invalid"][c[2]]
        if c[2] != 0:
            print(f"  [challenge {cid}] → {status_name}  ({eid_hex[:16]}…)")
            resolved.append(eid_hex)

    for eid_hex in resolved:
        del state["pending"][eid_hex]

    if resolved:
        save_state(state)

# ---------------------------------------------------------------------------
# Per-endpoint check
# ---------------------------------------------------------------------------

def check_endpoint(eid_hex: str, state: dict, check_interval: int):
    now  = int(time.time())
    last = state["last_checked"].get(eid_hex, 0)

    if now - last < check_interval:
        return  # checked recently enough — respect cooldown

    if eid_hex in state["pending"]:
        print(f"  [skip] {eid_hex[:16]}… — pending challenge #{state['pending'][eid_hex]}")
        return

    # Read on-chain endpoint
    eid_bytes = bytes.fromhex(eid_hex.removeprefix("0x"))
    ep = registry.functions.endpoints(eid_bytes).call()
    # (endpointId, provider, path, method, integrityHash, version, active, checkedAt, createdAt)
    _, provider, path, method, on_chain_hash, _, active, _, _ = ep

    if not active:
        return  # deactivated — skip silently

    on_chain_hex = "0x" + on_chain_hash.hex()

    print(f"\n  {method} {path}")
    print(f"    provider   : {provider}")
    print(f"    on-chain   : {on_chain_hex}")

    state["last_checked"][eid_hex] = now

    try:
        live_hash = fetch_integrity_hash(path, verbose=False)
    except Exception as e:
        print(f"    [warn] fetch error: {e} — skipping")
        save_state(state)
        return

    print(f"    live       : {live_hash}")

    if live_hash.lower() == on_chain_hex.lower():
        print(f"    ✓ match")
        save_state(state)
        return

    # Hash mismatch — open challenge
    print(f"    ✗ MISMATCH — challenging!")

    challenge_fee = cm.functions.challengeFee().call()
    usdc_bal      = usdc.functions.balanceOf(account.address).call()
    if usdc_bal < challenge_fee:
        print(f"    [warn] insufficient USDC for challenge fee "
              f"({usdc_bal/1e6:.2f} < {challenge_fee/1e6:.2f}) — skipping")
        save_state(state)
        return

    send_tx(w3, account, usdc.functions.approve(cm_address, challenge_fee), "approve")
    receipt = send_tx(w3, account, cm.functions.openChallenge(eid_bytes), "openChallenge")

    events = cm.events.ChallengeOpened().process_receipt(receipt, errors=DISCARD)
    if events:
        cid = int(events[0]["args"]["id"])
        print(f"    challenge #{cid} opened")
        state["pending"][eid_hex] = cid

    save_state(state)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="HTTPayer challenger watcher")
    parser.add_argument(
        "--once", action="store_true",
        help="Run one full cycle then exit",
    )
    parser.add_argument(
        "--check-interval", type=int, default=CHECK_INTERVAL,
        help=f"Seconds between re-checking each endpoint (default: {CHECK_INTERVAL})",
    )
    args = parser.parse_args()

    state = load_state()

    # First run: start from the registry deploy block
    if state["endpoints_scanned_to"] == 0:
        deploy_block = get_deploy_block("APIIntegrityRegistry")
        state["endpoints_scanned_to"] = deploy_block - 1
        print(f"First run — scanning from registry deploy block {deploy_block}")

    print(f"Challenger       : {account.address}")
    print(f"ChallengeManager : {cm_address}")
    print(f"Registry         : {registry_address}")
    print(f"USDC balance     : {usdc.functions.balanceOf(account.address).call() / 1e6:.2f} USDC")
    print(f"Check interval   : {args.check_interval}s")
    print(f"State file       : {STATE_FILE}")
    print()

    while True:
        print(f"[{time.strftime('%H:%M:%S')}] polling…")

        # 1. Resolve any pending challenges
        resolve_pending(state)

        # 2. Discover new endpoints
        added = sync_new_endpoints(state)
        if added:
            print(f"  {added} new endpoint(s) discovered")
        save_state(state)

        # 3. Check each known endpoint
        total = len(state["known_endpoints"])
        if total == 0:
            print(f"  no endpoints registered yet")
        else:
            print(f"  checking {total} endpoint(s)…")
            for eid_hex in state["known_endpoints"]:
                check_endpoint(eid_hex, state, args.check_interval)

        if args.once:
            break

        print(f"\n  sleeping {POLL_INTERVAL}s…\n")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
