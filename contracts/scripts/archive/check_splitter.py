"""Quick diagnostic: print all config of a deployed splitter."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dotenv import load_dotenv
from utils import build_w3, get_abi

load_dotenv()

addr = sys.argv[1] if len(sys.argv) > 1 else ""
if not addr:
    sys.exit("Usage: uv run python check_splitter.py <splitter_address>")

w3 = build_w3()
abi = get_abi("ProviderRevenueSplitter")
s   = w3.eth.contract(address=w3.to_checksum_address(addr), abi=abi)

usdc     = s.functions.USDC().call()
pt       = s.functions.protocolTreasury().call()
pt_bp    = s.functions.protocolTreasuryBp().call()
prov     = s.functions.providerTreasury().call()
prov_bp  = s.functions.providerTreasuryBp().call()
rs       = s.functions.revenueShare().call()
rs_bp    = s.functions.revenueShareBp().call()
vault    = s.functions.vault().call()
vault_bp = s.functions.vaultBp().call()
pending  = s.functions.pendingDistribution().call()

usdc_contract = w3.eth.contract(address=usdc, abi=[{
    "name": "balanceOf", "type": "function", "stateMutability": "view",
    "inputs": [{"name": "account", "type": "address"}],
    "outputs": [{"name": "", "type": "uint256"}],
}])

print(f"\n-- Splitter {addr} --")
print(f"  USDC              : {usdc}")
print(f"  protocolTreasury  : {pt}  ({pt_bp/100:.2f}%)")
print(f"  providerTreasury  : {prov}  ({prov_bp/100:.2f}%)")
print(f"  revenueShare      : {rs}  ({rs_bp/100:.2f}%)")
print(f"  vault             : {vault}  ({vault_bp/100:.2f}%)")
print(f"  pending USDC      : {pending / 1e6:.6f} USDC ({pending} raw)")

# Check bytecode at vault address
vault_code = w3.eth.get_code(w3.to_checksum_address(vault))
print(f"  vault has code    : {len(vault_code) > 0} ({len(vault_code)} bytes)")
