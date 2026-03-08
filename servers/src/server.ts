import express from "express";
import { paymentMiddleware, x402ResourceServer } from "@x402/express";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { HTTPFacilitatorClient } from "@x402/core/server";

const app = express();

// Your receiving wallet address
const payTo = process.env.PAY_TO || "0x0Bec71239f73D54287a32f478784170bfa6aE6fd";
const apiAmount = process.env.AMOUNT || "1000";

// Create facilitator client (testnet)
const facilitatorClient = new HTTPFacilitatorClient({
  url: "https://facilitator.ultravioletadao.xyz"
});

// Create resource server and register EVM scheme
const server = new x402ResourceServer(facilitatorClient)
  .register("eip155:43113", new ExactEvmScheme());

app.use(
  paymentMiddleware(
    {
      "GET /weather": {
        accepts: [
          {
            scheme: "exact",
            // Fuji USDC (6 decimals): $0.001 = 1000 raw units
            price: {
              amount: apiAmount,
              asset: "0x5425890298aed601595a70AB815c96711a31Bc65",
              extra: { name: "USD Coin", version: "2" },
            },
            network: "eip155:43113", // Avalanche Fuji (CAIP-2 format)
            payTo,
          },
        ],
        description: "Get current weather data for any location",
        mimeType: "application/json",
      },
    },
    server,
  ),
);

// Implement your route
app.get("/weather", (req, res) => {
  res.send({
    report: {
      weather: "sunny",
      temperature: 70,
    },
  });
});

app.listen(4021, () => {
  console.log(`Server listening at http://localhost:4021`);
  console.log(`PayTo: ${payTo}`);
  console.log(`API cost: ${apiAmount}`)
  console.log(`API endpoint: /weather`)
});