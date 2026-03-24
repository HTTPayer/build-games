from utils import build_w3, build_account, get_abi
from web3 import Web3
w3 = build_w3()
account = build_account(w3)
cm_addr = Web3.to_checksum_address('0x6482a09500ba59d084f00f707870b3878f31f9c0')
cm = w3.eth.contract(address=cm_addr, abi=get_abi('ChallengeManager'))
tx = cm.functions.setForwarder(Web3.to_checksum_address('0x2e7371a5d032489e4f60216d8d898a4c10805963')).build_transaction({
    'from': account.address,
    'nonce': w3.eth.get_transaction_count(account.address),
})
signed = w3.eth.account.sign_transaction(tx, account.key)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f'Tx: https://testnet.snowscan.xyz/tx/0x{tx_hash.hex()}')
