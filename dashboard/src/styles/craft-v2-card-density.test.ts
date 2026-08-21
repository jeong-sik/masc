// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

// The density card-padding rule used to select cards with `[class*="-card"]`.
// Substring matching cannot tell a card from a card's header: it also padded
// `.ov-card-h`, `.set-card-b-wide`, and (via the Tailwind utility
// `rounded-card`) every chat avatar. The set is enumerated now, which only
// stays correct if a newly added card class joins the list. This test is that
// obligation: every `*-card` class the stylesheets define must either be in the
// list or state its own padding.

const stylesDir = resolve(__dirname)

function cssFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) return cssFiles(path)
    return name.endsWith('.css') ? [path] : []
  })
}

const craft = readFileSync(resolve(stylesDir, 'craft-v2.css'), 'utf-8')
/** Comments carry the tombstone note naming the old selector; strip them. */
const craftRules = craft.replace(/\/\*[\s\S]*?\*\//g, '')

function enumeratedCards(): Set<string> {
  const match = craft.match(/\.v2-app\[data-density\] :is\(([\s\S]*?)\)\s*\{/)
  if (!match) throw new Error('density card rule not found in craft-v2.css')
  return new Set(match[1].split(',').map((s) => s.trim().replace(/^\./, '')).filter(Boolean))
}

/** Classes whose name ends in `-card` (plus bare `card`) — the container names. */
function declaredCardClasses(): Map<string, Set<string>> {
  const byClass = new Map<string, Set<string>>()
  for (const file of cssFiles(stylesDir)) {
    const css = readFileSync(file, 'utf-8')
    for (const m of css.matchAll(/\.([a-zA-Z][\w-]*-card)\b(?![\w-])/g)) {
      if (!byClass.has(m[1])) byClass.set(m[1], new Set())
      byClass.get(m[1])!.add(file)
    }
  }
  return byClass
}

/** True when some rule whose selector names the class also declares padding. */
function statesOwnPadding(cls: string, files: Set<string>): boolean {
  const selectorHasClass = new RegExp(`\\.${cls}\\b(?![\\w-])`)
  for (const file of files) {
    const css = readFileSync(file, 'utf-8')
    for (const block of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      if (selectorHasClass.test(block[1]) && /(^|[\s;])padding\s*:/.test(block[2])) return true
    }
  }
  return false
}

describe('craft-v2.css density card set', () => {
  it('selects cards by name, never by substring', () => {
    expect(craftRules).not.toMatch(/\[class\*="-card"\]/)
  })

  it('covers every declared *-card container class', () => {
    const listed = enumeratedCards()
    const uncovered = [...declaredCardClasses()]
      .filter(([cls, files]) => !listed.has(cls) && !statesOwnPadding(cls, files))
      .map(([cls]) => cls)
    expect(uncovered).toEqual([])
  })

  it('keeps the rule at (0,3,0) so a component can state its own density padding', () => {
    // `.ctx-card` is the case that regressed: the design gives it 14px/15px at
    // the spacious step (keeper-v2/craft.css), which a higher-specificity
    // blanket rule silently overrode with 16px/18px.
    const rule = craft.match(/\.v2-app\[data-density\] :is\([\s\S]*?\)\s*\{/)?.[0] ?? ''
    expect(rule).not.toMatch(/:not\(/)
  })
})
