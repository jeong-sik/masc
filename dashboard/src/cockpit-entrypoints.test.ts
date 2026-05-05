import { describe, expect, it } from 'vitest'

import {
  COCKPIT_ENTRYPOINTS,
  COCKPIT_MODE_TARGETS,
  cockpitTargetForParams,
  normalizeCockpitEntrypoint,
} from './cockpit-entrypoints'
import { sectionItemsForTab } from './config/navigation'

describe('cockpit entrypoint registry', () => {
  it('keeps every prototype plane mode mapped to a production route', () => {
    expect(Object.keys(COCKPIT_MODE_TARGETS)).toEqual([
      'dashboard',
      'cockpit',
      'work',
      'comms',
      'observe',
      'cognition',
      'ide',
      'code',
      'split',
      'terminal',
    ])
  })

  it('normalizes human tab labels and prototype ids to stable aliases', () => {
    expect(normalizeCockpitEntrypoint('Goal · Horizon')).toBe('goal-horizon')
    expect(normalizeCockpitEntrypoint('SPLIT DIFF')).toBe('split-diff')
    expect(normalizeCockpitEntrypoint('Keeper / Tool Access')).toBe('keeper-tool-access')
  })

  it('targets registered dashboard sections for every cockpit sub-entrypoint', () => {
    for (const entrypoint of COCKPIT_ENTRYPOINTS) {
      const section = entrypoint.target.params?.section
      if (!section) continue
      const knownSections = sectionItemsForTab(entrypoint.target.tab).map(item => item.params.section)
      expect(knownSections, `${entrypoint.mode}:${entrypoint.aliases[0]}`).toContain(section)
    }
  })

  it('resolves prototype subtabs to explicit live route homes', () => {
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'dc-str' })).toEqual({
      tab: 'monitoring',
      params: { section: 'cognition', view: 'decisions' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'sa-dash' })).toEqual({
      tab: 'command',
      params: { section: 'operations', view: 'safety' },
    })
    expect(cockpitTargetForParams({ mode: 'CODE', tab: 'graph' })).toEqual({
      tab: 'workspace',
      params: { section: 'repositories', view: 'graph' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'heuristic-log' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'heuristics', focus: 'log' },
    })
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'ar-fnd' })).toEqual({
      tab: 'monitoring',
      params: { section: 'cognition', view: 'autoresearch', focus: 'finding' },
    })
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'ar-flow' })).toEqual({
      tab: 'monitoring',
      params: { section: 'cognition', view: 'autoresearch', focus: 'flow' },
    })
  })
})
