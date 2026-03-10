import express from "express";
import { paymentMiddleware, x402ResourceServer } from "@x402/express";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { HTTPFacilitatorClient } from "@x402/core/server";

const app = express();

// Your receiving wallet address
const payTo = process.env.PAY_TO || "0x0Bec71239f73D54287a32f478784170bfa6aE6fd";
const apiAmount = process.env.AMOUNT || "1000";

const payTo2 = process.env.PAY_TO_2 || "0x0DDE5c57e64bF9803fEBf00c56a97e67A1E71500";
const apiAmount2 = process.env.AMOUNT_2 || "1000";

const payTo3 = process.env.PAY_TO_3 || "0x0Bec71239f73D54287a32f478784170bfa6aE6fd";
const apiAmount3 = process.env.AMOUNT_3 || "1000";

const payTo4 = process.env.PAY_TO_4 || "0x0Bec71239f73D54287a32f478784170bfa6aE6fd";
const apiAmount4 = process.env.AMOUNT_4 || "1000";

const payTo5 = process.env.PAY_TO_5 || "0x0Bec71239f73D54287a32f478784170bfa6aE6fd";
const apiAmount5 = process.env.AMOUNT_5 || "1000";

const payTo6 = process.env.PAY_TO_6 || "0x0Bec71239f73D54287a32f478784170bfa6aE6fd";
const apiAmount6 = process.env.AMOUNT_6 || "1000";

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
      "GET /weather-6": {
        accepts: [
          {
            scheme: "exact",
            price: {
              amount: apiAmount6,
              asset: "0x5425890298aed601595a70AB815c96711a31Bc65",
              extra: { name: "USD Coin", version: "2" },
            },
            network: "eip155:43113",
            payTo: payTo6,
          },
        ],
        description: "Get current weather data for any location (endpoint 6)",
        mimeType: "application/json",
      },
      "GET /weather-5": {
        accepts: [
          {
            scheme: "exact",
            price: {
              amount: apiAmount5,
              asset: "0x5425890298aed601595a70AB815c96711a31Bc65",
              extra: { name: "USD Coin", version: "2" },
            },
            network: "eip155:43113",
            payTo: payTo5,
          },
        ],
        description: "Get current weather data for any location (endpoint 5)",
        mimeType: "application/json",
      },
      "GET /weather-4": {
        accepts: [
          {
            scheme: "exact",
            price: {
              amount: apiAmount4,
              asset: "0x5425890298aed601595a70AB815c96711a31Bc65",
              extra: { name: "USD Coin", version: "2" },
            },
            network: "eip155:43113",
            payTo: payTo4,
          },
        ],
        description: "Get current weather data for any location (endpoint 4)",
        mimeType: "application/json",
      },
      "GET /weather-3": {
        accepts: [
          {
            scheme: "exact",
            price: {
              amount: apiAmount3,
              asset: "0x5425890298aed601595a70AB815c96711a31Bc65",
              extra: { name: "USD Coin", version: "2" },
            },
            network: "eip155:43113",
            payTo: payTo3,
          },
        ],
        description: "Get current weather data for any location (endpoint 3)",
        mimeType: "application/json",
      },
      "GET /weather-2": {
        accepts: [
          {
            scheme: "exact",
            price: {
              amount: apiAmount2,
              asset: "0x5425890298aed601595a70AB815c96711a31Bc65",
              extra: { name: "USD Coin", version: "2" },
            },
            network: "eip155:43113",
            payTo: payTo2,
          },
        ],
        description: "Get current weather data for any location (endpoint 2)",
        mimeType: "application/json",
      },
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

// Implement your routes
app.get("/weather-6", (req, res) => {
  res.send({ report: { weather: "sunny", temperature: 70 } });
});

app.get("/weather-5", (req, res) => {
  res.send({ report: { weather: "sunny", temperature: 70 } });
});

app.get("/weather-4", (req, res) => {
  res.send({ report: { weather: "sunny", temperature: 70 } });
});

app.get("/weather-3", (req, res) => {
  res.send({ report: { weather: "sunny", temperature: 70 } });
});

app.get("/weather-2", (req, res) => {
  res.send({ report: { weather: "sunny", temperature: 70 } });
});

app.get("/weather", (req, res) => {
  res.send({ report: { weather: "sunny", temperature: 70 } });
});

app.listen(4021, () => {
  console.log(`Server listening at http://localhost:4021`);
  console.log(`PayTo: ${payTo}`);
  console.log(`API cost: ${apiAmount}`)
  console.log(`API endpoint: /weather`)
  console.log(`PayTo2: ${payTo2}`);
  console.log(`API cost 2: ${apiAmount2}`)
  console.log(`API endpoint 2: /weather-2`)
  console.log(`PayTo3: ${payTo3}`);
  console.log(`API cost 3: ${apiAmount3}`)
  console.log(`API endpoint 3: /weather-3`)
  console.log(`PayTo4: ${payTo4}`);
  console.log(`API cost 4: ${apiAmount4}`)
  console.log(`API endpoint 4: /weather-4`)
  console.log(`PayTo5: ${payTo5}`);
  console.log(`API cost 5: ${apiAmount5}`)
  console.log(`API endpoint 5: /weather-5`)
  console.log(`PayTo6: ${payTo6}`);
  console.log(`API cost 6: ${apiAmount6}`)
  console.log(`API endpoint 6: /weather-6`)
});
