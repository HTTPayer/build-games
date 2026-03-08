"""
ChallengeManager — read checks and write operations.

On-chain functions exposed
──────────────────────────
  Read
    print_state()               — full ChallengeManager config
    print_challenge(id)         — single challenge by ID
    print_all_challenges()      — iterate all challenges

  Admin (owner only)
    set_challenge_fee(usdc_raw) — e.g. 1_000_000 = 1 USDC, 100_000 = 0.10 USDC
    set_slash_bp(bp)            — e.g. 2000 = 20%
    set_forwarder(address)      — update the CRE forwarder address

  Challenger
    open_challenge(endpoint_id) — approve fee + call openChallenge(endpointId)
                                   returns challenge_id

Workflow
────────
  1. node dry-run.js <url> [expectedHash]   — verify hash locally first
  2. open_challenge(endpoint_id)            — submit on-chain, Chainlink resolves it
  3. print_challenge(challenge_id)          — check status (Pending / Valid / Invalid)
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from utils import get_contract_config, get_abi, build_w3, build_account, send_tx, ERC20_ABI

# ── Setup ──────────────────────────────────────────────────────────────────────

w3      = build_w3()
account = build_account(w3)

cm_abi, cm_address = get_contract_config("ChallengeManager")
cm = w3.eth.contract(address=cm_address, abi=cm_abi)

usdc_address = cm.functions.USDC().call()
usdc         = w3.eth.contract(address=usdc_address, abi=ERC20_ABI)

STATUS_LABELS = {0: "Pending", 1: "Valid", 2: "Invalid"}

# ── Registry (for endpoint/provider lookup) ────────────────────────────────────

registry_abi     = get_abi("APIIntegrityRegistry")
registry_address = cm.functions.registry().call()
registry         = w3.eth.contract(address=registry_address, abi=registry_abi)

print(f"\nChallengeManager : {cm_address}")
print(f"Registry         : {registry_address}")
print(f"USDC             : {usdc_address}")
print(f"Signer           : {account.address}")

# ── Registry reads ─────────────────────────────────────────────────────────────

def print_registry_info():
    """
    List all registered providers and their endpoints.
    Provider IDs are sequential; endpoint IDs come from EndpointRegistered events.
    """
    count = registry.functions.providerCount().call()
    print(f"\n-- Registry providers ({count}) ----------------------------------------")
    if count == 0:
        print("  (none registered)")
        print("----------------------------------------------------------------------\n")
        return

    for pid in range(1, count + 1):
        p = registry.functions.providers(pid).call()
        # (owner, metadataURI, payoutAddress, revenueSplitter, active, createdAt)
        print(f"\n  Provider #{pid}")
        print(f"    owner          : {p[0]}")
        print(f"    metadataURI    : {p[1] or '(none)'}")
        print(f"    payoutAddress  : {p[2]}")
        print(f"    active         : {p[4]}")

        # Read providerEndpoints[owner] — stored by msg.sender of registerEndpoint()
        provider_addr = w3.to_checksum_address(p[0])
        eids = []
        i = 0
        while True:
            try:
                eid = registry.functions.providerEndpoints(provider_addr, i).call()
                eids.append(eid)
                i += 1
            except Exception:
                break
        if not eids:
            print(f"    endpoints      : (none — or registered from different address)")
        else:
            print(f"    endpoints      :")
            for eid in eids:
                e = registry.functions.endpoints(eid).call()
                # (endpointId, provider, path, method, integrityHash, version, active, ...)
                print(f"      endpointId   : 0x{eid.hex()}")
                print(f"      path         : {e[2]}")
                print(f"      method       : {e[3]}")
                print(f"      integrityHash: 0x{e[4].hex()}")
                print(f"      active       : {e[6]}")

    print("\n----------------------------------------------------------------------\n")

# ── Reads ──────────────────────────────────────────────────────────────────────

def print_state():
    fee       = cm.functions.challengeFee().call()
    slash_bp  = cm.functions.slashBp().call()
    forwarder = cm.functions.forwarder().call()
    count     = cm.functions.challengeCount().call()
    usdc_bal  = usdc.functions.balanceOf(account.address).call()
    cm_bal    = usdc.functions.balanceOf(cm_address).call()

    print("\n-- ChallengeManager state --------------------------------------------")
    print(f"  challengeFee      : {fee / 1e6:.6f} USDC  ({fee} raw)")
    print(f"  slashBp           : {slash_bp}  ({slash_bp / 100:.2f}%)")
    print(f"  forwarder         : {forwarder}")
    print(f"  challengeCount    : {count}")
    print(f"  contract USDC bal : {cm_bal / 1e6:.6f} USDC")
    print(f"  signer USDC bal   : {usdc_bal / 1e6:.6f} USDC")
    print("----------------------------------------------------------------------\n")


def print_challenge(challenge_id: int):
    c = cm.functions.challenges(challenge_id).call()
    # returns (challenger, endpointId, status)
    challenger  = c[0]
    endpoint_id = "0x" + c[1].hex()
    status      = STATUS_LABELS.get(c[2], f"unknown({c[2]})")

    print(f"\n-- Challenge #{challenge_id} -------------------------------------------------")
    print(f"  challenger  : {challenger}")
    print(f"  endpointId  : {endpoint_id}")
    print(f"  status      : {status}")
    print("----------------------------------------------------------------------\n")


def print_all_challenges():
    count = cm.functions.challengeCount().call()
    if count == 0:
        print("\n  (no challenges yet)\n")
        return
    print(f"\n-- All challenges ({count}) ---------------------------------------------------")
    for i in range(1, count + 1):
        c           = cm.functions.challenges(i).call()
        endpoint_id = "0x" + c[1].hex()
        status      = STATUS_LABELS.get(c[2], f"unknown({c[2]})")
        print(f"  #{i:<4} {status:<8}  endpoint={endpoint_id[:14]}...  challenger={c[0][:10]}...")
    print("----------------------------------------------------------------------\n")

# ── Admin writes ───────────────────────────────────────────────────────────────

def set_challenge_fee(usdc_raw: int):
    """
    Set the challenge fee in raw USDC units (6 decimals).
      set_challenge_fee(100_000_000)  # 100 USDC  (default)
      set_challenge_fee(1_000_000)    # 1 USDC
      set_challenge_fee(100_000)      # 0.10 USDC
    """
    print(f"\n-> setChallengeFee({usdc_raw})  ({usdc_raw / 1e6:.6f} USDC)")
    send_tx(w3, account, cm.functions.setChallengeFee(usdc_raw), "setChallengeFee")


def set_slash_bp(bp: int):
    """
    Set the slash percentage in basis points.
      set_slash_bp(2000)  # 20% (default)
      set_slash_bp(500)   # 5%
    """
    print(f"\n-> setSlashBp({bp})  ({bp / 100:.2f}%)")
    send_tx(w3, account, cm.functions.setSlashBp(bp), "setSlashBp")


def set_forwarder(address: str):
    """Update the CRE forwarder address (owner only)."""
    print(f"\n-> setForwarder({address})")
    send_tx(w3, account, cm.functions.setForwarder(address), "setForwarder")

# ── Challenger writes ──────────────────────────────────────────────────────────

def open_challenge(endpoint_id: str | bytes) -> int:
    """
    Approve the challenge fee and open a challenge for an endpoint.

    endpoint_id — bytes32 hex string (0x...) or raw bytes
    Returns the challenge ID (integer).

    Recommended workflow:
      1. node dry-run.js <url> <expectedHash>   -- confirm PASS locally first
      2. cid = open_challenge("0xabc...")        -- submit on-chain
      3. print_challenge(cid)                   -- check status (resolves async)
    """
    if isinstance(endpoint_id, str):
        endpoint_id = bytes.fromhex(endpoint_id.removeprefix("0x"))

    fee = cm.functions.challengeFee().call()
    bal = usdc.functions.balanceOf(account.address).call()
    assert bal >= fee, (
        f"Insufficient USDC: need {fee / 1e6:.6f}, have {bal / 1e6:.6f}"
    )

    print(f"\n-> openChallenge(0x{endpoint_id.hex()})")
    print(f"   fee: {fee / 1e6:.6f} USDC -- approving...")
    send_tx(w3, account, usdc.functions.approve(cm_address, fee), "approve")

    receipt = send_tx(w3, account, cm.functions.openChallenge(endpoint_id), "openChallenge")

    # Parse ChallengeOpened event to get the ID
    events = cm.events.ChallengeOpened().process_receipt(receipt)
    if events:
        cid = events[0]["args"]["id"]
        print(f"   challenge ID: {cid}")
        return cid

    # Fallback: challengeCount is the latest ID
    cid = cm.functions.challengeCount().call()
    print(f"   challenge ID: {cid}  (from challengeCount)")
    return cid

# ── Main ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print_registry_info()
    print_state()
    print_all_challenges()

    # ── Admin: update the CRE forwarder address ──────────────────────────────
    # set_forwarder("0xYourCREForwarderOnFuji")

    # ── Admin: adjust fee / slash ─────────────────────────────────────────────
    # set_challenge_fee(1_000_000)     # 1 USDC
    # set_slash_bp(500)                # 5%

    # ── Open a challenge (after CRE workflow is registered) ──────────────────
    endpoint_id = "0xa47ee1f016200c9a6f7a4b490849bea3da25cf5ec6efc25ad58733e6999607cb"
    cid = open_challenge(endpoint_id)
    print_challenge(cid)
    #
    # Check status after CRE workflow resolves:
    # print_challenge(cid)
