import { describe, expect, it } from 'vitest'

import {
  COGNITIVE_MODE_ORDER,
  COGNITIVE_MODE_STATES,
  COGNITIVE_MODE_TARGETS,
  COCKPIT_ENTRYPOINTS,
  COCKPIT_LEGACY_ENTRYPOINTS,
  COCKPIT_MODE_TARGETS,
  cognitiveModeForCockpitMode,
  cognitiveModeForRoute,
  cockpitTargetForParams,
  normalizeCognitiveMode,
  normalizeCockpitEntrypoint,
} from './cockpit-entrypoints'
import { sectionItemsForTab } from './config/navigation'

describe('cockpit entrypoint registry', () => {
  const visibleAliases = () => COCKPIT_ENTRYPOINTS.flatMap(entrypoint => entrypoint.aliases)
  const legacyAliases = () => COCKPIT_LEGACY_ENTRYPOINTS.flatMap(entrypoint => entrypoint.aliases)

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
      'explode',
    ])
  })

  it('keeps the four cognitive modes explicit and route-backed', () => {
    expect(COGNITIVE_MODE_ORDER).toEqual(['cockpit', 'code', 'split', 'explode'])
    expect(Object.keys(COGNITIVE_MODE_TARGETS)).toEqual(COGNITIVE_MODE_ORDER)
    expect(COGNITIVE_MODE_STATES.cockpit).toMatchObject({
      load: 'situational',
      layout: 'all-panels',
      target: { tab: 'overview' },
    })
    expect(COGNITIVE_MODE_STATES.code).toMatchObject({
      load: 'focused',
      layout: 'editor-first',
      target: { tab: 'code', params: { section: 'ide-shell', view: 'source' } },
    })
    expect(COGNITIVE_MODE_STATES.split).toMatchObject({
      load: 'comparative',
      layout: 'side-by-side',
      target: { tab: 'code', params: { section: 'ide-shell', view: 'split-diff' } },
    })
    expect(COGNITIVE_MODE_STATES.explode).toMatchObject({
      load: 'exploratory',
      layout: 'graph-map',
      target: { tab: 'workspace', params: { section: 'repositories', view: 'graph' } },
    })
  })

  it('keeps the visible cockpit command map to ten primary aliases', () => {
    const aliases = visibleAliases()

    expect(COCKPIT_ENTRYPOINTS).toHaveLength(10)
    expect(aliases).toEqual([
      'goal-horizon',
      'task-board',
      'board-feed',
      'composer',
      'cascade',
      'audit',
      'safety',
      'cost',
      'keeper-cognition',
      'source',
    ])
    expect(new Set(aliases).size).toBe(10)
    expect(aliases).not.toContain('ct-lat')
    expect(aliases).not.toContain('cs-deep')
    expect(aliases).not.toContain('pr-thread')
  })

  it('keeps old prototype aliases as legacy redirects instead of visible commands', () => {
    const visible = new Set(visibleAliases())
    const legacy = legacyAliases()

    for (const alias of ['ct-lat', 'cs-deep', 'pr-thread', 'dc-mem', 'acc-led']) {
      expect(visible.has(alias)).toBe(false)
      expect(legacy).toContain(alias)
    }
  })

  it('normalizes cognitive mode aliases from cockpit routes', () => {
    expect(normalizeCognitiveMode(' CODE ')).toBe('code')
    expect(cognitiveModeForCockpitMode('Work')).toBe('cockpit')
    expect(cognitiveModeForCockpitMode('terminal')).toBe('code')
    expect(cognitiveModeForCockpitMode('split')).toBe('split')
    expect(cognitiveModeForCockpitMode('EXPLODE')).toBe('explode')
    expect(cognitiveModeForCockpitMode('unknown')).toBeNull()
  })

  it('infers cognitive mode from canonical route state', () => {
    expect(cognitiveModeForRoute('overview')).toBe('cockpit')
    expect(cognitiveModeForRoute('code', { section: 'ide-shell', view: 'source' })).toBe('code')
    expect(cognitiveModeForRoute('code', { section: 'ide-shell', view: 'split-diff' })).toBe('split')
    expect(cognitiveModeForRoute('workspace', { section: 'repositories', view: 'graph' })).toBe('explode')
    expect(cognitiveModeForRoute('workspace', { mode: 'observe' })).toBe('cockpit')
  })

  it('normalizes human tab labels and prototype ids to stable aliases', () => {
    expect(normalizeCockpitEntrypoint('Goal · Horizon')).toBe('goal-horizon')
    expect(normalizeCockpitEntrypoint('SPLIT DIFF')).toBe('split-diff')
    expect(normalizeCockpitEntrypoint('Keeper / Tool Access')).toBe('keeper-tool-access')
  })

  it('targets registered dashboard sections for primary and legacy entrypoints', () => {
    for (const entrypoint of [...COCKPIT_ENTRYPOINTS, ...COCKPIT_LEGACY_ENTRYPOINTS]) {
      const section = entrypoint.target.params?.section
      if (!section) continue
      const knownSections = sectionItemsForTab(entrypoint.target.tab).map(item => item.params.section)
      expect(knownSections, `${entrypoint.mode}:${entrypoint.aliases[0]}`).toContain(section)
    }
  })

  it('resolves primary cockpit aliases to canonical production routes', () => {
    expect(cockpitTargetForParams({ mode: 'Work', tab: 'goal-horizon' })).toEqual({
      tab: 'workspace',
      params: { section: 'planning', view: 'goal-tree' },
    })
    expect(cockpitTargetForParams({ mode: 'Comms', tab: 'composer' })).toEqual({
      tab: 'command',
      params: { section: 'operations', view: 'ops' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'cost' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost' },
    })
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'keeper-cognition' })).toEqual({
      tab: 'monitoring',
      params: { section: 'cognition', view: 'keeper' },
    })
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'source' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
    })
  })

  it('keeps legacy prototype subtabs routeable without re-exposing them in the command map', () => {
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'edit' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
    })
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'split-diff' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'split-diff' },
    })
    expect(cockpitTargetForParams({ mode: 'EXPLODE' })).toEqual({
      tab: 'workspace',
      params: { section: 'repositories', view: 'graph' },
    })
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
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'au-act' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'audit', focus: 'actor' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'audit-summary' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'audit', focus: 'summary' },
    })
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'find' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', find: 'open' },
    })
    expect(cockpitTargetForParams({ mode: 'Comms', tab: 'cm-bc' })).toEqual({
      tab: 'command',
      params: { section: 'operations', view: 'ops', focus: 'broadcast' },
    })
    expect(cockpitTargetForParams({ mode: 'Work', tab: 'acc-led' })).toEqual({
      tab: 'workspace',
      params: { section: 'planning', focus: 'accountability-ledger' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'ct-lat' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost', focus: 'latency' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'cascade-compare' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'inspector', focus: 'compare' },
    })
  })
})
