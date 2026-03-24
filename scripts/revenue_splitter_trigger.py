"""
revenue_splitter_trigger.py — Trigger revenue distribution on ProviderRevenueSplitter.

Usage:
  uv run python scripts/revenue_splitter_trigger.py

Configure via .env:
  GATEWAY_URL=https://api.avax-test.network/ext/bc/C/rpc
  PRIVATE_KEY=0x...
  # Optionally specify a specific splitter address (otherwise reads from broadcast)
  REVENUE_SPLITTER_ADDRESS=0x...
  # Schedule interval in minutes (default: 15)
  SCHEDULE_INTERVAL_MINUTES=15
"""

import os
import sys
from pathlib import Path
from apscheduler.schedulers.blocking import BlockingScheduler

sys.path.insert(0, str(Path(__file__).parent.parent / "contracts" / "scripts"))

from dotenv import load_dotenv
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware, LocalFilterMiddleware

load_dotenv()

_CONTRACTS_DIR = Path(__file__).parent.parent / "contracts"
_BROADCAST_FILE = _CONTRACTS_DIR / "broadcast" / "DeployAll.s.sol" / "43113" / "run-latest.json"


def build_w3() -> Web3:
    gateway = os.getenv("GATEWAY_URL")
    assert gateway, "GATEWAY_URL not set in .env"
    w3 = Web3(Web3.HTTPProvider(gateway))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    w3.middleware_onion.add(LocalFilterMiddleware)
    return w3


def get_splitter_address() -> str:
    addr = os.getenv("REVENUE_SPLITTER_ADDRESS")
    if not addr:
        raise ValueError("REVENUE_SPLITTER_ADDRESS not set in .env")
    return addr


def main():
    w3 = build_w3()

    private_key = os.getenv("PRIVATE_KEY")
    assert private_key, "PRIVATE_KEY not set in .env"

    account = w3.eth.account.from_key(private_key)
    w3.eth.default_account = account.address

    splitter_address = get_splitter_address()
    print(f"Splitter: {splitter_address}")
    print(f"Caller:   {account.address}")

    # Minimal ABI for distribute()
    abi = [
        {
            "name": "distribute",
            "type": "function",
            "stateMutability": "nonpayable",
            "inputs": [],
            "outputs": [],
        }
    ]

    splitter = w3.eth.contract(address=splitter_address, abi=abi)

    tx = splitter.functions.distribute().build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
    })

    gas_est = w3.eth.estimate_gas(tx)
    block = w3.eth.get_block("latest")
    base_fee = block.get("baseFeePerGas", w3.to_wei(15, "gwei"))
    priority_fee = w3.to_wei(2, "gwei")

    tx.update({
        "gas": int(gas_est * 1.5),
        "maxFeePerGas": int(base_fee * 1.2) + priority_fee,
        "maxPriorityFeePerGas": priority_fee,
    })

    signed = w3.eth.account.sign_transaction(tx, private_key=account.key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)

    explorer = os.getenv("EXPLORER_URL", "https://testnet.snowscan.xyz/tx/")
    print(f"tx: {explorer}{tx_hash.hex()}")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    status = "✓" if receipt.status == 1 else "✗ FAILED"
    print(f"{status}  block={receipt.blockNumber}  gasUsed={receipt.gasUsed}")

    if receipt.status != 1:
        sys.exit(1)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Trigger revenue distribution")
    parser.add_argument("--once", action="store_true", help="Run once and exit")
    args = parser.parse_args()

    interval = int(os.getenv("SCHEDULE_INTERVAL_MINUTES", "15"))

    if args.once or interval == 0:
        main()
    else:
        print(f'Running scheduler job...')
        main()
        scheduler = BlockingScheduler()
        scheduler.add_job(main, "interval", minutes=interval, id="distribute")
        print(f"Scheduling distribute() every {interval} minutes...")
        scheduler.start()
