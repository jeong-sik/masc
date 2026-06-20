// @vitest-environment happy-dom
//
// Regression guard for the cascade-layer ORDER that governs app-shell-v2.css.
//
// Two failure modes this file locks down, both seen in production:
//
//  1. Overlay stacking: Tailwind v4's `.fixed` / `.absolute` / `.top-5` utilities
//     live in `@layer utilities`. The `.v2-app > * { position: relative }` rule
//     must sit in a layer BELOW utilities (it is in `@layer app-shell`) so it does
//     not force positioned overlays (toast, modals) back into normal flow.
//
//  2. Cascade inversion (#21846): the canonical layer order is declared by a bare
//     `@layer …;` statement at the top of app-shell-v2.css. Because Tailwind v4
//     emits theme/base/components/utilities as cascade-layer BLOCKS (no leading
//     order statement of its own) which the Vite plugin injects AFTER the imported
//     stylesheets, whichever bare `@layer …;` statement is emitted first decides
//     precedence. #21846 used `@layer app-shell, theme-defaults, theme-overrides,
//     utilities;` — it pinned `utilities` before Tailwind's later base/components
//     blocks, so those blocks appended AFTER utilities and BEAT every utility class
//     (Preflight reset + components clobbered all of Tailwind). The statement must
//     name base AND components BEFORE utilities to preserve Tailwind's internal
//     `theme < base < components < utilities` order.
//
// happy-dom resolves no cascade/layout, so neither defect is visible to a DOM test.
// These checks parse the SOURCE statement; they are a sound proxy for the merged
// build order because (a) app-shell-v2.css is the SOLE source file declaring a
// utilities-naming bare `@layer` statement (asserted below) and (b) Tailwind's own
// blocks are emitted after it. The authoritative check remains `vite build` output.
import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

const css = readFileSync(resolve(__dirname, 'app-shell-v2.css'), 'utf-8')

interface ChildRule {
  selector: string
  decls: Record<string, string>
  layers: string[]
}

interface CssParent {
  type: string
  name?: string
  params?: string
  parent?: CssParent
}

function layerAncestors(rule: { parent?: CssParent }): string[] {
  const layers: string[] = []
  let parent = rule.parent
  while (parent !== undefined) {
    if (parent.type === 'atrule' && parent.name === 'layer' && parent.params !== undefined) {
      layers.push(parent.params.trim())
    }
    parent = parent.parent
  }
  return layers
}

/** Every rule whose selector targets the direct children of `.v2-app`
 *  (`.v2-app > *` …), with its declarations. */
function v2AppChildRules(): ChildRule[] {
  const rules: ChildRule[] = []
  parse(css).walkRules((rule) => {
    for (const selector of rule.selectors) {
      if (!/^\.v2-app\s*>\s*\*/.test(selector)) continue
      const decls: Record<string, string> = {}
      rule.walkDecls((decl) => {
        decls[decl.prop] = decl.value.trim()
      })
      rules.push({
        selector,
        decls,
        layers: layerAncestors(rule),
      })
    }
  })
  return rules
}

/** Names declared by each root-level bare `@layer a, b, c;` statement in [src]
 *  (block form `@layer x { … }` is excluded — only ordering statements). */
function bareLayerStatements(src: string): string[][] {
  const statements: string[][] = []
  parse(src).walkAtRules('layer', (rule) => {
    if (rule.parent?.type !== 'root') return
    if (rule.nodes !== undefined) return // block form, not an ordering statement
    statements.push(rule.params.split(',').map((name) => name.trim()))
  })
  return statements
}

function topLevelLayerOrder(): string[] {
  return bareLayerStatements(css).flat()
}

describe('app-shell-v2.css `.v2-app > *` stacking rule', () => {
  it('positions in-flow children with position:relative and z-index:1', () => {
    const positionRules = v2AppChildRules().filter((r) => r.decls.position !== undefined)
    expect(positionRules.length).toBeGreaterThan(0)
    for (const rule of positionRules) {
      expect(rule.decls.position).toBe('relative')
      expect(rule.decls['z-index']).toBe('1')
    }
  })

  it('keeps the shell child positioning rule in the app-shell cascade layer', () => {
    const positionRules = v2AppChildRules().filter((r) => r.decls.position !== undefined)
    for (const rule of positionRules) {
      expect(rule.layers).toContain('app-shell')
    }
  })

  it('orders app-shell + Tailwind base/components before utilities, theming after', () => {
    const order = topLevelLayerOrder()
    const idx = (name: string): number => {
      const i = order.indexOf(name)
      expect(i, `layer "${name}" must be named in the order statement`).toBeGreaterThanOrEqual(0)
      return i
    }
    const utilities = idx('utilities')
    // app-shell below utilities → positioned overlay utilities (.fixed) win (toast fix).
    expect(idx('app-shell')).toBeLessThan(utilities)
    // Tailwind's own layers must stay below utilities so utility classes override
    // Preflight/base/components. #21846 pinned utilities ahead of base/components and
    // inverted this, letting the Preflight reset clobber every utility class.
    expect(idx('theme')).toBeLessThan(utilities)
    expect(idx('base')).toBeLessThan(utilities)
    expect(idx('components')).toBeLessThan(utilities)
    // Theming layers above utilities so [data-theme="paper"] overrides win.
    expect(idx('theme-defaults')).toBeGreaterThan(utilities)
    expect(idx('theme-overrides')).toBeGreaterThan(utilities)
  })

  it('is the only source stylesheet that pins the utilities layer order', () => {
    // The merged cascade order is set by the first bare `@layer …;` statement emitted
    // before Tailwind's blocks. If another source file also declared a utilities-naming
    // bare statement it could be emitted first and re-invert the cascade. Keep
    // app-shell-v2.css the single authority so the checks above stay a sound proxy.
    const dir = __dirname
    const offenders = readdirSync(dir)
      .filter((file) => file.endsWith('.css') && file !== 'app-shell-v2.css')
      .filter((file) =>
        bareLayerStatements(readFileSync(resolve(dir, file), 'utf-8')).some((names) =>
          names.includes('utilities'),
        ),
      )
    expect(offenders).toEqual([])
  })

  it('does not bake overlay class exclusions into the shell child selector', () => {
    const positionRules = v2AppChildRules().filter((r) => r.decls.position !== undefined)
    for (const rule of positionRules) {
      expect(rule.selector).toBe('.v2-app > *')
      expect(rule.selector).not.toContain(':not(')
    }
  })
})
