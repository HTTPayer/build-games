"""
Extract ABIs from compiled Solidity contracts.

Reads from contracts/out/{Name}.sol/{Name}.json and writes
cleaned ABI to abis/{Name}.json
"""

import json
import shutil
from pathlib import Path

ROOT = Path(__file__).parent.parent
OUT_DIR = ROOT / "contracts" / "out"
ABI_DIR = ROOT / "abis"

ABI_DIR.mkdir(exist_ok=True)

# Find all .json files in out/ that contain ABI
for artifact in OUT_DIR.rglob("*.json"):
    # Skip anything that's not a direct contract artifact
    # Pattern: out/ContractName.sol/ContractName.json
    parent = artifact.parent
    if parent.name.endswith(".sol") and parent.parent == OUT_DIR:
        name = parent.name.replace(".sol", "")
        if artifact.name == f"{name}.json":
            with open(artifact, encoding="utf-8") as f:
                data = json.load(f)
            
            # Write clean ABI
            out_path = ABI_DIR / f"{name}.json"
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump({"abi": data["abi"]}, f, indent=2)
            
            print(f"  {name}.json")

print(f"\nExtracted ABIs to {ABI_DIR}")
