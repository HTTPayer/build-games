"""
Inspect a deployed ProviderRevenueVault.

Usage:
    uv run python check_vault.py <vault_address>
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dotenv import load_dotenv
from utils import build_w3, get_abi, ERC20_ABI

load_dotenv()

addr = sys.argv[1] if len(sys.argv) > 1 else ""
if not addr:
    sys.exit("Usage: uv run python check_vault.py <vault_address>")

w3    = build_w3()
abi   = get_abi("ProviderRevenueVault")
vault = w3.eth.contract(address=w3.to_checksum_address(addr), abi=abi)

signer = w3.eth.accounts[0] if w3.eth.accounts else None

name     = vault.functions.name().call()
symbol   = vault.functions.symbol().call()
owner    = vault.functions.owner().call()
genesis  = vault.functions.genesisComplete().call()
deps_en  = vault.functions.depositsEnabled().call()
supply   = vault.functions.totalSupply().call()
assets   = vault.functions.totalAssets().call()
price    = (assets * 10**18 // supply) if supply else 0

usdc_addr = vault.functions.asset().call()
usdc      = w3.eth.contract(address=usdc_addr, abi=ERC20_ABI)

from dotenv import dotenv_values
env = dotenv_values()
pk  = env.get("PROVIDER_PRIVATE_KEY") or env.get("PRIVATE_KEY", "")
if pk:
    from eth_account import Account
    signer = Account.from_key(pk).address

signer_shares   = vault.functions.balanceOf(signer).call() if signer else 0
signer_redeemable = vault.functions.convertToAssets(signer_shares).call() if signer_shares else 0

dead_shares = vault.functions.balanceOf("0x000000000000000000000000000000000000dEaD").call()

print(f"\n-- Vault {addr} --")
print(f"  name              : {name} ({symbol})")
print(f"  owner             : {owner}")
print(f"  genesisComplete   : {genesis}")
print(f"  depositsEnabled   : {deps_en}")
print(f"  totalSupply       : {supply / 1e6:.6f} shares")
print(f"    of which dead   : {dead_shares / 1e6:.6f} shares (locked at 0xdead)")
print(f"  totalAssets       : {assets / 1e6:.6f} USDC")
print(f"  sharePrice        : {price / 1e18:.8f} USDC/share")
if signer:
    print(f"\n  signer            : {signer}")
    print(f"  signer shares     : {signer_shares / 1e6:.6f}")
    print(f"  signer redeemable : {signer_redeemable / 1e6:.6f} USDC")
print()
