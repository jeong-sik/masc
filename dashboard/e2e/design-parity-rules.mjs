// Names the stylesheet rule that actually wins a property on a selector, via
// CDP getMatchedStylesForNode. Guessing which file owns a computed value across
// 60 sheets is how a re-sync breaks an intentional override.
import { chromium } from 'playwright'
const [url, selector, prop] = process.argv.slice(2)
const b = await chromium.launch()
const c = await b.newContext({ viewport: { width: 1600, height: 1000 } })
const p = await c.newPage()
await p.goto(url, { waitUntil: 'load', timeout: 45000 })
await p.waitForSelector(selector, { timeout: 30000 })
await p.waitForTimeout(1500)
const cdp = await c.newCDPSession(p)
await cdp.send('DOM.enable'); await cdp.send('CSS.enable')
const { root } = await cdp.send('DOM.getDocument')
const { nodeId } = await cdp.send('DOM.querySelector', { nodeId: root.nodeId, selector })
const { matchedCSSRules } = await cdp.send('CSS.getMatchedStylesForNode', { nodeId })
for (const m of matchedCSSRules) {
  const decls = m.rule.style.cssProperties.filter(d => !prop || d.name === prop || d.name.startsWith(prop))
  if (!decls.length) continue
  const href = m.rule.styleSheetId
  const origin = m.rule.origin
  let file = '(inline/UA)'
  try { const ss = await cdp.send('CSS.getStyleSheetText', { styleSheetId: href }); file = origin } catch {}
  console.log(`${m.rule.selectorList.text}  [${origin}]`)
  for (const d of decls) console.log(`    ${d.name}: ${d.value}`)
}
await b.close()
