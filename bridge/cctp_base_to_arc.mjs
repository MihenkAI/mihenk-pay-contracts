// Move USDC from Base to Arc with Circle Bridge Kit (CCTP V2).
// useForwarder: Circle's forwarding service completes the mint on Arc,
// so the receiving wallet needs no gas on Arc.
// We used this on 13 Oct 2026 to fund the Arc mainnet demo campaign:
//   burn on Base: 0xd7c28654dec2e4af81c863787b6b0c5ffc0be6c934fe15a10b784143489b2c32
//   mint on Arc:  0x24db70c203ecd718ae876d1bebe4a5b8732398d9b36add10e7657e00fb153b17
// Estimate only: SPONSOR_KEY=0x... AMOUNT=5.40 node cctp_base_to_arc.mjs
// Bridge:        SPONSOR_KEY=0x... AMOUNT=5.40 SEND=1 node cctp_base_to_arc.mjs
import { BridgeKit } from '@circle-fin/bridge-kit'
import { createViemAdapterFromPrivateKey } from '@circle-fin/adapter-viem-v2'

const kit = new BridgeKit()
const adapter = createViemAdapterFromPrivateKey({ privateKey: process.env.SPONSOR_KEY })
const amount = process.env.AMOUNT || '5.40'
const params = { from: { adapter, chain: 'Base' }, to: { adapter, chain: 'Arc', useForwarder: true }, amount }
const show = (x) => JSON.stringify(x, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 1)

try {
  const est = await kit.estimate(params)
  console.log('ESTIMATE', show({ fees: est.fees, gasFees: est.gasFees }))
} catch (e) {
  console.log('ESTIMATE ERROR', e?.message || e)
}

if (process.env.SEND === '1') {
  const r = await kit.bridge(params)
  console.log('RESULT', show({
    state: r.state,
    steps: (r.steps || []).map((s) => ({ name: s.name, state: s.state, txHash: s.txHash, explorerUrl: s.explorerUrl, error: s.errorMessage || s.error })),
  }))
}
