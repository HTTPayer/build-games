"""Shared helpers for analytics scripts."""

import json
import os
from pathlib import Path
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware, LocalFilterMiddleware
from dotenv import load_dotenv

load_dotenv()

# From analytics/src/utils.py, go up to build-games root, then to contracts
_CONTRACTS_DIR = Path(__file__).parent.parent.parent / "contracts"
BROADCAST_FILE = _CONTRACTS_DIR / "broadcast" / "DeployAll.s.sol" / "43113" / "run-latest.json"

ERC20_ABI = [
    {"name": "approve", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}],
     "outputs": [{"name": "", "type": "bool"}]},
    {"name": "balanceOf", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"name": "allowance", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"name": "decimals", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"name": "", "type": "uint8"}]},
]


def get_abi(name: str):
    """Return the ABI for a contract by name."""
    artifact = _CONTRACTS_DIR / "out" / f"{name}.sol" / f"{name}.json"
    with open(artifact, encoding="utf-8") as f:
        return json.load(f)["abi"]


def get_contract_config(name: str):
    """Return (abi, checksummed_address) for a contract deployed by DeployAll.s.sol."""
    artifact = _CONTRACTS_DIR / "out" / f"{name}.sol" / f"{name}.json"
    with open(artifact, encoding="utf-8") as f:
        abi = json.load(f)["abi"]

    with open(BROADCAST_FILE, encoding="utf-8") as f:
        txs = json.load(f)["transactions"]

    address = next(
        tx["contractAddress"]
        for tx in reversed(txs)
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
