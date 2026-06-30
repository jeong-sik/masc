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

describe('board-v2.css pixel parity with Claude-Design prototype', () => {
  // Guards the odd-px spacing values against the even-number drift a parallel
  // session introduced on main. Each value cites its prototype source line
  // ("/Users/dancer/Downloads/v2 2/project/keeper-v2"/styles/surfaces.css).
  const cases: Array<{ selector: string; prop: string; value: string; src: string }> = [
    { selector: '.v2-board-surface .bd-rail', prop: 'padding', value: '14px 9px', src: 'surfaces.css:278' },
    { selector: '.v2-board-surface .bd-rail h4', prop: 'margin', value: '0 0 8px 7px', src: 'surfaces.css:279' },
    // type ladder T4 (surfaces.css:768) wins over base in the prototype
    { selector: '.v2-board-surface .bd-rail h4', prop: 'font-size', value: 'var(--fs-9)', src: 'v2.css:101 --fs-t4' },
    { selector: '.v2-board-surface .bd-rail h4', prop: 'font-weight', value: '600', src: 'v2.css:101 --fw-t4' },
    { selector: '.v2-board-surface .bd-sub', prop: 'padding', value: '7px 9px', src: 'surfaces.css:280' },
    { selector: '.v2-board-surface .bd-feed-head', prop: 'padding', value: '11px 18px', src: 'surfaces.css:290' },
    // type ladder T2 (surfaces.css:741) wins over base in the prototype
    { selector: '.v2-board-surface .bd-feed-head h2', prop: 'font-size', value: 'var(--fs-16)', src: 'v2.css:99 --fs-t2' },
    { selector: '.v2-board-surface .bd-list', prop: 'padding', value: '14px 18px', src: 'surfaces.css:298' },
    { selector: '.v2-board-surface .bd-post-h', prop: 'gap', value: '9px', src: 'surfaces.css:305' },
    { selector: '.v2-board-surface .bd-post-body', prop: 'margin-top', value: '5px', src: 'surfaces.css:319' },
    { selector: '.v2-board-surface .bd-post-foot', prop: 'gap', value: '7px', src: 'surfaces.css:322' },
    { selector: '.v2-board-surface .bd-react', prop: 'gap', value: '5px', src: 'surfaces.css:323' },
    { selector: '.v2-board-surface .bd-stateblock', prop: 'margin-top', value: '9px', src: 'surfaces.css:331' },
    { selector: '.v2-board-surface .bd-stateblock', prop: 'padding', value: '9px 12px', src: 'surfaces.css:331' },
    { selector: '.v2-board-surface .bd-composer', prop: 'padding', value: '10px 18px 14px', src: 'surfaces.css:337' },
    { selector: '.v2-board-surface .bd-comp-tab', prop: 'padding', value: '4px 11px', src: 'surfaces.css:339' },
    { selector: '.v2-board-surface .bd-comp-box', prop: 'padding', value: '5px 5px 5px 13px', src: 'surfaces.css:341' },
    { selector: '.v2-board-surface .bd-detail-h', prop: 'gap', value: '9px', src: 'surfaces.css:348' },
    { selector: '.v2-board-surface .bd-detail-scroll', prop: 'gap', value: '11px', src: 'surfaces.css:352' },
    { selector: '.v2-board-surface .bd-th', prop: 'gap', value: '9px', src: 'surfaces.css:353' },
    { selector: '.v2-board-surface .bd-th-hd', prop: 'gap', value: '7px', src: 'surfaces.css:354' },
    { selector: '.v2-board-surface .bd-mention-row', prop: 'gap', value: '9px', src: 'surfaces.css:358' },
    { selector: '.v2-board-surface .bd-mention-row', prop: 'padding', value: '9px 10px', src: 'surfaces.css:358' },
  ]

  for (const { selector, prop, value, src } of cases) {
    it(`${selector} ${prop} == ${value} (prototype ${src})`, () => {
      expect(ruleDecls(selector)[prop]).toBe(value)
    })
  }
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
