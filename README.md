# Mihenk Pay

Condition-based USDC payments between crypto projects and KOLs (influencers). Part of [Mihenk AI](https://mihenkai.com).

Mihenk AI measures which crypto KOLs really move the market: real reach (median views per post, not followers), bot-screened audiences, and every coin call scored against BTC. Mihenk Pay uses those measurements to settle KOL deals on-chain. The project locks the fee in USDC, the KOL accepts from the payout wallet, and the contract releases the money only when Mihenk verifies the post. Whatever isn't earned goes back to the project.

**Live on Arc mainnet, Base mainnet and Monad mainnet** with native USDC. Current version: **v2** (22 Oct 2026, addresses below).

## How it works

1. **Lock.** The project (or its agency) locks the fee for one KOL in a supported stablecoin (USDC, or any standard ERC-20 the owner allows). Terms are agreed off-chain; only their hash goes on-chain.
2. **Accept.** The KOL accepts from the payout wallet. This proves the wallet belongs to the KOL before any money moves.
3. **Verify and settle.** After the post has stayed live for the agreed period, Mihenk posts the result. The project sets a minimum time on-chain, counted from the KOL's acceptance, before which Mihenk cannot settle. One part of the fee is earned on delivery, the rest when the real-reach target is met. Only a hash of the measurement report goes on-chain.
4. **Dispute window.** Either side can dispute within the window (24 hours to 14 days, 3 days by default). The owner resolves with a corrected payout.
5. **Close.** Anyone can finalize after the window. The KOL receives the earned amount minus Mihenk's fee; the project gets back everything not earned.

If Mihenk never settles before the deadline, the project can reclaim the full amount. An unresolved dispute falls back to Mihenk's result after 30 days. If the token refuses a payout (for example to a USDC-blacklisted address), the other payouts still go through and the refused amount is credited to that address, which can claim it later itself. Funds can never be stuck.

## Design choices

- **Payouts are never tied to a token's price.** Paying KOLs for price moves would reward pumping. Mihenk pays for delivery and real reach only.
- **Commercial terms stay confidential.** No social handles on-chain; the chain holds only hashes of the terms and of the result.
- **Fee rate and fee recipient are fixed per campaign** at creation; the rate is hard-capped at 10%, so neither can change after a project has funded.
- **Separate roles.** The owner, the verifier and the fee recipient are separate addresses; `Deploy.s.sol` can hand ownership to a Safe multisig (`OWNER`).
- **Fee-on-transfer tokens are rejected**, and every token must be allow-listed.
- **Two-step ownership**, reentrancy guards, SafeERC20, custom errors.

## Setup

```
git clone https://github.com/MihenkAI/mihenk-pay-contracts && cd mihenk-pay-contracts
git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
git clone --depth 1 --branch v5.1.0 https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
forge test
```

## Tests

37 Foundry tests, including a fuzz test proving that every unit locked always ends up with the KOL, the project or the fee recipient (paid out, or credited for claim when an address is blacklisted), and nothing is stuck in the contract.

## Deploy

```
DEPLOYER_KEY=... VERIFIER=0x... FEE_RECIPIENT=0x... TOKEN=0x... OWNER=0x<safe> \
forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast
```

If `TOKEN` is empty, a testnet-only `TestUSD` with an open faucet is deployed and allow-listed. `DISPUTE_WINDOW` defaults to 3 days (minimum 24 hours). `script/DemoLive.s.sol` runs the full flow on a live network with a real stablecoin.

On Arc, USDC is the native gas token and its ERC-20 interface (`0x3600…0000`) is backed by a precompile that Foundry's local EVM does not implement, so `forge script` cannot simulate token calls there. Deployment works with `forge script`; the Arc demo campaign below was sent with `cast send`, letting the node estimate gas.

## Deployments

### v2 (live since 22 Oct 2026)

Deployed with `script/Deploy.s.sol` from this code. Owner [`0x9e366c62f1310115e5832af0d46c6f26f8a1e0b4`](https://basescan.org/address/0x9e366c62f1310115e5832af0d46c6f26f8a1e0b4); verifier and fee recipient `0x845B9cff41Eb67e56673375D842b7C5b949Cc7aA`; fee 3%; dispute window 3 days; native USDC allow-listed. Source verified on Sourcify (exact match) on all three networks.

| Network | MihenkPay v2 | Deploy transaction |
| --- | --- | --- |
| Arc mainnet (5042) | [0x7aB655F4c8F5C960E22a95E7694A6B5bA1531211](https://explorer.arc.io/address/0x7aB655F4c8F5C960E22a95E7694A6B5bA1531211) | [0x40817f7473…](https://explorer.arc.io/tx/0x40817f7473c51db3b4432aa0c8d18e6f24e1cd646cc967afbf74d5ffc3494c65) |
| Base mainnet (8453) | [0x6170DeEe0F3146E83D00F482B7364108dAD4b6de](https://basescan.org/address/0x6170DeEe0F3146E83D00F482B7364108dAD4b6de) | [0xde7374ffcd…](https://basescan.org/tx/0xde7374ffcd651c5daec9f454e09ef350ea7ee4413be15f30702ac8e99a00c9c9) |
| Monad mainnet (143) | [0x45f1710e871F0113D47CEce6C9D9dDB823B7Ba52](https://monadvision.com/address/0x45f1710e871F0113D47CEce6C9D9dDB823B7Ba52) | [0x4376c22089…](https://monadvision.com/tx/0x4376c220896fa171b09339c0654014c6121b7627fd59133608d7f6eab0a93055) |

What changed from v1, after issues were reported to us once v1 was live:

- A payout the token refuses (for example a USDC-blacklisted KOL, project or fee recipient) no longer blocks the other payouts. In v1 one such address could leave a settled campaign with no way out once the dispute window had passed; in v2 the refused amount is credited to that address and only that address can `claim(token)` it.
- The fee recipient is fixed per campaign at creation, like the fee rate.
- `createCampaign` takes `minLive`: the verifier cannot settle earlier than `minLive` seconds after the KOL accepts, and settlement must still fit before `settleDeadline`.
- The dispute window is at least 24 hours (v1 deployments ran with 1 hour).
- On Monad the owner is now a separate key from the verifier.
- Campaigns are read with `getCampaign(id)`.

### v1 (closed to new campaigns)

The first mainnet deployments each ran one 2-USDC demo campaign, all finalized. On 22 Oct 2026 USDC was removed from their allow-list, so no new campaign can be created there; they hold no funds.

| Network | MihenkPay v1 | USDC removed |
| --- | --- | --- |
| Arc mainnet | [0xd49Da88a030Ac997C5fda06E84752e9f4d9b7b72](https://explorer.arc.io/address/0xd49Da88a030Ac997C5fda06E84752e9f4d9b7b72) | [0xa371e767bd…](https://explorer.arc.io/tx/0xa371e767bd0acdc7a0fd48e3e30361f935ab5ddf3d093d41e2cf85f66390c6f6) |
| Base mainnet | [0xb5842Ea5b537C17DBda1F81d753b3969632107a9](https://basescan.org/address/0xb5842Ea5b537C17DBda1F81d753b3969632107a9) | [0xc7a0caf3b5…](https://basescan.org/tx/0xc7a0caf3b514475c299894200bd6f57293853d2852a431a2ec7a2f54726a94d5) |
| Monad mainnet | [0x95b35D96678f6a9aef9C5f09F95a0D9add06eFfb](https://monadvision.com/address/0x95b35D96678f6a9aef9C5f09F95a0D9add06eFfb) | [0xde6c8ed5a6…](https://monadvision.com/tx/0xde6c8ed5a682f5228d328b56b9d80c3c1bd376f759c1f49f85ed875b1d449628) |

The v1 demo campaigns follow.

#### Arc mainnet v1 (chain ID 5042)

Live with native USDC ([`0x3600000000000000000000000000000000000000`](https://explorer.arc.io/address/0x3600000000000000000000000000000000000000)). Source verified on Sourcify (exact match). The USDC used here was moved from Base to Arc with Circle CCTP V2 and the forwarding service ([burn on Base](https://basescan.org/tx/0xd7c28654dec2e4af81c863787b6b0c5ffc0be6c934fe15a10b784143489b2c32), [mint on Arc](https://explorer.arc.io/tx/0x24db70c203ecd718ae876d1bebe4a5b8732398d9b36add10e7657e00fb153b17)).

| Contract | Address |
| --- | --- |
| MihenkPay | [0xd49Da88a030Ac997C5fda06E84752e9f4d9b7b72](https://explorer.arc.io/address/0xd49Da88a030Ac997C5fda06E84752e9f4d9b7b72) |

Demo campaign #1 with 2 USDC: a real, organic KOL post measured by Mihenk AI, replayed as a paid campaign (no actual sponsorship took place). 50% earned on delivery, 50% on reaching 20,000 real views, 1-hour dispute window. Delivery and reach were both met.

| Step | Transaction |
| --- | --- |
| Project locks 2 USDC | [0x06826a768d…](https://explorer.arc.io/tx/0x06826a768dd3c87f6e002b2d6fa0814cef160e77763c6a46fdf6bca8b88bb55e) |
| KOL accepts from payout wallet | [0x056de246ee…](https://explorer.arc.io/tx/0x056de246ee7c588ad9c2d40bc40b7865aad1386ffc7e3828c32457217fe96a6c) |
| Mihenk settles (delivered + reach hit) | [0xdeb13c1b26…](https://explorer.arc.io/tx/0xdeb13c1b265fa483459afaaf79f7e7bf00a356412fc96c830176ada1a86f3c47) |
| Finalize: KOL receives 1.94 USDC (2 minus 3% fee) | [0x991737722c…](https://explorer.arc.io/tx/0x991737722c1f274df9a6e81bc2c0e0c7e0417e977927f268a7f3a99ceaa49a51) |

#### Base mainnet v1 (chain ID 8453)

Live with USDC ([`0x8335…2913`](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)). Source verified on Sourcify.

| Contract | Address |
| --- | --- |
| MihenkPay | [0xb5842Ea5b537C17DBda1F81d753b3969632107a9](https://basescan.org/address/0xb5842Ea5b537C17DBda1F81d753b3969632107a9) |

Same demo campaign with 2 USDC:

| Step | Transaction |
| --- | --- |
| Project locks 2 USDC | [0xf2c1ff0c94…](https://basescan.org/tx/0xf2c1ff0c94fe1bf799859f046ae1c2bd79be8661c55b18fd914e154fe4a3c1a6) |
| KOL accepts from payout wallet | [0xb526c0c5d1…](https://basescan.org/tx/0xb526c0c5d1cf54a05fb90708332b96bb8280005c494a8fcd919032b23c1f802b) |
| Mihenk settles (delivered + reach hit) | [0xb5c718f8a2…](https://basescan.org/tx/0xb5c718f8a2523b9c7bdd5aa23a2c156ff937c3788a1273e75965ea096491c224) |
| Finalize: KOL receives 1.94 USDC (2 minus 3% fee) | [0x03e629ff6f…](https://basescan.org/tx/0x03e629ff6fb9d7f6b3d0a5de97128fdb71506d34c81f4c6dbaedc86334f3fcd2) |

Base Builder Code: transactions sent from these scripts on Base mainnet carry Mihenk AI's Builder Code (`bc_s415ugdv`, [ERC-8021](https://eip.tools/eip/8021)) at the end of the calldata, so Base attributes the activity to Mihenk AI. See `script/BuilderCode.sol`; the contract ignores the suffix, and `test/BuilderCode.t.sol` runs a full campaign with tagged calldata. The demo campaign above was sent before the Builder Code was added.

#### Monad mainnet v1 (chain ID 143)

Live with USDC ([0x7547…b603](https://monadvision.com/address/0x754704Bc059F8C67012fEd69BC8A327a5aafb603)). Source verified on Sourcify.

| Contract | Address |
| --- | --- |
| MihenkPay | [0x95b35D96678f6a9aef9C5f09F95a0D9add06eFfb](https://monadvision.com/address/0x95b35D96678f6a9aef9C5f09F95a0D9add06eFfb) |

| Step | Transaction |
| --- | --- |
| Project locks 2 USDC | [0x36563ffb5b…](https://monadvision.com/tx/0x36563ffb5b23eb558e2c6dd6eeaa7b58d92ef0e8fcb7924a6e19c19decb89d97) |
| KOL accepts from payout wallet | [0x78aa74891b…](https://monadvision.com/tx/0x78aa74891b09752cc8ef3e85be9e2fda9ae4f3477ade860cc0d0537491b8692d) |
| Mihenk settles (delivered + reach hit) | [0x3d037663fd…](https://monadvision.com/tx/0x3d037663fd27615dff415deff3c420cb69070c9319cc7e79a1ae20472687fc46) |
| Finalize: KOL receives 1.94 USDC, contract balance back to 0 | [0x648b5c0901…](https://monadvision.com/tx/0x648b5c09013745750e6d2b0fb1d3943df66fd730c8a7ec3e9def9ebc673088c5) |

#### Robinhood Chain testnet v1 (chain ID 46630)

| Contract | Address |
| --- | --- |
| MihenkPay | [0x6170DeEe0F3146E83D00F482B7364108dAD4b6de](https://explorer.testnet.chain.robinhood.com/address/0x6170DeEe0F3146E83D00F482B7364108dAD4b6de) |
| TestUSD (testnet-only stablecoin) | [0xd49Da88a030Ac997C5fda06E84752e9f4d9b7b72](https://explorer.testnet.chain.robinhood.com/address/0xd49Da88a030Ac997C5fda06E84752e9f4d9b7b72) |

On every network, only `keccak256` hashes of the terms file and the measurement report are stored (`termsHash`, `resultHash`). The files themselves name the KOL, so they stay off-chain and are shared only with the parties.

## Status

The contracts have not had an external audit yet. Live deployments are used for demo campaigns with small amounts; client campaigns at scale come after an audit. Security reports are welcome at hello@mihenkai.com.

## Roadmap

- Connect settlement to Mihenk's live measurement pipeline (post detection, time live, bot-screened reach).
- "Approve and pay" inside Mihenk's existing proposal builder: the client approves a KOL list and funds the campaign in one step, paying with USDC from any chain through CCTP.
- Agent payments: let AI agents fund and settle KOL campaigns in USDC (x402-style flows).
- Write each campaign's result on-chain as a portable KOL track record.

## License

MIT
