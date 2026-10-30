// Looks for wiring vocabulary in *rendered* text, not in source.
//
// The design's cleanup plan (prototypes/keeper-v2/notes/cleanup-plan.md, the
// 2026-08-18 cut) puts field names, enums, producer and trace ids, WFQ,
// capacity_backpressure, p95 and not_observed behind a "기술 상세" toggle or a
// tooltip — off the operator's screen. A source grep cannot tell a rendered
// string from a variable name, so this walks the live DOM instead.
import { chromium } from 'playwright'

const TOKENS = [
  'WFQ', 'capacity_backpressure', 'not_observed', 'p95', 'producer_id',
  'trace_id', 'post_id', 'request_id', 'keeper_id', 'goal_id', 'task_id',
  'enum', 'schema_version', 'envelope',
]
const BASE = process.env.LIVE_BASE || 'http://localhost:5181/dashboard/#'

const b = await chromium.launch()
const c = await b.newContext({ viewport: { width: 1600, height: 1000 } })
const hits = new Map()
for (const s of process.argv.slice(2)) {
  const p = await c.newPage()
  try {
    await p.goto(`${BASE}${s}`, { waitUntil: 'load', timeout: 60000 })
    await p.waitForSelector('.v2-app', { timeout: 30000 })
    await p.waitForTimeout(2500)
    const found = await p.evaluate((tokens) => {
      const out = []
      const walk = document.createTreeWalker(document.querySelector('.v2-app'), NodeFilter.SHOW_TEXT)
      let n
      while ((n = walk.nextNode())) {
        const txt = (n.nodeValue || '').trim()
        if (!txt) continue
        const el = n.parentElement
        if (!el || el.offsetParent === null) continue
        for (const t of tokens) {
          if (txt.includes(t)) {
            out.push(`${t} :: "${txt.slice(0, 70)}" in .${(typeof el.className === 'string' ? el.className : '').split(/\s+/)[0]}`)
          }
        }
      }
      return out
    }, TOKENS)
    for (const f of found) {
      const tok = f.split(' :: ')[0]
      if (!hits.has(tok)) hits.set(tok, [])
      hits.get(tok).push(`${s}: ${f.slice(tok.length + 4)}`)
    }
  } catch (e) {
    console.log(`FAIL ${s}: ${String(e).split('\n')[0].slice(0, 90)}`)
  }
  await p.close()
}
await b.close()
if (!hits.size) { console.log('no wiring vocabulary rendered on the surfaces scanned') }
for (const [tok, where] of [...hits].sort((a, b) => b[1].length - a[1].length)) {
  console.log(`\n${tok} — ${where.length} rendered occurrence(s)`)
  where.slice(0, 4).forEach(w => console.log(`    ${w}`))
}
