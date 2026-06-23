import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

// Regression guard: the main surface containers must not re-introduce a centered
// max-width column. They fill the content area full-width and align left, to
// match the other surfaces (board / monitoring / command / lab / ide), which
// have no centered column. This is an intentional divergence from the v2
// prototype, which centers .ov-scroll and .cp-inner; per design direction the
// dashboard overrides that for cross-surface consistency. If a prototype
// re-sync re-adds `margin: 0 auto` + `max-width`, these tests fail on purpose.
//
// Reading-width columns (.thread-inner / .kw-thread-inner / .composer-inner at
// 980px) are a separate reading-line-length concern and intentionally stay
// centered — they are not covered here.

const read = (file: string): string => readFileSync(resolve(__dirname, file), 'utf-8')

describe('main surfaces are full-width (no centered max-width column)', () => {
  it('.ov-scroll (overview) fills width and does not center', () => {
    const d = declarationsForSelector(read('surfaces-v2.css'), '.ov-scroll')
    expect(d['max-width']).toBeUndefined()
    expect(d.margin).toBeUndefined()
    expect(d.width).toBe('100%')
  })

  it('.wk-inner (work) fills width and does not center', () => {
    const d = declarationsForSelector(read('work-v2.css'), '.wk-inner')
    expect(d['max-width']).toBeUndefined()
    expect(d.margin).toBeUndefined()
    expect(d.width).toBe('100%')
  })

  it('.cp-inner (cockpit) does not center', () => {
    const d = declarationsForSelector(read('cockpit-v2.css'), '.cp-inner')
    expect(d['max-width']).toBeUndefined()
    expect(d.margin).toBeUndefined()
    expect(d['flex-direction']).toBe('column')
  })

  it('reading-width columns stay centered (not affected)', () => {
    const thread = declarationsForSelector(read('keeper-workspace.css'), '.kw-thread-inner')
    expect(thread['max-width']).toContain('--kw-thread-w')
    expect(thread.margin).toBe('0 auto')
  })
})
