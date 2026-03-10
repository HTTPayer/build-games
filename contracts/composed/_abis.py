"""Minimal ABI definitions for the Composed protocol contracts."""

ERC20_ABI = [
    {
        "name": "approve",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "spender", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "outputs": [{"name": "", "type": "bool"}],
    },
    {
        "name": "balanceOf",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "account", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "allowance",
        "type": "function",
        "stateMutability": "view",
        "inputs": [
            {"name": "owner", "type": "address"},
            {"name": "spender", "type": "address"},
        ],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]

STAKE_MANAGER_ABI = [
    {
        "name": "stake",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "amount", "type": "uint256"}],
        "outputs": [],
    },
    {
        "name": "requestUnstake",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "amount", "type": "uint256"}],
        "outputs": [],
    },
    {
        "name": "withdraw",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "amount", "type": "uint256"}],
        "outputs": [],
    },
    {
        "name": "stakes",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "", "type": "address"}],
        "outputs": [
            {"name": "amount", "type": "uint256"},
            {"name": "unlocksAt", "type": "uint256"},
        ],
    },
    {
        "name": "withdrawCooldown",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "minimumStake",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]

REGISTRY_ABI = [
    {
        "name": "registerEndpoint",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "providerId", "type": "uint256"},
            {"name": "path", "type": "string"},
            {"name": "method", "type": "string"},
            {"name": "integrityHash", "type": "bytes32"},
        ],
        "outputs": [],
    },
    {
        "name": "updateProvider",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "id", "type": "uint256"},
            {"name": "metadataURI", "type": "string"},
            {"name": "payoutAddress", "type": "address"},
            {"name": "revenueSplitter", "type": "address"},
        ],
        "outputs": [],
    },
    {
        "name": "updateEndpoint",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "endpointId", "type": "bytes32"},
            {"name": "newIntegrityHash", "type": "bytes32"},
        ],
        "outputs": [],
    },
    {
        "name": "providers",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "id", "type": "uint256"}],
        "outputs": [
            {"name": "owner", "type": "address"},
            {"name": "metadataURI", "type": "string"},
            {"name": "payoutAddress", "type": "address"},
            {"name": "revenueSplitter", "type": "address"},
            {"name": "active", "type": "bool"},
            {"name": "createdAt", "type": "uint256"},
        ],
    },
    {
        "name": "endpoints",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "endpointId", "type": "bytes32"}],
        "outputs": [
            {"name": "endpointId", "type": "bytes32"},
            {"name": "provider", "type": "address"},
            {"name": "path", "type": "string"},
            {"name": "method", "type": "string"},
            {"name": "integrityHash", "type": "bytes32"},
            {"name": "version", "type": "uint256"},
            {"name": "active", "type": "bool"},
            {"name": "checkedAt", "type": "uint256"},
            {"name": "createdAt", "type": "uint256"},
        ],
    },
    {
        "name": "minimumStakeRequired",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "endpointsByProvider",
        "type": "function",
        "stateMutability": "view",
        "inputs": [
            {"name": "provider", "type": "address"},
            {"name": "index", "type": "uint256"},
        ],
        "outputs": [{"name": "", "type": "bytes32"}],
    },
    {
        "name": "ProviderRegistered",
        "type": "event",
        "anonymous": False,
        "inputs": [
            {"name": "id", "type": "uint256", "indexed": True},
            {"name": "owner", "type": "address", "indexed": True},
        ],
    },
    {
        "name": "EndpointRegistered",
        "type": "event",
        "anonymous": False,
        "inputs": [
            {"name": "endpointId", "type": "bytes32", "indexed": True},
            {"name": "provider", "type": "address", "indexed": True},
        ],
    },
    {
        "name": "EndpointHashUpdated",
        "type": "event",
        "anonymous": False,
        "inputs": [
            {"name": "endpointId", "type": "bytes32", "indexed": True},
            {"name": "newIntegrityHash", "type": "bytes32", "indexed": False},
            {"name": "version", "type": "uint256", "indexed": False},
        ],
    },
]

FACTORY_ABI = [
    {
        "name": "USDC",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "address"}],
    },
    {
        "name": "protocolTreasury",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "address"}],
    },
    {
        "name": "protocolTreasuryBp",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "providerCount",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "deployProvider",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "name", "type": "string"},
            {"name": "symbol", "type": "string"},
            {"name": "vaultBp", "type": "uint256"},
            {"name": "genesisShares", "type": "uint256"},
            {"name": "genesisRecipient", "type": "address"},
            {"name": "genesisDeposit", "type": "uint256"},
            {"name": "providerTreasury", "type": "address"},
            {"name": "revenueShareBp", "type": "uint256"},
            {"name": "rsShares", "type": "uint256"},
            {"name": "rsRecipient", "type": "address"},
            {"name": "metadataURI", "type": "string"},
        ],
        "outputs": [],
    },
    {
        "name": "ProviderDeployed",
        "type": "event",
        "anonymous": False,
        "inputs": [
            {"name": "deployer", "type": "address", "indexed": True},
            {"name": "vault", "type": "address", "indexed": True},
            {"name": "splitter", "type": "address", "indexed": True},
            {"name": "revenueShare", "type": "address", "indexed": False},
            {"name": "vaultGenesisRecipient", "type": "address", "indexed": False},
            {"name": "vaultGenesisShares", "type": "uint256", "indexed": False},
            {"name": "genesisDeposit", "type": "uint256", "indexed": False},
            {"name": "revenueShareRecipient", "type": "address", "indexed": False},
            {"name": "revenueShareShares", "type": "uint256", "indexed": False},
            {"name": "providerTreasury", "type": "address", "indexed": False},
            {"name": "protocolTreasuryBp", "type": "uint256", "indexed": False},
            {"name": "providerTreasuryBp", "type": "uint256", "indexed": False},
            {"name": "revenueShareBp", "type": "uint256", "indexed": False},
            {"name": "vaultBp", "type": "uint256", "indexed": False},
        ],
    },
]

CHALLENGE_MANAGER_ABI = [
    {
        "name": "challengeFee",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "challenges",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "id", "type": "uint256"}],
        "outputs": [
            {"name": "challenger", "type": "address"},
            {"name": "endpointId", "type": "bytes32"},
            {"name": "status", "type": "uint8"},
        ],
    },
    {
        "name": "slashBp",
        "type": "function",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "name": "openChallenge",
        "type": "function",
        "stateMutability": "nonpayable",
        "inputs": [{"name": "endpointId", "type": "bytes32"}],
        "outputs": [],
    },
    {
        "name": "ChallengeOpened",
        "type": "event",
        "anonymous": False,
        "inputs": [
            {"name": "id", "type": "uint256", "indexed": True},
            {"name": "endpointId", "type": "bytes32", "indexed": True},
            {"name": "path", "type": "string", "indexed": False},
            {"name": "method", "type": "string", "indexed": False},
            {"name": "integrityHash", "type": "bytes32", "indexed": False},
        ],
    },
    {
        "name": "ChallengeResolved",
        "type": "event",
        "anonymous": False,
        "inputs": [
            {"name": "id", "type": "uint256", "indexed": True},
            {"name": "result", "type": "uint8", "indexed": False},
        ],
    },
]
