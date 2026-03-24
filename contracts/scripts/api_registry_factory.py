"""
APIRegistryFactory — read checks and write tests.

Write function access
────────────────────
  deployProvider(...)  → any address (the caller becomes the RS owner and provider)

The factory has no admin functions — all protocol config (treasury address, bp cut)
is set once at constructor time and is immutable.

Deploy flow (what deployProvider does internally)
────────────────────────────────────────────────
  1. Deploy ProviderRevenueShare   (factory is temporary owner)
  2. genesisMint(recipient, shares)
  3. Transfer RS ownership → msg.sender (the provider)
  4. Deploy ProviderRevenueSplitter with immutable split config
  5. Emit ProviderDeployed(deployer, revenueShare, splitter, ...)

After deployment
───────────────
  - Set payTo = splitter address in your x402 server
  - Call registerProvider() + registerEndpoint() in APIIntegrityRegistry
  - x402 payments flow into splitter → distribute() routes to treasury / RS

Revenue split
────────────
  protocolTreasuryBp (≤3%) + providerTreasuryBp + revenueShareBp = 100%
  The remainder (after protocol + provider cuts) goes to RS holders.
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from web3.logs import DISCARD
from eth_abi import encode as abi_encode
from utils import get_contract_config, get_abi, build_w3, build_account, send_tx, ERC20_ABI
from verify import verify_contract
from x402_metadata import fetch_payment_metadata

# ── Setup ──────────────────────────────────────────────────────────────────────

w3      = build_w3()
account = build_account(w3, role="provider")

factory_abi, factory_address = get_contract_config("APIRegistryFactory")
factory = w3.eth.contract(address=factory_address, abi=factory_abi)

usdc_address   = factory.functions.USDC().call()
usdc           = w3.eth.contract(address=usdc_address, abi=ERC20_ABI)

PROTOCOL_BP    = factory.functions.protocolTreasuryBp().call()
MAX_PROVIDER_BP = 10_000 - PROTOCOL_BP   # basis points available to the provider

revenue_share_abi = get_abi("ProviderRevenueShare")
splitter_abi      = get_abi("ProviderRevenueSplitter")
stake_manager_abi = get_abi("StakeManager")

print(f"\nAPIRegistryFactory : {factory_address}")
print(f"USDC               : {usdc_address}")
print(f"Signer             : {account.address}")
print(f"Protocol fee       : {PROTOCOL_BP / 100:.2f}%  ({PROTOCOL_BP} bp)")
print(f"Available to provider: {MAX_PROVIDER_BP / 100:.2f}%  ({MAX_PROVIDER_BP} bp)")

# ── Reads ──────────────────────────────────────────────────────────────────────

def print_factory_state():
    max_bp            = factory.functions.MAX_PROTOCOL_BP().call()
    protocol_treasury = factory.functions.protocolTreasury().call()
    protocol_bp       = factory.functions.protocolTreasuryBp().call()
    registry_addr     = factory.functions.registry().call()
    provider_count    = factory.functions.providerCount().call()
    usdc_balance     = usdc.functions.balanceOf(account.address).call()

    print("\n── APIRegistryFactory state ──────────────────────────────────────")
    print(f"  protocolTreasury    : {protocol_treasury}")
    print(f"  protocolTreasuryBp  : {protocol_bp}  ({protocol_bp / 100:.2f}%)")
    print(f"  MAX_PROTOCOL_BP     : {max_bp}  ({max_bp / 100:.2f}%)")
    print(f"  registry            : {registry_addr}")
    print(f"  providerCount       : {provider_count}")
    print(f"  signer USDC balance : {usdc_balance / 1e6:.6f} USDC")
    print("──────────────────────────────────────────────────────────────────\n")


def print_revenue_share_state(rs_address: str):
    rs = w3.eth.contract(
        address=w3.to_checksum_address(rs_address),
        abi=revenue_share_abi,
    )
    total_supply    = rs.functions.totalSupply().call()
    total_dist     = rs.functions.totalDistributed().call()
    total_claimed  = rs.functions.totalClaimed().call()
    genesis_done   = rs.functions.genesisComplete().call()
    owner          = rs.functions.owner().call()
    signer_balance = rs.functions.balanceOf(account.address).call()
    name           = rs.functions.name().call()
    symbol         = rs.functions.symbol().call()
    claimable      = rs.functions.claimable(account.address).call()

    print(f"\n── RevenueShare {rs_address} ──────────────────────")
    print(f"  name            : {name} ({symbol})")
    print(f"  owner           : {owner}")
    print(f"  genesisComplete : {genesis_done}")
    print(f"  totalSupply     : {total_supply / 1e6:.6f} shares")
    print(f"  totalDistributed: {total_dist / 1e6:.6f} USDC")
    print(f"  totalClaimed    : {total_claimed / 1e6:.6f} USDC")
    print(f"  signer balance  : {signer_balance / 1e6:.6f} shares")
    print(f"  claimable now   : {claimable / 1e6:.6f} USDC")
    print("──────────────────────────────────────────────────────────────────\n")
    return rs


def print_splitter_state(splitter_address: str):
    splitter = w3.eth.contract(
        address=w3.to_checksum_address(splitter_address),
        abi=splitter_abi,
    )
    protocol_treasury = splitter.functions.protocolTreasury().call()
    protocol_bp       = splitter.functions.protocolTreasuryBp().call()
    provider_treasury = splitter.functions.providerTreasury().call()
    provider_bp       = splitter.functions.providerTreasuryBp().call()
    rs_address        = splitter.functions.revenueShare().call()
    rs_bp             = splitter.functions.revenueShareBp().call()
    pending           = splitter.functions.pendingDistribution().call()

    ZERO = "0x0000000000000000000000000000000000000000"
    print(f"\n── Splitter {splitter_address} ────────────────")
    print(f"  protocolTreasury  : {protocol_treasury}  ({protocol_bp / 100:.2f}%)")
    print(f"  providerTreasury  : {provider_treasury or '(none)'}  ({provider_bp / 100:.2f}%)")
    print(f"  revenueShare      : {rs_address}  ({rs_bp / 100:.2f}%)")
    print(f"  pendingDistribution: {pending / 1e6:.6f} USDC")
    print("──────────────────────────────────────────────────────────────────\n")
    return splitter

# ── Reads (registry) ───────────────────────────────────────────────────────────

registry_abi     = get_abi("APIIntegrityRegistry")
registry_address = factory.functions.registry().call()
ZERO             = "0x0000000000000000000000000000000000000000"

if registry_address != ZERO:
    registry = w3.eth.contract(
        address=w3.to_checksum_address(registry_address),
        abi=registry_abi,
    )
else:
    registry = None

stake_manager_address = registry.functions.stakeManager().call() if registry else None
stake_manager = (
    w3.eth.contract(address=w3.to_checksum_address(stake_manager_address), abi=stake_manager_abi)
    if stake_manager_address and stake_manager_address != ZERO
    else None
)

print(f"APIIntegrityRegistry : {registry_address or '(not set)'}")

def print_registry_provider(provider_id: int):
    """Print state of a registered provider by its registry ID (1-based)."""
    if registry is None:
        print("  (no registry configured)")
        return
    p = registry.functions.providers(provider_id).call()
    print(f"\n── Registry Provider #{provider_id} ─────────────────────────────────")
    print(f"  owner          : {p[0]}")
    print(f"  metadataURI    : {p[1]}")
    print(f"  payoutAddress  : {p[2]}")
    print(f"  revenueSplitter: {p[3]}")
    print(f"  active         : {p[4]}")
    print("──────────────────────────────────────────────────────────────────\n")


def print_registry_endpoint(endpoint_id: str):
    """Print state of a registered endpoint by its bytes32 endpointId (hex string)."""
    if registry is None:
        print("  (no registry configured)")
        return
    eid = bytes.fromhex(endpoint_id.removeprefix("0x"))
    e = registry.functions.endpoints(eid).call()
    print(f"\n── Endpoint {endpoint_id} ──────────")
    print(f"  provider       : {e[1]}")
    print(f"  path           : {e[2]}")
    print(f"  method         : {e[3]}")
    print(f"  integrityHash  : 0x{e[4].hex()}")
    print(f"  version        : {e[5]}")
    print(f"  active         : {e[6]}")
    print(f"  registeredAt   : {e[7]}")
    print(f"  lastCheckedAt  : {e[8]}")
    print("──────────────────────────────────────────────────────────────────\n")

# ── Writes ─────────────────────────────────────────────────────────────────────


def ensure_staked():
    """
    Check that account has at least the minimum stake in StakeManager.
    If not, approve and stake the shortfall automatically.
    Skips silently if no StakeManager is configured.
    """
    if stake_manager is None:
        return

    minimum     = registry.functions.minimumStakeRequired().call()
    staked, _   = stake_manager.functions.stakes(account.address).call()
    usdc_bal    = usdc.functions.balanceOf(account.address).call()
    shortfall   = max(0, minimum - staked)

    print(f"\n── Stake preflight ───────────────────────────────────────────────")
    print(f"  minimum stake : {minimum / 1e6:.2f} USDC")
    print(f"  current stake : {staked  / 1e6:.2f} USDC")
    print(f"  usdc balance  : {usdc_bal / 1e6:.2f} USDC")

    if shortfall == 0:
        print(f"  ✓ stake sufficient")
        print(f"──────────────────────────────────────────────────────────────────\n")
        return

    print(f"  shortfall     : {shortfall / 1e6:.2f} USDC — staking now…")
    assert usdc_bal >= shortfall, (
        f"Insufficient USDC: need {shortfall / 1e6:.2f}, have {usdc_bal / 1e6:.2f}"
    )

    stake_manager_address_cs = w3.to_checksum_address(stake_manager_address)
    send_tx(w3, account, usdc.functions.approve(stake_manager_address_cs, shortfall), "approve stake")
    send_tx(w3, account, stake_manager.functions.stake(shortfall), "stake")
    print(f"  ✓ staked {shortfall / 1e6:.2f} USDC")
    print(f"──────────────────────────────────────────────────────────────────\n")


def deploy_provider(
    rs_name: str,
    rs_symbol: str,
    revenue_share_shares: int,
    revenue_share_recipient: str = "",
    provider_treasury: str = "",
    provider_treasury_bp: int = 0,
    metadata_uri: str = "",
) -> tuple[str, str, int]:
    """
    Deploy a ProviderRevenueShare token + ProviderRevenueSplitter.

    Revenue split (must sum to 100%):
        protocolTreasuryBp (≤3%) + providerTreasuryBp + revenueShareBp = 100%
        revenueShareBp is auto-computed as the remainder.

    rs_name               — ERC20 name for the RS token (e.g. "Weather API Revenue Share").
    rs_symbol             — ERC20 symbol for the RS token (e.g. "WRS").
    revenue_share_shares  — Genesis shares to mint. Minimum 1_000_000 (1 full share).
                             This is the permanent total supply — never increases.
    revenue_share_recipient — Who receives genesis RS shares. Defaults to signer.
    provider_treasury     — Address for the provider's direct cut. Required when providerTreasuryBp > 0.
    provider_treasury_bp — Basis points routed to provider treasury directly.
                             Set 0 to route everything (minus protocol) to RS holders.
    metadata_uri           — IPFS URI for provider metadata. When set, registers in APIIntegrityRegistry.

    Returns (revenue_share_address, splitter_address, registry_provider_id).
    """
    ZERO = "0x0000000000000000000000000000000000000000"

    # Ensure sufficient stake before attempting registry registration
    if registry is not None:
        ensure_staked()

    print(f"\n→ deployProvider({rs_name!r}, {rs_symbol!r})")
    print(f"  protocolBp={PROTOCOL_BP / 100:.2f}%  providerTreasuryBp={provider_treasury_bp / 100:.2f}%")
    print(f"  → revenueShareBp auto-computed as remainder")
    if metadata_uri:
        print(f"  metadataURI={metadata_uri!r} → will register in APIIntegrityRegistry")

    treasury_addr = provider_treasury if provider_treasury_bp > 0 else ZERO
    revenue_share_bp = MAX_PROVIDER_BP - provider_treasury_bp

    receipt = send_tx(
        w3, account,
        factory.functions.deployProvider(
            rs_name,
            rs_symbol,
            revenue_share_shares,
            revenue_share_recipient or account.address,
            treasury_addr,
            provider_treasury_bp,
            metadata_uri,
        ),
        "deployProvider",
    )

    # Parse ProviderDeployed event from factory
    event = factory.events.ProviderDeployed().process_receipt(receipt, errors=DISCARD)[0]
    revenue_share_addr = event["args"]["revenueShare"]
    splitter_addr      = event["args"]["splitter"]

    # Parse ProviderRegistered event from registry (emitted in same tx when metadataURI set)
    registry_provider_id = 0
    if registry is not None and metadata_uri:
        reg_events = registry.events.ProviderRegistered().process_receipt(receipt, errors=DISCARD)
        if reg_events:
            registry_provider_id = reg_events[0]["args"]["id"]

    print(f"\n  ✓ revenueShare : {revenue_share_addr}")
    print(f"  ✓ splitter     : {splitter_addr}")
    if registry_provider_id:
        print(f"  ✓ registry id  : {registry_provider_id}  ← use for registerEndpoint()")
    print(f"\n  → set payTo = {splitter_addr} in your x402 server")
    if registry_provider_id:
        print(f"  → call register_endpoint({registry_provider_id}, url, method, integrity_hash)")

    # ── Auto-verify deployed contracts on Snowtrace ──────────────────────────
    print()
    protocol_treasury = factory.functions.protocolTreasury().call()

    # Verify RS
    ctor = abi_encode(
        ["address", "string", "string", "address"],
        [usdc_address, rs_name, rs_symbol, account.address],
    ).hex()
    verify_contract("ProviderRevenueShare", revenue_share_addr, ctor)

    # Verify Splitter
    splitter_ctor = abi_encode(
        ["address", "address", "uint256", "address", "address", "uint256", "address", "uint256"],
        [
            usdc_address,
            protocol_treasury,   # protocolAdmin
            PROTOCOL_BP,
            account.address,     # providerAdmin
            treasury_addr,       # providerTreasury
            provider_treasury_bp,
            revenue_share_addr,  # revenueShare
            revenue_share_bp,
        ],
    ).hex()
    verify_contract("ProviderRevenueSplitter", splitter_addr, splitter_ctor)

    return revenue_share_addr, splitter_addr, registry_provider_id


def simulate_revenue(splitter_address: str, amount_usdc_units: int):
    """
    Simulate an x402 payment: transfer USDC to the splitter then distribute.

    In production this happens automatically — the x402 facilitator sends USDC
    to the splitter (payTo), and anyone can call distribute() to route it.
    """
    splitter = w3.eth.contract(
        address=w3.to_checksum_address(splitter_address),
        abi=splitter_abi,
    )

    print(f"\n→ simulate revenue: {amount_usdc_units / 1e6:.6f} USDC → splitter")
    send_tx(
        w3, account,
        usdc.functions.transfer(splitter_address, amount_usdc_units),
        "transfer to splitter",
    )

    print(f"→ distribute()")
    send_tx(w3, account, splitter.functions.distribute(), "distribute")


def claim_revenue(revenue_share_address: str):
    """
    Claim accumulated dividends from the revenue share contract.
    """
    rs = w3.eth.contract(
        address=w3.to_checksum_address(revenue_share_address),
        abi=revenue_share_abi,
    )
    claimable = rs.functions.claimable(account.address).call()
    if claimable == 0:
        print(f"\n  nothing to claim")
        return
    print(f"\n→ claim({claimable / 1e6:.6f} USDC)")
    send_tx(w3, account, rs.functions.claim(account.address), "claim")


def register_endpoint(
    provider_id: int,
    path: str,
    method: str,
    pay_to: str = "",
    asset: str = "",
    network: str = "",
    url: str = "",
    amount: int = 0,
) -> str:
    """
    Register an API endpoint in the APIIntegrityRegistry.

    Must be called by the provider (registry owner of provider_id).
    provider_id  — the registry ID returned by deploy_provider() (1-based).
    path        — full API URL, e.g. "https://api.example.com/v1/price"
    method      — HTTP method, e.g. "GET" or "POST"
    pay_to      — optional. Pass address(0) or omit to use provider's revenueSplitter.
    asset       — payment asset address (e.g. USDC)
    network     — CAIP network ID (e.g. "eip155:43113")
    url         — the URL being registered (should match path or resource.url)
    amount      — payment amount in smallest units

    Returns the endpointId (hex string) emitted by EndpointRegistered.
    """
    from x402_metadata import fetch_payment_metadata

    if registry is None:
        raise RuntimeError("No registry configured on this factory")

    # If metadata not provided, fetch from endpoint
    needs_fetch = not all([asset, network, url, amount]) or pay_to == ""
    if needs_fetch:
        print(f"  fetching payment metadata from {path} …")
        metadata = fetch_payment_metadata(path)
        pay_to = pay_to or metadata.get("payTo", "")
        asset = asset or metadata.get("asset", "")
        network = network or metadata.get("network", "")
        url = url or metadata.get("url", "")
        amount = amount or int(metadata.get("amount", 0))

    # Convert to checksum addresses (use address(0) if not provided to use revenueSplitter)
    pay_to_addr = w3.to_checksum_address(pay_to) if pay_to else "0x" + "00" * 20
    asset_addr = w3.to_checksum_address(asset) if asset else "0x" + "00" * 20

    print(f"\n→ registerEndpoint(providerId={provider_id}, {method} {path})")
    print(f"  payTo={pay_to_addr} asset={asset_addr} network={network} amount={amount}")
    receipt = send_tx(
        w3, account,
        registry.functions.registerEndpoint(
            provider_id, path, method, pay_to_addr, asset_addr, network, url, amount
        ),
        "registerEndpoint",
    )

    event       = registry.events.EndpointRegistered().process_receipt(receipt, errors=DISCARD)[0]
    endpoint_id = "0x" + event["args"]["endpointId"].hex()
    print(f"  ✓ endpointId : {endpoint_id}")
    return endpoint_id


def update_provider(
    provider_id: int,
    metadata_uri: str,
    payout_address: str,
    revenue_splitter: str,
):
    """
    Update provider metadata or addresses in the registry.
    Only callable by the registered owner of provider_id.
    """
    if registry is None:
        raise RuntimeError("No registry configured on this factory")
    print(f"\n→ updateProvider(id={provider_id})")
    return send_tx(
        w3, account,
        registry.functions.updateProvider(
            provider_id, metadata_uri, payout_address, revenue_splitter
        ),
        "updateProvider",
    )

# ── Main ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print_factory_state()

    # ── Read previously deployed contracts (set these in .env or paste directly)
    revenue_share_address = os.getenv("REVENUE_SHARE_ADDRESS", "")
    splitter_address      = os.getenv("SPLITTER_ADDRESS", "")

    if revenue_share_address:
        print_revenue_share_state(revenue_share_address)
    if splitter_address:
        print_splitter_state(splitter_address)

    # ── Example write calls (uncomment to execute) ──────────────────────────
    #
    # Revenue split examples (assuming protocolTreasuryBp = 200 bp = 2%):
    #
    #   providerTreasuryBp=0    → RS gets 98%, you get 0% direct
    #   providerTreasuryBp=1000 → RS gets 88%, you get 10% direct
    #   providerTreasuryBp=5000 → RS gets 48%, you get 50% direct

    # ── Deploy RS only ──────────────────────────────────────────────────────
    rs_addr, spl_addr, reg_id = deploy_provider(
        rs_name               = "Weather API RS",
        rs_symbol             = "WRS",
        revenue_share_shares  = 1_000_000_000_000,  # 1M founder shares (6 dec)
        revenue_share_recipient = account.address,
        provider_treasury     = account.address,
        provider_treasury_bp  = 0,  # 0% direct, 98% to RS holders
        metadata_uri          = " ",
    )
    print(f"reg_id: {reg_id}")
    print_splitter_state(spl_addr)

    # ── Register API endpoints after deploying ───────────────────────────────
    url_path = os.getenv("X402_ENDPOINT")
    print(f'url_path: {url_path}')
    breakpoint()
    endpoint_id = register_endpoint(
        provider_id = reg_id,
        path        = url_path,
        method      = "GET",
    )
    # print_registry_endpoint(endpoint_id)

    # ── Simulate revenue ─────────────────────────────────────────────────────
    # simulate_revenue(spl_addr, 10_000_000)   # 10 USDC → routes per split
    # print_revenue_share_state(rs_addr)

    # ── Claim dividends ──────────────────────────────────────────────────────
    # claim_revenue(rs_addr)
