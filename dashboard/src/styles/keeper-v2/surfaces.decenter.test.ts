import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from '../css-test-utils'

// Regression guard: in the keeper-v2 skin (vendored prototype CSS SSOT), the main
// surface containers fill the content area full-width instead of the prototype's
// centered max-width column. Overview and Work share .ov-scroll; Cockpit uses
// .cp-inner. This is an intentional, design-directed divergence from the
// prototype — if a prototype re-sync re-adds `max-width` + `margin: 0 auto`,
// these tests fail on purpose.

const css = readFileSync(resolve(__dirname, 'surfaces.css'), 'utf-8')

describe('keeper-v2 main surfaces are full-width (no centered column)', () => {
  it('.ov-scroll (overview + work) fills width and does not center', () => {
    const d = declarationsForSelector(css, '.ov-scroll')
    expect(d['max-width']).toBeUndefined()
    expect(d.margin).toBeUndefined()
    expect(d.width).toBe('100%')
  })

  it('.cp-inner (cockpit) does not center', () => {
    const d = declarationsForSelector(css, '.cp-inner')
    expect(d['max-width']).toBeUndefined()
    expect(d.margin).toBeUndefined()
    expect(d['flex-direction']).toBe('column')
  })
})

// Regression guard: board detail collapse is driven by the inline
// --bd-detail-width custom property, so the keeper-v2 .bd-body grid must consume
// it as the third track (set to 0 by board-surface.ts when no detail is open).
// If a prototype re-sync hardcodes the third track back to `minmax(290px, 360px)`
// without the var, collapse silently stops working once the legacy board-v2.css
// grid is removed (main.ts:114 migration) — this test fails on purpose so the
// single source of truth is not lost. Pairs with board-surface.test.ts, which
// asserts the runtime value (0px collapsed / width open).
describe('keeper-v2 board grid consumes --bd-detail-width (collapse SSOT)', () => {
  it('the base .bd-body grid uses var(--bd-detail-width) as its third track', () => {
    // declarationsForSelector merges the responsive .bd-body override (a 2-track
    // mobile grid inside a media query) with the base rule, so assert against the
    // base rule text directly: some .bd-body block drives its grid from the
    // property. If a prototype re-sync hardcodes the track without the var, this
    // fails before the collapse silently breaks post-migration.
    expect(css).toMatch(
      /\.bd-body\s*\{[^}]*grid-template-columns:[^;]*var\(--bd-detail-width/,
    )
  })

  it('no .bd-body.no-detail rule remains (replaced by the inline property)', () => {
    expect(() => declarationsForSelector(css, '.bd-body.no-detail')).toThrow(
      /Selector not found/,
    )
  })
})
