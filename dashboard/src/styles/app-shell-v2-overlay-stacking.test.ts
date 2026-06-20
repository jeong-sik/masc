// @vitest-environment happy-dom
//
// Regression guard for the `.v2-app > *` stacking rule (app-shell-v2.css).
//
// Tailwind v4's `.fixed` / `.absolute` / `.top-5` / `.right-5` utilities are
// emitted inside `@layer utilities`. A bare unlayered `.v2-app > * { position:
// relative }` silently overrides the layered `.fixed` of any direct-child
// overlay, dropping it into normal flow. That is exactly what pushed the toast
// host off-screen to the bottom of the `h-screen; overflow-hidden` shell column.
//
// happy-dom resolves no cascade/layout, so this defect is invisible to a normal
// component test. This guard asserts the SOURCE rule stays in a lower cascade
// layer than Tailwind utilities, locking the fix against a future unlayered
// revert or overlay-class allowlist.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
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

function topLevelLayerOrder(): string[] {
  const order: string[] = []
  parse(css).walkAtRules('layer', (rule) => {
    if (rule.parent?.type !== 'root') return
    if (rule.nodes !== undefined) return
    for (const name of rule.params.split(',')) {
      order.push(name.trim())
    }
  })
  return order
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

  it('declares app-shell before utilities so Tailwind positioning wins', () => {
    const order = topLevelLayerOrder()
    expect(order).toContain('app-shell')
    expect(order).toContain('utilities')
    expect(order.indexOf('app-shell')).toBeLessThan(order.indexOf('utilities'))
  })

  it('does not bake overlay class exclusions into the shell child selector', () => {
    const positionRules = v2AppChildRules().filter((r) => r.decls.position !== undefined)
    for (const rule of positionRules) {
      expect(rule.selector).toBe('.v2-app > *')
      expect(rule.selector).not.toContain(':not(')
    }
  })
})
