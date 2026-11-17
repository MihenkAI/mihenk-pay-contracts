# Mihenk AI MCP server

Mihenk measures crypto KOLs (influencers) on X: real reach, audience quality and what the market did after their calls.
Next to each KOL call it offers one-tap trading from the user's own wallet; it also runs Mihenk Pay for KOL campaign payments and the x402 Agent API.
The MCP server gives AI agents a free, read-only slice of that data, so an agent can check a KOL or a token before it acts.

- **Endpoint:** `https://app.mihenkai.com/mcp` (Streamable HTTP, no sign-in, no API key)
- **MCP Registry name:** `com.mihenkai/mihenk`
- **Limit:** 60 tool calls per hour per IP
- **Full records:** sold per call on the x402 Agent API, see [`../x402`](../x402)

## Add it to your client

Claude Code:

```bash
claude mcp add --transport http mihenk https://app.mihenkai.com/mcp
```

Any other client that supports remote MCP servers over Streamable HTTP: add `https://app.mihenkai.com/mcp` as the server URL.

## Tools

All tools are read-only (`readOnlyHint: true`) and return JSON as text.

| Tool | What it returns | Arguments |
| --- | --- | --- |
| `kol_lookup` | One X account: Mihenk score (0-10), real reach (typical views per post), followers, region, 90-day call record (share of calls that went the call's way within 24 h) and the last 5 calls | `handle` (required): X handle, e.g. `cobie` |
| `organic_interest` | Which measured KOLs talked about a token, how many views those posts got and how much of it was organic (posts that 3+ accounts published with the same text count as coordinated) | `token` (required): ticker without `$` (e.g. `PEPE`) or a contract address · `days`: 7, 30 or 90 (default 30) |
| `ecosystem_report` | Who among measured KOLs talks about a chain, its most-discussed tokens, and the KOLs whose posts were followed by more trading volume | `chain` (required): e.g. `base`, `solana`, `ethereum`, `bsc`, `near`, `arbitrum`, `hyperliquid` · `days`: 7, 30 or 90 (default 30) |
| `evidence_search` | Archived posts of measured KOLs with the exact post time, including posts later deleted from X; at most 10 records with links and record hashes | `handle`: X handle without `@` · `words`: words or a `$ticker` · `deleted_only`: `true` for deleted posts only (default `false`). Give a handle, words, or both |
| `kol_basket` | The spot coins a KOL promoted in the window, with the median 24 h move after their posts | `handle` (required): X handle without `@` · `days`: 7, 30 or 90 (default 30) |

## Example

```bash
curl -s https://app.mihenkai.com/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"kol_lookup","arguments":{"handle":"CryptoMichNL"}}}'
```

The answer holds the account's Mihenk score, real reach, 90-day call record and last calls, with links to its public card and to the full record on the x402 API.

## About this folder

The server runs on Mihenk's own infrastructure, next to the measurement database. This folder documents its interface; the server's source code is not published.

- Website: https://mihenkai.com
- How Mihenk measures: https://mihenkai.com/methodology.html
- Contact: team@mihenkai.com

Measurement, not investment advice.
