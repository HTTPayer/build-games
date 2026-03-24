"""
Fetch x402 payment requirements and compute the integrity hash.

Replicates on-chain _computeIntegrityHash exactly:
  1. Detect v1 (body) vs v2 (PAYMENT-REQUIRED header, base64-encoded)
  2. Extract amount, asset, network, payTo, url from the accepts[0] entry
  3. Build sorted compact JSON → keccak256

Usage as a script:
  X402_ENDPOINT=http://localhost:4021/weather uv run python x402_metadata.py

Usage as a module:
  from x402_metadata import fetch_integrity_hash
  integrity_hash = fetch_integrity_hash("http://localhost:4021/weather")
"""

import base64
import json

import requests
from web3 import Web3


def fetch_integrity_hash(endpoint_url: str, verbose: bool = True, expected_pay_to: str = "") -> str:
    """
    Fetch the x402 payment requirements from endpoint_url and return the
    integrity hash (0x-prefixed hex) suitable for registerEndpoint().

    Handles both v1 (requirements in body) and v2 (PAYMENT-REQUIRED header).
    """
    metadata = fetch_payment_metadata(endpoint_url, verbose=False)

    data_string = json.dumps(metadata, sort_keys=True, separators=(",", ":"))
    integrity_hash = "0x" + Web3.keccak(text=data_string).hex()

    if expected_pay_to and metadata["payTo"] != expected_pay_to.lower():
        raise ValueError(
            f"payTo mismatch — server has {metadata['payTo']!r} "
            f"but expected {expected_pay_to.lower()!r}.\n"
            f"  Update your x402 server's payTo to the splitter address first."
        )

    if verbose:
        print(f"  [x402] payTo   : {metadata['payTo']}")
        print(f"  [x402] url     : {metadata['url']}")
        print(f"  [x402] amount  : {metadata['amount']}  asset={metadata['asset']}  network={metadata['network']}")
        print(f"  [x402] json    : {data_string}")
        print(f"  [x402] hash    : {integrity_hash}")

    return integrity_hash


def fetch_payment_metadata(endpoint_url: str, verbose: bool = True) -> dict:
    """
    Fetch the x402 payment requirements from endpoint_url and return the raw
    metadata dict (amount, asset, network, payTo, url).

    Handles both v1 (requirements in body) and v2 (PAYMENT-REQUIRED header).
    """
    resp = requests.get(endpoint_url)

    if resp.status_code not in (200, 402):
        resp.raise_for_status()

    # Version detection
    payment_required_header = (
        resp.headers.get("payment-required")
        or resp.headers.get("PAYMENT-REQUIRED")
    )

    if payment_required_header:
        version = 2
        payload_bytes = base64.b64decode(payment_required_header)
    else:
        version = 1
        payload_bytes = resp.content

    data = json.loads(payload_bytes)
    entry = data["accepts"][0]

    return {
        "payTo": entry["payTo"].lower(),
        "amount": str(entry["amount"]),
        "asset": entry["asset"],
        "network": entry["network"],
        "url": data["resource"]["url"],
    }


# ── Run as script ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import os
    from dotenv import load_dotenv
    load_dotenv()

    endpoint = os.getenv("X402_ENDPOINT")
    assert endpoint, "X402_ENDPOINT not set in .env"

    print(f"x402_endpoint : {endpoint}\n")
    h = fetch_integrity_hash(endpoint, verbose=True)
    print(f"\nintegrity_hash : {h}")
    print(f"\nUse in register_endpoint():")
    print(f'  integrity_hash = "{h}"')
