import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

// Regression guard for the chat header's deliberate divergences from the
// keeper-v2 prototype.
//
// The live header already dual-emits the prototype's `chat-head` alongside
// `kw-chat-head`, so the vendored skin owns the shared properties. The
// remaining `kw-*` rules are NOT a stale mimic — each one carries a fix or a
// state the prototype does not have. main.ts loads keeper-v2/v2.css after
// keeper-workspace.css, so a same-specificity prototype rule wins; adopting
// the prototype class on these nodes would therefore silently undo the fix.
//
// This pins the divergences so a later prototype re-sync has to argue with a
// failing test instead of quietly regressing them.

const read = (file: string): string => readFileSync(resolve(__dirname, file), 'utf-8')

/** Declarations of the top-level (non-media) rules for one selector, merged in
 *  source order. declarationsForSelector() is media-blind and would fold the
 *  mobile overrides into the same object, which is what this guard must not
 *  compare against. */
function baseDeclarations(css: string, selector: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  let found = false

  parse(css).walkRules((rule) => {
    if (rule.parent?.type !== 'root') return
    if (!rule.selectors.includes(selector)) return
    found = true
    rule.walkDecls((decl) => {
      declarations[decl.prop] = decl.value.trim()
    })
  })

  if (!found) throw new Error(`Selector not found at top level: ${selector}`)
  return declarations
}

const live = (): string => read('keeper-workspace.css')
const proto = (): string => read('keeper-v2/v2.css')

describe('chat header divergences from the keeper-v2 prototype', () => {
  it('.kw-chat-id keeps a desktop min-width the prototype zeroes', () => {
    // Paired with the header's flex-wrap: without a floor here the flex:none
    // action row squeezes the identity to width:0 and the name overflows the
    // buttons at 3-pane laptop widths (keeper-workspace.css:526-530). The
    // mobile block deliberately relaxes it back to 0 — that is a narrow-screen
    // decision, not the desktop contract this pins.
    expect(baseDeclarations(live(), '.kw-chat-id')['min-width']).toBe('9rem')
    expect(baseDeclarations(proto(), '.chat-id')['min-width']).toBe('0')
  })

  it('.kw-chat-head wraps where the prototype does not', () => {
    expect(baseDeclarations(live(), '.kw-chat-head')['flex-wrap']).toBe('wrap')
    // The prototype leaves flex-wrap unset, which is why dual-emitting
    // `chat-head` is safe: the live rule supplies what the prototype omits.
    expect(baseDeclarations(proto(), '.chat-head')['flex-wrap']).toBeUndefined()
  })

  it('.kw-state-pill carries runtime states the prototype pill lacks', () => {
    // statePillTone() (keeper-workspace-shared.ts:153) is total over
    // run|warn|bad|busy|off. The prototype only styles run|pause|off, so
    // dropping the kw- variants would render warn/bad/busy as the base pill.
    const liveCss = live()
    const protoCss = proto()
    for (const variant of ['warn', 'bad', 'busy']) {
      expect(() => baseDeclarations(liveCss, `.kw-state-pill.${variant}`)).not.toThrow()
      expect(() => baseDeclarations(protoCss, `.state-pill.${variant}`)).toThrow()
    }
  })
})
