"""ABI resolution for the Composed SDK.

Reads ABIs from compiled Solidity artifacts to avoid hardcoding.
"""

import json
from pathlib import Path

_ROOT = Path(__file__).parent.parent.parent
OUT_DIR = _ROOT / "contracts" / "out"


def _load_abi(contract_name: str) -> list[dict]:
    """Load ABI from compiled artifact."""
    artifact = OUT_DIR / f"{contract_name}.sol" / f"{contract_name}.json"
    with open(artifact, encoding="utf-8") as f:
        return json.load(f)["abi"]


FACTORY_ABI       = _load_abi("APIRegistryFactory")
REGISTRY_ABI      = _load_abi("APIIntegrityRegistry")
STAKE_MANAGER_ABI = _load_abi("StakeManager")
CHALLENGE_MANAGER_ABI = _load_abi("ChallengeManager")

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
    {"name": "transfer",  "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "to", "type": "address"}, {"name": "amount", "type": "uint256"}],
     "outputs": [{"name": "", "type": "bool"}]},
]
