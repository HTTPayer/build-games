"""
APIIntegrityRegistry — read checks and write tests.

Write function access
────────────────────
  registerProvider        → any address (provider self-registers)
  registerEndpoint        → provider (msg.sender must own the providerId)
  setMinimumStakeRequired → ADMIN_ROLE only
  recordCheck             → CHECKER_ROLE only (granted to ChallengeManager at deploy;
                            not tested here — will revert unless your wallet has the role)
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from utils import get_contract_config, build_w3, build_account, send_tx

# ── Setup ──────────────────────────────────────────────────────────────────────

w3      = build_w3()
account = build_account(w3)

registry_abi, registry_address = get_contract_config("APIIntegrityRegistry")
contract = w3.eth.contract(address=registry_address, abi=registry_abi)

print(f"\nAPIIntegrityRegistry : {registry_address}")
print(f"Signer               : {account.address}")

# ── Reads ──────────────────────────────────────────────────────────────────────

def print_state():
    admin_role    = contract.functions.ADMIN_ROLE().call()
    checker_role  = contract.functions.CHECKER_ROLE().call()
    default_admin = contract.functions.DEFAULT_ADMIN_ROLE().call()

    print("\n── APIIntegrityRegistry state ────────────────────────────────────")
    print(f"  providerCount        : {contract.functions.providerCount().call()}")
    print(f"  endpointCount        : {contract.functions.endpointCount().call()}")
    print(f"  minimumStakeRequired : {contract.functions.minimumStakeRequired().call() / 1e6:.2f} USDC")
    print(f"  paused               : {contract.functions.paused().call()}")
    print(f"  signer hasAdminRole  : {contract.functions.hasRole(admin_role, account.address).call()}")
    print(f"  signer hasCheckerRole: {contract.functions.hasRole(checker_role, account.address).call()}")
    print(f"  ADMIN_ROLE           : 0x{admin_role.hex()}")
    print(f"  CHECKER_ROLE         : 0x{checker_role.hex()}")
    print(f"  DEFAULT_ADMIN_ROLE   : 0x{default_admin.hex()}")
    print("──────────────────────────────────────────────────────────────────\n")


def get_provider(provider_id: int):
    """Print details for a given provider ID (1-indexed)."""
    p = contract.functions.providers(provider_id).call()
    # (owner, metadataURI, payoutAddress, revenueSplitter, active, createdAt)
    print(f"\n── Provider #{provider_id} ────────────────────────────────────────────")
    print(f"  owner           : {p[0]}")
    print(f"  metadataURI     : {p[1]}")
    print(f"  payoutAddress   : {p[2]}")
    print(f"  revenueSplitter : {p[3]}")
    print(f"  active          : {p[4]}")
    print(f"  createdAt       : {p[5]}")
    print("──────────────────────────────────────────────────────────────────\n")
    return p


def get_endpoint(endpoint_id: bytes):
    """Print details for a given endpoint ID (bytes32)."""
    e = contract.functions.endpoints(endpoint_id).call()
    # (endpointId, provider, path, method, integrityHash, version, active, registeredAt, lastCheckedAt)
    print(f"\n── Endpoint 0x{endpoint_id.hex()[:16]}… ───────────────────────────────────")
    print(f"  provider      : {e[1]}")
    print(f"  path          : {e[2]}")
    print(f"  method        : {e[3]}")
    print(f"  integrityHash : 0x{e[4].hex()}")
    print(f"  version       : {e[5]}")
    print(f"  active        : {e[6]}")
    print(f"  registeredAt  : {e[7]}")
    print(f"  lastCheckedAt : {e[8]}")
    print("──────────────────────────────────────────────────────────────────\n")
    return e


def get_provider_endpoints(provider_address: str):
    """Return and print all endpoint IDs registered under a provider address."""
    ids = contract.functions.providerEndpoints(provider_address).call()
    print(f"\n── Endpoints for {provider_address} ──")
    for eid in ids:
        print(f"  0x{eid.hex()}")
    if not ids:
        print("  (none)")
    print("──────────────────────────────────────────────────────────────────\n")
    return ids

# ── Writes ─────────────────────────────────────────────────────────────────────

def register_provider(metadata_uri: str, payout_address: str, revenue_splitter: str):
    """
    Register a new provider. Callable by any address.
    revenue_splitter — use address(0) if not yet deployed via factory.
    Returns receipt; new provider ID == providerCount after the tx.
    """
    print(f"\n→ registerProvider({metadata_uri!r}, {payout_address}, {revenue_splitter})")
    return send_tx(
        w3, account,
        contract.functions.registerProvider(metadata_uri, payout_address, revenue_splitter),
        "registerProvider",
    )


def register_endpoint(provider_id: int, path: str, method: str, integrity_hash: bytes):
    """
    Register an endpoint under an existing provider.
    msg.sender must be the provider owner.
    integrity_hash — 32 bytes, e.g. bytes.fromhex("ab" * 32) or hashlib.sha256(b"…").digest()
    """
    assert len(integrity_hash) == 32, "integrity_hash must be exactly 32 bytes"
    print(f"\n→ registerEndpoint(providerId={provider_id}, path={path!r}, method={method!r})")
    return send_tx(
        w3, account,
        contract.functions.registerEndpoint(provider_id, path, method, integrity_hash),
        "registerEndpoint",
    )


def set_minimum_stake_required(amount_usdc_units: int):
    """
    Update the minimum stake threshold. Requires ADMIN_ROLE.
    amount_usdc_units — raw units (6 decimals), e.g. 1_000_000_000 = 1000 USDC
    """
    print(f"\n→ setMinimumStakeRequired({amount_usdc_units})  [{amount_usdc_units / 1e6:.2f} USDC]")
    return send_tx(
        w3, account,
        contract.functions.setMinimumStakeRequired(amount_usdc_units),
        "setMinimumStakeRequired",
    )


# recordCheck(bytes32) — requires CHECKER_ROLE, granted only to ChallengeManager.
# Calling this directly will revert unless your wallet has been explicitly granted CHECKER_ROLE.

# ── Main ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print_state()

    provider_count = contract.functions.providerCount().call()
    if provider_count > 0:
        get_provider(1)
        endpoint_ids = get_provider_endpoints(account.address)
        if endpoint_ids:
            get_endpoint(endpoint_ids[0])

    # ── Example write calls (uncomment to execute) ──────────────────────────

    # Register a new provider (creates a new provider ID each time you run it):
    # receipt = register_provider(
    #     "ipfs://QmYourMetadataHash",
    #     account.address,                                     # payout address
    #     "0x0000000000000000000000000000000000000000",        # no splitter yet
    # )
    # new_id = contract.functions.providerCount().call()
    # print(f"new provider ID: {new_id}")

    # Register an endpoint under an existing provider:
    # import hashlib
    # h = hashlib.sha256(b"my-402-response-metadata").digest()  # 32-byte integrity hash
    # receipt = register_endpoint(
    #     provider_id    = 1,
    #     path           = "https://api.example.com/v1/pricing",
    #     method         = "GET",
    #     integrity_hash = h,
    # )

    # Update minimum stake (admin only):
    receipt = set_minimum_stake_required(1_000_000)  # 1 USDC

    print_state()
