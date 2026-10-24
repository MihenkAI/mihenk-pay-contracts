// Pay for Mihenk data with x402 (Circle Gateway). Usage:
//   AGENT_KEY=0x... CHAIN=base node pay.mjs https://app.mihenkai.com/x402/kol/CryptoMichNL
//   AGENT_KEY=0x... CHAIN=base DEPOSIT=1 node pay.mjs ...   (one-time Gateway deposit first)
// AGENT_KEY must be an EOA private key. For tests use CHAIN=arcTestnet and USDC from https://faucet.circle.com.
import { GatewayClient } from "@circle-fin/x402-batching/client";

const url = process.argv[2] || "https://app.mihenkai.com/x402/kol/CryptoMichNL";
const chain = process.env.CHAIN || "base";
// Arc RPCs live under arc.io (https://docs.arc.io/arc/references/rpc-endpoints); pass them explicitly.
const RPC = { arcTestnet: "https://rpc.testnet.arc.io", arc: "https://rpc.mainnet.arc.io" };
const client = new GatewayClient({ chain, privateKey: process.env.AGENT_KEY, ...(RPC[chain] ? { rpcUrl: RPC[chain] } : {}) });

const b = await client.getBalances();
console.log("wallet", b.wallet.formatted, "USDC · gateway", b.gateway.formatted ?? String(b.gateway.total), "USDC");
if (process.env.DEPOSIT) {
  const d = await client.deposit(process.env.DEPOSIT);
  console.log("deposit", d);
}
const r = await client.pay(url);
console.log("paid", r.formattedAmount, "USDC · settlement", r.transaction);
console.log(JSON.stringify(r.data, null, 2));
