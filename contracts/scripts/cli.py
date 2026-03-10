"""
Composed provider CLI.

Commands:
  stake              Ensure account is staked to the minimum required
  unstake            Request to unstake USDC (starts cooldown)
  withdraw           Withdraw unstaked USDC after cooldown expires
  deploy-provider    Deploy vault + splitter, register in APIIntegrityRegistry
  register-endpoint  Fetch x402 hash from live server and register on-chain
  update-endpoint    Update the integrity hash for a registered endpoint
  update-provider    Update metadata URI, payout address, or splitter address
  registry           List all providers and their endpoint IDs
  challenge          Open a CRE integrity challenge for a registered endpoint
  challenge-status   Check the status of a challenge
  vault              Inspect vault state and call vault functions
  splitter           Show splitter + vault state, optionally distribute
  status             Print factory / stake / registry state

Usage:
  uv run python cli.py stake
  uv run python cli.py unstake --amount 10000000
  uv run python cli.py withdraw --amount 10000000
  uv run python cli.py deploy-provider --name "Weather API" --symbol "wAPI" --vault-bp 9800
  uv run python cli.py register-endpoint --provider-id 1 --splitter 0x... --url http://...
  uv run python cli.py update-provider --provider-id 1 --splitter 0x... --payout 0x...
  uv run python cli.py status
"""

import argparse
import os
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from web3.logs import DISCARD
from eth_abi import encode as abi_encode
from dotenv import load_dotenv

from utils import get_abi, send_tx
from verify import verify_contract
from x402_metadata import fetch_integrity_hash

# SDK — installed as an editable package from contracts/
from composed import ComposedClient

load_dotenv()

ZERO     = "0x0000000000000000000000000000000000000000"
EXPLORER = os.getenv("EXPLORER_URL", "https://testnet.snowscan.xyz/tx/")

# ── Globals (lazy-initialised in main()) ────────────────────────────────────

_client: ComposedClient | None = None
_PROTOCOL_BP:     int = 0
_MAX_PROVIDER_BP: int = 10_000

# ABIs for contracts not in the SDK (vault, splitter, revenue-share)
_vault_abi    = None
_splitter_abi = None
_rs_abi       = None


def _tx_url(tx_hash: str) -> str:
    h = tx_hash if tx_hash.startswith("0x") else "0x" + tx_hash
    return f"{EXPLORER}{h}"


def _my_deployments() -> list[dict]:
    """Return all ProviderDeployed event args for the current signer (chunked to stay within RPC limits)."""
    from composed._addresses import DEPLOY_BLOCK
    CHUNK = 2000
    latest = _client.w3.eth.block_number
    results = []
    start = DEPLOY_BLOCK
    while start <= latest:
        end = min(start + CHUNK - 1, latest)
        try:
            logs = _client.factory.events.ProviderDeployed().get_logs(
                from_block=start,
                to_block=end,
                argument_filters={"deployer": _client.account.address},
            )
            results.extend(dict(log["args"]) for log in logs)
        except Exception:
            pass
        start = end + 1
    return results


def _resolve_splitter(arg: str | None) -> str:
    if arg:
        return _client.w3.to_checksum_address(arg)
    deployments = _my_deployments()
    splitters = [d["splitter"] for d in deployments]
    if not splitters:
        sys.exit("No deployed providers found for this signer. Pass --splitter explicitly.")
    if len(splitters) > 1:
        sys.exit("Multiple splitters found — pass --splitter explicitly:\n"
                 + "\n".join(f"  {s}" for s in splitters))
    print(f"  (auto-detected splitter: {splitters[0]})")
    return _client.w3.to_checksum_address(splitters[0])


def _resolve_vault(arg: str | None) -> str:
    if arg:
        return _client.w3.to_checksum_address(arg)
    deployments = _my_deployments()
    vaults = [d["vault"] for d in deployments if d["vault"] != ZERO]
    if not vaults:
        sys.exit("No deployed vaults found for this signer. Pass --vault explicitly.")
    if len(vaults) > 1:
        sys.exit("Multiple vaults found — pass --vault explicitly:\n"
                 + "\n".join(f"  {v}" for v in vaults))
    print(f"  (auto-detected vault: {vaults[0]})")
    return _client.w3.to_checksum_address(vaults[0])


def _resolve_revenue_share(arg: str | None) -> str:
    if arg:
        return _client.w3.to_checksum_address(arg)
    deployments = _my_deployments()
    rs_addrs = [d["revenueShare"] for d in deployments if d.get("revenueShare", ZERO) != ZERO]
    if not rs_addrs:
        sys.exit("No revenue share contracts found for this signer. Pass --rs explicitly.")
    if len(rs_addrs) > 1:
        sys.exit("Multiple RS contracts found — pass --rs explicitly:\n"
                 + "\n".join(f"  {r}" for r in rs_addrs))
    print(f"  (auto-detected revenue share: {rs_addrs[0]})")
    return _client.w3.to_checksum_address(rs_addrs[0])


def _print_provider_stats(vault_addr: str, splitter_addr: str, rs_addr: str) -> None:
    """Print a compact stats block for one deployed provider."""
    # Splitter
    s = _client.w3.eth.contract(
        address=_client.w3.to_checksum_address(splitter_addr), abi=_splitter_abi
    )
    pending = s.functions.pendingDistribution().call()
    print(f"  splitter      : {splitter_addr}")
    print(f"  pending       : {pending / 1e6:.6f} USDC")

    # Vault
    if vault_addr and vault_addr != ZERO:
        vault   = _client.w3.eth.contract(
            address=_client.w3.to_checksum_address(vault_addr), abi=_vault_abi
        )
        supply    = vault.functions.totalSupply().call()
        assets    = vault.functions.totalAssets().call()
        price     = (assets * 10**18 // supply) if supply else 0
        my_shares = vault.functions.balanceOf(_client.account.address).call()
        redeemable = vault.functions.convertToAssets(my_shares).call() if my_shares else 0
        print(f"  vault         : {vault_addr}")
        print(f"    TVL         : {assets / 1e6:.6f} USDC")
        print(f"    sharePrice  : {price / 1e18:.8f} USDC/share")
        print(f"    supply      : {supply / 1e6:.6f} shares")
        if my_shares:
            print(f"    your shares : {my_shares / 1e6:.6f}  (redeemable: {redeemable / 1e6:.6f} USDC)")

    # Revenue Share
    if rs_addr and rs_addr != ZERO:
        rs        = _client.w3.eth.contract(
            address=_client.w3.to_checksum_address(rs_addr), abi=_rs_abi
        )
        supply      = rs.functions.totalSupply().call()
        total_dist  = rs.functions.totalDistributed().call()
        eps         = rs.functions.cumulativeRevenuePerShare().call()
        my_shares   = rs.functions.balanceOf(_client.account.address).call()
        claimable   = rs.functions.claimable(_client.account.address).call()
        print(f"  revenue share : {rs_addr}")
        print(f"    supply      : {supply / 1e6:.6f} shares")
        print(f"    distributed : {total_dist / 1e6:.6f} USDC")
        print(f"    EPS         : {eps / 1e6:.6f} USDC/share")
        if my_shares:
            print(f"    your shares : {my_shares / 1e6:.6f}")
            print(f"    claimable   : {claimable / 1e6:.6f} USDC")


# ── Commands ─────────────────────────────────────────────────────────────────

def cmd_stake(args):
    print("\n── Stake ─────────────────────────────────────────────────────────")
    info     = _client.get_stake()
    minimum  = _client.registry.functions.minimumStakeRequired().call()
    usdc_bal = _client.usdc.functions.balanceOf(_client.account.address).call()
    shortfall = max(0, minimum - info.amount)

    print(f"  minimum stake : {minimum  / 1e6:.2f} USDC")
    print(f"  current stake : {info.amount / 1e6:.2f} USDC")
    print(f"  usdc balance  : {usdc_bal / 1e6:.2f} USDC")

    if shortfall == 0:
        print(f"  ✓ stake sufficient")
    else:
        print(f"  shortfall     : {shortfall / 1e6:.2f} USDC — staking now…")
        if usdc_bal < shortfall:
            sys.exit(f"Insufficient USDC: need {shortfall/1e6:.2f}, have {usdc_bal/1e6:.2f}")
        tx_hash = _client.stake(shortfall)
        print(f"  tx: {_tx_url(tx_hash)}")
        print(f"  ✓ staked {shortfall / 1e6:.2f} USDC")

    print("──────────────────────────────────────────────────────────────────\n")


def cmd_unstake(args):
    info     = _client.get_stake()
    amount   = args.amount or info.amount
    cooldown = info.cooldown_seconds

    print(f"\n── Unstake ───────────────────────────────────────────────────────")
    print(f"  currently staked : {info.amount / 1e6:.2f} USDC")
    print(f"  requesting       : {amount / 1e6:.2f} USDC")
    print(f"  cooldown         : {cooldown // 3600}h {(cooldown % 3600) // 60}m")

    if amount > info.amount:
        sys.exit(f"insufficient stake: have {info.amount / 1e6:.2f}, requested {amount / 1e6:.2f}")

    tx_hash = _client.request_unstake(amount)
    print(f"  tx: {_tx_url(tx_hash)}")
    print(f"  ✓ cooldown started — withdraw available after {cooldown // 3600}h")
    print(f"    uv run python cli.py withdraw --amount {amount}")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_withdraw(args):
    info = _client.get_stake()
    now  = int(time.time())

    print(f"\n── Withdraw ──────────────────────────────────────────────────────")
    print(f"  staked           : {info.amount / 1e6:.2f} USDC")
    print(f"  unlock at        : {info.unlocks_at} ({max(0, info.unlocks_at - now)}s remaining)")

    if info.unlocks_at > now:
        sys.exit(f"cooldown not elapsed — {info.unlocks_at - now}s remaining")

    amount = args.amount or info.amount
    tx_hash = _client.withdraw(amount)
    print(f"  tx: {_tx_url(tx_hash)}")
    new_info = _client.get_stake()
    print(f"  ✓ withdrawn {amount / 1e6:.2f} USDC")
    print(f"  new stake        : {new_info.amount / 1e6:.2f} USDC")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_deploy_provider(args):
    vault_bp         = args.vault_bp
    revenue_share_bp = args.revenue_share_bp
    remainder        = _MAX_PROVIDER_BP - vault_bp - revenue_share_bp

    if remainder < 0:
        sys.exit(f"bp exceeds available {_MAX_PROVIDER_BP} (protocol takes {_PROTOCOL_BP})")
    if vault_bp == 0 and revenue_share_bp == 0:
        sys.exit("at least one of --vault-bp or --revenue-share-bp must be > 0")

    print(f"\n── deploy-provider ───────────────────────────────────────────────")
    print(f"  name          : {args.name} ({args.symbol})")
    print(f"  vault         : {vault_bp / 100:.2f}%")
    print(f"  revenue share : {revenue_share_bp / 100:.2f}%")
    print(f"  protocol      : {_PROTOCOL_BP / 100:.2f}%")
    print(f"  direct        : {remainder / 100:.2f}%")

    print()
    # Stake preflight — print state before deploying
    stake_info = _client.get_stake()
    minimum = _client.registry.functions.minimumStakeRequired().call()
    usdc_bal = _client.usdc.functions.balanceOf(_client.account.address).call()
    shortfall = max(0, minimum - stake_info.amount)
    print(f"  minimum stake : {minimum / 1e6:.2f} USDC")
    print(f"  current stake : {stake_info.amount / 1e6:.2f} USDC")
    print(f"  usdc balance  : {usdc_bal / 1e6:.2f} USDC")
    if shortfall == 0:
        print(f"  ✓ stake sufficient")
    else:
        print(f"  shortfall     : {shortfall / 1e6:.2f} USDC — staking now…")
        if usdc_bal < shortfall:
            sys.exit(f"Insufficient USDC: need {shortfall/1e6:.2f}, have {usdc_bal/1e6:.2f}")
        tx_hash = _client.stake(shortfall)
        print(f"  tx: {_tx_url(tx_hash)}")
        print(f"  ✓ staked {shortfall / 1e6:.2f} USDC")

    deployed = _client.deploy_provider(
        name=args.name,
        symbol=args.symbol,
        vault_bp=vault_bp,
        rev_share_bp=revenue_share_bp,
        genesis_deposit=args.genesis_deposit,
        provider_treasury=args.provider_treasury or ZERO,
        rs_shares=args.rs_shares,
        rs_recipient=args.rs_recipient or ZERO,
        genesis_shares=args.genesis_shares,
        genesis_recipient=args.genesis_recipient or ZERO,
        metadata_uri=args.metadata_uri,
    )
    print(f"  tx: {_tx_url(deployed.tx_hash)}")

    vault_addr    = deployed.vault
    rs_addr       = deployed.revenue_share
    splitter_addr = deployed.splitter
    reg_id        = deployed.id

    print(f"\n  ✓ vault        : {vault_addr}")
    if rs_addr != ZERO:
        print(f"  ✓ revenueShare : {rs_addr}")
    print(f"  ✓ splitter     : {splitter_addr}")
    if reg_id and reg_id > 0:
        print(f"  ✓ provider id  : {reg_id}")

    print(f"\n  ┌─────────────────────────────────────────────────────────┐")
    print(f"  │  Next: update your x402 server                          │")
    print(f"  │  payTo = {splitter_addr}  │")
    print(f"  └─────────────────────────────────────────────────────────┘")
    if reg_id and reg_id > 0:
        print(f"\n  Then register your endpoints:")
        print(f"  uv run python cli.py register-endpoint \\")
        print(f"    --provider-id {reg_id} --splitter {splitter_addr} \\")
        print(f"    --url <your-endpoint-url>")

    # Auto-verify
    print()
    usdc_address      = _client.usdc.address
    protocol_treasury = _client.factory.functions.protocolTreasury().call()

    if vault_addr != ZERO:
        ctor = abi_encode(
            ["address", "string", "string", "address"],
            [usdc_address, args.name, args.symbol, _client.account.address],
        ).hex()
        verify_contract("ProviderRevenueVault", vault_addr, ctor)
    if rs_addr != ZERO:
        verify_contract("ProviderRevenueShare", rs_addr, abi_encode(
            ["address", "string", "string", "address"],
            [usdc_address, args.name + " Revenue Share", args.symbol + "RS", _client.account.address],
        ).hex())
    verify_contract("ProviderRevenueSplitter", splitter_addr, abi_encode(
        ["address", "address", "uint256", "address", "uint256", "address", "uint256", "address"],
        [usdc_address, protocol_treasury, _PROTOCOL_BP, args.provider_treasury or ZERO,
         remainder, rs_addr, revenue_share_bp, vault_addr],
    ).hex())

    print("──────────────────────────────────────────────────────────────────\n")


def cmd_register_endpoint(args):
    if _client.registry is None:
        sys.exit("No registry configured on this factory")

    print(f"\n── register-endpoint ─────────────────────────────────────────────")
    print(f"  provider id : {args.provider_id}")
    print(f"  url         : {args.url}")
    print(f"  method      : {args.method}")
    print(f"  splitter    : {args.splitter}")

    if args.hash:
        integrity_hash = args.hash
        print(f"  hash        : {integrity_hash}  (provided)")
    else:
        print(f"\n  fetching integrity hash from live server…")
        integrity_hash = fetch_integrity_hash(
            args.url, verbose=True, expected_pay_to=args.splitter
        )

    integrity_bytes = bytes.fromhex(integrity_hash.removeprefix("0x"))

    print(f"\n→ registerEndpoint(providerId={args.provider_id}, {args.method} {args.url})")
    receipt = send_tx(
        _client.w3, _client.account,
        _client.registry.functions.registerEndpoint(
            args.provider_id, args.url, args.method, integrity_bytes
        ),
        "registerEndpoint",
    )

    event       = _client.registry.events.EndpointRegistered().process_receipt(receipt, errors=DISCARD)[0]
    endpoint_id = "0x" + event["args"]["endpointId"].hex()
    print(f"  ✓ endpointId : {endpoint_id}")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_update_endpoint(args):
    print(f"\n── update-endpoint ───────────────────────────────────────────────")

    # Show current state
    ep = _client.get_endpoint(args.endpoint_id)
    if not ep.active:
        sys.exit("endpoint is inactive")
    print(f"  endpointId    : {ep.endpoint_id}")
    print(f"  url           : {ep.path}")
    print(f"  method        : {ep.method}")
    print(f"  current hash  : {ep.integrity_hash}  (v{ep.version})")

    if args.hash:
        new_hash = args.hash
        print(f"  new hash      : {new_hash}  (provided)")
    else:
        print(f"\n  fetching integrity hash from live server…")
        new_hash = fetch_integrity_hash(ep.path, verbose=True)

    if new_hash == ep.integrity_hash:
        print(f"\n  hash unchanged — nothing to update")
        print("──────────────────────────────────────────────────────────────────\n")
        return

    tx_hash = _client.update_endpoint(args.endpoint_id, new_hash)
    print(f"  tx: {_tx_url(tx_hash)}")
    print(f"  ✓ hash updated to {new_hash}  (v{ep.version + 1})")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_hash_endpoint(args):
    print(f"\n── hash-endpoint ─────────────────────────────────────────────────")
    print(f"  url    : {args.url}")
    print(f"  method : {args.method}")
    print(f"\n  fetching integrity hash from live server…")
    h = fetch_integrity_hash(args.url, verbose=True)
    print(f"\n  integrity hash : {h}")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_update_provider(args):
    print(f"\n── update-provider ───────────────────────────────────────────────")
    print(f"  provider id   : {args.provider_id}")

    tx_hash = _client.update_provider(
        provider_id=args.provider_id,
        metadata_uri=args.metadata_uri or "",
        payout_address=args.payout or "",
        splitter=args.splitter or "",
    )
    p = _client.get_provider(args.provider_id)
    print(f"  metadataURI   : {p.metadata_uri or '(none)'}")
    print(f"  payoutAddress : {p.payout_address}")
    print(f"  splitter      : {p.revenue_splitter}")
    print(f"  tx: {_tx_url(tx_hash)}")
    print(f"  ✓ provider {args.provider_id} updated")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_challenge(args):
    print(f"\n-- challenge -------------------------------------------------------")
    print(f"  ChallengeManager  : {_client.challenge_manager.address}")

    challenge_fee = _client.get_challenge_fee()
    cm_full = _client.w3.eth.contract(
        address=_client.challenge_manager.address,
        abi=get_abi("ChallengeManager"),
    )
    slash_bp = cm_full.functions.slashBp().call()
    print(f"  challengeFee      : {challenge_fee / 1e6:.2f} USDC")
    print(f"  slashBp           : {slash_bp / 100:.1f}%")

    # Resolve endpointId — either passed directly or derived from provider+url+method
    if args.endpoint_id:
        endpoint_id_hex = args.endpoint_id if args.endpoint_id.startswith("0x") else "0x" + args.endpoint_id
    else:
        if not args.provider or not args.url:
            sys.exit("provide --endpoint-id OR both --provider and --url")
        eid_bytes = _client.w3.solidity_keccak(
            ["uint256", "string", "string"],
            [args.provider_id, args.url, args.method],
        )
        endpoint_id_hex = "0x" + eid_bytes.hex()

    print(f"  endpointId        : {endpoint_id_hex}")

    # Read endpoint from registry to confirm it's active
    ep = _client.get_endpoint(endpoint_id_hex)
    if not ep.active:
        sys.exit("endpoint is not active — cannot challenge")

    print(f"  url               : {ep.path}")
    print(f"  method            : {ep.method}")
    print(f"  provider          : {ep.provider}")
    print(f"  integrityHash     : {ep.integrity_hash}")

    usdc_bal = _client.usdc.functions.balanceOf(_client.account.address).call()
    if usdc_bal < challenge_fee:
        sys.exit(f"insufficient USDC: need {challenge_fee/1e6:.2f}, have {usdc_bal/1e6:.2f}")

    print(f"\n  opening challenge…")
    challenge_id = _client.open_challenge(endpoint_id_hex)
    print(f"\n  challenge id      : {challenge_id}")
    print(f"  CRE workflow triggered — result arrives after DON consensus")
    print(f"  Check status:  uv run python cli.py challenge-status --id {challenge_id}")
    print("--------------------------------------------------------------------\n")


def cmd_challenge_status(args):
    c = _client.get_challenge(args.id)
    print(f"\n-- challenge {args.id} --")
    print(f"  challenger  : {c.challenger}")
    print(f"  endpointId  : {c.endpoint_id}")
    print(f"  status      : {c.status_name}")
    if c.status_name == "Valid":
        print(f"  result      : endpoint verified OK, challenger fee returned to provider")
    elif c.status_name == "Invalid":
        print(f"  result      : endpoint failed, provider slashed, fee returned to challenger")
    else:
        print(f"  result      : waiting for CRE DON callback...")
    print()


def cmd_vault(args):
    addr  = _resolve_vault(args.vault)
    vault = _client.w3.eth.contract(address=addr, abi=_vault_abi)

    name      = vault.functions.name().call()
    symbol    = vault.functions.symbol().call()
    owner     = vault.functions.owner().call()
    genesis   = vault.functions.genesisComplete().call()
    deps_en   = vault.functions.depositsEnabled().call()
    supply    = vault.functions.totalSupply().call()
    assets    = vault.functions.totalAssets().call()
    price     = (assets * 10**18 // supply) if supply else 0
    dead      = vault.functions.balanceOf("0x000000000000000000000000000000000000dEaD").call()
    my_shares = vault.functions.balanceOf(_client.account.address).call()
    redeemable = vault.functions.convertToAssets(my_shares).call() if my_shares else 0

    print(f"\n── Vault {addr} ──────────────────────────────────────────")
    print(f"  name              : {name} ({symbol})")
    print(f"  owner             : {owner}")
    print(f"  genesisComplete   : {genesis}")
    print(f"  depositsEnabled   : {deps_en}")
    print(f"  totalSupply       : {supply / 1e6:.6f} shares")
    print(f"    dead shares     : {dead / 1e6:.6f} (locked at 0xdead)")
    print(f"  totalAssets       : {assets / 1e6:.6f} USDC")
    print(f"  sharePrice        : {price / 1e18:.8f} USDC/share")
    print(f"  signer shares     : {my_shares / 1e6:.6f}")
    print(f"  signer redeemable : {redeemable / 1e6:.6f} USDC")
    print("────────────────────────────────────────────────────────────────────")

    if args.open_deposits:
        if deps_en:
            print("  deposits already open")
        else:
            send_tx(_client.w3, _client.account, vault.functions.openDeposits(), "openDeposits")
            print("  deposits opened")

    if args.deposit:
        if not deps_en and not args.open_deposits:
            sys.exit("deposits not open — pass --open-deposits to open first")
        amount = args.deposit
        print(f"\n  approving {amount / 1e6:.6f} USDC...")
        send_tx(_client.w3, _client.account, _client.usdc.functions.approve(addr, amount), "approve")
        send_tx(_client.w3, _client.account, vault.functions.deposit(amount, _client.account.address), "deposit")
        new_bal = vault.functions.balanceOf(_client.account.address).call()
        print(f"  new share balance : {new_bal / 1e6:.6f}")

    if args.redeem:
        shares = args.redeem
        if shares > my_shares:
            sys.exit(f"insufficient shares: have {my_shares / 1e6:.6f}, requested {shares / 1e6:.6f}")
        send_tx(_client.w3, _client.account,
                vault.functions.redeem(shares, _client.account.address, _client.account.address),
                "redeem")
        new_assets = vault.functions.totalAssets().call()
        print(f"  redeemed {shares / 1e6:.6f} shares")
        print(f"  vault totalAssets now : {new_assets / 1e6:.6f} USDC")

    print()


def cmd_splitter(args):
    addr = _resolve_splitter(args.splitter)
    s    = _client.w3.eth.contract(address=addr, abi=_splitter_abi)

    pt      = s.functions.protocolTreasury().call()
    pt_bp   = s.functions.protocolTreasuryBp().call()
    prov    = s.functions.providerTreasury().call()
    prov_bp = s.functions.providerTreasuryBp().call()
    rs      = s.functions.revenueShare().call()
    rs_bp   = s.functions.revenueShareBp().call()
    vault   = s.functions.vault().call()
    v_bp    = s.functions.vaultBp().call()
    pending = s.functions.pendingDistribution().call()

    vault_contract = _client.w3.eth.contract(
        address=_client.w3.to_checksum_address(vault), abi=_vault_abi
    )
    v_supply = vault_contract.functions.totalSupply().call()
    v_assets = vault_contract.functions.totalAssets().call()
    v_deps   = vault_contract.functions.depositsEnabled().call()
    v_gen    = vault_contract.functions.genesisComplete().call()

    print(f"\n── Splitter {addr} ──────────────────────────────────────")
    print(f"  protocolTreasury  : {pt}  ({pt_bp / 100:.2f}%)")
    print(f"  providerTreasury  : {prov}  ({prov_bp / 100:.2f}%)")
    print(f"  revenueShare      : {rs}  ({rs_bp / 100:.2f}%)")
    print(f"  vault             : {vault}  ({v_bp / 100:.2f}%)")
    print(f"  pending           : {pending / 1e6:.6f} USDC")

    print(f"\n── Vault {vault} ──────────────────────────────────────")
    print(f"  totalSupply       : {v_supply / 1e6:.6f} shares")
    print(f"  totalAssets       : {v_assets / 1e6:.6f} USDC")
    if v_supply:
        print(f"  sharePrice        : {(v_assets * 1e18 // v_supply) / 1e18:.8f} USDC/share")
    else:
        print(f"  sharePrice        : n/a")
    print(f"  depositsEnabled   : {v_deps}")
    print(f"  genesisComplete   : {v_gen}")
    print("────────────────────────────────────────────────────────────────────\n")

    if args.distribute:
        if pending == 0:
            print("  nothing to distribute (balance is 0)\n")
            return
        print(f"  distributing {pending / 1e6:.6f} USDC...")
        send_tx(_client.w3, _client.account, s.functions.distribute(), "distribute")
        print("  done\n")


def cmd_registry(args):
    raw_addr    = _client.account.address if args.address == "self" else args.address
    filter_addr = _client.w3.to_checksum_address(raw_addr) if raw_addr else None
    all_ep_events = _client.registry.events.EndpointRegistered.get_logs(from_block=0)

    count = _client.registry.functions.providerCount().call()
    print(f"\n-- Registry providers ({count}) ----------------------------------------")
    if count == 0:
        print("  (none registered)")
        print("----------------------------------------------------------------------\n")
        return

    for pid in range(1, count + 1):
        p = _client.registry.functions.providers(pid).call()
        # (owner, metadataURI, payoutAddress, revenueSplitter, active, createdAt)
        print(f"\n  Provider #{pid}")
        print(f"    owner        : {p[0]}")
        print(f"    metadataURI  : {p[1] or '(none)'}")
        print(f"    payoutAddress: {p[2]}")
        print(f"    active       : {p[4]}")

        ep_events = [
            ev for ev in all_ep_events
            if filter_addr is None
            or _client.w3.to_checksum_address(ev["args"]["provider"]) == filter_addr
        ]
        if not ep_events:
            print(f"    endpoints    : (none)")
        else:
            print(f"    endpoints    :")
            for ev in ep_events:
                eid = ev["args"]["endpointId"]
                e   = _client.registry.functions.endpoints(eid).call()
                # (endpointId, provider, path, method, integrityHash, version, active, ...)
                print(f"      endpointId     : 0x{eid.hex()}")
                print(f"      registeredBy   : {ev['args']['provider']}")
                print(f"      path           : {e[2]}")
                print(f"      method         : {e[3]}")
                print(f"      integrityHash  : 0x{e[4].hex()}")
                print(f"      active         : {e[6]}")

    print("\n----------------------------------------------------------------------\n")


def cmd_revenue_share(args):
    addr = _resolve_revenue_share(args.rs)
    rs   = _client.w3.eth.contract(address=addr, abi=_rs_abi)

    name         = rs.functions.name().call()
    symbol       = rs.functions.symbol().call()
    owner        = rs.functions.owner().call()
    genesis      = rs.functions.genesisComplete().call()
    supply       = rs.functions.totalSupply().call()
    total_dist   = rs.functions.totalDistributed().call()
    total_claimed = rs.functions.totalClaimed().call()
    total_pending = rs.functions.totalPending().call()
    eps          = rs.functions.cumulativeRevenuePerShare().call()
    my_shares    = rs.functions.balanceOf(_client.account.address).call()
    claimable    = rs.functions.claimable(_client.account.address).call()

    try:
        apr7d, apr30d = rs.functions.getCurrentAPRs().call()
    except Exception:
        apr7d, apr30d = 0, 0

    print(f"\n── Revenue Share {addr} ───────────────────────────────")
    print(f"  name           : {name} ({symbol})")
    print(f"  owner          : {owner}")
    print(f"  genesisComplete: {genesis}")
    print(f"  totalSupply    : {supply / 1e6:.6f} shares")
    print(f"  totalDistrib   : {total_dist / 1e6:.6f} USDC")
    print(f"  totalClaimed   : {total_claimed / 1e6:.6f} USDC")
    print(f"  unclaimed pool : {total_pending / 1e6:.6f} USDC")
    print(f"  EPS (lifetime) : {eps / 1e6:.6f} USDC/share")
    if apr7d or apr30d:
        print(f"  APR (7d)       : {apr7d / 1e6:.4f}%")
        print(f"  APR (30d)      : {apr30d / 1e6:.4f}%")
    print(f"\n  your shares    : {my_shares / 1e6:.6f}")
    print(f"  claimable      : {claimable / 1e6:.6f} USDC")
    print("────────────────────────────────────────────────────────────────────")

    if args.claim:
        if claimable == 0:
            print("  nothing to claim\n")
        else:
            print(f"\n  claiming {claimable / 1e6:.6f} USDC...")
            send_tx(_client.w3, _client.account, rs.functions.claim(), "claim")
            print("  done\n")
    else:
        print()


def cmd_status(args):
    usdc_bal   = _client.usdc.functions.balanceOf(_client.account.address).call()
    stake_info = _client.get_stake()
    minimum    = _client.registry.functions.minimumStakeRequired().call()
    count      = _client.factory.functions.providerCount().call()

    print(f"\n── Status ────────────────────────────────────────────────────────")
    print(f"  signer        : {_client.account.address}")
    print(f"  factory       : {_client.factory.address}")
    print(f"  registry      : {_client.registry.address}")
    print(f"  usdc          : {_client.usdc.address}")
    print(f"  protocol fee  : {_PROTOCOL_BP / 100:.2f}%")
    print(f"  usdc balance  : {usdc_bal / 1e6:.2f} USDC")
    print(f"  staked        : {stake_info.amount / 1e6:.2f} USDC  (minimum: {minimum / 1e6:.2f})")
    print(f"  total providers registered : {count}")

    deployments = _my_deployments()
    if deployments:
        print(f"\n── Your Deployed Providers ({len(deployments)}) ──────────────────────────────────")
        for i, d in enumerate(deployments, 1):
            print(f"\n  ── Provider {i} ──")
            _print_provider_stats(d["vault"], d["splitter"], d.get("revenueShare", ZERO))

    print("\n──────────────────────────────────────────────────────────────────\n")


# ── Help & parser ────────────────────────────────────────────────────────────

class _Parser(argparse.ArgumentParser):
    """Argparse subclass that replaces the default error output with our custom help."""
    def error(self, message):
        if "invalid choice" in message:
            # Unknown command — show grouped help instead of the raw choices list
            unknown = message.split("'")[1] if "'" in message else message
            print(f"  unknown command: {unknown}")
        else:
            print(f"  error: {message}")
        _print_help()
        raise SystemExit(0)


def _print_help():
    print("""
Composed Protocol CLI

  Staking
    stake                 Top up stake to the minimum required
    unstake  [--amount]   Request unstake — starts cooldown
    withdraw [--amount]   Withdraw after cooldown expires

  Provider
    deploy-provider       Deploy vault + splitter, register in registry
    update-provider       Update metadata URI, payout, or splitter address
    hash-endpoint         Compute x402 integrity hash for a URL (no tx)
    register-endpoint     Fetch x402 hash from live server and register on-chain
    update-endpoint       Update integrity hash after a price change

  Challenges
    challenge             Open a Chainlink CRE challenge for an endpoint
    challenge-status      Check the result of a challenge

  Inspection
    status                Signer, stake, USDC balance + all deployed provider stats
    registry              List all providers and their endpoints
    vault                 Vault TVL, share price, your shares; deposit/redeem
    revenue-share         RS supply, EPS, APR, your claimable USDC; optionally claim
    splitter              Pending balance, routing config; optionally distribute

Use 'composed <command> --help' for command-specific options.
""")


# ── Argparse ─────────────────────────────────────────────────────────────────

def main():
    global _client, _PROTOCOL_BP, _MAX_PROVIDER_BP
    global _vault_abi, _splitter_abi, _rs_abi

    parser = _Parser(prog="composed", add_help=False)
    parser.add_argument("-h", "--help", action="store_true")
    sub    = parser.add_subparsers(dest="command")

    # stake
    sub.add_parser("stake", help="Ensure account meets minimum stake requirement")

    # unstake
    us = sub.add_parser("unstake", help="Request to unstake USDC (starts cooldown)")
    us.add_argument("--amount", type=int, default=0, help="Raw USDC units to unstake (default: full stake)")

    # withdraw
    wd = sub.add_parser("withdraw", help="Withdraw unstaked USDC after cooldown expires")
    wd.add_argument("--amount", type=int, default=0, help="Raw USDC units to withdraw (default: full stake)")

    # deploy-provider
    dp = sub.add_parser("deploy-provider", help="Deploy vault + splitter and register provider")
    dp.add_argument("--name",             required=True,  help="Vault token name")
    dp.add_argument("--symbol",           required=True,  help="Vault token symbol")
    dp.add_argument("--vault-bp",         type=int, default=9_800, help="Basis points to vault (default 9800)")
    dp.add_argument("--revenue-share-bp", type=int, default=0,     help="Basis points to revenue share (default 0)")
    dp.add_argument("--rs-shares",        type=int, default=0,     help="Genesis shares for revenue share contract")
    dp.add_argument("--rs-recipient",     default="",  help="Revenue share genesis recipient (default: signer)")
    dp.add_argument("--genesis-shares",   type=int, default=0,  help="Vault genesis shares to mint")
    dp.add_argument("--genesis-deposit",  type=int, default=0,  help="USDC (raw units) to seed vault")
    dp.add_argument("--genesis-recipient",default="",  help="Vault genesis recipient (default: signer)")
    dp.add_argument("--provider-treasury",default="",  help="Address for remainder direct cut")
    dp.add_argument("--metadata-uri",     default="",  help="Metadata URI for registry")

    # hash-endpoint
    he = sub.add_parser("hash-endpoint", help="Compute the x402 integrity hash for a URL (no on-chain action)")
    he.add_argument("--url",    required=True, help="Full endpoint URL to fetch")
    he.add_argument("--method", default="GET", help="HTTP method (default: GET)")

    # update-endpoint
    ue = sub.add_parser("update-endpoint", help="Update the integrity hash for a registered endpoint")
    ue.add_argument("--endpoint-id", required=True, help="Endpoint ID (bytes32 hex)")
    ue.add_argument("--hash",        default="",    help="New integrity hash (omit to re-fetch from live server)")

    # update-provider
    up = sub.add_parser("update-provider", help="Update provider metadata, payout address, or splitter")
    up.add_argument("--provider-id",   type=int, required=True, help="Provider ID to update")
    up.add_argument("--metadata-uri",  default=None, help="New metadata URI (keep existing if omitted)")
    up.add_argument("--payout",        default="",   help="New payout address (keep existing if omitted)")
    up.add_argument("--splitter",      default="",   help="New splitter address (keep existing if omitted)")

    # register-endpoint
    re = sub.add_parser("register-endpoint", help="Register an API endpoint on-chain")
    re.add_argument("--provider-id", type=int, required=True, help="Registry provider ID")
    re.add_argument("--splitter",    required=True, help="Splitter address (used to validate server payTo)")
    re.add_argument("--url",         required=True, help="Full endpoint URL")
    re.add_argument("--method",      default="GET", help="HTTP method (default: GET)")
    re.add_argument("--hash",        default="",    help="Pre-computed integrity hash (skips live fetch)")

    # challenge
    ch = sub.add_parser("challenge", help="Open a Chainlink challenge for a registered endpoint")
    grp = ch.add_mutually_exclusive_group(required=True)
    grp.add_argument("--endpoint-id", help="Endpoint ID (bytes32 hex)")
    grp.add_argument("--url",         help="Endpoint URL (derives ID with --provider-id and --method)")
    ch.add_argument("--provider-id",  type=int, default=0, help="Provider ID (used with --url)")
    ch.add_argument("--provider",     default="",          help="Provider address (used with --url)")
    ch.add_argument("--method",       default="GET",       help="HTTP method (default: GET)")

    # challenge-status
    cs = sub.add_parser("challenge-status", help="Check the status of a challenge")
    cs.add_argument("--id", type=int, required=True, help="Challenge ID")

    # vault
    vp = sub.add_parser("vault", help="Inspect vault state and call vault functions")
    vp.add_argument("--vault",          default="",      help="Vault address (auto-detected if omitted)")
    vp.add_argument("--open-deposits",  action="store_true", help="Call openDeposits() (owner only)")
    vp.add_argument("--deposit",        type=int, default=0,  help="Deposit USDC raw units into vault")
    vp.add_argument("--redeem",         type=int, default=0,  help="Redeem shares (raw units)")

    # revenue-share
    rs = sub.add_parser("revenue-share", help="Inspect revenue share contract; optionally claim")
    rs.add_argument("--rs",    default="", help="Revenue share address (auto-detected if omitted)")
    rs.add_argument("--claim", action="store_true", help="Claim all accrued USDC dividends")

    # splitter
    sp = sub.add_parser("splitter", help="Show splitter + vault state, optionally distribute")
    sp.add_argument("--splitter",    default="", help="Splitter address (auto-detected from ProviderDeployed events if omitted)")
    sp.add_argument("--distribute",  action="store_true", help="Call distribute() if balance > 0")

    # registry
    rg = sub.add_parser("registry", help="List all registered providers and their endpoint IDs")
    rg.add_argument("--address", nargs="?", const="self", default="", help="Filter endpoints by registering address (omit for all, --address alone = signer)")

    # status
    sub.add_parser("status", help="Print account and protocol state")

    # ── Initialise SDK client ────────────────────────────────────────────────
    rpc_url     = os.getenv("GATEWAY_URL") or os.getenv("AVALANCHE_FUJI_RPC_URL")
    private_key = os.getenv("PROVIDER_PRIVATE_KEY") or os.getenv("PRIVATE_KEY")
    assert rpc_url, "GATEWAY_URL (or AVALANCHE_FUJI_RPC_URL) not set in .env"
    assert private_key, "PROVIDER_PRIVATE_KEY (or PRIVATE_KEY) not set in .env"

    _client = ComposedClient(rpc_url=rpc_url, private_key=private_key)

    _PROTOCOL_BP     = _client.factory.functions.protocolTreasuryBp().call()
    _MAX_PROVIDER_BP = 10_000 - _PROTOCOL_BP

    # ABIs for contracts not managed by the SDK
    _vault_abi    = get_abi("ProviderRevenueVault")
    _splitter_abi = get_abi("ProviderRevenueSplitter")
    _rs_abi       = get_abi("ProviderRevenueShare")

    # ── Dispatch ─────────────────────────────────────────────────────────────
    dispatch = {
        "stake":             cmd_stake,
        "unstake":           cmd_unstake,
        "withdraw":          cmd_withdraw,
        "deploy-provider":   cmd_deploy_provider,
        "update-provider":   cmd_update_provider,
        "hash-endpoint":     cmd_hash_endpoint,
        "register-endpoint": cmd_register_endpoint,
        "update-endpoint":   cmd_update_endpoint,
        "challenge":         cmd_challenge,
        "challenge-status":  cmd_challenge_status,
        "vault":             cmd_vault,
        "revenue-share":     cmd_revenue_share,
        "splitter":          cmd_splitter,
        "registry":          cmd_registry,
        "status":            cmd_status,
    }

    def _run(argv: list[str]) -> None:
        if not argv or argv == ["-h"] or argv == ["--help"] or argv == ["help"]:
            _print_help()
            return
        try:
            parsed = parser.parse_args(argv)
            if parsed.help or not parsed.command:
                _print_help()
                return
            dispatch[parsed.command](parsed)
        except SystemExit as e:
            if e.code not in (None, 0) and isinstance(e.code, str):
                print(e.code)

    if len(sys.argv) > 1:
        # Direct invocation: composed status
        _run(sys.argv[1:])
    else:
        # Interactive shell
        print(f"Composed Protocol CLI  —  signer: {_client.account.address}")
        print("Type a command or 'help'. Press Ctrl-C or type 'exit' to quit.\n")
        while True:
            try:
                line = input("composed> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                continue
            if line in ("exit", "quit", "q"):
                break
            _run(shlex.split(line))


if __name__ == "__main__":
    main()
