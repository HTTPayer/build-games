"""
APIRegistryFactory — read checks and write tests.

Write function access
────────────────────
  deployProvider(...)  → any address (the caller becomes the vault owner and provider)

The factory has no admin functions — all protocol config (treasury address, bp cut)
is set once at constructor time and is immutable.

Deploy flow (what deployProvider does internally)
─────────────────────────────────────────────────
  1. Deploy ProviderRevenueVault   (factory is temporary owner)
  2. genesisMint(genesisRecipient, genesisShares)
  3. Transfer vault ownership → msg.sender (the provider)
  4. Deploy ProviderRevenueSplitter with immutable split config
  5. Emit ProviderDeployed(deployer, vault, splitter, ...)

After deployment
────────────────
  - Set payTo = splitter address in your x402 server
  - Call registerProvider() + registerEndpoint() in APIIntegrityRegistry
  - x402 payments flow into splitter → distribute() routes to treasury / vault

Revenue simulation
──────────────────
  Transfer USDC to splitter  →  simulate an x402 payment landing
  Call splitter.distribute() →  routes to protocol treasury, provider treasury, vault
  Read vault.sharePrice()    →  share price rises with each distribution
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from web3.logs import DISCARD
from eth_abi import encode as abi_encode
from utils import get_contract_config, get_abi, build_w3, build_account, send_tx, ERC20_ABI
from verify import verify_contract
from x402_metadata import fetch_integrity_hash

# ── Setup ──────────────────────────────────────────────────────────────────────

w3      = build_w3()
account = build_account(w3, role="provider")

factory_abi, factory_address = get_contract_config("APIRegistryFactory")
factory = w3.eth.contract(address=factory_address, abi=factory_abi)

usdc_address   = factory.functions.USDC().call()
usdc           = w3.eth.contract(address=usdc_address, abi=ERC20_ABI)

PROTOCOL_BP    = factory.functions.protocolTreasuryBp().call()
MAX_PROVIDER_BP = 10_000 - PROTOCOL_BP   # basis points available to the provider

vault_abi         = get_abi("ProviderRevenueVault")
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
    usdc_balance      = usdc.functions.balanceOf(account.address).call()

    print("\n── APIRegistryFactory state ──────────────────────────────────────")
    print(f"  protocolTreasury    : {protocol_treasury}")
    print(f"  protocolTreasuryBp  : {protocol_bp}  ({protocol_bp / 100:.2f}%)")
    print(f"  MAX_PROTOCOL_BP     : {max_bp}  ({max_bp / 100:.2f}%)")
    print(f"  registry            : {registry_addr}")
    print(f"  providerCount       : {provider_count}")
    print(f"  signer USDC balance : {usdc_balance / 1e6:.6f} USDC")
    print("──────────────────────────────────────────────────────────────────\n")


def print_vault_state(vault_address: str):
    vault = w3.eth.contract(
        address=w3.to_checksum_address(vault_address),
        abi=vault_abi,
    )
    total_assets    = vault.functions.totalAssets().call()
    total_supply    = vault.functions.totalSupply().call()
    share_price     = vault.functions.sharePrice().call()
    genesis_done    = vault.functions.genesisComplete().call()
    owner           = vault.functions.owner().call()
    signer_shares   = vault.functions.balanceOf(account.address).call()
    name            = vault.functions.name().call()
    symbol          = vault.functions.symbol().call()

    print(f"\n── Vault {vault_address} ──────────────────────")
    print(f"  name          : {name} ({symbol})")
    print(f"  owner         : {owner}")
    print(f"  genesisComplete: {genesis_done}")
    print(f"  totalSupply   : {total_supply / 1e6:.6f} shares")
    print(f"  totalAssets   : {total_assets / 1e6:.6f} USDC")
    print(f"  sharePrice    : {share_price / 1e18:.8f} USDC/share")
    print(f"  signer shares : {signer_shares / 1e6:.6f}")
    print("──────────────────────────────────────────────────────────────────\n")
    return vault


def print_splitter_state(splitter_address: str):
    splitter = w3.eth.contract(
        address=w3.to_checksum_address(splitter_address),
        abi=splitter_abi,
    )
    cfg     = splitter.functions.splitConfig().call()
    pending = splitter.functions.pendingDistribution().call()
    # splitConfig returns:
    # (protocolTreasury, protocolBp, providerTreasury, providerBp,
    #  revenueShare, revenueShareBp, vault, vaultBp)

    ZERO = "0x0000000000000000000000000000000000000000"
    print(f"\n── Splitter {splitter_address} ────────────────")
    print(f"  protocolTreasury  : {cfg[0]}  ({cfg[1] / 100:.2f}%)")
    print(f"  providerTreasury  : {cfg[2] or '(none)'}  ({cfg[3] / 100:.2f}%)")
    print(f"  revenueShare      : {cfg[4] if cfg[4] != ZERO else '(none)'}  ({cfg[5] / 100:.2f}%)")
    print(f"  vault             : {cfg[6]}  ({cfg[7] / 100:.2f}%)")
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
    # returns (owner, metadataURI, payoutAddress, revenueSplitter, active, createdAt)
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
    # returns (endpointId, provider, path, method, integrityHash, version, active, registeredAt, lastCheckedAt)
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

revenue_share_abi = get_abi("ProviderRevenueShare")


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
    vault_name: str,
    vault_symbol: str,
    vault_bp: int = 0,
    vault_genesis_shares: int = 0,
    vault_genesis_recipient: str = "",
    genesis_deposit: int = 0,
    provider_treasury: str = "",
    revenue_share_bp: int = 0,
    revenue_share_shares: int = 0,
    revenue_share_recipient: str = "",
    metadata_uri: str = "",
) -> tuple[str, str, str, int]:
    """
    Deploy a vault + optional revenue share + splitter. Caller becomes vault owner.

    Revenue split — set the two explicit allocations; the remainder goes directly
    to provider_treasury:

        vault_bp           →  ProviderRevenueVault  (set 0 to skip)
        revenue_share_bp   →  ProviderRevenueShare  (set 0 to skip)
        protocol_bp        →  protocol treasury     (fixed at factory deploy)
        remainder          →  provider_treasury     (auto-computed)

    At least one of vault_bp or revenue_share_bp must be > 0.

    vault_genesis_shares    — raw share units (6 dec). e.g. 1_000_000_000_000 = 1M shares.
                              Set 0 to skip genesis mint (first investor deposits at 1:1).
    vault_genesis_recipient — who receives vault genesis shares. Defaults to signer.
    genesis_deposit         — USDC raw units to seed vault so share price > 0.
                              Requires vault_genesis_shares > 0.
    provider_treasury       — address for the remainder direct USDC cut.
                              Required when remainder bp > 0.
    revenue_share_shares    — genesis shares for the revenue share contract.
                              Required when revenue_share_bp > 0.
    revenue_share_recipient — who receives revenue share genesis shares. Defaults to signer.
    metadata_uri            — IPFS URI or URL for provider metadata. When non-empty and the
                              factory has a registry configured, registers the provider in
                              APIIntegrityRegistry in the same transaction.

    Returns (vault_address, revenue_share_address, splitter_address, registry_provider_id).
    vault_address / revenue_share_address are zero address when not deployed.
    registry_provider_id is 0 when metadata_uri is empty or registry not configured.
    """
    remainder = MAX_PROVIDER_BP - vault_bp - revenue_share_bp

    ZERO = "0x0000000000000000000000000000000000000000"

    # Ensure sufficient stake before attempting registry registration
    if registry is not None:
        ensure_staked()

    print(f"\n→ deployProvider({vault_name!r}, {vault_symbol!r})")
    print(f"  vaultBp={vault_bp / 100:.2f}%  revenueShareBp={revenue_share_bp / 100:.2f}%  "
          f"protocolBp={PROTOCOL_BP / 100:.2f}%  providerTreasury(remainder)={remainder / 100:.2f}%")
    if metadata_uri:
        print(f"  metadataURI={metadata_uri!r} → will register in APIIntegrityRegistry")

    if genesis_deposit > 0:
        print(f"  approving factory for genesis deposit ({genesis_deposit / 1e6:.2f} USDC)…")
        send_tx(w3, account, usdc.functions.approve(factory_address, genesis_deposit), "approve")

    treasury_addr = provider_treasury if remainder > 0 else ZERO

    receipt = send_tx(
        w3, account,
        factory.functions.deployProvider(
            vault_name,
            vault_symbol,
            vault_bp,
            vault_genesis_shares,
            vault_genesis_recipient or (account.address if vault_genesis_shares > 0 else ZERO),
            genesis_deposit,
            treasury_addr,
            revenue_share_bp,
            revenue_share_shares,
            revenue_share_recipient or (account.address if revenue_share_bp > 0 else ZERO),
            metadata_uri,
        ),
        "deployProvider",
    )

    # Parse ProviderDeployed event from factory
    event = factory.events.ProviderDeployed().process_receipt(receipt, errors=DISCARD)[0]
    vault_addr         = event["args"]["vault"]
    revenue_share_addr = event["args"]["revenueShare"]
    splitter_addr      = event["args"]["splitter"]

    # Parse ProviderRegistered event from registry (emitted in same tx when metadataURI set)
    registry_provider_id = 0
    if registry is not None and metadata_uri:
        reg_events = registry.events.ProviderRegistered().process_receipt(receipt, errors=DISCARD)
        if reg_events:
            registry_provider_id = reg_events[0]["args"]["id"]

    print(f"\n  ✓ vault        : {vault_addr}")
    if revenue_share_addr != ZERO:
        print(f"  ✓ revenueShare : {revenue_share_addr}")
    print(f"  ✓ splitter     : {splitter_addr}")
    if registry_provider_id:
        print(f"  ✓ registry id  : {registry_provider_id}  ← use for registerEndpoint()")
    print(f"\n  → set payTo = {splitter_addr} in your x402 server")
    if registry_provider_id:
        print(f"  → call register_endpoint({registry_provider_id}, url, method, integrity_hash)")

    # ── Auto-verify deployed contracts on Snowtrace ──────────────────────────
    print()
    protocol_treasury = factory.functions.protocolTreasury().call()

    if vault_addr != ZERO:
        ctor = abi_encode(
            ["address", "string", "string", "address"],
            [usdc_address, vault_name, vault_symbol, account.address],
        ).hex()
        verify_contract("ProviderRevenueVault", vault_addr, ctor)

    if revenue_share_addr != ZERO:
        rs_name   = vault_name + " Revenue Share"
        rs_symbol = vault_symbol + "RS"
        ctor = abi_encode(
            ["address", "string", "string", "address"],
            [usdc_address, rs_name, rs_symbol, account.address],
        ).hex()
        verify_contract("ProviderRevenueShare", revenue_share_addr, ctor)

    splitter_ctor = abi_encode(
        ["address", "address", "uint256", "address", "uint256", "address", "uint256", "address"],
        [
            usdc_address,
            protocol_treasury,
            PROTOCOL_BP,
            treasury_addr,
            remainder,
            revenue_share_addr,
            revenue_share_bp,
            vault_addr,
        ],
    ).hex()
    verify_contract("ProviderRevenueSplitter", splitter_addr, splitter_ctor)

    return vault_addr, revenue_share_addr, splitter_addr, registry_provider_id


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


def redeem_shares(vault_address: str, shares: int, receiver: str = None):
    """
    Redeem vault shares for proportional USDC.
    receiver defaults to the signer's address.
    """
    vault    = w3.eth.contract(address=w3.to_checksum_address(vault_address), abi=vault_abi)
    receiver = receiver or account.address
    print(f"\n→ redeem({shares} shares) → {receiver}")
    return send_tx(
        w3, account,
        vault.functions.redeem(shares, receiver, account.address),
        "redeem",
    )


def register_endpoint(
    provider_id: int,
    path: str,
    method: str,
    integrity_hash: bytes | str = "",
    splitter: str = "",
) -> str:
    """
    Register an API endpoint in the APIIntegrityRegistry.

    Must be called by the provider (registry owner of provider_id).
    provider_id     — the registry ID returned by deploy_provider() (1-based).
    path            — full API URL, e.g. "https://api.example.com/v1/price"
    method          — HTTP method, e.g. "GET" or "POST"
    integrity_hash  — bytes32 hash of the x402 payment metadata.
                      Pass as 0x-prefixed hex string or raw bytes.
                      If omitted, fetches the hash live from path via fetch_integrity_hash().

    Returns the endpointId (hex string) emitted by EndpointRegistered.
    """
    if registry is None:
        raise RuntimeError("No registry configured on this factory")

    if not integrity_hash:
        print(f"  fetching integrity hash from {path} …")
        integrity_hash = fetch_integrity_hash(path, verbose=True, expected_pay_to=splitter)

    if isinstance(integrity_hash, str):
        integrity_hash = bytes.fromhex(integrity_hash.removeprefix("0x"))

    print(f"\n→ registerEndpoint(providerId={provider_id}, {method} {path})")
    receipt = send_tx(
        w3, account,
        registry.functions.registerEndpoint(provider_id, path, method, integrity_hash),
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
    vault_address         = os.getenv("VAULT_ADDRESS", "")
    revenue_share_address = os.getenv("REVENUE_SHARE_ADDRESS", "")
    splitter_address      = os.getenv("SPLITTER_ADDRESS", "")

    if vault_address:
        print_vault_state(vault_address)
    if revenue_share_address:
        # Revenue share state: balances, claimable, etc.
        rs = w3.eth.contract(
            address=w3.to_checksum_address(revenue_share_address),
            abi=revenue_share_abi,
        )
        total_dist   = rs.functions.totalDistributed().call()
        total_claimed= rs.functions.totalClaimed().call()
        claimable    = rs.functions.claimable(account.address).call()
        supply       = rs.functions.totalSupply().call()
        balance      = rs.functions.balanceOf(account.address).call()
        print(f"\n── RevenueShare {revenue_share_address} ──────────────────")
        print(f"  totalSupply     : {supply / 1e6:.6f} shares")
        print(f"  signer balance  : {balance / 1e6:.6f} shares")
        print(f"  totalDistributed: {total_dist / 1e6:.6f} USDC")
        print(f"  totalClaimed    : {total_claimed / 1e6:.6f} USDC")
        print(f"  claimable now   : {claimable / 1e6:.6f} USDC")
        print("──────────────────────────────────────────────────────────────────\n")
    if splitter_address:
        print_splitter_state(splitter_address)

    # ── Example write calls (uncomment to execute) ──────────────────────────
    #
    # Set vault_bp and revenue_share_bp explicitly.
    # The remainder (100% - protocol% - vault% - rs%) goes to provider_treasury directly.
    # Assuming protocolTreasuryBp = 200 (2%):
    #
    #   vault_bp=9800, revenue_share_bp=0    → vault 98%, you 0%  (vault only)
    #   vault_bp=0,    revenue_share_bp=9800 → RS 98%,    you 0%  (RS only)
    #   vault_bp=7800, revenue_share_bp=2000 → vault 78%, RS 20%, you 0%
    #   vault_bp=5000, revenue_share_bp=2000 → vault 50%, RS 20%, you 28% direct

    # ── MODE A: Vault only ───────────────────────────────────────────────────
    # vault_addr, _, splitter_addr, reg_id = deploy_provider(
    #     vault_name   = "Weather API Vault",
    #     vault_symbol = "wrvAPI",
    #     vault_bp     = 9_800,          # 98% to vault; protocol gets 2%; you get 0% direct 
    #     vault_genesis_shares= 1000000000000, #Optional, 1 million
    #     metadata_uri = "https://placeholder",
    # )
    # print_vault_state(vault_addr)
    # print_splitter_state(splitter_addr)
    # print(f'now you can set splitter as the payTo')
    # breakpoint()

    # ── MODE B: Revenue share only ───────────────────────────────────────────
    _, rs_addr, splitter_addr, reg_id = deploy_provider(
        vault_name           = "Weather API 5",
        vault_symbol         = "wv5API",
        vault_bp             = 0,              # no vault
        revenue_share_bp     = 9_800,          # 98% to RS; protocol gets 2%; you get 0% direct
        revenue_share_shares = 1_000_000_000_000,  # 1M founder shares (6 dec)
        metadata_uri         = "ipfs://Qm...",
    )
    print_splitter_state(splitter_addr)

    # ── MODE C: Two-tier, all revenue shared ────────────────────────────────
    # vault_addr, rs_addr, splitter_addr, reg_id = deploy_provider(
    #     vault_name           = "Weather API Vault",
    #     vault_symbol         = "wrvAPI",
    #     vault_bp             = 7_800,          # 78% to vault investors
    #     revenue_share_bp     = 2_000,          # 20% to founder RS; protocol 2%; you 0% direct
    #     revenue_share_shares = 1_000_000_000_000,
    #     metadata_uri         = "ipfs://Qm...",
    # )
    # print_vault_state(vault_addr)
    # print_splitter_state(splitter_addr)

    # ── MODE D: Three-way split ──────────────────────────────────────────────
    # vault_addr, rs_addr, splitter_addr, reg_id = deploy_provider(
    #     vault_name           = "Weather API Vault",
    #     vault_symbol         = "wrvAPI",
    #     vault_bp             = 5_000,          # 50% to vault investors
    #     revenue_share_bp     = 2_000,          # 20% to founder RS
    #     revenue_share_shares = 1_000_000_000_000,
    #     provider_treasury    = account.address, # 28% direct to you (remainder)
    #     metadata_uri         = "ipfs://Qm...",
    # )
    # print_vault_state(vault_addr)
    # print_splitter_state(splitter_addr)
    # print_registry_provider(reg_id)
    #
    # # Register API endpoints after deploying (one call per route):
    url_path = os.getenv("X402_ENDPOINT")
    print(f'url_path: {url_path}')
    breakpoint()
    endpoint_id = register_endpoint(
        provider_id = reg_id,
        path        = url_path,
        method      = "GET",
        splitter    = splitter_addr,
    )
    # print_registry_endpoint(endpoint_id)

    # ── Simulate revenue (any mode) ──────────────────────────────────────────
    # simulate_revenue(splitter_address, 10_000_000)   # 10 USDC → routes per split
    # print_vault_state(vault_address)                 # share price rises (vault modes)

    # ── Redeem vault shares for USDC (vault modes) ───────────────────────────
    # redeem_shares(vault_address, shares=1_000_000)   # redeem 1 share
