import { describe, expect, it } from 'vitest'

import { VALID_TABS } from '../types'
import { TAB_SURFACE } from './dashboard-shell'

describe('TAB_SURFACE', () => {
  it('resolves every routable tab to a dedicated component and label', () => {
    const components = VALID_TABS.map(tab => {
      const surface = TAB_SURFACE[tab]
      expect(surface.label.length).toBeGreaterThan(0)
      expect(surface.Component).toBeTypeOf('function')
      return surface.Component
    })

    expect(new Set(components).size).toBe(VALID_TABS.length)
  })

  it('cannot alias an unknown tab to Overview', () => {
    const overview = TAB_SURFACE.overview.Component
    for (const tab of VALID_TABS) {
      if (tab !== 'overview') expect(TAB_SURFACE[tab].Component).not.toBe(overview)
    }
  })
})
