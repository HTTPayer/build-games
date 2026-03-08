"""Shared helpers for all contract test scripts."""

import os
import json
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware, LocalFilterMiddleware
from dotenv import load_dotenv

load_dotenv()

_TEST_DIR      = os.path.dirname(os.path.abspath(__file__))
_CONTRACTS_DIR = os.path.join(_TEST_DIR, "..")
BROADCAST_FILE = os.path.join(
    _CONTRACTS_DIR, "broadcast", "DeployAll.s.sol", "43113", "run-latest.json"
)

# Minimal ERC-20 ABI — just what we need for approve / balance / allowance checks.
ERC20_ABI = [
    {"name": "approve",   "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}],
     "outputs": [{"name": "", "type": "bool"}]},
    {"name": "balanceOf", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"name": "allowance", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"name": "decimals",  "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"name": "", "type": "uint8"}]},
]


def get_abi(name: str):
    """Return the ABI for a contract by name (no address lookup)."""
    artifact = os.path.join(_CONTRACTS_DIR, "out", f"{name}.sol", f"{name}.json")
    with open(artifact, encoding="utf-8") as f:
        return json.load(f)["abi"]


def get_contract_config(name: str):
    """Return (abi, checksummed_address) for a contract deployed by DeployAll.s.sol."""
    artifact = os.path.join(_CONTRACTS_DIR, "out", f"{name}.sol", f"{name}.json")
    with open(artifact, encoding="utf-8") as f:
        abi = json.load(f)["abi"]

    with open(BROADCAST_FILE, encoding="utf-8") as f:
        txs = json.load(f)["transactions"]

    address = next(
        tx["contractAddress"]
        for tx in txs
        if tx.get("transactionType") == "CREATE" and tx.get("contractName") == name
    )
    return abi, Web3.to_checksum_address(address)


def build_w3() -> Web3:
    """Build a Web3 instance configured for Avalanche Fuji (POA chain)."""
    gateway = os.getenv("GATEWAY_URL")
    assert gateway, "GATEWAY_URL not set in .env"
    w3 = Web3(Web3.HTTPProvider(gateway))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    w3.middleware_onion.add(LocalFilterMiddleware)
    return w3


def build_account(w3: Web3, role: str = "admin"):
    """
    Load a signing account from env vars.

    role="admin"    → reads PRIVATE_KEY         (protocol deployer / admin)
    role="provider" → reads PROVIDER_PRIVATE_KEY if set, falls back to PRIVATE_KEY
    """
    if role == "provider":
        private_key = os.getenv("PROVIDER_PRIVATE_KEY") or os.getenv("PRIVATE_KEY")
        assert private_key, "PROVIDER_PRIVATE_KEY or PRIVATE_KEY not set in .env"
    else:
        private_key = os.getenv("PRIVATE_KEY")
        assert private_key, "PRIVATE_KEY not set in .env"

    account = w3.eth.account.from_key(private_key)
    w3.eth.default_account = account.address
    return account


def send_tx(w3: Web3, account, contract_fn, label: str = ""):
    """
    Build, sign, broadcast, and wait for a contract write transaction.

    contract_fn  — a prepared contract function call, e.g.
                   contract.functions.stake(amount)

    Returns the transaction receipt. Raises on revert (status == 0).
    """
    explorer = os.getenv("EXPLORER_URL", "https://testnet.snowtrace.io/tx/")

    tx = contract_fn.build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address, "pending"),
    })

    gas_est      = w3.eth.estimate_gas(tx)
    block        = w3.eth.get_block("latest")
    base_fee     = block.get("baseFeePerGas", w3.to_wei(15, "gwei"))
    priority_fee = w3.to_wei(2, "gwei")

    tx.update({
        "gas":                  int(gas_est * 1.5),
        "maxFeePerGas":         int(base_fee * 1.2) + priority_fee,
        "maxPriorityFeePerGas": priority_fee,
    })

    signed   = w3.eth.account.sign_transaction(tx, private_key=account.key)
    tx_hash  = w3.eth.send_raw_transaction(signed.raw_transaction)
    tag      = f"[{label}] " if label else ""
    print(f"  {tag}tx:  {explorer}{'0x' + tx_hash.hex()}")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    status  = "✓" if receipt.status == 1 else "✗ REVERTED"
    print(f"  {tag}{status}  block={receipt.blockNumber}  gasUsed={receipt.gasUsed}")

    if receipt.status != 1:
        raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")

    return receipt
