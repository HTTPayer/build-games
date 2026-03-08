"""
Verify a deployed ProviderRevenueSplitter by reading its constructor args from on-chain state.

Usage:
    uv run python verify_splitter.py <splitter_address>
"""

import json, os, sys, time
import urllib.request, urllib.parse
from pathlib import Path
from dotenv import load_dotenv
from eth_abi import encode as abi_encode

sys.path.insert(0, str(Path(__file__).parent))
from utils import build_w3, get_abi
from verify import _standard_json, _compiler_version

load_dotenv()

_TEST_DIR      = Path(__file__).parent
_CONTRACTS_DIR = _TEST_DIR.parent

_API_URL  = "https://api.etherscan.io/v2/api"
_API_KEY  = os.getenv("ETHERSCAN_API_KEY", "")
_CHAIN_ID = "43113"


def _submit_and_poll(addr: str, name: str, source: str, compiler: str, ctor_hex: str):
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
    print(f"  constructorArgs : {ctor_hex[:80] or '(none)'}")
    print(f"  compilerversion : {compiler}")
    print(f"  sourceCode len  : {len(source):,} chars")

    data = urllib.parse.urlencode(body_params).encode()
    req  = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())

    guid = body.get("result", "")
    msg  = body.get("message", "")
    print(f"  submit response : {body}")

    if not guid or msg.upper() == "NOTOK":
        print(f"FAIL: submission rejected")
        return

    print(f"\n  guid: {guid}")
    print("  polling...")
    for attempt in range(24):
        time.sleep(5)
        params = urllib.parse.urlencode({
            "module": "contract",
            "action": "checkverifystatus",
            "guid":   guid,
            "apikey": _API_KEY,
        })
        with urllib.request.urlopen(f"{url}&{params}", timeout=30) as resp:
            poll = json.loads(resp.read())
        status = poll.get("status", "0")
        result = poll.get("result", "")
        print(f"  [{attempt+1:02d}] status={status!r}  result={result!r}")
        if status == "1" or "Pass" in result:
            print(f"\nVerified: https://testnet.snowscan.xyz/address/{addr}#code")
            return
        if "Fail" in result or "fail" in result or "Error" in result:
            print(f"\nVerification failed: {result}")
            return

    print("Timed out — check Snowscan manually")


def main():
    if not _API_KEY:
        sys.exit("ETHERSCAN_API_KEY not set")

    addr = sys.argv[1] if len(sys.argv) > 1 else ""
    if not addr:
        sys.exit("Usage: uv run python verify_splitter.py <splitter_address>")

    w3 = build_w3()
    splitter_abi = get_abi("ProviderRevenueSplitter")
    splitter = w3.eth.contract(address=w3.to_checksum_address(addr), abi=splitter_abi)

    print(f"\nReading constructor args from on-chain state of {addr}...")
    usdc              = splitter.functions.USDC().call()
    protocol_treasury = splitter.functions.protocolTreasury().call()
    protocol_bp       = splitter.functions.protocolTreasuryBp().call()
    provider_treasury = splitter.functions.providerTreasury().call()
    provider_bp       = splitter.functions.providerTreasuryBp().call()
    revenue_share     = splitter.functions.revenueShare().call()
    revenue_share_bp  = splitter.functions.revenueShareBp().call()
    vault             = splitter.functions.vault().call()

    print(f"  USDC              : {usdc}")
    print(f"  protocolTreasury  : {protocol_treasury}")
    print(f"  protocolBp        : {protocol_bp}")
    print(f"  providerTreasury  : {provider_treasury}")
    print(f"  providerBp        : {provider_bp}")
    print(f"  revenueShare      : {revenue_share}")
    print(f"  revenueShareBp    : {revenue_share_bp}")
    print(f"  vault             : {vault}")

    ctor_hex = abi_encode(
        ["address", "address", "uint256", "address", "uint256", "address", "uint256", "address"],
        [usdc, protocol_treasury, protocol_bp, provider_treasury,
         provider_bp, revenue_share, revenue_share_bp, vault],
    ).hex()

    print(f"\nSubmitting verification for ProviderRevenueSplitter @ {addr}...")
    compiler = _compiler_version("ProviderRevenueSplitter")
    source   = _standard_json("ProviderRevenueSplitter")
    if source is None:
        sys.exit("Could not get standard JSON input")

    _submit_and_poll(addr, "ProviderRevenueSplitter", source, compiler, ctor_hex)


if __name__ == "__main__":
    main()
