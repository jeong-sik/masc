// @vitest-environment happy-dom
//
// Regression guard for the `.v2-app > *` stacking rule (app-shell-v2.css).
//
// Tailwind v4's `.fixed` / `.absolute` / `.top-5` / `.right-5` utilities are
// emitted inside `@layer utilities`, while every custom rule in app-shell-v2.css
// is unlayered. Per the CSS cascade, unlayered declarations always beat layered
// ones regardless of specificity — so a bare `.v2-app > * { position: relative }`
// silently overrides the layered `.fixed` of any direct-child overlay, dropping
// it into normal flow. That is exactly what pushed the toast host off-screen to
// the bottom of the `h-screen; overflow-hidden` shell column.
//
// happy-dom resolves no cascade/layout, so this defect is invisible to a normal
// component test. This guard asserts the SOURCE selector keeps positioned
// overlays excluded, locking the fix against a future revert to the bare form.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

const css = readFileSync(resolve(__dirname, 'app-shell-v2.css'), 'utf-8')

interface ChildRule {
  selector: string
  decls: Record<string, string>
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
      rules.push({ selector, decls })
    }
  })
  return rules
}

// The overlay classes that position themselves (Tailwind utility or custom
// class) and therefore must NOT be forced back to position:relative.
const EXCLUDED_OVERLAY_CLASSES = [':not(.fixed)', ':not(.absolute)', ':not(.dock-fab)', ':not(.twk-panel)']

describe('app-shell-v2.css `.v2-app > *` stacking rule', () => {
  it('positions in-flow children with position:relative and z-index:1', () => {
    const positionRules = v2AppChildRules().filter((r) => r.decls.position !== undefined)
    expect(positionRules.length).toBeGreaterThan(0)
    for (const rule of positionRules) {
      expect(rule.decls.position).toBe('relative')
      expect(rule.decls['z-index']).toBe('1')
    }
  })

  it('excludes every positioned overlay so the unlayered rule never clobbers a layered .fixed', () => {
    const positionRules = v2AppChildRules().filter((r) => r.decls.position !== undefined)
    for (const rule of positionRules) {
      for (const exclusion of EXCLUDED_OVERLAY_CLASSES) {
        expect(rule.selector).toContain(exclusion)
      }
    }
  })

  it('has no bare `.v2-app > *` rule that would force position onto overlays', () => {
    const bare = v2AppChildRules().find(
      (r) => /^\.v2-app\s*>\s*\*$/.test(r.selector) && r.decls.position !== undefined,
    )
    expect(bare).toBeUndefined()
  })
})
