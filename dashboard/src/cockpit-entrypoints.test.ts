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
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'pr-thread' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'unified', focus: 'review' },
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

  it('routes covered C3 composer variants to focused quick intervention modes', () => {
    const variants = [
      ['cm-bc', 'broadcast'],
      ['cm-mn', 'mention'],
      ['cm-st', 'state'],
    ] as const

    for (const [alias, focus] of variants) {
      const entrypoint = COCKPIT_ENTRYPOINTS.find(entry => entry.aliases.includes(alias))
      expect(entrypoint?.coverage).toBe('covered')
      expect(cockpitTargetForParams({ mode: 'Comms', tab: alias })).toEqual({
        tab: 'command',
        params: { section: 'operations', view: 'ops', focus },
      })
    }
  })
  it('marks IDE review entrypoints as covered review focus routes', () => {
    const byAlias = new Map(COCKPIT_ENTRYPOINTS.flatMap(entrypoint =>
      entrypoint.aliases.map(alias => [alias, entrypoint] as const),
    ))

    expect(byAlias.get('review')).toMatchObject({
      coverage: 'covered',
      target: { tab: 'code', params: { section: 'ide-shell', view: 'unified', focus: 'review' } },
    })
    expect(byAlias.get('pr-thread')).toMatchObject({
      coverage: 'covered',
      target: { tab: 'code', params: { section: 'ide-shell', view: 'unified', focus: 'review' } },
    })
  })

  it('marks planning focus cockpit entries as route-covered', () => {
    const byAlias = new Map(COCKPIT_ENTRYPOINTS.flatMap(entrypoint =>
      entrypoint.aliases.map(alias => [alias, entrypoint] as const),
    ))

    expect(byAlias.get('task-st')?.coverage).toBe('covered')
    expect(byAlias.get('acc-led')?.coverage).toBe('covered')
    expect(byAlias.get('acc-mtx')?.coverage).toBe('covered')
    expect(cockpitTargetForParams({ mode: 'Work', tab: 'acc-led' })).toEqual({
      tab: 'workspace',
      params: { section: 'planning', focus: 'accountability-ledger' },
    })
    expect(cockpitTargetForParams({ mode: 'Work', tab: 'acc-mtx' })).toEqual({
      tab: 'workspace',
      params: { section: 'planning', focus: 'accountability-matrix' },
    })
  })

  it('marks cost cockpit entries as route-covered focus surfaces', () => {
    const byAlias = new Map(COCKPIT_ENTRYPOINTS.flatMap(entrypoint =>
      entrypoint.aliases.map(alias => [alias, entrypoint] as const),
    ))

    expect(byAlias.get('ct-agt')?.coverage).toBe('covered')
    expect(byAlias.get('ct-mtx')?.coverage).toBe('covered')
    expect(byAlias.get('ct-lat')?.coverage).toBe('covered')
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'ct-agt' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost', focus: 'agent' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'ct-mtx' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost', focus: 'matrix' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'ct-lat' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost', focus: 'latency' },
    })
  })
})
