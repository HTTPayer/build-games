"""
StakeManager — read checks and write tests.

Write function access
────────────────────
  stake(amount)              → any provider (requires prior USDC approve)
  requestUnstake(amount)     → any provider (starts cooldown timer)
  withdraw(amount)           → any provider (only after cooldown has elapsed)
  setTreasury(address)       → DEFAULT_ADMIN_ROLE only
  setProtocolSlashBp(uint256)→ DEFAULT_ADMIN_ROLE only
  setWithdrawCooldown(uint256)→ DEFAULT_ADMIN_ROLE only
  slash(provider, bp, challenger) → SLASHER_ROLE only (granted to ChallengeManager;
                                    not tested here — will revert without that role)

Staking flow
────────────
  1. Approve StakeManager to spend USDC  →  approve_usdc(amount)
  2. Stake                               →  stake(amount)
  3. Request to unstake                  →  request_unstake(amount)
  4. Wait withdrawCooldown seconds
  5. Withdraw                            →  withdraw(amount)
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from utils import get_contract_config, build_w3, build_account, send_tx, ERC20_ABI

# ── Setup ──────────────────────────────────────────────────────────────────────

w3      = build_w3()
account = build_account(w3)

stake_abi, stake_address = get_contract_config("StakeManager")
contract = w3.eth.contract(address=stake_address, abi=stake_abi)

# StakeManager exposes its USDC address as a public immutable getter.
usdc_address = contract.functions.USDC().call()
usdc         = w3.eth.contract(address=usdc_address, abi=ERC20_ABI)

print(f"\nStakeManager : {stake_address}")
print(f"USDC         : {usdc_address}")
print(f"Signer       : {account.address}")

# ── Reads ──────────────────────────────────────────────────────────────────────

def print_state():
    slasher_role   = contract.functions.SLASHER_ROLE().call()
    cooldown       = contract.functions.withdrawCooldown().call()
    slash_bp       = contract.functions.protocolSlashBp().call()
    treasury       = contract.functions.treasury().call()
    stake_info     = contract.functions.stakes(account.address).call()
    # stake_info: (amount, unlockTimestamp)
    usdc_balance   = usdc.functions.balanceOf(account.address).call()
    usdc_allowance = usdc.functions.allowance(account.address, stake_address).call()

    print("\n── StakeManager state ────────────────────────────────────────────")
    print(f"  treasury            : {treasury}")
    print(f"  withdrawCooldown    : {cooldown}s  ({cooldown / 86400:.1f} days)")
    print(f"  protocolSlashBp     : {slash_bp}  ({slash_bp / 100:.1f}%)")
    print(f"  SLASHER_ROLE        : 0x{slasher_role.hex()}")
    print(f"  ── signer ──────────────────────────────────────────────────────")
    print(f"  stake.amount        : {stake_info[0] / 1e6:.6f} USDC")
    print(f"  stake.unlockAt      : {stake_info[1]}  (0 = not requested)")
    print(f"  USDC balance        : {usdc_balance / 1e6:.6f} USDC")
    print(f"  USDC allowance      : {usdc_allowance / 1e6:.6f} USDC  (to StakeManager)")
    print("──────────────────────────────────────────────────────────────────\n")


def get_stake(provider_address: str):
    """Print the stake info for any provider address."""
    info = contract.functions.stakes(provider_address).call()
    print(f"\n── Stake for {provider_address} ──")
    print(f"  amount      : {info[0] / 1e6:.6f} USDC")
    print(f"  unlockAt    : {info[1]}  (0 = not requested)")
    print("──────────────────────────────────────────────────────────────────\n")
    return info

# ── Writes ─────────────────────────────────────────────────────────────────────

def approve_usdc(amount_usdc_units: int):
    """
    Approve StakeManager to pull USDC from your wallet.
    Must be called before stake() if your current allowance is insufficient.
    """
    print(f"\n→ USDC.approve(StakeManager, {amount_usdc_units})  [{amount_usdc_units / 1e6:.6f} USDC]")
    return send_tx(
        w3, account,
        usdc.functions.approve(stake_address, amount_usdc_units),
        "approve",
    )


def stake(amount_usdc_units: int):
    """
    Stake USDC as a provider bond.
    Ensure approve_usdc(amount) has been called first.
    """
    print(f"\n→ stake({amount_usdc_units})  [{amount_usdc_units / 1e6:.6f} USDC]")
    return send_tx(
        w3, account,
        contract.functions.stake(amount_usdc_units),
        "stake",
    )


def request_unstake(amount_usdc_units: int):
    """
    Start the unstake cooldown for a given amount.
    After withdrawCooldown seconds you can call withdraw().
    """
    print(f"\n→ requestUnstake({amount_usdc_units})  [{amount_usdc_units / 1e6:.6f} USDC]")
    return send_tx(
        w3, account,
        contract.functions.requestUnstake(amount_usdc_units),
        "requestUnstake",
    )


def withdraw(amount_usdc_units: int):
    """
    Withdraw staked USDC after the cooldown has elapsed.
    Will revert if cooldown has not passed, or if remaining stake would fall below minimum.
    """
    print(f"\n→ withdraw({amount_usdc_units})  [{amount_usdc_units / 1e6:.6f} USDC]")
    return send_tx(
        w3, account,
        contract.functions.withdraw(amount_usdc_units),
        "withdraw",
    )


def set_treasury(new_treasury: str):
    """Update the protocol treasury address. Requires DEFAULT_ADMIN_ROLE."""
    print(f"\n→ setTreasury({new_treasury})")
    return send_tx(
        w3, account,
        contract.functions.setTreasury(new_treasury),
        "setTreasury",
    )


def set_protocol_slash_bp(bp: int):
    """
    Update the protocol's cut of each slash. Requires DEFAULT_ADMIN_ROLE.
    bp — basis points (10000 = 100%). E.g. 1000 = 10%.
    """
    print(f"\n→ setProtocolSlashBp({bp})  [{bp / 100:.2f}%]")
    return send_tx(
        w3, account,
        contract.functions.setProtocolSlashBp(bp),
        "setProtocolSlashBp",
    )


def set_withdraw_cooldown(seconds: int):
    """Update the unstake cooldown period. Requires DEFAULT_ADMIN_ROLE."""
    print(f"\n→ setWithdrawCooldown({seconds})  [{seconds / 86400:.2f} days]")
    return send_tx(
        w3, account,
        contract.functions.setWithdrawCooldown(seconds),
        "setWithdrawCooldown",
    )


# slash(provider, slashBp, challenger) — requires SLASHER_ROLE, granted only to ChallengeManager.
# Calling this directly will revert without that role.

# ── Main ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print_state()

    # ── Example write calls (uncomment to execute) ──────────────────────────

    # Full staking flow:
    # STAKE_AMOUNT = 1_000_000_000  # 1000 USDC
    #
    # Step 1 — approve (only needed if allowance < amount):
    # approve_usdc(STAKE_AMOUNT)
    #
    # Step 2 — stake:
    # stake(STAKE_AMOUNT)
    #
    # Step 3 — request unstake (starts cooldown):
    # request_unstake(STAKE_AMOUNT)
    #
    # Step 4 — withdraw (run after withdrawCooldown seconds have elapsed):
    # withdraw(STAKE_AMOUNT)

    # Admin: update treasury address:
    # set_treasury("0xYourNewTreasuryAddress")

    # Admin: change the protocol slash cut to 5%:
    # set_protocol_slash_bp(500)

    # Admin: shorten cooldown to 1 day (useful for testnet):
    # set_withdraw_cooldown(86400)

    print_state()
