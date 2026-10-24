// Mihenk Agent API — measured crypto KOL data sold per call over x402 (Circle Gateway Nanopayments).
// 24 Oct 2026. Runs on 127.0.0.1:8097 behind Caddy (app.mihenkai.com/x402/*). Data comes from a private, read-only
// helper (X402_HELPER, run with `kol <handle>` or `coin <SYMBOL> <hours>`, prints one JSON object) that returns
// only measured, verifiable data. The helper and the database are not part of this repository.
//
// Payment flow: a request without a payment gets 402 + PAYMENT-REQUIRED from the Gateway middleware.
// A request with a payment is checked first (handle / symbol measured?); only then is the payment settled,
// so nobody pays for a 404.
import express from "express";
import { execFile } from "node:child_process";
import { appendFile } from "node:fs";
import { createGatewayMiddleware } from "@circle-fin/x402-batching/server";

const PORT = Number(process.env.PORT || 8097);
const HOST = process.env.HOST || "127.0.0.1";
const SELLER = process.env.X402_SELLER || "";
const FACILITATOR = process.env.X402_FACILITATOR || "";              // empty = Circle Gateway mainnet
const NETWORKS = (process.env.X402_NETWORKS || "").split(",").map((s) => s.trim()).filter(Boolean);
const usd = (v) => (String(v).startsWith("$") ? String(v) : "$" + String(v));   // env holds 0.01 so shells do not expand "$"
const PRICE = usd(process.env.X402_PRICE || "0.01");
const PRICE_KOL = usd(process.env.X402_PRICE_KOL || PRICE);
const PRICE_COIN = usd(process.env.X402_PRICE_COIN || PRICE);
// Bulk-download guard: paid calls per paying wallet per UTC day, so the dataset cannot be copied for a few dollars.
const DAILY_CAP = Number(process.env.X402_DAILY_CAP || 200);
const LOG_FILE = process.env.X402_LOG || "payments.jsonl";
const BASE_URL = process.env.X402_BASE_URL || "https://app.mihenkai.com/x402";
const PY = process.env.X402_PYTHON || "python3";
const HELPER = process.env.X402_HELPER || "";
const DATA_DIR = process.env.X402_DATA_DIR || process.cwd();

if (!/^0x[0-9a-fA-F]{40}$/.test(SELLER) || !HELPER) {
  console.error("Set X402_SELLER (EOA address that receives USDC) and X402_HELPER (data helper script)");
  process.exit(1);
}

const gateway = createGatewayMiddleware({
  sellerAddress: SELLER,
  ...(NETWORKS.length ? { networks: NETWORKS } : {}),
  ...(FACILITATOR ? { facilitatorUrl: FACILITATOR } : {}),
  description: "Mihenk AI: measured crypto KOL data",
});
const COUNTS = new Map();   // payer -> { day, n }
const day = () => new Date().toISOString().slice(0, 10);
const payerOf = (ctx) => String(ctx?.paymentPayload?.payload?.authorization?.from || "").toLowerCase();
gateway.onBeforeSettle(async (ctx) => {
  const p = payerOf(ctx);
  if (!p) return;
  const s = COUNTS.get(p);
  if (s && s.day === day() && s.n >= DAILY_CAP) {
    return { abort: true, reason: "daily_limit", message: `Daily limit of ${DAILY_CAP} paid calls per wallet reached; try again tomorrow (UTC).` };
  }
});
gateway.onAfterSettle(async (ctx) => {
  try {
    const r = ctx.result || {};
    const p = (r.payer || payerOf(ctx) || "").toLowerCase();
    if (r.success && p) {
      const s = COUNTS.get(p);
      COUNTS.set(p, s && s.day === day() ? { day: s.day, n: s.n + 1 } : { day: day(), n: 1 });
      if (COUNTS.size > 20000) COUNTS.clear();
    }
    const line = JSON.stringify({ ev: "settled", ok: !!r.success, reason: r.errorReason, payer: r.payer, network: r.network, tx: r.transaction,
      amount: ctx.requirements?.amount, payTo: ctx.requirements?.payTo, at: new Date().toISOString() });
    console.log(line);
    appendFile(LOG_FILE, line + "\n", () => {});
  } catch { /* logging only */ }
});

function helper(args) {
  return new Promise((resolve) => {
    execFile(PY, [HELPER, ...args], { timeout: 15000, maxBuffer: 2 * 1024 * 1024, cwd: DATA_DIR }, (err, out, errout) => {
      if (errout) console.error(String(errout).slice(0, 500));
      try { resolve(JSON.parse(out)); } catch { resolve({ status: 500, error: "internal" }); }
    });
  });
}

const app = express();
app.disable("x-powered-by");
app.set("trust proxy", "loopback");

// Light per-IP limit (agents pay per call; this only stops floods of unpaid probes).
const SAY = new Map();
app.use((req, res, next) => {
  const ip = req.ip || "-";
  const now = Date.now();
  const s = SAY.get(ip) || { t: now, n: 0 };
  if (now - s.t > 60_000) { s.t = now; s.n = 0; }
  s.n += 1; SAY.set(ip, s);
  if (SAY.size > 5000) SAY.clear();
  if (s.n > 120) return res.status(429).json({ error: "rate_limited", message: "Too many requests; try again in a minute." });
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Expose-Headers", "PAYMENT-REQUIRED, PAYMENT-RESPONSE");
  next();
});

const hasPayment = (req) => !!(req.get("payment-signature") || req.get("x-payment"));

// Validates params for free, computes data before settlement when a payment is attached.
function precheck(fn) {
  return async (req, res, next) => {
    const v = fn.check(req);
    if (v) return res.status(400).json(v);
    if (!hasPayment(req)) return next();               // no payment yet -> middleware answers 402
    const r = await fn.run(req);
    if (r.status !== 200) return res.status(r.status).json({ error: r.error, ...(r.message ? { message: r.message } : {}) });
    res.locals.data = r.data;
    next();
  };
}
function respond(fn) {
  return async (req, res) => {
    let d = res.locals.data;
    if (!d) {
      const r = await fn.run(req);
      if (r.status !== 200) return res.status(r.status).json({ error: r.error });
      d = r.data;
    }
    if (req.payment) {
      console.log(JSON.stringify({ ev: "served", path: req.path, payer: req.payment.payer, network: req.payment.network,
        amount: req.payment.amount, at: new Date().toISOString() }));
    }
    res.json(d);
  };
}

const KOL = {
  check: (req) => (/^@?[A-Za-z0-9_]{1,15}$/.test(req.params.handle || "") ? null
    : { error: "invalid_handle", message: "Use an X handle, e.g. /x402/kol/CryptoMichNL" }),
  run: (req) => helper(["kol", req.params.handle]),
};
const COIN = {
  check: (req) => {
    if (!/^\$?[A-Za-z0-9]{1,15}$/.test(req.params.symbol || "")) return { error: "invalid_symbol", message: "Use a ticker, e.g. /x402/coin/SOL/calls" };
    const h = req.query.hours;
    if (h !== undefined && !(/^\d{1,3}$/.test(String(h)) && Number(h) >= 1 && Number(h) <= 168)) return { error: "invalid_hours", message: "hours must be 1 to 168" };
    return null;
  },
  run: (req) => helper(["coin", req.params.symbol, String(req.query.hours || 24)]),
};

const ABOUT = {
  name: "Mihenk Agent API",
  description: "Measured crypto KOL (influencer) data for AI agents, paid per call in USDC over x402 (Circle Gateway Nanopayments). "
    + "Real reach, audience quality and what the market did after each KOL's calls. Only measured data; not investment advice.",
  price_per_call: { kol: PRICE_KOL.replace("$", "") + " USDC", coin_calls: PRICE_COIN.replace("$", "") + " USDC" },
  daily_limit_per_wallet: DAILY_CAP,
  payment: { protocol: "x402", scheme: "Circle Gateway batched (gas-free)", seller: SELLER,
    networks: NETWORKS.length ? NETWORKS : "all Circle Gateway networks" },
  endpoints: {
    [`GET ${BASE_URL}/kol/{handle}`]: "KOL record: Mihenk score, real reach, audience quality, integrity, 90-day call record, recent calls",
    [`GET ${BASE_URL}/coin/{symbol}/calls?hours=24`]: "Measured KOLs who called a coin in the last N hours (1-168), with price moves and each KOL's record",
  },
  free: { [`GET ${BASE_URL}/`]: "this page", [`GET ${BASE_URL}/openapi.json`]: "OpenAPI 3.1 spec" },
  no_charge_on_404: "If the handle or symbol has nothing measured, the API answers 404 and the payment is not settled.",
  docs: "https://mihenkai.com/methodology.html",
  contact: "hello@mihenkai.com",
};

const OPENAPI = {
  openapi: "3.1.0",
  info: { title: "Mihenk Agent API", version: "1.0.0", description: ABOUT.description, contact: { email: "hello@mihenkai.com", url: "https://mihenkai.com" } },
  servers: [{ url: BASE_URL }],
  paths: {
    "/kol/{handle}": {
      get: {
        operationId: "getKol", summary: "Measured record of one crypto KOL on X",
        description: `Costs ${ABOUT.price_per_call.kol} per call over x402. Without a payment the API answers 402 with the PAYMENT-REQUIRED header. Up to ${DAILY_CAP} paid calls per wallet per UTC day.`,
        parameters: [{ name: "handle", in: "path", required: true, schema: { type: "string", pattern: "^@?[A-Za-z0-9_]{1,15}$" }, example: "CryptoMichNL" }],
        responses: {
          200: { description: "KOL record", content: { "application/json": { schema: { $ref: "#/components/schemas/Kol" } } } },
          402: { description: "Payment required (x402). See PAYMENT-REQUIRED header." },
          404: { description: "Not measured by Mihenk; no payment is settled." },
          400: { description: "Invalid handle" },
        },
      },
    },
    "/coin/{symbol}/calls": {
      get: {
        operationId: "getCoinCalls", summary: "Measured KOL calls on a coin in the last N hours",
        description: `Costs ${ABOUT.price_per_call.coin_calls} per call over x402. Up to 100 calls, newest first.`,
        parameters: [
          { name: "symbol", in: "path", required: true, schema: { type: "string", pattern: "^\\$?[A-Za-z0-9]{1,15}$" }, example: "SOL" },
          { name: "hours", in: "query", required: false, schema: { type: "integer", minimum: 1, maximum: 168, default: 24 } },
        ],
        responses: {
          200: { description: "Calls", content: { "application/json": { schema: { $ref: "#/components/schemas/CoinCalls" } } } },
          402: { description: "Payment required (x402). See PAYMENT-REQUIRED header." },
          400: { description: "Invalid symbol or hours" },
        },
      },
    },
  },
  components: {
    schemas: {
      Record90d: { type: "object", properties: {
        measured: { type: "integer", description: "Measured calls in the last 90 days" },
        went_their_way: { type: "integer", description: "Calls where the price moved in the call's direction within 24h" },
        hit_rate_pct: { type: ["number", "null"], description: "Shown with at least 5 measured calls" },
        avg_move_pct: { type: ["number", "null"], description: "Average 24h move in the call's direction" } } },
      Kol: { type: "object", properties: {
        handle: { type: "string" }, name: { type: ["string", "null"] }, profile_url: { type: "string" }, followers: { type: "integer" },
        real_reach: { type: "object", properties: { median_views_per_post: { type: "integer" }, views_per_follower: { type: ["number", "null"] } } },
        impact_class: { type: ["string", "null"], enum: ["mega", "macro", "mid", "micro", "nano", null] },
        audience: { type: "object", properties: { authentic_engagement: { type: ["number", "null"] }, audience_quality: { type: ["number", "null"] },
          integrity: { type: ["number", "null"] }, scale: { type: "string" } } },
        mihenk_score: { type: "object", properties: { value: { type: ["number", "null"] }, scale: { type: "string" }, about: { type: "string" } } },
        smart_followers: { type: "integer" },
        calls_90d: { $ref: "#/components/schemas/Record90d" },
        recent_calls: { type: "array", items: { type: "object", properties: { coin: { type: "string" }, direction: { type: "string", enum: ["long", "short"] },
          posted_at: { type: "string" }, move_24h_pct: { type: ["number", "null"] } } } },
        measured_at: { type: ["string", "null"] }, card_url: { type: "string" }, methodology_url: { type: "string" }, note: { type: "string" } } },
      CoinCalls: { type: "object", properties: {
        symbol: { type: "string" }, hours: { type: "integer" },
        summary: { type: "object", properties: { calls: { type: "integer" }, kols: { type: "integer" }, long: { type: "integer" }, short: { type: "integer" } } },
        calls: { type: "array", items: { type: "object", properties: {
          kol: { type: "string" }, followers: { type: "integer" }, median_views_per_post: { type: "integer" }, direction: { type: "string" },
          posted_at: { type: "string" }, post_url: { type: ["string", "null"] },
          price_move_pct: { type: "object", description: "Keys 5m, 1h, 4h, 24h once measured", additionalProperties: { type: "number" } },
          price_source: { type: ["string", "null"] }, kol_record_90d: { type: "object" } } } },
        note: { type: "string" } } },
    },
  },
};

app.get(["/x402", "/x402/"], (req, res) => res.json(ABOUT));
app.get("/x402/openapi.json", (req, res) => res.json(OPENAPI));
app.get("/x402/health", (req, res) => res.json({ ok: true }));
app.get("/x402/kol/:handle", precheck(KOL), gateway.require(PRICE_KOL), respond(KOL));
app.get("/x402/coin/:symbol/calls", precheck(COIN), gateway.require(PRICE_COIN), respond(COIN));
app.use((req, res) => res.status(404).json({ error: "not_found", see: `${BASE_URL}/` }));
app.use((err, req, res, _next) => {
  console.error("hata", String(err && err.stack || err).slice(0, 800));
  if (!res.headersSent) res.status(500).json({ error: "internal" });
});

app.listen(PORT, HOST, () => console.log(`mihenk-x402 on ${HOST}:${PORT} seller ${SELLER} networks ${NETWORKS.join(",") || "all"} ${FACILITATOR || "mainnet"}`));
