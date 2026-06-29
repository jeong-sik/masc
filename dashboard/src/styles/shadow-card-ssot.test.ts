import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

// Guards the --shadow-card cascade after the dead-decl removal in
// variables.css. The rendered values below were measured with
// getComputedStyle across data-theme × data-volt on 2026-06-30 (dev server,
// html[data-skin="v2"]):
//
//   theme=default/dark-fantasy : :root --shadow-card = 0 1px 3px /.5  (skin-v2)
//   theme=paper                : :root --shadow-card = 0 1px 2px /.06 (paper)
//   theme=styleseed            : :root --shadow-card = 0 1px 3px /.5
//   .gd-board (any theme)      :       --shadow-card = 0 2px 8px /.35 (own)
//
// The variables.css :root --shadow-card (0 1px 3px /.04) never appeared in any
// measured root — it is dead because skin-v2.css (specificity 0,3,1) outranks
// :root. This test pins the structural invariants that keep that true; it does
// not re-run the browser (jsdom does not compute the cascade).

function declsFor(css: string, match: (selector: string) => boolean): Record<string, string> {
  const out: Record<string, string> = {}
  parse(css).walkRules((rule) => {
    // base-layer rules only; skip @media/@supports nesting
    if (rule.parent?.type === 'atrule') return
    if (!rule.selectors.some(match)) return
    rule.walkDecls((decl) => {
      out[decl.prop] = decl.value.trim()
    })
  })
  return out
}

const variables = readFileSync(resolve(__dirname, 'variables.css'), 'utf-8')
const skinV2 = readFileSync(resolve(__dirname, 'skin-v2.css'), 'utf-8')

describe('--shadow-card SSOT (getComputedStyle-verified 2026-06-30)', () => {
  it(':root in variables.css declares no --shadow-card (dead — skin-v2 wins)', () => {
    const root = declsFor(variables, (s) => s === ':root')
    expect(root['--shadow-card']).toBeUndefined()
  })

  it(':root keeps shadow-elevated/modal (skin-v2 does not redefine them — LIVE)', () => {
    const root = declsFor(variables, (s) => s === ':root')
    expect(root['--shadow-elevated']).toBe('0 4px 12px rgba(0, 0, 0, 0.08)')
    expect(root['--shadow-modal']).toBe('0 8px 24px rgba(0, 0, 0, 0.12)')
  })

  it('.gd-board keeps its own --shadow-card (LIVE: self-declaration beats inheritance)', () => {
    const gd = declsFor(variables, (s) => s === '.gd-board')
    expect(gd['--shadow-card']).toBe('0 2px 8px rgba(0, 0, 0, 0.35)')
  })

  it('skin-v2.css is the SSOT card shadow for default/dark-fantasy themes', () => {
    const skin = declsFor(
      skinV2,
      (s) =>
        s.includes('[data-skin="v2"]') &&
        s.includes(':not([data-theme="paper"]') &&
        !s.includes('[data-volt'),
    )
    expect(skin['--shadow-card']).toBe('0 1px 3px rgba(0,0,0,0.5)')
  })
})
