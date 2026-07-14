// Tab → content contract (WO-A4-3b). TAB_SURFACE is a Record<TabId, …>, so
// deleting a key is a COMPILE error — that is the primary mutation guard.
// This runtime walk pins the remaining holes the type system cannot see:
// every routable tab must resolve to a defined surface with a non-empty
// fallback label, and no non-overview tab may alias the Overview component
// (the pre-refactor switch's default arm silently did exactly that).

import { describe, expect, it } from 'vitest'
import { VALID_TABS } from './../types'
import { TAB_SURFACE } from './dashboard-shell'

describe('TAB_SURFACE contract', () => {
  it('resolves every VALID_TABS entry to a dedicated surface', () => {
    for (const tab of VALID_TABS) {
      const surface = TAB_SURFACE[tab]
      expect(surface, `missing surface for tab ${tab}`).toBeDefined()
      expect(surface.label.length, `empty label for tab ${tab}`).toBeGreaterThan(0)
      expect(surface.Component, `missing component for tab ${tab}`).toBeTypeOf('function')
    }
  })

  it('never renders the Overview fallback for a non-overview tab', () => {
    const overview = TAB_SURFACE.overview.Component
    for (const tab of VALID_TABS) {
      if (tab === 'overview') continue
      expect(TAB_SURFACE[tab].Component, `tab ${tab} aliases Overview`).not.toBe(overview)
    }
  })

  it('gives every tab its own component (no accidental aliasing)', () => {
    const components = VALID_TABS.map(tab => TAB_SURFACE[tab].Component)
    expect(new Set(components).size).toBe(VALID_TABS.length)
  })
})
