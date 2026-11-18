# Mihenk AI on 0G

Mihenk AI measures crypto KOLs (influencers) by what the market did after their calls. On 0G it uses all three layers:

- **0G Compute:** a TEE-attested model on 0G Private Computer reads each new KOL call post a second time.
- **0G Storage:** every UTC day, those readings and that day's x402 payment receipts are uploaded as one JSON file.
- **0G Chain:** Mihenk Pay (KOL payments in USDC) and MihenkRecords (the daily roots, written once and never changed).

Live overview, free JSON: **https://app.mihenkai.com/x402/0g** (add `?day=YYYY-MM-DD` for one day).

## 0G Compute: a second reading of each call

Every 10 minutes, new posts that Mihenk reads as coin calls (a coin plus a direction, long or short) are sent to a model on
0G Private Computer through the 0G compute router. The provider signs each answer inside a TEE, and Mihenk checks the
signature with `broker.inference.processResponse(provider, chat_id)` from `@0gfoundation/0g-compute-ts-sdk`.

When the 0G reading finds the same coin and direction, the call carries a `verification` object in the Agent API
(`GET https://app.mihenkai.com/x402/coin/{symbol}/calls`, see [`../x402`](../x402)):

```json
"verification": {
  "network": "0G",
  "agrees_with_mihenk": true,
  "provider": "0x…",
  "chat_id": "…",
  "tee_verified": true,
  "archive_0g": {
    "day_utc": "2026-11-17",
    "storage_root": "0x504a3ff78a40cb9275034250a72b2f3d51d9ef56626610c7d9478c324c910cde",
    "storage_tx": "https://chainscan.0g.ai/tx/0xe711c2c18d059b2d2270389b886fbcf32b12177f7d60e4830550c12c370ef5d8",
    "how_to_check": "https://app.mihenkai.com/x402/0g?day=2026-11-17"
  }
}
```

`provider` and `chat_id` let anyone check the TEE signature again. `archive_0g` appears once the reading's day has been
archived (nightly).

## 0G Storage: the daily archive

At 00:20 UTC, the previous UTC day goes into one JSON file: every 0G reading (post id, model, provider, chat_id, the 0G
reading, Mihenk's own reading, whether they agree, whether the TEE signature verified) and the day's x402 payment receipts.
From 16 Nov 2026 the file also holds the day's evidence seal: the Merkle root over the day's records in Mihenk's evidence
archive of KOL posts (what was posted and when, deleted posts included). The file is uploaded to 0G Storage mainnet, and its
root hash, upload transaction and sha256 are listed at `/x402/0g`.

Download a day and check it:

```js
import { Indexer } from "@0gfoundation/0g-storage-ts-sdk";

const indexer = new Indexer("https://indexer-storage-turbo.0g.ai");
const err = await indexer.download(storageRoot, "mihenk_0g_day.json", true); // true: check the Merkle proof
```

Then compare the file's sha256 with the `sha256` listed for that day.

The first daily archives:

| UTC day | 0G readings | Storage root | Upload |
| --- | --- | --- | --- |
| 2026-11-13 | 996 | `0xcce2f6aa43d677a0e6e3fc1eee5799e7668e8c724d3f6cc2a4ffd31490a67bf1` | [tx](https://chainscan.0g.ai/tx/0x53950c06867fd73414f8e93be224eb2c21b5d4d33568d5bbf7f859b1db2521e1) |
| 2026-11-14 | 996 | `0xd0168cbb353492567c0773a34c87487de3e328e56df68b4a6421df34eccb0675` | [tx](https://chainscan.0g.ai/tx/0x57a17b8bd288cec7d17ec6e2bbc6642ab8fd6a6cad47c89e02be4481c6839a76) |
| 2026-11-15 | 919 | `0x2ac8f3cf26926fff5778384c6af8c4da426a17eeb377d64db25e226bd3b65ffd` | [tx](https://chainscan.0g.ai/tx/0x69e35e929009c2d09922f961ab04d326dcbedb4e6d92cf1d741b2084dd39bbb1) |
| 2026-11-16 | 679 | `0xaf1a2e9d90e203786fced22ad479e6cfe88f564245e024dab7ad9bbee23e8892` | [tx](https://chainscan.0g.ai/tx/0x2304c03e83508ebbc5b31fb63f09703dfc1a301cf8136a2cf5d70f37635a11be) |
| 2026-11-17 | 724 | `0x504a3ff78a40cb9275034250a72b2f3d51d9ef56626610c7d9478c324c910cde` | [tx](https://chainscan.0g.ai/tx/0xe711c2c18d059b2d2270389b886fbcf32b12177f7d60e4830550c12c370ef5d8) |

The evidence seals from 24 Sep to 15 Nov 2026 were uploaded once, together:
root `0xb846f0d803536b16eb401ecd7db3b9b48b7f2b810cb4e2799a699bd374145489`
([tx](https://chainscan.0g.ai/tx/0x97ef4e2bfa024d148d3271e7e0da086c9501401045aa53d1d5d4ac5714dfd33a)).

## 0G Chain

| Contract | Address | Notes |
| --- | --- | --- |
| MihenkPay v2 | [`0xA4461bA5791D32C541081DEf50DF2eFC6E3a611F`](https://chainscan.0g.ai/address/0xA4461bA5791D32C541081DEf50DF2eFC6E3a611F) | Deployed 13 Nov 2026 from [`src/MihenkPay.sol`](../../src/MihenkPay.sol), Sourcify exact match. Token: Bridged USDC (USDC.e) [`0x1f3a…473e`](https://chainscan.0g.ai/address/0x1f3aa82227281ca364bfb3d253b0f1af1da6473e). |
| MihenkRecords | [`0x4d1f3aB10f21b6995769F4d26195cCB69225eF9C`](https://chainscan.0g.ai/address/0x4d1f3aB10f21b6995769F4d26195cCB69225eF9C) | Deployed 18 Nov 2026 from [`src/MihenkRecords.sol`](../../src/MihenkRecords.sol), Sourcify exact match. Writer: Mihenk's archive wallet `0xB3298604C606c14FF6B5958AC5CFa64BfcbCa476`. |

**Mihenk Pay on 0G.** A project locks a KOL's fee in USDC.e. The KOL accepts from the payout wallet, Mihenk verifies the
post, and the contract pays the KOL; whatever is not earned goes back to the project. Projects create campaigns from their own
wallet on Mihenk's payment page; 0G is one of the networks there.

**MihenkRecords on 0G.** Every day after the archive upload, two roots are written for the previous UTC day:
`0G_STORAGE_DAILY` (the storage root of the day's archive) and `EVIDENCE_SEAL` (the evidence archive's Merkle root).
`rootOf(kind, day)` reads a record (`kind`: 32-byte ASCII label, `day`: `YYYYMMDD`). A record can be written once and never
changed, so the chain shows when each root existed. The evidence seals back to 24 Sep 2026 were written on 18 Nov 2026.
The same roots also go to MihenkRecords on Arbitrum One
([`0x8774c56FAB137a9Ed11EbE2816F8eD6FBcE4f57B`](https://arbiscan.io/address/0x8774c56FAB137a9Ed11EbE2816F8eD6FBcE4f57B), Sourcify exact match).
