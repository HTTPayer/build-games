"""
HTTPayer admin CLI.

Commands:
  status               Print all protocol parameters
  set-forwarder        Set CRE forwarder address on ChallengeManager
  set-challenge-fee    Set challenge fee (raw USDC units)
  set-slash-bp         Set challenge slash basis points on ChallengeManager
  set-minimum-stake    Set minimum stake required on APIIntegrityRegistry
  set-stake-manager    Set stake manager address on APIIntegrityRegistry
  set-treasury         Set treasury address on StakeManager
  set-protocol-slash   Set protocol slash basis points on StakeManager
  set-cooldown         Set withdraw cooldown seconds on StakeManager
  mint-usdc            Mint MockUSDC to an address (minter role required)

Usage:
  uv run python admin_cli.py status
  uv run python admin_cli.py set-forwarder --address 0x...
  uv run python admin_cli.py set-challenge-fee --fee 1000000
  uv run python admin_cli.py set-slash-bp --bp 2000
  uv run python admin_cli.py set-minimum-stake --amount 10000000
  uv run python admin_cli.py set-treasury --address 0x...
  uv run python admin_cli.py set-protocol-slash --bp 1000
  uv run python admin_cli.py set-cooldown --seconds 86400
  uv run python admin_cli.py mint-usdc --to 0x... --amount 100000000
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dotenv import load_dotenv

from utils import get_contract_config, get_abi, build_w3, build_account, send_tx, ERC20_ABI

load_dotenv()

# ── Bootstrap ───────────────────────────────────────────────────────────────────

w3      = build_w3()
account = build_account(w3, role="admin")

factory_abi, factory_address           = get_contract_config("APIRegistryFactory")
challenge_manager_abi, challenge_manager_address = get_contract_config("ChallengeManager")

factory          = w3.eth.contract(address=factory_address,          abi=factory_abi)
challenge_manager = w3.eth.contract(address=challenge_manager_address, abi=challenge_manager_abi)

usdc_address = factory.functions.USDC().call()
usdc         = w3.eth.contract(address=usdc_address, abi=ERC20_ABI)

ZERO = "0x0000000000000000000000000000000000000000"

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

# MockUSDC ABI extension for mint
MOCK_USDC_MINT_ABI = [
    {"name": "mint", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "to", "type": "address"}, {"name": "amount", "type": "uint256"}],
     "outputs": []},
    {"name": "MINTER_ROLE", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "bytes32"}]},
    {"name": "hasRole", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "role", "type": "bytes32"}, {"name": "account", "type": "address"}],
     "outputs": [{"type": "bool"}]},
]
mock_usdc = w3.eth.contract(address=usdc_address, abi=ERC20_ABI + MOCK_USDC_MINT_ABI)


# ── Commands ─────────────────────────────────────────────────────────────────────

def cmd_status(args):
    print(f"\n── Admin Status ──────────────────────────────────────────────────")
    print(f"  signer                  : {account.address}")
    print(f"  factory                 : {factory_address}")
    print(f"  registry                : {registry_address}")
    print(f"  challenge manager       : {challenge_manager_address}")
    print(f"  usdc                    : {usdc_address}")

    # ChallengeManager
    print(f"\n  -- ChallengeManager --")
    try:
        forwarder    = challenge_manager.functions.forwarder().call()
        challenge_fee = challenge_manager.functions.challengeFee().call()
        slash_bp      = challenge_manager.functions.slashBp().call()
        ch_count      = challenge_manager.functions.challengeCount().call()
        print(f"  forwarder               : {forwarder}")
        print(f"  challengeFee            : {challenge_fee / 1e6:.2f} USDC")
        print(f"  slashBp                 : {slash_bp / 100:.2f}%")
        print(f"  challengeCount          : {ch_count}")
    except Exception as e:
        print(f"  (error reading ChallengeManager: {e})")

    # APIIntegrityRegistry
    if registry:
        print(f"\n  -- APIIntegrityRegistry --")
        try:
            min_stake   = registry.functions.minimumStakeRequired().call()
            sm_addr     = registry.functions.stakeManager().call()
            prov_count  = registry.functions.providerCount().call()
            print(f"  minimumStakeRequired    : {min_stake / 1e6:.2f} USDC")
            print(f"  stakeManager            : {sm_addr}")
            print(f"  providerCount           : {prov_count}")
        except Exception as e:
            print(f"  (error reading registry: {e})")

    # StakeManager
    if stake_manager:
        print(f"\n  -- StakeManager --")
        try:
            treasury    = stake_manager.functions.treasury().call()
            slash_bp_sm = stake_manager.functions.protocolSlashBp().call()
            cooldown    = stake_manager.functions.withdrawCooldown().call()
            print(f"  treasury                : {treasury}")
            print(f"  protocolSlashBp         : {slash_bp_sm / 100:.2f}%")
            print(f"  withdrawCooldown        : {cooldown}s ({cooldown // 3600}h {(cooldown % 3600) // 60}m)")
        except Exception as e:
            print(f"  (error reading StakeManager: {e})")

    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_forwarder(args):
    addr = w3.to_checksum_address(args.address)
    print(f"\n── set-forwarder ─────────────────────────────────────────────────")
    print(f"  new forwarder : {addr}")
    send_tx(w3, account, challenge_manager.functions.setForwarder(addr), "setForwarder")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_challenge_fee(args):
    print(f"\n── set-challenge-fee ─────────────────────────────────────────────")
    print(f"  new fee : {args.fee / 1e6:.2f} USDC ({args.fee} raw)")
    send_tx(w3, account, challenge_manager.functions.setChallengeFee(args.fee), "setChallengeFee")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_slash_bp(args):
    print(f"\n── set-slash-bp ──────────────────────────────────────────────────")
    print(f"  new slashBp : {args.bp} ({args.bp / 100:.2f}%)")
    send_tx(w3, account, challenge_manager.functions.setSlashBp(args.bp), "setSlashBp")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_minimum_stake(args):
    if registry is None:
        sys.exit("No registry configured")
    print(f"\n── set-minimum-stake ─────────────────────────────────────────────")
    print(f"  new minimum : {args.amount / 1e6:.2f} USDC ({args.amount} raw)")
    send_tx(w3, account, registry.functions.setMinimumStakeRequired(args.amount), "setMinimumStakeRequired")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_stake_manager(args):
    if registry is None:
        sys.exit("No registry configured")
    addr = w3.to_checksum_address(args.address)
    print(f"\n── set-stake-manager ─────────────────────────────────────────────")
    print(f"  new stakeManager : {addr}")
    send_tx(w3, account, registry.functions.setStakeManager(addr), "setStakeManager")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_treasury(args):
    if stake_manager is None:
        sys.exit("No stake manager configured")
    addr = w3.to_checksum_address(args.address)
    print(f"\n── set-treasury ──────────────────────────────────────────────────")
    print(f"  new treasury : {addr}")
    send_tx(w3, account, stake_manager.functions.setTreasury(addr), "setTreasury")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_protocol_slash(args):
    if stake_manager is None:
        sys.exit("No stake manager configured")
    print(f"\n── set-protocol-slash ────────────────────────────────────────────")
    print(f"  new protocolSlashBp : {args.bp} ({args.bp / 100:.2f}%)")
    send_tx(w3, account, stake_manager.functions.setProtocolSlashBp(args.bp), "setProtocolSlashBp")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_set_cooldown(args):
    if stake_manager is None:
        sys.exit("No stake manager configured")
    secs = args.seconds
    print(f"\n── set-cooldown ──────────────────────────────────────────────────")
    print(f"  new cooldown : {secs}s ({secs // 3600}h {(secs % 3600) // 60}m)")
    send_tx(w3, account, stake_manager.functions.setWithdrawCooldown(secs), "setWithdrawCooldown")
    print(f"  ✓ done")
    print("──────────────────────────────────────────────────────────────────\n")


def cmd_mint_usdc(args):
    to = w3.to_checksum_address(args.to)
    print(f"\n── mint-usdc ─────────────────────────────────────────────────────")
    print(f"  to     : {to}")
    print(f"  amount : {args.amount / 1e6:.2f} USDC ({args.amount} raw)")
    bal_before = mock_usdc.functions.balanceOf(to).call()
    send_tx(w3, account, mock_usdc.functions.mint(to, args.amount), "mint")
    bal_after = mock_usdc.functions.balanceOf(to).call()
    print(f"  balance before : {bal_before / 1e6:.2f} USDC")
    print(f"  balance after  : {bal_after  / 1e6:.2f} USDC")
    print("──────────────────────────────────────────────────────────────────\n")


# ── Argparse ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(prog="admin_cli", description="HTTPayer admin CLI")
    sub    = parser.add_subparsers(dest="command", required=True)

    # status
    sub.add_parser("status", help="Print all protocol parameters")

    # set-forwarder
    sf = sub.add_parser("set-forwarder", help="Set CRE forwarder on ChallengeManager")
    sf.add_argument("--address", required=True, help="New forwarder address")

    # set-challenge-fee
    scf = sub.add_parser("set-challenge-fee", help="Set challenge fee (raw USDC units)")
    scf.add_argument("--fee", type=int, required=True, help="Fee in raw USDC units (e.g. 1000000 = 1 USDC)")

    # set-slash-bp
    ssb = sub.add_parser("set-slash-bp", help="Set slash basis points on ChallengeManager")
    ssb.add_argument("--bp", type=int, required=True, help="Basis points (e.g. 2000 = 20%%)")

    # set-minimum-stake
    sms = sub.add_parser("set-minimum-stake", help="Set minimum stake required on registry")
    sms.add_argument("--amount", type=int, required=True, help="Minimum stake in raw USDC units")

    # set-stake-manager
    ssm = sub.add_parser("set-stake-manager", help="Set stake manager address on registry")
    ssm.add_argument("--address", required=True, help="New StakeManager contract address")

    # set-treasury
    st = sub.add_parser("set-treasury", help="Set treasury address on StakeManager")
    st.add_argument("--address", required=True, help="New treasury address")

    # set-protocol-slash
    sps = sub.add_parser("set-protocol-slash", help="Set protocol slash basis points on StakeManager")
    sps.add_argument("--bp", type=int, required=True, help="Basis points (e.g. 1000 = 10%%)")

    # set-cooldown
    sc = sub.add_parser("set-cooldown", help="Set withdraw cooldown on StakeManager")
    sc.add_argument("--seconds", type=int, required=True, help="Cooldown in seconds (e.g. 86400 = 1 day)")

    # mint-usdc
    mu = sub.add_parser("mint-usdc", help="Mint MockUSDC (minter role required)")
    mu.add_argument("--to",     required=True, help="Recipient address")
    mu.add_argument("--amount", type=int, required=True, help="Amount in raw USDC units")

    args = parser.parse_args()

    if args.command == "status":
        cmd_status(args)
    elif args.command == "set-forwarder":
        cmd_set_forwarder(args)
    elif args.command == "set-challenge-fee":
        cmd_set_challenge_fee(args)
    elif args.command == "set-slash-bp":
        cmd_set_slash_bp(args)
    elif args.command == "set-minimum-stake":
        cmd_set_minimum_stake(args)
    elif args.command == "set-stake-manager":
        cmd_set_stake_manager(args)
    elif args.command == "set-treasury":
        cmd_set_treasury(args)
    elif args.command == "set-protocol-slash":
        cmd_set_protocol_slash(args)
    elif args.command == "set-cooldown":
        cmd_set_cooldown(args)
    elif args.command == "mint-usdc":
        cmd_mint_usdc(args)


if __name__ == "__main__":
    main()
