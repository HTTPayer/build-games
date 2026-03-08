from web3 import Web3
from eth_account import Account
from dotenv import load_dotenv
import os
import json

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

print(f'base_dir: {BASE_DIR}')

mock_usdc_artifact_path = os.path.join(BASE_DIR, "..", "out", "MockUSDC.sol", "MockUSDC.json")

with open(mock_usdc_artifact_path, 'r') as f:
    mock_usdc_abi = json.load(f)['abi']

print(json.dumps(mock_usdc_abi, indent=2))

# # Using EscrowBridge (USDC version) for Base
# escrow_bridge_artifact_path = os.path.join(BASE_DIR, "..", "contracts", "out", "EscrowBridge.sol", "EscrowBridge.json")
# native_bridge_artifact_path = os.path.join(BASE_DIR, "..", "contracts", "out", "EscrowBridgeETH.sol", "EscrowBridgeETH.json")

# bdag_address_path = os.path.join(BASE_DIR, "..", "contracts", "deployments", "blockdag-escrow-bridge.json")
# base_address_path = os.path.join(BASE_DIR, "..", "contracts", "deployments", "base-escrow-bridge.json")

# print(f'Loading ABI from {escrow_bridge_artifact_path}')

# # Load EscrowBridge ABI (USDC version)
# with open(escrow_bridge_artifact_path, 'r') as f:
#     escrow_bridge_abi = json.load(f)['abi']

# with open(native_bridge_artifact_path, 'r') as f:
#     native_bridge_abi = json.load(f)['abi']

# with open(base_address_path, 'r') as f:
#     ESCROW_BRIDGE_ADDRESS_BASE = json.load(f)['deployedTo']

# with open(bdag_address_path, 'r') as f:
#     ESCROW_BRIDGE_ADDRESS_BDAG = json.load(f)['deployedTo']

# erc20_abi_path = os.path.join(BASE_DIR, 'abi', 'erc20Abi.json')
# with open(erc20_abi_path, 'r') as f:
#     erc20_abi = json.load(f)
