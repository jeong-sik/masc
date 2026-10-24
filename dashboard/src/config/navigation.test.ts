import { describe, expect, it } from 'vitest'

import {
  DASHBOARD_SURFACES,
  PRIMARY_DASHBOARD_NAV_ITEMS,
  PRIMARY_DASHBOARD_SURFACES,
  VISIBLE_DASHBOARD_NAV_ITEMS,
  defaultParamsForTab,
  isSectionlessSurface,
  normalizeRouteParams,
  sectionItemsForTab,
  visibleSectionItemsForTab,
} from './navigation'

describe('dashboard surface navigation', () => {

  it('exposes Keepers as a top-level v2 workspace without nested sections', () => {
    expect(defaultParamsForTab('keepers')).toEqual({})
    expect(VISIBLE_DASHBOARD_NAV_ITEMS.map(item => item.id)).toContain('keepers')
    expect(sectionItemsForTab('keepers')).toEqual([])
    expect(visibleSectionItemsForTab('keepers')).toEqual([])

    const result = normalizeRouteParams('keepers', { section: 'agents', keeper: 'sangsu', surface: 'old' })
    expect(result).toEqual({ keeper: 'sangsu' })
  })

  it('exposes Board as a top-level v2 surface without workspace section baggage', () => {
    expect(defaultParamsForTab('board')).toEqual({})
    expect(VISIBLE_DASHBOARD_NAV_ITEMS.map(item => item.id)).toContain('board')
    expect(sectionItemsForTab('board')).toEqual([])
    expect(visibleSectionItemsForTab('board')).toEqual([])

    const result = normalizeRouteParams('board', {
      section: 'board',
      post: 'post-1',
      comment: 'comment-1',
      focus: 'curation',
      surface: 'old',
    })
    expect(result).toEqual({
      post: 'post-1',
      comment: 'comment-1',
      focus: 'curation',
    })
  })

  it('labels the workspace route as the v2 Work surface while preserving route compatibility', () => {
    const workspace = DASHBOARD_SURFACES.find(surface => surface.id === 'workspace')

    expect(workspace?.label).toBe('Work')
    expect(defaultParamsForTab('workspace')).toEqual({ section: 'work' })
    expect(workspace?.defaultTab).toBe('workspace')
  })

  it('keeps the v2 primary shell aligned to the keeper-v2 prototype rail order', () => {
    expect(PRIMARY_DASHBOARD_SURFACES.map(surface => surface.id)).toEqual([
      'overview',
      'keepers',
      'registry',
      'monitoring',
      'workspace',
      'approvals',
      'schedule',
      'board',
      'fusion',
      'logs',
      'code',
      'connectors',
      'command',
      'lab',
      'settings',
    ])
    expect(PRIMARY_DASHBOARD_NAV_ITEMS.map(item => item.label)).toEqual([
      'Overview',
      'Keepers',
      'Registry',
      'Monitor',
      'Work',
      'Gate',
      'Schedule',
      'Board',
      'Fusion',
      'Logs',
      'IDE',
      'Connectors',
      'Command',
      'Lab',
      'Settings',
    ])
  })

  it('uses one sectionless-surface classifier for section stripping and section lookup', () => {
    const sectionless = ['overview', 'logs', 'settings', 'keepers', 'registry', 'board', 'schedule', 'approvals', 'fusion'] as const
    expect(sectionless.filter(id => isSectionlessSurface(id))).toEqual([...sectionless])
    expect(sectionItemsForTab('settings')).toEqual([])
    expect(normalizeRouteParams('settings', { section: 'legacy', surface: 'old', panel: 'theme' })).toEqual({
      panel: 'theme',
    })
    expect(normalizeRouteParams('settings', { section: 'runtimes', surface: 'old', panel: 'runtime' })).toEqual({
      section: 'runtimes',
      panel: 'runtime',
    })
    expect(normalizeRouteParams('settings', { section: 'account', panel: 'theme' })).toEqual({
      section: 'account',
      panel: 'theme',
    })
    expect(normalizeRouteParams('fusion', { section: 'legacy', surface: 'old', run_id: 'fus-1' })).toEqual({
      run_id: 'fus-1',
    })
  })

  it('exposes Schedule as a dedicated top-level v2 surface without lab section baggage', () => {
    expect(defaultParamsForTab('schedule')).toEqual({})
    expect(VISIBLE_DASHBOARD_NAV_ITEMS.map(item => item.id)).toContain('schedule')
    expect(sectionItemsForTab('schedule')).toEqual([])
    expect(visibleSectionItemsForTab('schedule')).toEqual([])

    const result = normalizeRouteParams('schedule', { section: 'tools', surface: 'lab', view: 'legacy' })
    expect(result).toEqual({ view: 'legacy' })
  })
})

describe('code (IDE plane) navigation', () => {
  it('exposes the production IDE plane in the sidebar', () => {
    expect(defaultParamsForTab('code')).toEqual({ section: 'ide-shell' })
    expect(DASHBOARD_SURFACES.find(surface => surface.id === 'code')?.hidden).not.toBe(true)
    expect(DASHBOARD_SURFACES.find(surface => surface.id === 'code')?.label).toBe('IDE')

    const visibleCodeSections = visibleSectionItemsForTab('code')
    const allCodeSections = sectionItemsForTab('code')

    expect(visibleCodeSections.map(item => item.id)).toEqual(['ide-shell'])
    expect(allCodeSections.map(item => item.id)).toEqual(['ide-shell'])
    expect(allCodeSections.map(item => item.label)).toEqual(['Code IDE'])
  })

  it('normalizes unknown code section to default ide-shell', () => {
    const result = normalizeRouteParams('code', { section: 'bogus' })
    expect(result.section).toBe('ide-shell')
  })
})

describe('lab navigation', () => {
  it('contains lab support surfaces', () => {
    expect(defaultParamsForTab('lab')).toEqual({ section: 'tools' })

    const labSections = visibleSectionItemsForTab('lab')

    expect(labSections.map(item => item.id)).toEqual([
      'tools',
      'harness',
      'keeper-memory-health',
    ])

    expect(labSections.map(item => item.label)).toEqual([
      'Tools',
      'Safety Harness',
      '키퍼 메모리 상태',
    ])
  })
})

describe('command navigation', () => {
  it('has only operations section (Phase 6+7: inspector absorbed; connectors split out)', () => {
    expect(defaultParamsForTab('command')).toEqual({ section: 'operations' })

    const commandSections = visibleSectionItemsForTab('command')

    expect(commandSections.map(item => item.id)).toEqual([
      'operations',
    ])

    expect(commandSections.map(item => item.label)).toEqual([
      'Actions',
    ])
  })
})

describe('connectors navigation (Phase 7, post-2026-04-30 merge)', () => {
  it('exposes connectors as a top-level surface with a single all-connectors section', () => {
    expect(defaultParamsForTab('connectors')).toEqual({ section: 'connector-status' })

    const sections = visibleSectionItemsForTab('connectors')
    expect(sections.map(item => item.id)).toEqual(['connector-status'])
    expect(sections.map(item => item.label)).toEqual(['All'])
  })

  it('normalizes unknown connectors section to default', () => {
    const result = normalizeRouteParams('connectors', { section: 'bogus' })
    expect(result.section).toBe('connector-status')
  })

  it('keeps only known connector route filters', () => {
    expect(normalizeRouteParams('connectors', {
      section: 'connector-status',
      connector: 'telegram',
      q: 'gate',
    })).toEqual({
      section: 'connector-status',
      connector: 'telegram',
      q: 'gate',
    })
    expect(normalizeRouteParams('connectors', {
      section: 'connector-status',
      connector: 'bogus',
      q: 'gate',
    })).toEqual({
      section: 'connector-status',
      q: 'gate',
    })
  })
})

describe('monitoring navigation labels', () => {
  it('uses keeper-fleet first Monitor IA labels', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('agents')).toBe('Keeper Fleet')
    expect(labelFor('fleet-health')).toBe('Tool Monitor')
    expect(labelFor('runtime')).toBe('Runtime')
    expect(labelFor('observatory')).toBe('Observatory')
    expect(labelFor('transport-health')).toBeUndefined()
    expect(labelFor('cognition')).toBeUndefined()
    expect(labelFor('journey')).toBeUndefined()
  })

  it('keeps monitoring descriptions concise instead of comma-heavy domain lists', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const descriptions = Object.fromEntries(sections.map(item => [item.id, item.description]))

    expect(descriptions).toMatchObject({
      agents: 'Live and configured keeper roster.',
      'fleet-health': 'Tool quality and Gate signals.',
      runtime: 'Runtime lane health.',
      observatory: 'Activity and runtime evidence.',
    })

    for (const item of sections) {
      const wordCount = item.description.split(/\s+/).filter(Boolean).length
      expect(wordCount).toBeLessThanOrEqual(7)
      expect(item.description.split(',').length).toBeLessThanOrEqual(2)
    }
  })

  it('surfaces the primary Monitor lanes and keeps support diagnostics routeable', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const allSections = sectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)
    const allIds = allSections.map(item => item.id)

    expect(defaultParamsForTab('monitoring')).toEqual({ section: 'agents' })
    expect(ids).toEqual([
      'agents', 'internal-agents', 'fleet-health', 'runtime', 'observatory', 'skills', 'lane-inventory', 'lane-addons', 'lanes',
    ])
    expect(ids).toContain('agents')
    expect(ids).toContain('fleet-health')
    expect(ids).toContain('runtime')
    expect(ids).toContain('observatory')
    expect(allIds).toContain('transport-health')
    expect(ids).not.toContain('transport-health')
    // Legacy sections removed in Phase 1
    expect(ids).not.toContain('live')
    expect(ids).not.toContain('git-graph')
    expect(ids).not.toContain('safe-autonomy')
    expect(ids).not.toContain('cost')
    expect(ids).not.toContain('runtime-inspector')
    expect(ids).not.toContain('attribution')
    expect(ids).not.toContain('activity')
    expect(ids).not.toContain('tool-quality')
    expect(ids).not.toContain('fleet')
    expect(ids).not.toContain('telemetry')
    expect(ids).not.toContain('metrics')
    expect(ids).not.toContain('gate')
  })

  it('puts keeper fleet first before tool, runtime, and evidence lanes', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    expect(sections.map(section => section.id)).toEqual([
      'agents',
      'internal-agents',
      'fleet-health',
      'runtime',
      'observatory',
      'skills',
      'lane-inventory',
      'lane-addons',
      'lanes',
    ])
  })

  it('keeps support diagnostics hidden from the sidebar', () => {
    const sections = sectionItemsForTab('monitoring')
    const hiddenIds = sections.filter(item => item.hidden).map(item => item.id)

    expect(hiddenIds).toEqual([
      'transport-health',
      'journey',
    ])
  })

  it('monitoring sidebar labels are unique (no overloaded term like "런타임")', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labels = sections.map(item => item.label)
    const uniq = new Set(labels)
    expect(uniq.size).toBe(labels.length)
    // Regression guard: the Runtime label must not be overloaded across
    // multiple sidebar items.
    const runtimeOccurrences = labels.filter(l => l.includes('Runtime')).length
    expect(runtimeOccurrences).toBe(1)
  })
})

describe('workspace navigation labels', () => {
  it('uses consolidated planning label (absorbs goals)', () => {
    const sections = visibleSectionItemsForTab('workspace')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('planning')).toBe('Plans & Goals')
    // goals is no longer a standalone section
    const ids = sections.map(item => item.id)
    expect(ids).not.toContain('goals')
  })

  it('hides legacy board-family sections now that Board is top-level', () => {
    const visibleIds = visibleSectionItemsForTab('workspace').map(item => item.id)
    const allSections = sectionItemsForTab('workspace')
    const hiddenIds = allSections.filter(item => item.hidden).map(item => item.id)

    expect(visibleIds).toEqual([
      'work',
      'artifacts',
      'planning',
      'repositories',
      'verification',
    ])
    expect(hiddenIds).toEqual([
      'board',
      'sub-boards',
    ])

    expect(normalizeRouteParams('workspace', { section: 'board', post: 'post-1' })).toMatchObject({
      section: 'board',
      post: 'post-1',
    })
    expect(normalizeRouteParams('workspace', { section: 'sub-boards' }).section).toBe('sub-boards')
  })
})

describe('normalizeRouteParams query param preservation', () => {
  it('keeps monitor view and diagnostic targets on the canonical section', () => {
    expect(normalizeRouteParams('monitoring', {
      section: 'fleet-health', view: 'tool-quality', tool: 'bash',
      session_id: 'sess-1', operation_id: 'op-42', worker_run_id: 'run-7',
    })).toEqual({
      section: 'fleet-health', view: 'tool-quality', tool: 'bash',
      session_id: 'sess-1', operation_id: 'op-42', worker_run_id: 'run-7',
    })
  })

  it('keeps operations workflow targets on the canonical section', () => {
    expect(normalizeRouteParams('command', {
      section: 'operations', target_type: 'operation', target_id: 'op-x',
      source: 'execution', focus_kind: 'operation',
    })).toEqual({
      section: 'operations', target_type: 'operation', target_id: 'op-x',
      source: 'execution', focus_kind: 'operation',
    })
  })
})

describe('normalizeRouteParams view param', () => {
  it('preserves explicit view param on fleet-health', () => {
    const result = normalizeRouteParams('monitoring', { section: 'fleet-health', view: 'event-log' })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('event-log')
  })

  it('does not inject a view param when absent on the agents section', () => {
    const result = normalizeRouteParams('monitoring', { section: 'agents' })
    expect(result.view).toBeUndefined()
  })

})
