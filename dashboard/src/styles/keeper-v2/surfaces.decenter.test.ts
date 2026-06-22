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
