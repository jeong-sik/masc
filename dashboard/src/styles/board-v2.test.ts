import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

const css = readFileSync(resolve(__dirname, 'board-v2.css'), 'utf-8')

function mobileBoardDetailDecls(): Record<string, string> {
  const declarations: Record<string, string> = {}

  parse(css).walkAtRules('media', (atRule) => {
    if (!atRule.params.includes('max-width: 900px')) return

    atRule.walkRules((rule) => {
      if (!rule.selectors.includes('.v2-board-surface .bd-detail.has-post')) return
      if (!rule.selectors.includes('.v2-board-surface .bd-detail.is-mentions.is-mobile-open')) return

      rule.walkDecls((decl) => {
        declarations[decl.prop] = decl.value.trim()
      })
    })
  })

  return declarations
}

describe('board-v2.css mobile detail overlay', () => {
  it('reserves mobile shell tab clearance for thread and mention detail panels', () => {
    const declarations = mobileBoardDetailDecls()

    expect(declarations.left).toBe('0')
    expect(declarations.bottom).toBe('calc(46px + env(safe-area-inset-bottom, 0px))')
    expect(declarations.width).toBe('100%')
  })
})

function ruleDecls(selector: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  parse(css).walkRules((rule) => {
    // skip rules nested inside @media so the base-layer decls are read
    if (rule.parent?.type === 'atrule') return
    if (!rule.selectors.includes(selector)) return
    rule.walkDecls((decl) => {
      declarations[decl.prop] = decl.value.trim()
    })
  })
  return declarations
}

describe('board-v2.css type ladder parity (prototype resolved values)', () => {
  it('matches the prototype T2 region title size for the feed head (--fs-t2=16px)', () => {
    // Prototype: surfaces.css TYPE LADDER (.bd-feed-head h2 -> T2) loads after
    // the base rule and wins, so the rendered size is --fs-t2=16px, not 15px.
    // Our .v2-board-surface prefix raises specificity above the ladder, so the
    // literal must mirror the resolved T2 size.
    const decls = ruleDecls('.v2-board-surface .bd-feed-head h2')
    expect(decls['font-size']).toBe('16px')
    expect(decls['font-weight']).toBe('600')
    expect(decls['font-family']).toBe('var(--font-display)')
  })

  it('matches the prototype T4 micro-label tier for the rail heading (--fs-t4=9px, --fw-t4=600)', () => {
    // Prototype: surfaces.css TYPE LADDER (.bd-rail h4 -> T4) loads after the
    // base rule and wins (9px / weight 600), not the base 9.5px / weight 500.
    const decls = ruleDecls('.v2-board-surface .bd-rail h4')
    expect(decls['font-size']).toBe('9px')
    expect(decls['font-weight']).toBe('600')
    expect(decls['letter-spacing']).toBe('0.2em')
    expect(decls['text-transform']).toBe('uppercase')
    expect(decls['font-family']).toBe('var(--font-ui)')
    expect(decls['color']).toBe('var(--text-dim)')
  })
})

describe('board-v2.css author sigil (SigilBadge prototype parity)', () => {
  it('renders the base sigil as a solid volt fill with a 5px radius and dark glyph', () => {
    const decls = ruleDecls('.v2-board-surface .bd-sigil')

    // prototype board.jsx:8 inline borderRadius:5 — literal, not --radius-sm (4px)
    expect(decls['border-radius']).toBe('5px')
    // solid fill (prototype v2.css:485 .msg-av.op background:var(--volt)), not a wash
    expect(decls.background).toBe('var(--volt)')
    expect(decls.color).toBe('var(--volt-ink)')
    expect(decls['font-weight']).toBe('700')
  })

  it('keeps the operator sigil on a solid volt fill rather than volt-wash', () => {
    const decls = ruleDecls('.v2-board-surface .bd-sigil.op')

    expect(decls.background).toBe('var(--volt)')
    expect(decls.background).not.toBe('var(--volt-wash)')
    expect(decls.color).toBe('var(--volt-ink)')
  })
})
