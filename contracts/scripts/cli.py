"""
HTTPayer provider CLI.

Commands:
  stake              Ensure account is staked to the minimum required
  unstake            Request to unstake USDC (starts cooldown)
  withdraw           Withdraw unstaked USDC after cooldown expires
  deploy-provider    Deploy vault + splitter, register in APIIntegrityRegistry
  register-endpoint  Fetch x402 hash from live server and register on-chain
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
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from web3.logs import DISCARD
from eth_abi import encode as abi_encode
from dotenv import load_dotenv

from utils import get_contract_config, get_abi, build_w3, build_account, send_tx, ERC20_ABI
from verify import verify_contract
from x402_metadata import fetch_integrity_hash

load_dotenv()

# ── Bootstrap ───────────────────────────────────────────────────────────────────

w3      = build_w3()
account = build_account(w3, role="provider")

factory_abi, factory_address   = get_contract_config("APIRegistryFactory")
challenge_manager_abi, challenge_manager_address = get_contract_config("ChallengeManager")
challenge_manager = w3.eth.contract(address=challenge_manager_address, abi=challenge_manager_abi)
factory = w3.eth.contract(address=factory_address, abi=factory_abi)

usdc_address = factory.functions.USDC().call()
usdc         = w3.eth.contract(address=usdc_address, abi=ERC20_ABI)

PROTOCOL_BP     = factory.functions.protocolTreasuryBp().call()
MAX_PROVIDER_BP = 10_000 - PROTOCOL_BP
ZERO            = "0x0000000000000000000000000000000000000000"

registry_abi     = get_abi("APIIntegrityRegistry")
registry_address = factory.functions.registry().call()
registry = (
    w3.eth.contract(address=w3.to_checksum_address(registry_address), abi=registry_abi)
    if registry_address != ZERO else None
)

stake_manager_abi = get_abi("StakeManager")
stake_manager_address = registry.functions.stakeManager().call() if registry else None
stake_manager = (
    w3.eth.contract(address=w3.to_checksum_address(stake_manager_address), abi=stake_manager_abi)
    if stake_manager_address and stake_manager_address != ZERO else None
)

vault_abi    = get_abi("ProviderRevenueVault")
splitter_abi = get_abi("ProviderRevenueSplitter")
rs_abi       = get_abi("ProviderRevenueShare")

# ── Helpers ─────────────────────────────────────────────────────────────────────

def _ensure_staked():
    if stake_manager is None:
        return
    minimum   = registry.functions.minimumStakeRequired().call()
    staked, _ = stake_manager.functions.stakes(account.address).call()
    usdc_bal  = usdc.functions.balanceOf(account.address).call()
    shortfall = max(0, minimum - staked)

    print(f"  minimum stake : {minimum  / 1e6:.2f} USDC")
    print(f"  current stake : {staked   / 1e6:.2f} USDC")
    print(f"  usdc balance  : {usdc_bal / 1e6:.2f} USDC")

    if shortfall == 0:
        print(f"  ✓ stake sufficient")
        return

    print(f"  shortfall     : {shortfall / 1e6:.2f} USDC — staking now…")
    if usdc_bal < shortfall:
        sys.exit(f"Insufficient USDC: need {shortfall/1e6:.2f}, have {usdc_bal/1e6:.2f}")

    sm_addr = w3.to_checksum_address(stake_manager_address)
    send_tx(w3, account, usdc.functions.approve(sm_addr, shortfall), "approve stake")
    send_tx(w3, account, stake_manager.functions.stake(shortfall), "stake")
    print(f"  ✓ staked {shortfall / 1e6:.2f} USDC")


# ── Commands ─────────────────────────────────────────────────────────────────────

def cmd_stake(args):
    print("\n── Stake ─────────────────────────────────────────────────────────")
    _ensure_staked()
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_unstake(args):
    if stake_manager is None:
        sys.exit("No stake manager configured")
    staked, unlock = stake_manager.functions.stakes(account.address).call()
    cooldown = stake_manager.functions.withdrawCooldown().call()
    amount = args.amount or staked
    print(f"\n── Unstake ───────────────────────────────────────────────────────")
    print(f"  currently staked : {staked / 1e6:.2f} USDC")
    print(f"  requesting       : {amount / 1e6:.2f} USDC")
    print(f"  cooldown         : {cooldown // 3600}h {(cooldown % 3600) // 60}m")
    if amount > staked:
        sys.exit(f"insufficient stake: have {staked / 1e6:.2f}, requested {amount / 1e6:.2f}")
    send_tx(w3, account, stake_manager.functions.requestUnstake(amount), "requestUnstake")
    import time
    unlock_at = int(time.time()) + cooldown
    print(f"  ✓ cooldown started — withdraw available after {cooldown // 3600}h")
    print(f"    uv run python cli.py withdraw --amount {amount}")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_withdraw(args):
    if stake_manager is None:
        sys.exit("No stake manager configured")
    staked, unlock = stake_manager.functions.stakes(account.address).call()
    import time
    now = int(time.time())
    print(f"\n── Withdraw ──────────────────────────────────────────────────────")
    print(f"  staked           : {staked / 1e6:.2f} USDC")
    print(f"  unlock at        : {unlock} ({max(0, unlock - now)}s remaining)")
    if unlock > now:
        sys.exit(f"cooldown not elapsed — {unlock - now}s remaining")
    amount = args.amount or staked
    send_tx(w3, account, stake_manager.functions.withdraw(amount), "withdraw")
    new_staked, _ = stake_manager.functions.stakes(account.address).call()
    print(f"  ✓ withdrawn {amount / 1e6:.2f} USDC")
    print(f"  new stake        : {new_staked / 1e6:.2f} USDC")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_deploy_provider(args):
    vault_bp         = args.vault_bp
    revenue_share_bp = args.revenue_share_bp
    remainder        = MAX_PROVIDER_BP - vault_bp - revenue_share_bp

    if remainder < 0:
        sys.exit(f"bp exceeds available {MAX_PROVIDER_BP} (protocol takes {PROTOCOL_BP})")
    if vault_bp == 0 and revenue_share_bp == 0:
        sys.exit("at least one of --vault-bp or --revenue-share-bp must be > 0")

    print(f"\n── deploy-provider ───────────────────────────────────────────────")
    print(f"  name          : {args.name} ({args.symbol})")
    print(f"  vault         : {vault_bp / 100:.2f}%")
    print(f"  revenue share : {revenue_share_bp / 100:.2f}%")
    print(f"  protocol      : {PROTOCOL_BP / 100:.2f}%")
    print(f"  direct        : {remainder / 100:.2f}%")

    # Stake preflight
    if registry is not None:
        print()
        _ensure_staked()

    # Genesis deposit approval
    if args.genesis_deposit > 0:
        print(f"\n  approving genesis deposit ({args.genesis_deposit / 1e6:.2f} USDC)…")
        send_tx(w3, account, usdc.functions.approve(factory_address, args.genesis_deposit), "approve")

    treasury_addr      = args.provider_treasury or ZERO
    genesis_recipient  = args.genesis_recipient or ZERO
    rs_recipient       = args.rs_recipient      or ZERO

    receipt = send_tx(
        w3, account,
        factory.functions.deployProvider(
            args.name,
            args.symbol,
            vault_bp,
            args.genesis_shares,
            genesis_recipient,
            args.genesis_deposit,
            treasury_addr,
            revenue_share_bp,
            args.rs_shares,
            rs_recipient,
            args.metadata_uri,
        ),
        "deployProvider",
    )

    event        = factory.events.ProviderDeployed().process_receipt(receipt, errors=DISCARD)[0]
    vault_addr   = event["args"]["vault"]
    rs_addr      = event["args"]["revenueShare"]
    splitter_addr = event["args"]["splitter"]

    reg_id = 0
    if registry is not None:
        reg_events = registry.events.ProviderRegistered().process_receipt(receipt, errors=DISCARD)
        if reg_events:
            reg_id = reg_events[0]["args"]["id"]

    print(f"\n  ✓ vault        : {vault_addr}")
    if rs_addr != ZERO:
        print(f"  ✓ revenueShare : {rs_addr}")
    print(f"  ✓ splitter     : {splitter_addr}")
    if reg_id:
        print(f"  ✓ provider id  : {reg_id}")

    print(f"\n  ┌─────────────────────────────────────────────────────────┐")
    print(f"  │  Next: update your x402 server                          │")
    print(f"  │  payTo = {splitter_addr}  │")
    print(f"  └─────────────────────────────────────────────────────────┘")
    if reg_id:
        print(f"\n  Then register your endpoints:")
        print(f"  uv run python cli.py register-endpoint \\")
        print(f"    --provider-id {reg_id} --splitter {splitter_addr} \\")
        print(f"    --url <your-endpoint-url>")

    # Auto-verify
    print()
    protocol_treasury = factory.functions.protocolTreasury().call()
    if vault_addr != ZERO:
        ctor = abi_encode(
            ["address", "string", "string", "address"],
            [usdc_address, args.name, args.symbol, account.address],
        ).hex()
        verify_contract("ProviderRevenueVault", vault_addr, ctor)
    if rs_addr != ZERO:
        verify_contract("ProviderRevenueShare", rs_addr, abi_encode(
            ["address", "string", "string", "address"],
            [usdc_address, args.name + " Revenue Share", args.symbol + "RS", account.address],
        ).hex())
    verify_contract("ProviderRevenueSplitter", splitter_addr, abi_encode(
        ["address", "address", "uint256", "address", "uint256", "address", "uint256", "address"],
        [usdc_address, protocol_treasury, PROTOCOL_BP, treasury_addr,
         remainder, rs_addr, revenue_share_bp, vault_addr],
    ).hex())

    print("──────────────────────────────────────────────────────────────────\n")


def cmd_register_endpoint(args):
    if registry is None:
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
        w3, account,
        registry.functions.registerEndpoint(
            args.provider_id, args.url, args.method, integrity_bytes
        ),
        "registerEndpoint",
    )

    event       = registry.events.EndpointRegistered().process_receipt(receipt, errors=DISCARD)[0]
    endpoint_id = "0x" + event["args"]["endpointId"].hex()
    print(f"  ✓ endpointId : {endpoint_id}")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_update_provider(args):
    if registry is None:
        sys.exit("No registry configured")
    p = registry.functions.providers(args.provider_id).call()
    # (owner, metadataURI, payoutAddress, revenueSplitter, active, createdAt)
    payout    = args.payout    or p[2]
    splitter  = args.splitter  or p[3]
    meta_uri  = args.metadata_uri if args.metadata_uri is not None else p[1]

    print(f"\n── update-provider ───────────────────────────────────────────────")
    print(f"  provider id   : {args.provider_id}")
    print(f"  metadataURI   : {meta_uri or '(none)'}")
    print(f"  payoutAddress : {payout}")
    print(f"  splitter      : {splitter}")
    send_tx(
        w3, account,
        registry.functions.updateProvider(
            args.provider_id,
            meta_uri,
            w3.to_checksum_address(payout),
            w3.to_checksum_address(splitter),
        ),
        "updateProvider",
    )
    print(f"  ✓ provider {args.provider_id} updated")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_challenge(args):
    print(f"\n-- challenge -------------------------------------------------------")
    print(f"  ChallengeManager  : {challenge_manager_address}")

    challenge_fee = challenge_manager.functions.challengeFee().call()
    slash_bp      = challenge_manager.functions.slashBp().call()
    print(f"  challengeFee      : {challenge_fee / 1e6:.2f} USDC")
    print(f"  slashBp           : {slash_bp / 100:.1f}%")

    # Resolve endpointId — either passed directly or derived from provider+url+method
    if args.endpoint_id:
        endpoint_id = bytes.fromhex(args.endpoint_id.removeprefix("0x"))
    else:
        if not args.provider or not args.url:
            sys.exit("provide --endpoint-id OR both --provider and --url")
        endpoint_id = w3.solidity_keccak(
            ["uint256", "string", "string"],
            [args.provider_id, args.url, args.method],
        )

    endpoint_id_hex = "0x" + endpoint_id.hex()
    print(f"  endpointId        : {endpoint_id_hex}")

    # Read endpoint from registry to confirm it's active
    ep = registry.functions.endpoints(endpoint_id).call()
    _, provider, path, method, integrity_hash, _, active, _, _ = ep
    if not active:
        sys.exit("endpoint is not active — cannot challenge")

    print(f"  url               : {path}")
    print(f"  method            : {method}")
    print(f"  provider          : {provider}")
    print(f"  integrityHash     : 0x{integrity_hash.hex()}")

    # Approve challengeFee
    usdc_bal = usdc.functions.balanceOf(account.address).call()
    if usdc_bal < challenge_fee:
        sys.exit(f"insufficient USDC: need {challenge_fee/1e6:.2f}, have {usdc_bal/1e6:.2f}")

    print(f"\n  approving {challenge_fee / 1e6:.2f} USDC for challenge fee...")
    send_tx(w3, account, usdc.functions.approve(challenge_manager_address, challenge_fee), "approve")

    print(f"  opening challenge...")
    receipt = send_tx(w3, account, challenge_manager.functions.openChallenge(endpoint_id), "openChallenge")

    from web3.logs import DISCARD
    events = challenge_manager.events.ChallengeOpened().process_receipt(receipt, errors=DISCARD)
    if events:
        challenge_id = events[0]["args"]["id"]
        print(f"\n  challenge id      : {challenge_id}")
        print(f"  CRE workflow triggered — result arrives after DON consensus")
        print(f"  Check status:  uv run python cli.py challenge-status --id {challenge_id}")
    print("--------------------------------------------------------------------\n")


def cmd_challenge_status(args):
    c = challenge_manager.functions.challenges(args.id).call()
    challenger, endpoint_id, status = c
    status_name = ["Pending", "Valid", "Invalid"][status]

    print(f"\n-- challenge {args.id} --")
    print(f"  challenger  : {challenger}")
    print(f"  endpointId  : 0x{endpoint_id.hex()}")
    print(f"  status      : {status_name}")
    if status_name == "Valid":
        print(f"  result      : endpoint verified OK, challenger fee returned to provider")
    elif status_name == "Invalid":
        print(f"  result      : endpoint failed, provider slashed, fee returned to challenger")
    else:
        print(f"  result      : waiting for CRE DON callback...")
    print()


def cmd_vault(args):
    addr  = w3.to_checksum_address(args.vault)
    vault = w3.eth.contract(address=addr, abi=vault_abi)

    name     = vault.functions.name().call()
    symbol   = vault.functions.symbol().call()
    owner    = vault.functions.owner().call()
    genesis  = vault.functions.genesisComplete().call()
    deps_en  = vault.functions.depositsEnabled().call()
    supply   = vault.functions.totalSupply().call()
    assets   = vault.functions.totalAssets().call()
    price    = (assets * 10**18 // supply) if supply else 0
    dead     = vault.functions.balanceOf("0x000000000000000000000000000000000000dEaD").call()
    my_shares = vault.functions.balanceOf(account.address).call()
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
            send_tx(w3, account, vault.functions.openDeposits(), "openDeposits")
            print("  deposits opened")

    if args.deposit:
        if not deps_en and not args.open_deposits:
            sys.exit("deposits not open — pass --open-deposits to open first")
        amount = args.deposit
        print(f"\n  approving {amount / 1e6:.6f} USDC...")
        send_tx(w3, account, usdc.functions.approve(addr, amount), "approve")
        send_tx(w3, account, vault.functions.deposit(amount, account.address), "deposit")
        new_bal = vault.functions.balanceOf(account.address).call()
        print(f"  new share balance : {new_bal / 1e6:.6f}")

    if args.redeem:
        shares = args.redeem
        if shares > my_shares:
            sys.exit(f"insufficient shares: have {my_shares / 1e6:.6f}, requested {shares / 1e6:.6f}")
        send_tx(w3, account,
                vault.functions.redeem(shares, account.address, account.address),
                "redeem")
        new_assets = vault.functions.totalAssets().call()
        print(f"  redeemed {shares / 1e6:.6f} shares")
        print(f"  vault totalAssets now : {new_assets / 1e6:.6f} USDC")

    print()


def cmd_splitter(args):
    addr = w3.to_checksum_address(args.splitter)
    s    = w3.eth.contract(address=addr, abi=splitter_abi)

    pt      = s.functions.protocolTreasury().call()
    pt_bp   = s.functions.protocolTreasuryBp().call()
    prov    = s.functions.providerTreasury().call()
    prov_bp = s.functions.providerTreasuryBp().call()
    rs      = s.functions.revenueShare().call()
    rs_bp   = s.functions.revenueShareBp().call()
    vault   = s.functions.vault().call()
    v_bp    = s.functions.vaultBp().call()
    pending = s.functions.pendingDistribution().call()

    vault_contract = w3.eth.contract(address=w3.to_checksum_address(vault), abi=vault_abi)
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
    print(f"  sharePrice        : {(v_assets * 1e18 // v_supply) / 1e18:.8f} USDC/share" if v_supply else "  sharePrice        : n/a")
    print(f"  depositsEnabled   : {v_deps}")
    print(f"  genesisComplete   : {v_gen}")
    print("────────────────────────────────────────────────────────────────────\n")

    if args.distribute:
        if pending == 0:
            print("  nothing to distribute (balance is 0)\n")
            return
        print(f"  distributing {pending / 1e6:.6f} USDC...")
        send_tx(w3, account, s.functions.distribute(), "distribute")
        print("  done\n")


def cmd_registry(args):
    if registry is None:
        print("No registry configured.")
        return

    # Fetch all EndpointRegistered events once, filter client-side if --address passed
    raw_addr    = account.address if args.address == "self" else args.address
    filter_addr = w3.to_checksum_address(raw_addr) if raw_addr else None
    all_ep_events = registry.events.EndpointRegistered.get_logs(from_block=0)

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
        print(f"    owner        : {p[0]}")
        print(f"    metadataURI  : {p[1] or '(none)'}")
        print(f"    payoutAddress: {p[2]}")
        print(f"    active       : {p[4]}")

        ep_events = [
            ev for ev in all_ep_events
            if filter_addr is None
            or w3.to_checksum_address(ev["args"]["provider"]) == filter_addr
        ]
        if not ep_events:
            print(f"    endpoints    : (none)")
        else:
            print(f"    endpoints    :")
            for ev in ep_events:
                eid = ev["args"]["endpointId"]
                e   = registry.functions.endpoints(eid).call()
                # (endpointId, provider, path, method, integrityHash, version, active, ...)
                print(f"      endpointId     : 0x{eid.hex()}")
                print(f"      registeredBy   : {ev['args']['provider']}")
                print(f"      path           : {e[2]}")
                print(f"      method         : {e[3]}")
                print(f"      integrityHash  : 0x{e[4].hex()}")
                print(f"      active         : {e[6]}")

    print("\n----------------------------------------------------------------------\n")


def cmd_status(args):
    print(f"\n── Status ────────────────────────────────────────────────────────")
    print(f"  signer        : {account.address}")
    print(f"  factory       : {factory_address}")
    print(f"  registry      : {registry_address}")
    print(f"  usdc          : {usdc_address}")
    print(f"  protocol fee  : {PROTOCOL_BP / 100:.2f}%")
    print(f"  usdc balance  : {usdc.functions.balanceOf(account.address).call() / 1e6:.2f} USDC")

    if stake_manager:
        staked, unlock = stake_manager.functions.stakes(account.address).call()
        minimum        = registry.functions.minimumStakeRequired().call()
        print(f"  staked        : {staked / 1e6:.2f} USDC  (minimum: {minimum / 1e6:.2f})")

    if registry:
        count = factory.functions.providerCount().call()
        print(f"  providers     : {count}")

    print("──────────────────────────────────────────────────────────────────\n")


# ── Argparse ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(prog="cli", description="HTTPayer provider CLI")
    sub    = parser.add_subparsers(dest="command", required=True)

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
    vp.add_argument("--vault",          required=True,   help="Vault address")
    vp.add_argument("--open-deposits",  action="store_true", help="Call openDeposits() (owner only)")
    vp.add_argument("--deposit",        type=int, default=0,  help="Deposit USDC raw units into vault")
    vp.add_argument("--redeem",         type=int, default=0,  help="Redeem shares (raw units)")

    # splitter
    sp = sub.add_parser("splitter", help="Show splitter + vault state, optionally distribute")
    sp.add_argument("--splitter",    required=True, help="Splitter address")
    sp.add_argument("--distribute",  action="store_true", help="Call distribute() if balance > 0")

    # registry
    rg = sub.add_parser("registry", help="List all registered providers and their endpoint IDs")
    rg.add_argument("--address", nargs="?", const="self", default="", help="Filter endpoints by registering address (omit for all, --address alone = signer)")

    # status
    sub.add_parser("status", help="Print account and protocol state")

    args = parser.parse_args()

    if args.command == "stake":
        cmd_stake(args)
    elif args.command == "unstake":
        cmd_unstake(args)
    elif args.command == "withdraw":
        cmd_withdraw(args)
    elif args.command == "deploy-provider":
        cmd_deploy_provider(args)
    elif args.command == "update-provider":
        cmd_update_provider(args)
    elif args.command == "register-endpoint":
        cmd_register_endpoint(args)
    elif args.command == "challenge":
        cmd_challenge(args)
    elif args.command == "challenge-status":
        cmd_challenge_status(args)
    elif args.command == "vault":
        cmd_vault(args)
    elif args.command == "splitter":
        cmd_splitter(args)
    elif args.command == "registry":
        cmd_registry(args)
    elif args.command == "status":
        cmd_status(args)


if __name__ == "__main__":
    main()
