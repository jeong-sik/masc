import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

// Regression guard: the kanban board must not keep an explicit column template
// in its final cascade. The v3 prototype renders exactly 5 columns, so its
// repeat(5) base rule survives alongside the later horizontal-scroll override
// without visible damage. The live dashboard renders 9 protocol status columns
// (work.ts KANBAN_COLUMNS); with repeat(5) still effective the first five
// columns land in explicit minmax(0,1fr) tracks and get squeezed to ~65px while
// the implicit tracks hold 244px. The intentional divergence in keeper-v2/v2.css
// clears the template so every column sizes via grid-auto-columns. If a
// prototype re-sync drops the `unset`, this test fails on purpose.
//
// declarationsForSelector merges same-selector rules in source order, so the
// asserted values are the cascade-final ones (keeper-v2/v2.css loads after the
// *-v2.css glob in main.ts and owns the final word on shared selectors).

const read = (file: string): string => readFileSync(resolve(__dirname, file), 'utf-8')

describe('kanban swimlanes size via grid-auto-columns, not an explicit template', () => {
  it('.wk-kanban final cascade clears grid-template-columns', () => {
    const d = declarationsForSelector(read('keeper-v2/v2.css'), '.wk-kanban')
    expect(d['grid-template-columns']).toBe('unset')
    expect(d['grid-auto-flow']).toBe('column')
    expect(d['grid-auto-columns']).toBe('minmax(244px, 1fr)')
    expect(d['overflow-x']).toBe('auto')
  })
})
