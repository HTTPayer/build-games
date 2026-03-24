"""
cre_watcher.py — Watches ChallengeManager for ChallengeOpened events and
automatically calls `cre workflow simulate` to settle each challenge on-chain.

On startup it syncs all events from the last saved block (or block 0 on first
run), then polls continuously for new events.  State is persisted so the
watcher resumes correctly after going down — no challenge is ever submitted
twice, and no challenge is permanently skipped as long as the simulate
eventually succeeds.

Usage:
  uv run python -m cre_watcher.cre_watcher
  uv run python -m cre_watcher.cre_watcher --from-block 0          # force full re-scan
  uv run python -m cre_watcher.cre_watcher --once                  # one sync pass, then exit
  uv run python -m cre_watcher.cre_watcher --target staging-settings
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Add src to path for utils import
sys.path.insert(0, str(Path(__file__).parent))

from dotenv import load_dotenv
from web3 import Web3

from utils import get_contract_config, build_w3, BROADCAST_FILE

load_dotenv()

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

POLL_INTERVAL = 15  # seconds between live polls
CHUNK = 2000        # max blocks per get_logs request

_cre_env = os.getenv("CRE_WORK_DIR")
CRE_WORK_DIR = Path(_cre_env) if _cre_env else Path(__file__).parents[1] / "cre"

print(f'CRE_WORK_DIR: {CRE_WORK_DIR}')

# Persisted state
STATE_FILE = Path(__file__).parent / "cre_watcher_state.json"

# Event signature (must match ChallengeManager.sol exactly)
CHALLENGE_OPENED_SIG = "ChallengeOpened(uint256,bytes32,address,string,string,bytes32)"

# ---------------------------------------------------------------------------
# Deployment block helper
# ---------------------------------------------------------------------------

def get_deploy_block(w3: Web3, contract_name: str) -> int:
    """Look up the deployment tx hash from the broadcast file and return its block number."""
    with open(BROADCAST_FILE, encoding="utf-8") as f:
        txs = json.load(f)["transactions"]
    deploy_tx = next(
        (tx for tx in txs
         if tx.get("transactionType") == "CREATE" and tx.get("contractName") == contract_name),
        None,
    )
    if not deploy_tx:
        raise RuntimeError(f"No CREATE tx found for {contract_name} in broadcast file")
    tx_hash = deploy_tx["hash"]
    receipt = w3.eth.get_transaction_receipt(tx_hash)
    return receipt["blockNumber"]


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def load_state() -> dict:
    if STATE_FILE.exists():
        with open(STATE_FILE) as f:
            data = json.load(f)
        # ensure processed is a list of ints
        data["processed"] = [int(x) for x in data.get("processed", [])]
        data.setdefault("last_block", 0)
        return data
    return {"last_block": 0, "processed": []}


def save_state(state: dict):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


# ---------------------------------------------------------------------------
# Find the ChallengeOpened log index within a transaction
# ---------------------------------------------------------------------------

def find_event_index(w3: Web3, tx_hash: str, cm_address: str, topic0: bytes) -> int | None:
    """Return the index of the ChallengeOpened log in the tx receipt, or None."""
    receipt = w3.eth.get_transaction_receipt(tx_hash)
    for i, log in enumerate(receipt["logs"]):
        if (
            log["address"].lower() == cm_address.lower()
            and log["topics"]
            and bytes(log["topics"][0]) == topic0
        ):
            return i
    return None


# ---------------------------------------------------------------------------
# CRE simulate
# ---------------------------------------------------------------------------

def run_cre_simulate(tx_hash: str, event_index: int, target: str) -> bool:
    cmd = [
        "cre", "workflow", "simulate", "integrity-workflow",
        "--non-interactive",
        "--trigger-index",   "0",
        "--evm-tx-hash",     tx_hash,
        "--evm-event-index", str(event_index),
        "--target",          target,
        "--broadcast",
    ]
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(CRE_WORK_DIR))
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Process a single event
# ---------------------------------------------------------------------------

def process_event(
    w3: Web3,
    event,
    cm,
    cm_address: str,
    topic0: bytes,
    state: dict,
    target: str,
):
    challenge_id = int(event["args"]["id"])
    tx_hash      = "0x" + event["transactionHash"].hex()
    block_number = event["blockNumber"]

    if challenge_id in state["processed"]:
        print(f"  [skip] challenge {challenge_id} already settled")
        return

    print(f"\n  challenge {challenge_id}  block={block_number}  tx={tx_hash}")

    # Check on-chain status before simulating — if already resolved, mark and skip.
    # onReport() reverts with "already resolved" if status != Pending, so there's
    # no point running the full CRE workflow.
    c = cm.functions.challenges(challenge_id).call()
    # (challenger, endpointId, status)  0=Pending 1=Valid 2=Invalid
    status = c[2]
    if status != 0:
        status_name = ["Pending", "Valid", "Invalid"][status]
        print(f"  [skip] already resolved on-chain ({status_name}) — marking processed")
        state["processed"].append(challenge_id)
        save_state(state)
        return

    event_index = find_event_index(w3, tx_hash, cm_address, topic0)
    if event_index is None:
        print(f"  [warn] ChallengeOpened log not found in tx receipt — skipping this cycle")
        return

    print(f"  log index : {event_index}")
    ok = run_cre_simulate(tx_hash, event_index, target)

    if ok:
        print(f"  ✓ simulate succeeded — challenge {challenge_id} settled")
        state["processed"].append(challenge_id)
        save_state(state)
    else:
        print(f"  ✗ simulate failed — challenge {challenge_id} will retry next cycle")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="CRE challenge watcher")
    parser.add_argument(
        "--from-block", type=int, default=None,
        help="Override start block (ignores saved last_block)",
    )
    parser.add_argument(
        "--target", default="staging-settings",
        help="CRE workflow --target (default: staging-settings)",
    )
    parser.add_argument(
        "--once", action="store_true",
        help="Run one sync pass then exit instead of polling",
    )
    args = parser.parse_args()

    if not CRE_WORK_DIR.exists():
        sys.exit(f"CRE work dir not found: {CRE_WORK_DIR}")

    w3 = build_w3()
    cm_abi, cm_address = get_contract_config("ChallengeManager")
    cm = w3.eth.contract(address=cm_address, abi=cm_abi)

    topic0 = bytes(Web3.keccak(text=CHALLENGE_OPENED_SIG))

    state = load_state()
    if args.from_block is not None:
        state["last_block"] = args.from_block
        print(f"Overriding start block to {args.from_block}")
    elif state["last_block"] == 0:
        deploy_block = get_deploy_block(w3, "ChallengeManager")
        state["last_block"] = deploy_block
        print(f"First run — starting from ChallengeManager deploy block {deploy_block}")

    print(f"ChallengeManager : {cm_address}")
    print(f"CRE work dir     : {CRE_WORK_DIR}")
    print(f"State file       : {STATE_FILE}")
    print(f"Start block      : {state['last_block']}")
    print(f"Already settled  : {len(state['processed'])} challenge(s)")
    print()

    while True:
        current_block = w3.eth.block_number
        from_block    = state["last_block"]

        if from_block <= current_block:
            print(f"[{time.strftime('%H:%M:%S')}] blocks {from_block}–{current_block}")
            events = []
            start = from_block
            while start <= current_block:
                end = min(start + CHUNK - 1, current_block)
                try:
                    chunk = cm.events.ChallengeOpened.get_logs(
                        from_block=start, to_block=end,
                    )
                    events.extend(chunk)
                except Exception as exc:
                    print(f"  [warn] get_logs {start}-{end}: {exc}")
                start = end + 1
            print(f"  {len(events)} new ChallengeOpened event(s)")

            for event in events:
                process_event(w3, event, cm, cm_address, topic0, state, args.target)

            # Advance past the last scanned block so we never re-scan it
            state["last_block"] = current_block + 1
            save_state(state)
        else:
            print(f"[{time.strftime('%H:%M:%S')}] up to date (block {current_block})")

        if args.once:
            break

        print(f"  sleeping {POLL_INTERVAL}s…\n")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
