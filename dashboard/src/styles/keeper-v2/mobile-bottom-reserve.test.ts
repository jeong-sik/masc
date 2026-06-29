import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

// Contract guard for the mobile shell regression fixed in the dashboard polish
// pass: the reskin dropped the `data-mpane` shell attribute but left the
// `.v2-body[data-mpane="chat"]` rules in v2.css as dead selectors. The bottom
// reserve (`padding-bottom: 58px`) was gated on `:not([data-mpane="chat"])`,
// which — with the attribute gone — was always true, so the 58px band stayed
// reserved even in keeper chat reading mode (nav hidden) and the composer
// floated above the viewport bottom. The reserve is now keyed off the live
// `.v2-app[data-reading="true"]` attribute instead.

const v2Css = readFileSync(resolve(__dirname, 'v2.css'), 'utf-8')
const craftCss = readFileSync(resolve(__dirname, 'craft.css'), 'utf-8')

const SHELL_MOBILE_CHROME_BREAKPOINT = '900px'

function mediaRuleDecls(source: string, selector: string, maxWidth: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  parse(source).walkAtRules('media', (atRule) => {
    if (!atRule.params.includes(`max-width: ${maxWidth}`)) return
    atRule.walkRules((rule) => {
      if (!rule.selectors.includes(selector)) return
      rule.walkDecls((decl) => {
        declarations[decl.prop] = decl.value.trim()
      })
    })
  })
  return declarations
}

// `--pad-surface: <top> <inline> <bottom>` shorthand → the inline (L/R) token.
function inlinePad(padSurface: string): string {
  const parts = padSurface.split(/\s+/)
  return parts[1] ?? parts[0] ?? ''
}
const px = (v: string): number => Number.parseFloat(v)

describe('mobile bottom-bar reserve (data-reading, not dead data-mpane)', () => {
  it('has no selector gated on the dropped data-mpane attribute', () => {
    // `data-mpane` is never set by the app (the reskin dropped it). Any rule
    // gated on it is a dead selector — regressions hide here. (The word may
    // still appear in an explanatory comment; we only forbid it in selectors.)
    const deadSelectors: string[] = []
    parse(v2Css).walkRules((rule) => {
      if (rule.selector.includes('data-mpane')) deadSelectors.push(rule.selector)
    })
    expect(deadSelectors).toEqual([])
  })

  it('reserves the bottom-bar band only when NOT in reading mode', () => {
    const decls = mediaRuleDecls(
      v2Css,
      '.v2-app:not([data-reading="true"]) .v2-body',
      SHELL_MOBILE_CHROME_BREAKPOINT,
    )
    expect(decls['padding-bottom']).toBeDefined()
    expect(decls['padding-bottom']).toContain('58px')
  })
})

describe('mobile surface padding compresses per density tier (≤900px)', () => {
  // Desktop tiers (craft.css): spacious 42px / regular 26px / compact 18px
  // inline padding. On the single-column mobile shell these are disproportionate
  // (spacious 42px + 12px shell pad ≈ 27% of a 406px viewport).
  const DESKTOP_INLINE: Record<string, number> = { spacious: 42, regular: 26, compact: 18 }

  for (const tier of ['spacious', 'regular', 'compact'] as const) {
    it(`tightens --pad-surface inline padding for data-density="${tier}"`, () => {
      const decls = mediaRuleDecls(craftCss, `.v2-app[data-density="${tier}"]`, SHELL_MOBILE_CHROME_BREAKPOINT)
      const pad = decls['--pad-surface']
      expect(pad).toBeDefined()
      expect(px(inlinePad(pad))).toBeLessThan(DESKTOP_INLINE[tier])
    })
  }
})
