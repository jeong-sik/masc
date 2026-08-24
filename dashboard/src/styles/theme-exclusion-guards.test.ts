import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

import { OPT_IN_THEMES, themeExclusionSuffix } from '../lib/theme'

// Default/dark token sources load after the opt-in theme sources, so each one
// yields with a `:not([data-theme=...])` per opt-in theme. Adding a theme meant
// editing every guard by hand, and missing one silently reintroduced the
// override for that theme -- the assertions were literal selector strings, so
// the missed CSS site came with a missed test site (#21860).
//
// These check every guard against the list in lib/theme instead. A new theme
// fails here, once, naming the file and the selector that still has to yield.
const GUARDED_STYLESHEETS = [
  'src/styles/skin-v2.css',
  'src/styles/keeper-v2/tempered.css',
  'src/styles/ss-keeper-v2-bridge.css',
]

// A selector line that already excludes at least one theme is a guard: it has
// declared it must yield, so it has to yield to all of them. Comments mention
// the guard too, so they are stripped first -- a prose line matched on the
// first attempt and reported a gap that does not exist.
const GUARD_LINE = /:not\(\[data-theme="/

function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '')
}

function guardLines(file: string): string[] {
  return stripComments(readFileSync(resolve(process.cwd(), file), 'utf8'))
    .split('\n')
    .filter((line) => GUARD_LINE.test(line))
}

describe('opt-in theme exclusion guards', () => {
  it('every guard excludes every opt-in theme', () => {
    const gaps: string[] = []
    for (const file of GUARDED_STYLESHEETS) {
      for (const line of guardLines(file)) {
        for (const theme of OPT_IN_THEMES) {
          if (!line.includes(`:not([data-theme="${theme}"])`)) {
            gaps.push(`${file}: ${line.trim()} does not yield to ${theme}`)
          }
        }
      }
    }
    expect(gaps).toEqual([])
  })

  it('finds guards to check', () => {
    // A regex that matches nothing would make the check above vacuous.
    const total = GUARDED_STYLESHEETS.reduce((n, f) => n + guardLines(f).length, 0)
    expect(total).toBeGreaterThan(0)
  })

  it('the suffix helper matches what the stylesheets write', () => {
    const suffix = themeExclusionSuffix()
    const skin = readFileSync(resolve(process.cwd(), 'src/styles/skin-v2.css'), 'utf8')
    expect(skin).toContain(`html[data-skin="v2"]${suffix}`)
  })
})
