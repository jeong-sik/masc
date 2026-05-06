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
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'ki-bdi' })).toEqual({
      tab: 'monitoring',
      params: { section: 'cognition', view: 'keeper', focus: 'bdi' },
    })
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'keeper-tool-access' })).toEqual({
      tab: 'monitoring',
      params: { section: 'cognition', view: 'keeper', focus: 'tool-access' },
    })
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'dc-mem' })).toEqual({
      tab: 'monitoring',
      params: { section: 'cognition', view: 'memory', focus: 'entries' },
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

  it('routes the covered IDE search entrypoint directly to the find panel', () => {
    const entrypoint = COCKPIT_ENTRYPOINTS.find(entry => entry.aliases.includes('find'))

    expect(entrypoint?.coverage).toBe('covered')
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'search' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', find: 'open' },
    })
    expect(cockpitTargetForParams({ mode: 'CODE', tab: 'find' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', find: 'open' },
    })
  })
})
