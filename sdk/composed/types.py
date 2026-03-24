from dataclasses import dataclass


@dataclass
class StakeInfo:
    amount: int           # raw USDC (6 decimals)
    amount_usdc: str      # formatted e.g. "12.50"
    unlocks_at: int       # unix ts, 0 if no pending unstake
    cooldown_seconds: int


@dataclass
class DeployedProvider:
    id: int
    revenue_share: str
    splitter: str
    rev_share_bp: int
    provider_bp: int
    tx_hash: str


@dataclass
class Provider:
    id: int
    owner: str
    metadata_uri: str
    payout_address: str
    revenue_splitter: str
    active: bool
    created_at: int


@dataclass
class Endpoint:
    endpoint_id: str      # bytes32 hex
    provider: str         # owner address
    path: str
    method: str
    integrity_hash: str   # bytes32 hex
    version: int
    active: bool
    checked_at: int
    created_at: int


@dataclass
class Challenge:
    id: int
    challenger: str
    endpoint_id: str
    status: int           # 0=Pending 1=Valid 2=Invalid
    status_name: str      # "Pending" | "Valid" | "Invalid"
