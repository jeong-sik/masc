import { describe, expect, it } from 'vitest'

import {
  COGNITIVE_MODE_ORDER,
  COGNITIVE_MODE_STATES,
  COGNITIVE_MODE_TARGETS,
  COCKPIT_ENTRYPOINTS,
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
      target: { tab: 'workspace', params: { section: 'repositories' } },
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
      'runtime',
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
    expect(cognitiveModeForRoute('workspace', { section: 'repositories' })).toBe('explode')
    expect(cognitiveModeForRoute('workspace', { mode: 'observe' })).toBe('cockpit')
  })

  it('normalizes human tab labels and prototype ids to stable aliases', () => {
    expect(normalizeCockpitEntrypoint('Goal · Horizon')).toBe('goal-horizon')
    expect(normalizeCockpitEntrypoint('SPLIT DIFF')).toBe('split-diff')
    expect(normalizeCockpitEntrypoint('Keeper / Tool Access')).toBe('keeper-tool-access')
  })

  it('targets registered dashboard sections for primary entrypoints', () => {
    for (const entrypoint of COCKPIT_ENTRYPOINTS) {
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
    expect(cockpitTargetForParams({ mode: 'Comms', tab: 'board-feed' })).toEqual({
      tab: 'board',
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
      params: { section: 'agents', view: 'keeper' },
    })
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'source' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
    })
  })

  it('ignores retired prototype subtab aliases', () => {
    expect(cockpitTargetForParams({ mode: 'EXPLODE' })).toEqual({
      tab: 'workspace',
      params: { section: 'repositories' },
    })
    expect(cockpitTargetForParams({ mode: 'Cognition', tab: 'keeper-tool-access' })).toEqual({
      tab: 'monitoring',
      params: { section: 'agents' },
    })
    expect(cockpitTargetForParams({ mode: 'IDE', tab: 'pr-thread' })).toEqual({
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'au-act' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime' },
    })
    expect(cockpitTargetForParams({ mode: 'Work', tab: 'acc-led' })).toEqual({
      tab: 'workspace',
      params: { section: 'planning' },
    })
    expect(cockpitTargetForParams({ mode: 'Observe', tab: 'ct-lat' })).toEqual({
      tab: 'monitoring',
      params: { section: 'runtime' },
    })
  })
})
