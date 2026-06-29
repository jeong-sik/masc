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
const globalCss = readFileSync(resolve(__dirname, '../global.css'), 'utf-8')
const variablesCss = readFileSync(resolve(__dirname, '../variables.css'), 'utf-8')
const appSource = readFileSync(resolve(__dirname, '../../app.ts'), 'utf-8')

// Resolve a `--token: <Npx>;` declaration from variables.css to its pixel number.
function tokenPx(prop: string): number {
  let value = ''
  parse(variablesCss).walkDecls((decl) => {
    if (decl.prop === prop) value = decl.value.trim()
  })
  return Number.parseFloat(value)
}

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

describe('mobile shell gutter is tightened (≤900px)', () => {
  // The shell gutter is owned by the ID-specificity rule `#main-content > div
  // { padding: var(--spacing-card) }` in global.css — NOT by the shell's
  // `dashboard-main-scroll p-4` utility classes, which lose the cascade to the
  // ID selector and never reach the element. An earlier attempt tightened the
  // gutter via `max-[900px]:px-2` on the shell className; that class generates
  // but is overridden by the ID rule, so it was a no-op at runtime. The real
  // lever is a mobile override on `#main-content > div`.

  it('does not rely on the dead max-[900px]:px-2 shell class (loses to the ID rule)', () => {
    const shellBranch = appSource.match(/dashboard-main-scroll[^'"`]*/)?.[0] ?? ''
    expect(shellBranch).not.toContain('px-2')
  })

  it('tightens #main-content > div inline padding on the mobile branch', () => {
    const decls = mediaRuleDecls(globalCss, '#main-content > div', SHELL_MOBILE_CHROME_BREAKPOINT)
    expect(decls['padding-inline']).toBe('var(--spacing-element)')
  })

  it('the mobile gutter token is smaller than the desktop --spacing-card', () => {
    // Desktop: `#main-content > div { padding: var(--spacing-card) }`.
    // Mobile steps down one semantic tier to --spacing-element.
    expect(tokenPx('--spacing-element')).toBeLessThan(tokenPx('--spacing-card'))
  })
})

describe('mobile surface padding compresses per density tier (≤900px)', () => {
  // Desktop tiers (craft.css): spacious 42px / regular 26px / compact 18px
  // inline padding. On the single-column mobile shell these are disproportionate
  // (spacious 42px + 12px shell pad ≈ 27% of a 406px viewport).
  const TIERS = [
    { tier: 'spacious', desktopInline: 42 },
    { tier: 'regular', desktopInline: 26 },
    { tier: 'compact', desktopInline: 18 },
  ] as const

  for (const { tier, desktopInline } of TIERS) {
    it(`tightens --pad-surface inline padding for data-density="${tier}"`, () => {
      const decls = mediaRuleDecls(craftCss, `.v2-app[data-density="${tier}"]`, SHELL_MOBILE_CHROME_BREAKPOINT)
      const pad = decls['--pad-surface'] ?? ''
      expect(pad).not.toBe('')
      expect(px(inlinePad(pad))).toBeLessThan(desktopInline)
    })
  }
})
