"""ComposedClient — Python SDK for the Composed Protocol on Avalanche Fuji."""

from __future__ import annotations

from typing import Any

from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

from ._abis import (
    CHALLENGE_MANAGER_ABI,
    ERC20_ABI,
    FACTORY_ABI,
    REGISTRY_ABI,
    STAKE_MANAGER_ABI,
)
from ._addresses import DEPLOY_BLOCK, FUJI_ADDRESSES, FUJI_CHAIN_ID
from .hash import compute_integrity_hash as _compute_integrity_hash
from .hash import fetch_integrity_hash as _fetch_integrity_hash
from .types import Challenge, DeployedProvider, Endpoint, Provider, StakeInfo

ZERO = "0x0000000000000000000000000000000000000000"
_CHALLENGE_STATUS = {0: "Pending", 1: "Valid", 2: "Invalid"}
_LOG_CHUNK = 2000


def _fmt_usdc(raw: int) -> str:
    """Format a raw 6-decimal USDC value as a human-readable string."""
    whole = raw // 1_000_000
    frac = raw % 1_000_000
    return f"{whole}.{frac:06d}".rstrip("0").rstrip(".")


def _bytes32_to_hex(value: bytes | str) -> str:
    """Normalise a bytes32 to a 0x-prefixed 66-char hex string."""
    if isinstance(value, (bytes, bytearray)):
        return "0x" + value.hex()
    s = str(value)
    if not s.startswith("0x"):
        s = "0x" + s
    return s.lower()


def _hex_to_bytes32(value: str) -> bytes:
    """Convert a 0x-prefixed hex string to 32-byte bytes."""
    s = value[2:] if value.startswith("0x") else value
    return bytes.fromhex(s.zfill(64))


class ComposedClient:
    """SDK client for the Composed Protocol."""

    def __init__(
        self,
        rpc_url: str,
        private_key: str | None = None,
        addresses: dict | None = None,
        chain_id: int = FUJI_CHAIN_ID,
    ) -> None:
        """Initialise the client with an RPC URL and optional signing key."""
        self._w3 = Web3(Web3.HTTPProvider(rpc_url))
        self._w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

        if not self._w3.is_connected():
            raise ConnectionError(f"Cannot connect to RPC endpoint: {rpc_url}")

        self._chain_id = chain_id
        self._private_key: str | None = private_key
        self._account: Any = None
        if private_key:
            self._account = self._w3.eth.account.from_key(private_key)

        addr = {**FUJI_ADDRESSES, **(addresses or {})}

        self._usdc = self._w3.eth.contract(
            address=Web3.to_checksum_address(addr["usdc"]),
            abi=ERC20_ABI,
        )
        self._stake_manager = self._w3.eth.contract(
            address=Web3.to_checksum_address(addr["stake_manager"]),
            abi=STAKE_MANAGER_ABI,
        )
        self._registry = self._w3.eth.contract(
            address=Web3.to_checksum_address(addr["registry"]),
            abi=REGISTRY_ABI,
        )
        self._factory = self._w3.eth.contract(
            address=Web3.to_checksum_address(addr["factory"]),
            abi=FACTORY_ABI,
        )
        self._challenge_manager = self._w3.eth.contract(
            address=Web3.to_checksum_address(addr["challenge_manager"]),
            abi=CHALLENGE_MANAGER_ABI,
        )

    # ------------------------------------------------------------------ #
    # Public accessors                                                     #
    # ------------------------------------------------------------------ #

    @property
    def w3(self) -> Web3:
        return self._w3

    @property
    def account(self) -> Any:
        return self._account

    @property
    def usdc(self):
        return self._usdc

    @property
    def factory(self):
        return self._factory

    @property
    def registry(self):
        return self._registry

    @property
    def stake_manager(self):
        return self._stake_manager

    @property
    def challenge_manager(self):
        return self._challenge_manager

    # ------------------------------------------------------------------ #
    # Internal helpers                                                     #
    # ------------------------------------------------------------------ #

    def _require_signer(self) -> None:
        if self._account is None:
            raise ValueError(
                "private_key required — this method sends a transaction."
            )

    def _send_tx(self, fn: Any, label: str = "") -> Any:
        """Build, sign, broadcast, and wait for a transaction. Returns the receipt."""
        self._require_signer()
        nonce = self._w3.eth.get_transaction_count(self._account.address)
        tx = fn.build_transaction(
            {
                "from": self._account.address,
                "chainId": self._chain_id,
                "nonce": nonce,
                "gas": 500_000,
                "gasPrice": self._w3.eth.gas_price,
            }
        )
        signed = self._w3.eth.account.sign_transaction(tx, self._private_key)
        tx_hash = self._w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self._w3.eth.wait_for_transaction_receipt(tx_hash)
        if receipt["status"] != 1:
            raise RuntimeError(
                f"Transaction reverted{(' (' + label + ')') if label else ''}. "
                f"tx_hash={tx_hash.hex()}"
            )
        return receipt

    def _ensure_allowance(self, spender: str, amount: int) -> None:
        """Approve the spender if the current allowance is insufficient."""
        self._require_signer()
        owner = self._account.address
        current = self._usdc.functions.allowance(owner, spender).call()
        if current < amount:
            self._send_tx(
                self._usdc.functions.approve(spender, amount),
                label="USDC approve",
            )

    # ------------------------------------------------------------------ #
    # Staking                                                              #
    # ------------------------------------------------------------------ #

    def get_stake(self, address: str | None = None) -> StakeInfo:
        """Return staking info for *address* (defaults to the signer)."""
        if address is None:
            if self._account is None:
                raise ValueError(
                    "address required when no private_key is configured."
                )
            address = self._account.address

        address = Web3.to_checksum_address(address)
        amount, unlocks_at = self._stake_manager.functions.stakes(address).call()
        cooldown = self._stake_manager.functions.withdrawCooldown().call()
        return StakeInfo(
            amount=amount,
            amount_usdc=_fmt_usdc(amount),
            unlocks_at=unlocks_at,
            cooldown_seconds=cooldown,
        )

    def stake(self, amount: int) -> str:
        """Approve and stake *amount* raw USDC. Returns the transaction hash."""
        self._require_signer()
        self._ensure_allowance(self._stake_manager.address, amount)
        receipt = self._send_tx(
            self._stake_manager.functions.stake(amount),
            label="stake",
        )
        return receipt["transactionHash"].hex()

    def request_unstake(self, amount: int = 0) -> str:
        """Request an unstake of *amount* (0 = full stake). Returns tx hash."""
        self._require_signer()
        if amount == 0:
            info = self.get_stake()
            amount = info.amount
            if amount == 0:
                raise ValueError("No staked amount to unstake.")
        receipt = self._send_tx(
            self._stake_manager.functions.requestUnstake(amount),
            label="requestUnstake",
        )
        return receipt["transactionHash"].hex()

    def withdraw(self, amount: int = 0) -> str:
        """Withdraw *amount* unlocked USDC (0 = full unlocked amount). Returns tx hash."""
        self._require_signer()
        if amount == 0:
            info = self.get_stake()
            amount = info.amount
            if amount == 0:
                raise ValueError("No staked amount to withdraw.")
        receipt = self._send_tx(
            self._stake_manager.functions.withdraw(amount),
            label="withdraw",
        )
        return receipt["transactionHash"].hex()

    # ------------------------------------------------------------------ #
    # Provider & Endpoint                                                  #
    # ------------------------------------------------------------------ #

    def deploy_provider(
        self,
        name: str,
        symbol: str,
        vault_bp: int = 9800,
        rev_share_bp: int = 0,
        genesis_deposit: int = 0,
        provider_treasury: str = ZERO,
        rs_shares: int = 0,
        rs_recipient: str = ZERO,
        genesis_shares: int = 0,
        genesis_recipient: str = ZERO,
        metadata_uri: str = "",
    ) -> DeployedProvider:
        """Deploy a new provider vault. Approves genesis_deposit if > 0."""
        self._require_signer()

        factory_addr = self._factory.address

        if genesis_deposit > 0:
            self._ensure_allowance(factory_addr, genesis_deposit)

        receipt = self._send_tx(
            self._factory.functions.deployProvider(
                name,
                symbol,
                vault_bp,
                genesis_shares,
                Web3.to_checksum_address(genesis_recipient),
                genesis_deposit,
                Web3.to_checksum_address(provider_treasury),
                rev_share_bp,
                rs_shares,
                Web3.to_checksum_address(rs_recipient),
                metadata_uri,
            ),
            label="deployProvider",
        )

        # Parse ProviderDeployed from factory.
        deployed_logs = self._factory.events.ProviderDeployed().process_receipt(receipt)
        if not deployed_logs:
            raise RuntimeError(
                "deployProvider succeeded but ProviderDeployed event not found in receipt."
            )
        ev = deployed_logs[0]
        args = ev["args"]

        vault = args["vault"]
        splitter = args["splitter"]
        revenue_share = args.get("revenueShare", ZERO)
        actual_vault_bp = args.get("vaultBp", vault_bp)
        actual_rev_share_bp = args.get("revenueShareBp", rev_share_bp)

        # Parse ProviderRegistered from registry.
        reg_logs = self._registry.events.ProviderRegistered().process_receipt(receipt)
        provider_id = reg_logs[0]["args"]["id"] if reg_logs else -1

        return DeployedProvider(
            id=provider_id,
            vault=vault,
            splitter=splitter,
            revenue_share=revenue_share if revenue_share != ZERO else ZERO,
            vault_bp=actual_vault_bp,
            rev_share_bp=actual_rev_share_bp,
            tx_hash=receipt["transactionHash"].hex(),
        )

    def register_endpoint(
        self,
        provider_id: int,
        url: str,
        method: str = "GET",
        integrity_hash: str = "",
    ) -> str:
        """Register an endpoint; fetches integrity hash if not provided. Returns endpoint_id hex."""
        self._require_signer()

        if not integrity_hash:
            integrity_hash = _fetch_integrity_hash(url)

        # Parse URL into path (everything after the host).
        from urllib.parse import urlparse
        parsed = urlparse(url)
        path = parsed.path
        if parsed.query:
            path = path + "?" + parsed.query

        # Convert integrity_hash to bytes32.
        ih_bytes = _hex_to_bytes32(integrity_hash)

        receipt = self._send_tx(
            self._registry.functions.registerEndpoint(
                provider_id,
                path,
                method.upper(),
                ih_bytes,
            ),
            label="registerEndpoint",
        )

        reg_logs = self._registry.events.EndpointRegistered().process_receipt(receipt)
        if not reg_logs:
            raise RuntimeError(
                "registerEndpoint succeeded but EndpointRegistered event not found."
            )
        endpoint_id_raw = reg_logs[0]["args"]["endpointId"]
        return _bytes32_to_hex(endpoint_id_raw)

    def update_endpoint(
        self,
        endpoint_id: str,
        integrity_hash: str = "",
    ) -> str:
        """Update the integrity hash for a registered endpoint.

        If *integrity_hash* is omitted the hash is re-fetched live from the
        endpoint URL stored on-chain (useful after a price change).
        Returns the transaction hash.
        """
        self._require_signer()

        if not integrity_hash:
            ep = self.get_endpoint(endpoint_id)
            if not ep.path:
                raise ValueError(
                    "integrity_hash required — endpoint path is empty on-chain."
                )
            integrity_hash = _fetch_integrity_hash(ep.path)

        eid_bytes = _hex_to_bytes32(endpoint_id)
        ih_bytes  = _hex_to_bytes32(integrity_hash)

        receipt = self._send_tx(
            self._registry.functions.updateEndpoint(eid_bytes, ih_bytes),
            label="updateEndpoint",
        )
        return receipt["transactionHash"].hex()

    def update_provider(
        self,
        provider_id: int,
        metadata_uri: str = "",
        payout_address: str = "",
        splitter: str = "",
    ) -> str:
        """Update provider metadata/addresses; reads current values for omitted fields. Returns tx hash."""
        self._require_signer()
        current = self.get_provider(provider_id)

        metadata_uri = metadata_uri or current.metadata_uri
        payout_address = payout_address or current.payout_address
        splitter = splitter or current.revenue_splitter

        receipt = self._send_tx(
            self._registry.functions.updateProvider(
                provider_id,
                metadata_uri,
                Web3.to_checksum_address(payout_address),
                Web3.to_checksum_address(splitter),
            ),
            label="updateProvider",
        )
        return receipt["transactionHash"].hex()

    def get_provider(self, provider_id: int) -> Provider:
        """Return on-chain provider data for *provider_id*."""
        owner, metadata_uri, payout_address, revenue_splitter, active, created_at = (
            self._registry.functions.providers(provider_id).call()
        )
        return Provider(
            id=provider_id,
            owner=owner,
            metadata_uri=metadata_uri,
            payout_address=payout_address,
            revenue_splitter=revenue_splitter,
            active=active,
            created_at=created_at,
        )

    def get_endpoint(self, endpoint_id: str) -> Endpoint:
        """Return on-chain endpoint data for *endpoint_id* (bytes32 hex)."""
        eid_bytes = _hex_to_bytes32(endpoint_id)
        (
            eid_raw,
            provider,
            path,
            method,
            integrity_hash_raw,
            version,
            active,
            checked_at,
            created_at,
        ) = self._registry.functions.endpoints(eid_bytes).call()
        return Endpoint(
            endpoint_id=_bytes32_to_hex(eid_raw),
            provider=provider,
            path=path,
            method=method,
            integrity_hash=_bytes32_to_hex(integrity_hash_raw),
            version=version,
            active=active,
            checked_at=checked_at,
            created_at=created_at,
        )

    def list_my_endpoints(self, address: str | None = None) -> list[Endpoint]:
        """Return all endpoints registered by *address* (defaults to signer)."""
        if address is None:
            if self._account is None:
                raise ValueError(
                    "address required when no private_key is configured."
                )
            address = self._account.address

        address = Web3.to_checksum_address(address)
        latest = self._w3.eth.block_number
        from_block = DEPLOY_BLOCK

        endpoint_ids: list[str] = []

        # Chunk getLogs to stay within RPC limits.
        block = from_block
        while block <= latest:
            to_block = min(block + _LOG_CHUNK - 1, latest)
            logs = self._registry.events.EndpointRegistered().get_logs(
                from_block=block,
                to_block=to_block,
                argument_filters={"provider": address},
            )
            for log in logs:
                endpoint_ids.append(_bytes32_to_hex(log["args"]["endpointId"]))
            block = to_block + 1

        return [self.get_endpoint(eid) for eid in endpoint_ids]

    # ------------------------------------------------------------------ #
    # Challenges                                                           #
    # ------------------------------------------------------------------ #

    def get_challenge_fee(self) -> int:
        """Return the raw USDC challenge fee."""
        return self._challenge_manager.functions.challengeFee().call()

    def open_challenge(self, endpoint_id: str) -> int:
        """Approve and open a challenge for *endpoint_id*. Returns the challenge id."""
        self._require_signer()
        fee = self.get_challenge_fee()
        self._ensure_allowance(self._challenge_manager.address, fee)

        eid_bytes = _hex_to_bytes32(endpoint_id)
        receipt = self._send_tx(
            self._challenge_manager.functions.openChallenge(eid_bytes),
            label="openChallenge",
        )

        opened_logs = self._challenge_manager.events.ChallengeOpened().process_receipt(
            receipt
        )
        if not opened_logs:
            raise RuntimeError(
                "openChallenge succeeded but ChallengeOpened event not found."
            )
        return opened_logs[0]["args"]["id"]

    def get_challenge(self, challenge_id: int) -> Challenge:
        """Return on-chain challenge data for *challenge_id*."""
        challenger, endpoint_id_raw, status = (
            self._challenge_manager.functions.challenges(challenge_id).call()
        )
        return Challenge(
            id=challenge_id,
            challenger=challenger,
            endpoint_id=_bytes32_to_hex(endpoint_id_raw),
            status=status,
            status_name=_CHALLENGE_STATUS.get(status, "Unknown"),
        )

    # ------------------------------------------------------------------ #
    # Hash convenience methods                                             #
    # ------------------------------------------------------------------ #

    def compute_integrity_hash(self, payment_data: dict) -> str:
        """Compute the integrity hash from a parsed payment-data dict."""
        return _compute_integrity_hash(payment_data)

    def fetch_integrity_hash(self, url: str) -> str:
        """Fetch *url* and derive its integrity hash from the 402 response."""
        return _fetch_integrity_hash(url)
