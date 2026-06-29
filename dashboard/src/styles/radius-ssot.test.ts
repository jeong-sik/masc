import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

// Guards the --radius-* cascade after the dead :root decl removal in
// variables.css. Rendered values measured with getComputedStyle on the dev
// server (2026-06-30):
//
//   app (html[data-skin=v2]) : xs 3 / sm 4 / md 6 / lg 10 / xl 8 / pill 999
//   preview (no data-skin)   : xs 2 / sm 4 / md 6 / lg 12 / xl 8 / pill 999
//   .gd-board (any theme)    : xs 2 / pill 9999  (own, LIVE via self-decl)
//
// The :root lg6/md4/sm3 (removed) never rendered: skin-v2.css (specificity
// 0,3,1) wins for the app and generated tokens.generated.css wins with no
// skin. The :root xl8 IS live (neither skin-v2 nor generated defines --radius-xl)
// and is kept. This test pins the structural invariants; it does not re-run
// the browser (jsdom does not compute the cascade).

function declsFor(css: string, match: (selector: string) => boolean): Record<string, string> {
  const out: Record<string, string> = {}
  parse(css).walkRules((rule) => {
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

describe('--radius-* SSOT (getComputedStyle-verified 2026-06-30)', () => {
  it(':root drops dead --radius-lg/md/sm (skin-v2 / generated win)', () => {
    const root = declsFor(variables, (s) => s === ':root')
    expect(root['--radius-lg']).toBeUndefined()
    expect(root['--radius-md']).toBeUndefined()
    expect(root['--radius-sm']).toBeUndefined()
  })

  it(':root keeps --radius-xl: 8px (LIVE — neither skin-v2 nor generated defines xl)', () => {
    const root = declsFor(variables, (s) => s === ':root')
    expect(root['--radius-xl']).toBe('8px')
  })

  it('.gd-board self-declares --radius-xs/pill (LIVE: self-declaration beats inheritance)', () => {
    const gd = declsFor(variables, (s) => s === '.gd-board')
    expect(gd['--radius-xs']).toBe('2px')
    expect(gd['--radius-pill']).toBe('9999px')
  })

  it('skin-v2.css is the canonical radius scale for the app', () => {
    const skin = declsFor(
      skinV2,
      (s) =>
        s.includes('[data-skin="v2"]') &&
        s.includes(':not([data-theme="paper"]') &&
        !s.includes('[data-volt'),
    )
    expect(skin['--radius-xs']).toBe('3px')
    expect(skin['--radius-sm']).toBe('4px')
    expect(skin['--radius-md']).toBe('6px')
    expect(skin['--radius-lg']).toBe('10px')
  })
})
