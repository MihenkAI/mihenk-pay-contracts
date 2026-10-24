# Paying for Mihenk data with x402

Mihenk sells its measured crypto KOL (influencer) data to AI agents per call, in USDC, over [x402](https://x402.org) with
[Circle Gateway Nanopayments](https://developers.circle.com/gateway). No account and no API key: an agent asks for the data,
gets `402 Payment Required`, signs a gas-free USDC payment and gets the JSON.

Live API: `https://app.mihenkai.com/x402/` · OpenAPI: `https://app.mihenkai.com/x402/openapi.json`

## Endpoints

| Endpoint | Price | Returns |
| --- | --- | --- |
| `GET /x402/kol/{handle}` | 0.01 USDC | One KOL on X: Mihenk score, real reach (median views per post), authentic engagement, audience quality, integrity, 90-day call record, last 10 calls |
| `GET /x402/coin/{symbol}/calls?hours=24` | 0.01 USDC | Measured KOLs who called a coin in the last 1–168 hours: direction, post link, price move at 5 min / 1 h / 4 h / 24 h, each KOL's 90-day record |
| `GET /x402/` and `/x402/openapi.json` | free | Description and spec |

- **Networks:** Arc (`eip155:5042`), Base (`eip155:8453`), Polygon (`eip155:137`), through Circle Gateway (batched, gas-free for the buyer).
- **No charge for nothing:** if a handle or symbol has no measured data, the API answers `404` and the payment is not settled.
- **Daily limit:** 200 paid calls per paying wallet per UTC day, so the dataset can't be bulk-copied.
- **What "measured" means:** a call is a KOL post that names a coin with a direction; Mihenk prices it 5 minutes, 1 hour, 4 hours and 24 hours after the post. Details: https://mihenkai.com/methodology.html. Measurement, not investment advice.

## Buyer: pay from an agent

```bash
npm install @circle-fin/x402-batching viem
```

```js
import { GatewayClient } from "@circle-fin/x402-batching/client";

const client = new GatewayClient({ chain: "base", privateKey: process.env.AGENT_KEY }); // an EOA
await client.deposit("1");   // one-time: moves 1 USDC into your Gateway balance (on-chain)
const r = await client.pay("https://app.mihenkai.com/x402/kol/CryptoMichNL");
console.log(r.formattedAmount, r.data.real_reach, r.data.calls_90d);
```

See [`buyer/pay.mjs`](buyer/pay.mjs). For testing use `chain: "arcTestnet"` and testnet USDC from https://faucet.circle.com.

## Seller: how the API is built

[`seller/server.js`](seller/server.js) is the code that runs in production (Express + `createGatewayMiddleware`).
Configuration is by environment: `X402_SELLER` (the EOA that receives USDC), `X402_NETWORKS`, `X402_PRICE`,
`X402_DAILY_CAP` and `X402_HELPER`. Mihenk's data helper and database are private and not in this repository;
any script that prints one JSON object (`{"status":200,"data":{...}}`) for `kol <handle>` or `coin <SYMBOL> <hours>` can stand in for it.

Order of operations for a paid request:

1. Free validation of the path (bad handle or symbol → `400`, no payment asked).
2. If a payment is attached, the data is looked up first; nothing measured → `404`, payment not settled.
3. Daily limit per payer is checked before settlement (`onBeforeSettle`).
4. Circle Gateway settles the payment, the JSON is returned, and the settlement is logged.

Contact: hello@mihenkai.com
