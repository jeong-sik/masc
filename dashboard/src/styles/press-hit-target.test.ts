// Press feedback must not move the click hit-target (2026-06-25 fix, PR #22245).
//
// CSS `transform` is a single property: translate/scale functions do not
// compose. When :active applies `transform: translateY/scale(...)`, it
// overwrites any rest transform on the same element — e.g. .kp-more is
// centered with `top:50%; transform:translateY(-50%)` (-12px); a press
// transform replaces that and the button jumps 12px+ DURING the click. An
// edge click then has its mouseup land off the hit-target and the browser
// drops the `click` event ("버튼이 도망감 / 눌렀는데 아무 일도 안 일어남").
//
// Press feedback must use hit-stable properties (filter / opacity). This
// test pins that invariant for the two press sites: craft-v2.css (global
// button / [role="button"] / 18 v2 controls) and @utility pressable
// (ui.css).
//
// Non-vacuous: reintroducing `transform: translateY/scale` on any :active
// rule in these two files fails this test. Verified by reverting the fix
// (translateY(var(--press)) / scale(0.97)) — both `it` blocks fail.

import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'
import { describe, expect, it } from 'vitest'

// Read stylesheets as text from disk. Resolve relative to cwd, tolerating
// either the dashboard package root or the repo root (mirrors
// approvals-css-ownership.test.ts; import.meta.url is not a file: URL under
// the vitest module runner and `… ?raw` is stubbed to empty).
function readStyle(rel: string): string {
  const candidates = [
    resolve(process.cwd(), 'src/styles', rel),
    resolve(process.cwd(), 'dashboard/src/styles', rel),
  ]
  const found = candidates.find(existsSync)
  if (!found) {
    throw new Error(
      `press-hit-target.test: cannot locate ${rel} from cwd=${process.cwd()} (tried: ${candidates.join(', ')})`,
    )
  }
  return readFileSync(found, 'utf8')
}

// transform values that move the box — the hit-target shifters.
// `transform: none` is the absence of a transform and is allowed.
const HIT_SHIFTING_TRANSFORM = /(translate|scale|matrix)\(/

/** Return every :active rule declaration whose `transform` shifts the box. */
function activeHitShiftingTransforms(css: string): string[] {
  const hits: string[] = []
  parse(css).walkRules((rule) => {
    const isActive = rule.selectors.some((s) => s.includes(':active'))
    if (!isActive) return
    rule.walkDecls('transform', (decl) => {
      if (HIT_SHIFTING_TRANSFORM.test(decl.value)) {
        hits.push(`${rule.selector} → transform: ${decl.value}`)
      }
    })
  })
  return hits
}

describe('press feedback never shifts the :active hit-target (PR #22245)', () => {
  it('craft-v2.css :active rules use no translate/scale/matrix transform', () => {
    const hits = activeHitShiftingTransforms(readStyle('craft-v2.css'))
    expect(hits, hits.join('\n')).toEqual([])
  })

  it('ui.css :active rules (incl. @utility pressable) use no translate/scale/matrix transform', () => {
    const hits = activeHitShiftingTransforms(readStyle('ui.css'))
    expect(hits, hits.join('\n')).toEqual([])
  })
})
