import { x402Client, wrapFetchWithPayment, x402HTTPClient } from "@x402/fetch";
import { registerExactEvmScheme } from "@x402/evm/exact/client";
import { toClientEvmSigner } from "@x402/evm";
import { privateKeyToAccount } from "viem/accounts";
import { createPublicClient, http } from "viem";
import { avalancheFuji } from "viem/chains";
import dotenv from "dotenv";

dotenv.config();

const account = privateKeyToAccount(process.env.EVM_PRIVATE_KEY as `0x${string}`);
const publicClient = createPublicClient({ chain: avalancheFuji, transport: http() });
const signer = toClientEvmSigner(account, publicClient);

// Create x402 client and register schemes
const client = new x402Client();
registerExactEvmScheme(client, { signer });

// Wrap fetch with payment handling
const fetchWithPayment = wrapFetchWithPayment(fetch, client);

// Make request - payment is handled automatically
const response = await fetchWithPayment("http://localhost:4021/weather-2", {
  method: "GET",
});

const body = await response.json();
console.log("Response:", body);

// Get payment receipt from response headers
if (response.ok) {
  const httpClient = new x402HTTPClient(client);
  const paymentResponse = httpClient.getPaymentSettleResponse(
    (name) => response.headers.get(name)
  );
  console.log("Payment settled:", paymentResponse);
}