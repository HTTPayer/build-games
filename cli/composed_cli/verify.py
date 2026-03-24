"""
Submit a contract for verification on Snowtrace (Fuji) via the Etherscan-compatible API.
Fire-and-forget — submits the request and prints the explorer link without polling.

Requires ETHERSCAN_API_KEY in .env.
"""

import json, os, subprocess, time
import urllib.request, urllib.parse
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

_SCRIPT_DIR    = Path(__file__).parent
_ROOT_DIR      = _SCRIPT_DIR.parent.parent
_CONTRACTS_DIR = _ROOT_DIR / "contracts"
_SRC           = _CONTRACTS_DIR / "src"

_API_URL  = "https://api.etherscan.io/v2/api"
_API_KEY  = os.getenv("ETHERSCAN_API_KEY", "")
_CHAIN_ID = "43113"
_EXPLORER = "https://testnet.snowscan.xyz/address/"


def _standard_json(name: str) -> str | None:
    """Return forge's standard-json-input for the contract (carries viaIR + all settings)."""
    sol_file = _SRC / f"{name}.sol"
    if not sol_file.exists():
        found = list(_SRC.rglob(f"{name}.sol"))
        if not found:
            return None
        sol_file = found[0]

    rel_path = sol_file.relative_to(_CONTRACTS_DIR)

    if os.name == "nt":
        wsl_cwd = str(_CONTRACTS_DIR).replace("\\", "/").replace("C:", "/mnt/c")
        wsl_sol = str(sol_file).replace("\\", "/").replace("C:", "/mnt/c")
        wsl_rel = str(rel_path).replace("\\", "/")
        cmd = [
            "wsl", "bash", "-c",
            f'cd "{wsl_cwd}" && ~/.foundry/bin/forge verify-contract 0x0000000000000000000000000000000000000000'
            f' "{wsl_rel}:{name}" --show-standard-json-input',
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    else:
        result = subprocess.run(
            ["forge", "verify-contract", "0x0000000000000000000000000000000000000000",
             f"{rel_path}:{name}", "--show-standard-json-input"],
            capture_output=True, text=True, cwd=str(_CONTRACTS_DIR), encoding="utf-8",
        )

    if result.returncode != 0:
        print(f"\n    [standard-json stderr] {result.stderr[:300]}")
        return None
    # Output is the JSON on stdout
    return result.stdout.strip()


def _compiler_version(name: str) -> str:
    out = _CONTRACTS_DIR / "out"
    artifact_path = out / f"{name}.sol" / f"{name}.json"
    with open(artifact_path, encoding="utf-8") as f:
        artifact = json.load(f)
    meta = artifact.get("metadata", {})
    if isinstance(meta, str):
        meta = json.loads(meta)
    version = meta.get("compiler", {}).get("version", "")
    return f"v{version}" if version and not version.startswith("v") else version


def _submit(addr: str, name: str, source_json: str, compiler: str, ctor_hex: str) -> tuple[str, str]:
    # chainid goes in the URL for Etherscan V2; everything else in POST body
    url = f"{_API_URL}?chainid={_CHAIN_ID}"
    body_params = {
        "module":               "contract",
        "action":               "verifysourcecode",
        "apikey":               _API_KEY,
        "contractaddress":      addr,
        "sourceCode":           source_json,
        "codeformat":           "solidity-standard-json-input",
        "contractname":         f"{name}.sol:{name}",
        "compilerversion":      compiler,
        "constructorArguments": ctor_hex,
        "licenseType":          "3",       # MIT
    }
    data = urllib.parse.urlencode(body_params).encode()
    req  = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    return body.get("result", ""), body.get("message", "")


def verify_contract(name: str, addr: str, ctor_args_hex: str = ""):
    """
    Submit a contract for verification on Snowtrace.

    name          — contract name matching the artifact (e.g. "ProviderRevenueVault")
    addr          — deployed address (checksummed or not)
    ctor_args_hex — ABI-encoded constructor args as hex string (no 0x prefix), or ""
    """
    if not _API_KEY:
        print(f"  [verify] skipped — ETHERSCAN_API_KEY not set")
        return

    print(f"  [verify] {name} … ", end="", flush=True)

    source_json = _standard_json(name)
    if source_json is None:
        print("X could not get standard JSON input")
        return

    try:
        compiler = _compiler_version(name)
    except Exception as e:
        print(f"X could not read compiler version: {e}")
        return

    # Give Etherscan time to index the newly deployed contract
    time.sleep(10)

    try:
        guid, msg = _submit(addr, name, source_json, compiler, ctor_args_hex)
    except Exception as e:
        print(f"X submit failed: {e}")
        return

    if guid and msg.upper() != "NOTOK":
        print(f"submitted")
        print(f"  [verify] {_EXPLORER}{addr}#code")
    else:
        print(f"X {msg}: {guid}")
