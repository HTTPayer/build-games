"""Address resolution for the Composed Protocol.

Reads contract addresses from the foundry broadcast file to avoid
hardcoding stale deployment addresses.
"""

import json
from pathlib import Path
from typing import Optional

_ROOT = Path(__file__).parent.parent.parent
BROADCAST_FILE = (
    _ROOT / "contracts" / "broadcast" / "DeployAll.s.sol" / "43113" / "run-latest.json"
)

FUJI_CHAIN_ID = 43113
DEPLOY_BLOCK  = 52_477_983


def _get_addresses_from_broadcast() -> dict:
    """Read current deployment addresses from the foundry broadcast file."""
    if not BROADCAST_FILE.exists():
        raise FileNotFoundError(
            f"Broadcast file not found: {BROADCAST_FILE}\n"
            "Run `forge script script/DeployAll.s.sol --broadcast` first."
        )

    with open(BROADCAST_FILE, encoding="utf-8") as f:
        data = json.load(f)

    txs = data["transactions"]

    def find_address(contract_name: str) -> str:
        """Find the last (most recent) deployment of a contract."""
        for tx in reversed(txs):
            if tx.get("transactionType") == "CREATE" and tx.get("contractName") == contract_name:
                return tx["contractAddress"]
        raise ValueError(f"Contract '{contract_name}' not found in broadcast file")

    return {
        "factory":          find_address("APIRegistryFactory"),
        "registry":         find_address("APIIntegrityRegistry"),
        "stake_manager":    find_address("StakeManager"),
        "challenge_manager": find_address("ChallengeManager"),
        "usdc":             "0x5425890298aed601595a70AB815c96711a31Bc65",
    }


# Try to load from broadcast; fall back to empty dict if broadcast not available
try:
    FUJI_ADDRESSES = _get_addresses_from_broadcast()
except FileNotFoundError:
    FUJI_ADDRESSES = {
        "factory": "",
        "registry": "",
        "stake_manager": "",
        "challenge_manager": "",
        "usdc": "0x5425890298aed601595a70AB815c96711a31Bc65",
    }
