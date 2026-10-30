// Names the UI the dashboard renders that the design does not.
//
// Every other probe here asks "does the dashboard have what the design has".
// This asks the reverse: which components are on screen that the mock never
// draws. Some are real capability the mock could not model — a live backend has
// connection state, an emergency stop, a version badge. Some are leftovers. The
// probe does not judge; it produces the list to review.
import { chromium } from 'playwright'

const PROTO = 'http://127.0.0.1:8979/prototypes/keeper-v2/Keeper%20Agent%20v5.html?surface='
const LIVE = process.env.LIVE_BASE || 'http://localhost:5181/dashboard/#'

const CLASSES = `(() => {
  const out = new Set()
  for (const el of document.querySelectorAll('.v2-app *')) {
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue
    const cn = typeof el.className === 'string' ? el.className : ''
    for (const c of cn.trim().split(/\\s+/)) {
      // Skip Tailwind utilities and state modifiers: they are not components.
      if (!c || c.length < 4) continue
      // Tailwind utilities, variants and arbitrary values are not components.
      if (c.includes(':') || c.includes('[') || c.includes('/')) continue
      if (/^(is-|has-|on$|active|open|flex|grid|items-|justify-|text-|bg-|px-|py-|mx-|my-|mt-|mb-|ml-|mr-|pt-|pb-|pl-|pr-|gap-|w-|h-|min-|max-|rounded|border|shrink|grow|absolute|relative|inline|hidden|overflow|whitespace|font-|leading-|tracking-|truncate|select-|cursor-|transition|group|size-|self-|space-|animate|fade|slide|zoom|duration|delay|ease|fill-mode|sr-only|skip-link|order-|z-|top-|left-|right-|bottom-|opacity-|shadow|ring|outline|pointer-|touch-|scroll-|snap-|list-|align-|place-|col-|row-|basis-|object-|aspect-|backdrop|filter|blur|contrast|invert|saturate|sepia|origin-|rotate-|scale-|translate|skew-|first|last|only|odd|even|visited|checked|disabled|indeterminate|placeholder|before|after|marker|file|selection|caret|accent|appearance|resize|will-change|content-)/.test(c)) continue
      out.add(c)
    }
  }
  return [...out]
})()`

const b = await chromium.launch()
const c = await b.newContext({ viewport: { width: 1600, height: 1000 } })

async function classesAt(url, waitSel = '.v2-app') {
  const p = await c.newPage()
  try {
    await p.goto(url, { waitUntil: 'load', timeout: 60000 })
    await p.waitForSelector(waitSel, { timeout: 30000 })
    await p.waitForTimeout(2500)
    return new Set(await p.evaluate(CLASSES))
  } catch { return new Set() } finally { await p.close() }
}

for (const [protoSurface, liveSurface] of process.argv.slice(2).map(a => a.split(':'))) {
  const design = await classesAt(PROTO + protoSurface)
  const live = await classesAt(LIVE + (liveSurface || protoSurface))
  const extra = [...live].filter(x => !design.has(x)).sort()
  console.log(`\n${protoSurface} → live-only components (${extra.length} of ${live.size} rendered)`)
  extra.slice(0, 30).forEach(x => console.log(`    .${x}`))
  if (extra.length > 30) console.log(`    … and ${extra.length - 30} more`)
}
await b.close()
