"""Integrity hash computation and fetching for the Composed protocol."""

import base64
import hashlib
import json
import urllib.request
from urllib.error import URLError


def compute_integrity_hash(payment_data: dict) -> str:
    """Compute the x402 integrity hash from a parsed payment-data dict."""
    fields = {
        "amount": payment_data["amount"],
        "asset": payment_data["asset"],
        "network": payment_data["network"],
        "payTo": payment_data["payTo"].lower(),
        "url": payment_data["url"],
    }
    canonical = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode()).hexdigest()
    return "0x" + digest


def fetch_integrity_hash(endpoint_url: str, timeout: int = 10) -> str:
    """Fetch an endpoint and derive its integrity hash from the 402 response."""
    req = urllib.request.Request(endpoint_url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            # If we get a 200 we still need to probe; fall through.
            body_bytes = resp.read()
            headers = dict(resp.headers)
            status = resp.status
    except urllib.error.HTTPError as e:
        status = e.code
        headers = dict(e.headers)
        body_bytes = e.read()

    payment_data = _parse_payment_data(status, headers, body_bytes, endpoint_url)
    return compute_integrity_hash(payment_data)


def _parse_payment_data(
    status: int,
    headers: dict,
    body_bytes: bytes,
    endpoint_url: str,
) -> dict:
    """Extract payment data from either x402 v2 (header) or v1 (body) format."""
    # Normalise header keys to lowercase for lookup.
    lower_headers = {k.lower(): v for k, v in headers.items()}

    # --- x402 v2: payment-required header (base64-encoded JSON) ---
    v2_header = lower_headers.get("payment-required")
    if v2_header:
        try:
            decoded = base64.b64decode(v2_header).decode()
            parsed = json.loads(decoded)
            return _extract_payment_fields(parsed, endpoint_url)
        except Exception as exc:
            raise ValueError(
                f"Failed to parse x402 v2 'payment-required' header: {exc}"
            ) from exc

    # --- x402 v1: JSON body (status 402) ---
    if status == 402:
        try:
            parsed = json.loads(body_bytes.decode())
            return _extract_payment_fields(parsed, endpoint_url)
        except Exception as exc:
            raise ValueError(
                f"Failed to parse x402 v1 JSON body from {endpoint_url}: {exc}"
            ) from exc

    raise ValueError(
        f"Endpoint {endpoint_url} did not return a 402 response or "
        "'payment-required' header; cannot derive integrity hash."
    )


def _extract_payment_fields(parsed: dict, endpoint_url: str) -> dict:
    """Pull the canonical fields out of a parsed x402 payment object."""
    # Support both wrapped {"paymentRequired": {...}} and flat objects.
    inner = parsed.get("paymentRequired", parsed)

    # x402 v2 nested accepts list
    accepts = inner.get("accepts") or inner.get("accept") or []
    if accepts and isinstance(accepts, list):
        inner = accepts[0]

    amount = inner.get("amount") or inner.get("maxAmountRequired") or inner.get("price")
    asset = inner.get("asset") or inner.get("tokenAddress") or inner.get("currency")
    network = inner.get("network") or inner.get("networkId") or inner.get("chainId")
    pay_to = inner.get("payTo") or inner.get("paymentAddress") or inner.get("address")
    url = inner.get("url") or inner.get("resource") or endpoint_url

    missing = [
        k
        for k, v in [
            ("amount", amount),
            ("asset", asset),
            ("network", network),
            ("payTo", pay_to),
            ("url", url),
        ]
        if v is None
    ]
    if missing:
        raise ValueError(
            f"x402 payment data is missing required fields: {missing}. "
            f"Parsed object: {parsed}"
        )

    return {
        "amount": amount,
        "asset": asset,
        "network": network,
        "payTo": pay_to,
        "url": url,
    }
