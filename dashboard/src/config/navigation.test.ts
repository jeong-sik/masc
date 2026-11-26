import { describe, expect, it } from 'vitest'

import {
  DASHBOARD_NAV_ITEMS,
  DASHBOARD_SURFACES,
  defaultParamsForTab,
  isSectionlessSurface,
  normalizeRouteParams,
  sectionItemsForTab,
  visibleSectionItemsForTab,
} from './navigation'

describe('dashboard surface navigation', () => {

  it('exposes Keepers as a top-level v2 workspace without nested sections', () => {
    expect(defaultParamsForTab('keepers')).toEqual({})
    expect(DASHBOARD_NAV_ITEMS.map(item => item.id)).toContain('keepers')
    expect(sectionItemsForTab('keepers')).toEqual([])
    expect(visibleSectionItemsForTab('keepers')).toEqual([])

    const result = normalizeRouteParams('keepers', { section: 'agents', keeper: 'sangsu', surface: 'old' })
    expect(result).toEqual({ keeper: 'sangsu' })
  })

  it('exposes Board as a top-level v2 surface without workspace section baggage', () => {
    expect(defaultParamsForTab('board')).toEqual({})
    expect(DASHBOARD_NAV_ITEMS.map(item => item.id)).toContain('board')
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

  it('uses one sectionless-surface classifier for section stripping and section lookup', () => {
    const sectionless = ['overview', 'logs', 'settings', 'keepers', 'board', 'schedule', 'approvals', 'fusion'] as const
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

  it('exposes Schedule as a dedicated top-level surface without section baggage', () => {
    expect(defaultParamsForTab('schedule')).toEqual({})
    expect(DASHBOARD_NAV_ITEMS.map(item => item.id)).toContain('schedule')
    expect(sectionItemsForTab('schedule')).toEqual([])
    expect(visibleSectionItemsForTab('schedule')).toEqual([])

    const result = normalizeRouteParams('schedule', { section: 'tools', surface: 'lab', view: 'legacy' })
    expect(result).toEqual({ view: 'legacy' })
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
  it('uses runtime-first Monitor IA labels', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('runtime')).toBe('Runtime')
    expect(labelFor('fleet-health')).toBe('Tool Monitor')
    expect(labelFor('transport-health')).toBeUndefined()
    expect(labelFor('cognition')).toBeUndefined()
    expect(labelFor('journey')).toBeUndefined()
  })

  it('keeps monitoring descriptions concise instead of comma-heavy domain lists', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const descriptions = Object.fromEntries(sections.map(item => [item.id, item.description]))

    expect(descriptions).toMatchObject({
      'fleet-health': 'Tool quality and Gate signals.',
      runtime: 'Runtime lane health.',
    })

    for (const item of sections) {
      const wordCount = item.description.split(/\s+/).filter(Boolean).length
      expect(wordCount).toBeLessThanOrEqual(8)
      expect(item.description.split(',').length).toBeLessThanOrEqual(2)
    }
  })

  it('surfaces the primary Monitor lanes and keeps support diagnostics routeable', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const allSections = sectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)
    const allIds = allSections.map(item => item.id)

    expect(defaultParamsForTab('monitoring')).toEqual({ section: 'runtime' })
    expect(ids).toEqual([
      'runtime', 'internal-agents', 'fleet-health', 'skills', 'lane-inventory', 'lane-addons', 'lanes',
    ])
    expect(allIds).toContain('transport-health')
    expect(ids).not.toContain('transport-health')
  })

  it('keeps support diagnostics hidden from the sidebar', () => {
    const sections = sectionItemsForTab('monitoring')
    const hiddenIds = sections.filter(item => item.hidden).map(item => item.id)

    expect(hiddenIds).toEqual([
      'transport-health',
    ])
  })

  it('monitoring sidebar labels are unique (no overloaded term like "런타임")', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labels = sections.map(item => item.label)
    const uniq = new Set(labels)
    expect(uniq.size).toBe(labels.length)
    const runtimeOccurrences = labels.filter(l => l.includes('Runtime')).length
    expect(runtimeOccurrences).toBe(1)
  })
})

describe('workspace navigation labels', () => {
  it('hides legacy board-family sections now that Board is top-level', () => {
    const visibleIds = visibleSectionItemsForTab('workspace').map(item => item.id)
    const allSections = sectionItemsForTab('workspace')
    const hiddenIds = allSections.filter(item => item.hidden).map(item => item.id)

    expect(visibleIds).toEqual([
      'work',
      'artifacts',
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
})

describe('normalizeRouteParams view param', () => {
  it('preserves explicit view param on fleet-health', () => {
    const result = normalizeRouteParams('monitoring', { section: 'fleet-health', view: 'event-log' })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('event-log')
  })

  it('does not inject a view param when absent on the runtime section', () => {
    const result = normalizeRouteParams('monitoring', { section: 'runtime' })
    expect(result.view).toBeUndefined()
  })
})
