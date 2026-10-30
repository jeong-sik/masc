// Scores one screenshot set: mean SSIM between the design prototype and the
// parity page, per surface, ascending so the worst surface reads first.
// Batch design-parity scorer: SSIM(proto, live) per surface pair.
import { ssim } from './design-parity-ssim.mjs'
const [dir, pairsCsv] = process.argv.slice(2)
const pairs = pairsCsv.split(',').map(p => p.split(':'))
let sum = 0, n = 0
const rows = []
for (const [ps, ls] of pairs) {
  try {
    const v = ssim(`${dir}/proto-${ps}.png`, `${dir}/live-${ls}.png`)
    rows.push([ps, v]); sum += v; n++
  } catch (e) { rows.push([ps, NaN]); console.error(`${ps}: ${e.message}`) }
}
rows.sort((a, b) => a[1] - b[1])
for (const [s, v] of rows) console.log(`${s.padEnd(12)} ${Number.isFinite(v) ? v.toFixed(4) : 'ERR'}`)
console.log(`${'MEAN'.padEnd(12)} ${(sum / n).toFixed(4)}   (n=${n})`)
