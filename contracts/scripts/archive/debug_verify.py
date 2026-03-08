"""
Debug verification for a single contract — submits and polls until confirmed or failed.

Usage:
    uv run python debug_verify.py <ContractName> <address> [ctor_hex]

Example:
    uv run python debug_verify.py ProviderRevenueSplitter 0x743cAe7e20094Edb21CA4AFbDe3eF886f853FA16
"""

import json, os, subprocess, sys, time
import urllib.request, urllib.parse
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

_TEST_DIR      = Path(__file__).parent
_CONTRACTS_DIR = _TEST_DIR.parent
_OUT           = _CONTRACTS_DIR / "out"
_SRC           = _CONTRACTS_DIR / "src"

_API_URL  = "https://api.etherscan.io/v2/api"
_API_KEY  = os.getenv("ETHERSCAN_API_KEY", "")
_CHAIN_ID = "43113"


def _compiler_version(name: str) -> str:
    artifact_path = _OUT / f"{name}.sol" / f"{name}.json"
    with open(artifact_path, encoding="utf-8") as f:
        artifact = json.load(f)
    meta = artifact.get("metadata", {})
    if isinstance(meta, str):
        meta = json.loads(meta)
    version = meta.get("compiler", {}).get("version", "")
    return f"v{version}" if version and not version.startswith("v") else version


def _standard_json(name: str) -> str | None:
    sol_file = _SRC / f"{name}.sol"
    if not sol_file.exists():
        found = list(_SRC.rglob(f"{name}.sol"))
        if not found:
            return None
        sol_file = found[0]
    rel_path = str(sol_file.relative_to(_CONTRACTS_DIR)).replace("\\", "/")
    if os.name == "nt":
        wsl_cwd = str(_CONTRACTS_DIR).replace("\\", "/").replace("C:", "/mnt/c")
        cmd = ["wsl", "bash", "-c",
               f'cd "{wsl_cwd}" && ~/.foundry/bin/forge verify-contract 0x0000000000000000000000000000000000000000'
               f' "{rel_path}:{name}" --show-standard-json-input']
        result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    else:
        result = subprocess.run(
            ["forge", "verify-contract", "0x0000000000000000000000000000000000000000",
             f"{rel_path}:{name}", "--show-standard-json-input"],
            capture_output=True, text=True, cwd=str(_CONTRACTS_DIR), encoding="utf-8",
        )
    if result.returncode != 0:
        print(f"[standard-json stderr] {result.stderr[:500]}")
        return None
    return result.stdout.strip()


def _submit(addr: str, name: str, source: str, compiler: str, ctor_hex: str) -> tuple[str, str]:
    url = f"{_API_URL}?chainid={_CHAIN_ID}"
    body_params = {
        "module":               "contract",
        "action":               "verifysourcecode",
        "apikey":               _API_KEY,
        "contractaddress":      addr,
        "sourceCode":           source,
        "codeformat":           "solidity-standard-json-input",
        "contractname":         f"{name}.sol:{name}",
        "compilerversion":      compiler,
        "optimizationUsed":     "1",
        "runs":                 "200",
        "constructorArguments": ctor_hex,
        "licenseType":          "3",
    }
    print(f"\n[submit] POST {url}")
    print(f"  contractaddress : {body_params['contractaddress']}")
    print(f"  contractname    : {body_params['contractname']}")
    print(f"  compilerversion : {body_params['compilerversion']}")
    print(f"  codeformat      : {body_params['codeformat']}")
    print(f"  optimizationUsed: {body_params['optimizationUsed']}")
    print(f"  runs            : {body_params['runs']}")
    print(f"  constructorArgs : {ctor_hex[:80] or '(none)'}")
    print(f"  sourceCode len  : {len(source):,} chars")

    data = urllib.parse.urlencode(body_params).encode()
    req  = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    print(f"\n[submit response] {body}")
    return body.get("result", ""), body.get("message", "")


def _poll(guid: str) -> tuple[str, str]:
    url = f"{_API_URL}?chainid={_CHAIN_ID}"
    params = urllib.parse.urlencode({
        "module": "contract",
        "action": "checkverifystatus",
        "guid":   guid,
        "apikey": _API_KEY,
    })
    with urllib.request.urlopen(f"{url}&{params}", timeout=30) as resp:
        body = json.loads(resp.read())
    return body.get("status", "0"), body.get("result", "")


def main():
    if not _API_KEY:
        sys.exit("ETHERSCAN_API_KEY not set")

    name     = sys.argv[1] if len(sys.argv) > 1 else "ProviderRevenueSplitter"
    addr     = sys.argv[2] if len(sys.argv) > 2 else ""
    ctor_hex = sys.argv[3] if len(sys.argv) > 3 else ""

    if not addr:
        sys.exit("Usage: uv run python debug_verify.py <ContractName> <address> [ctor_hex]")

    print(f"\n=== Debugging verification for {name} @ {addr} ===")

    compiler = _compiler_version(name)
    print(f"compiler version : {compiler}")

    source = _standard_json(name)
    if source is None:
        sys.exit("Could not get standard JSON input")
    print(f"standard json    : {len(source):,} chars")

    guid, msg = _submit(addr, name, source, compiler, ctor_hex)

    if not guid or msg.upper() == "NOTOK":
        print(f"\n[FAIL] Submission rejected: {msg} — {guid}")
        return

    print(f"\n[guid] {guid}")
    print("Polling for result (up to 120s)...")

    for attempt in range(24):
        time.sleep(5)
        status, result = _poll(guid)
        print(f"  [{attempt+1:02d}] status={status!r}  result={result!r}")
        if status == "1" or "Pass" in result:
            print(f"\n✓ Verified! https://testnet.snowscan.xyz/address/{addr}#code")
            return
        if "Fail" in result or "fail" in result or "Error" in result or "error" in result:
            print(f"\n✗ Verification failed: {result}")
            return

    print("\n[TIMEOUT] Still pending after 120s — check Snowscan manually")


if __name__ == "__main__":
    main()
