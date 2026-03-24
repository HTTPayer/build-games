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

usdc      = s.functions.USDC().call()
protocol  = s.functions.protocolTreasury().call()
prov      = s.functions.providerTreasury().call()
prov_admin = s.functions.providerAdmin().call()
rs        = s.functions.revenueShare().call()
p_dist    = s.functions.pendingDistribution().call()

ZERO = "0x0000000000000000000000000000000000000000"

print(f"\n-- Splitter {addr} --")
print(f"  USDC              : {usdc}")
print(f"  protocolTreasury  : {protocol}")
print(f"  providerTreasury  : {prov or '(none)'}")
print(f"  providerAdmin    : {prov_admin}")
print(f"  revenueShare     : {rs}")
print(f"  pending USDC     : {p_dist / 1e6:.6f} USDC ({p_dist} raw)")

# Check revenue share config
if rs != ZERO:
    rs_abi = get_abi("ProviderRevenueShare")
    r = w3.eth.contract(address=rs, abi=rs_abi)
    total_supply = r.functions.totalSupply().call()
    total_dist = r.functions.totalDistributed().call()
    print(f"\n-- RevenueShare {rs} --")
    print(f"  totalSupply      : {total_supply / 1e6:.6f} shares")
    print(f"  totalDistributed : {total_dist / 1e6:.6f} USDC")
