import { describe, expect, it } from 'vitest'

import {
  DASHBOARD_SURFACES,
  PRIMARY_DASHBOARD_NAV_ITEMS,
  PRIMARY_DASHBOARD_SURFACES,
  SECTION_REDIRECTS,
  VISIBLE_DASHBOARD_NAV_ITEMS,
  defaultParamsForTab,
  isSectionlessSurface,
  normalizeRouteParams,
  sectionItemsForTab,
  visibleSectionItemsForTab,
} from './navigation'

describe('dashboard surface navigation', () => {
  it('keeps MASC Cockpit routeable but out of primary navigation', () => {
    const cockpit = DASHBOARD_SURFACES.find(surface => surface.id === 'cockpit')

    expect(cockpit?.hidden).toBe(true)
    expect(defaultParamsForTab('cockpit')).toEqual({})
    expect(VISIBLE_DASHBOARD_NAV_ITEMS.map(item => item.id)).not.toContain('cockpit')
  })

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

  it('keeps the v2 primary shell aligned to the 2026-07 keeper-v2 export rail order', () => {
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
      'performance',
      'memory-subsystems',
      'keeper-memory-health',
    ])

    expect(labSections.map(item => item.label)).toEqual([
      'Tools',
      'Safety Harness',
      'Performance',
      'Memory OS',
      '키퍼 메모리 상태',
    ])
    expect(labSections.find(item => item.id === 'memory-subsystems')?.description).toBe(
      'Live episodes, user model projection, Hebbian synapses, and gated memory entries.',
    )
    expect(labSections.find(item => item.id === 'performance')?.description).toBe(
      'FPS meter, VirtualList, content-visibility, native dialog, and observer probes.',
    )
  })

  it('collapses legacy Memory Explore links into the backed Memory OS route', () => {
    expect(normalizeRouteParams('lab', {
      section: 'memory-explore',
      focus: 'episodes',
      view: 'stale',
    })).toEqual({
      section: 'memory-subsystems',
      focus: 'episodes',
    })
  })

  it('collapses legacy Design Canvas links into the backed tools inventory', () => {
    expect(normalizeRouteParams('lab', {
      section: 'design-canvas',
      view: 'fixtures',
    })).toEqual({
      section: 'tools',
    })
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

  it('redirects legacy per-bridge section deep links to connector-status', () => {
    // The four per-sidecar sub-tabs were merged into the single
    // all-connectors view on 2026-04-30; deep links to the old
    // section ids fall back to the default.
    const result = normalizeRouteParams('connectors', { section: 'connector-slack' })
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
    expect(labelFor('feature-health')).toBeUndefined()
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

  it('does not expose sessions section (removed in Phase 0 of RFC-MASC-006)', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)

    expect(ids).not.toContain('sessions')
  })

  it('surfaces four primary Monitor lanes and keeps support diagnostics routeable', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const allSections = sectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)
    const allIds = allSections.map(item => item.id)

    expect(defaultParamsForTab('monitoring')).toEqual({ section: 'agents' })
    expect(ids).toEqual([
      'agents', 'fleet-health', 'runtime', 'observatory',
    ])
    expect(ids).toContain('agents')
    expect(ids).toContain('fleet-health')
    expect(ids).toContain('runtime')
    expect(ids).toContain('observatory')
    expect(allIds).toContain('transport-health')
    expect(allIds).toContain('feature-health')
    expect(ids).not.toContain('transport-health')
    expect(ids).not.toContain('feature-health')
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
      'fleet-health',
      'runtime',
      'observatory',
    ])
  })

  it('keeps support diagnostics hidden from the sidebar', () => {
    const sections = sectionItemsForTab('monitoring')
    const hiddenIds = sections.filter(item => item.hidden).map(item => item.id)

    expect(hiddenIds).toEqual([
      'transport-health',
      'feature-health',
      'journey',
      'cognition',
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
  it('uses the task planning label', () => {
    const sections = visibleSectionItemsForTab('workspace')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('planning')).toBe('Planning')
    expect(labelFor('moderation')).toBeUndefined()
    const ids = sections.map(item => item.id)
    expect(ids).not.toContain('moderation')
  })

  it('hides legacy board-family sections now that Board is top-level', () => {
    const visibleIds = visibleSectionItemsForTab('workspace').map(item => item.id)
    const allSections = sectionItemsForTab('workspace')
    const hiddenIds = allSections.filter(item => item.hidden).map(item => item.id)

    expect(visibleIds).toEqual([
      'work',
      'planning',
      'repositories',
      'verification',
    ])
    expect(hiddenIds).toEqual([
      'board',
      'sub-boards',
      'moderation',
    ])

    expect(normalizeRouteParams('workspace', { section: 'board', post: 'post-1' })).toMatchObject({
      section: 'board',
      post: 'post-1',
    })
    expect(normalizeRouteParams('workspace', { section: 'sub-boards' }).section).toBe('sub-boards')
    expect(normalizeRouteParams('workspace', { section: 'moderation' }).section).toBe('moderation')
  })
})

describe('normalizeRouteParams backward compat (RFC-MASC-006 Phase 0)', () => {
  it('redirects legacy ?section=sessions URL to agents and preserves other params', () => {
    const redirected = normalizeRouteParams('monitoring', { section: 'sessions', session_id: 's-123' })
    expect(redirected.section).toBe('agents')
    expect(redirected.session_id).toBe('s-123')
  })

  it('redirects telemetry to fleet-health with event-log view (Phase 1)', () => {
    const result = normalizeRouteParams('monitoring', { section: 'telemetry' })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('event-log')
  })

  it('falls back invalid activity section to default agents and upgrades ag_range to range', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'activity',
      ag_range: '6h',
      keeper: 'nova',
    })
    expect(result.section).toBe('agents')
    expect(result.range).toBe('6h')
    expect(result.ag_range).toBeUndefined()
    expect(result.keeper).toBe('nova')
  })

  it('falls back invalid live section to default agents', () => {
    const result = normalizeRouteParams('monitoring', { section: 'live' })
    expect(result.section).toBe('agents')
    expect(result.view).toBeUndefined()
  })

  it('redirects standalone runtime diagnostics into runtime views', () => {
    expect(normalizeRouteParams('monitoring', { section: 'cost' })).toMatchObject({
      section: 'runtime',
      view: 'cost',
    })
  })

  it('redirects attribution into fleet-health', () => {
    const result = normalizeRouteParams('monitoring', { section: 'attribution' })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('attribution')
  })

  it('falls back invalid activity with unsupported all-range to default agents', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'activity',
      ag_range: 'all',
    })
    expect(result.section).toBe('agents')
    expect(result.range).toBeUndefined()
    expect(result.ag_range).toBeUndefined()
  })
})

describe('SECTION_REDIRECTS table (consolidation Phase -1)', () => {
  it('exposes the sessions → agents redirect as reference contract', () => {
    expect(SECTION_REDIRECTS['monitoring:sessions']).toEqual({ section: 'agents' })
  })

  it('is the single source of truth for legacy section remaps', () => {
    // All entries must produce valid canonical sections after application.
    // This guards against typos when Phase 1+ adds new entries.
    for (const [key, redirect] of Object.entries(SECTION_REDIRECTS)) {
      expect(redirect.section).toMatch(/^[a-z][a-z0-9-]*$/)
      if (redirect.view !== undefined) {
        expect(redirect.view).toMatch(/^[a-z][a-z0-9-]*$/)
      }
      expect(key).toMatch(/^(monitoring|command|connectors|workspace|lab):/)
    }
  })
})

describe('normalizeRouteParams query param preservation', () => {
  it('preserves telemetry deep-link params through fleet-health redirect', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'telemetry',
      session_id: 'sess-1',
      operation_id: 'op-42',
      worker_run_id: 'run-7',
    })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('event-log')
    expect(result.session_id).toBe('sess-1')
    expect(result.operation_id).toBe('op-42')
    expect(result.worker_run_id).toBe('run-7')
  })

  it('preserves tool query param through tool-quality → fleet-health redirect', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'tool-quality',
      tool: 'bash',
    })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('tool-quality')
    expect(result.tool).toBe('bash')
  })

  it('preserves connector intent through old per-connector routes', () => {
    const result = normalizeRouteParams('connectors', { section: 'connector-slack' })
    expect(result.section).toBe('connector-status')
    expect(result.connector).toBe('slack')
  })

  it('preserves intervene workflow params through operations redirect', () => {
    const result = normalizeRouteParams('command', {
      section: 'intervene',
      target_type: 'operation',
      target_id: 'op-x',
      source: 'execution',
      focus_kind: 'operation',
    })
    expect(result.section).toBe('operations')
    expect(result.target_type).toBe('operation')
    expect(result.target_id).toBe('op-x')
    expect(result.source).toBe('execution')
    expect(result.focus_kind).toBe('operation')
  })

  it('preserves session_id through the sessions → agents redirect', () => {
    const result = normalizeRouteParams('monitoring', { section: 'sessions', session_id: 's-9' })
    expect(result.section).toBe('agents')
    expect(result.session_id).toBe('s-9')
  })

  it('preserves keeper filter through invalid activity fallback to agents', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'activity',
      keeper: 'nova',
      ag_range: '24h',
    })
    expect(result.section).toBe('agents')
    expect(result.keeper).toBe('nova')
    expect(result.range).toBe('24h')
  })
})

describe('normalizeRouteParams view param (Phase 1 active)', () => {
  it('preserves explicit view param on fleet-health', () => {
    const result = normalizeRouteParams('monitoring', { section: 'fleet-health', view: 'event-log' })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('event-log')
  })

  it('does not inject a view param when absent on a non-redirected section', () => {
    const result = normalizeRouteParams('monitoring', { section: 'agents' })
    expect(result.view).toBeUndefined()
  })

  it('injects view from redirect table when redirect provides one', () => {
    // telemetry → fleet-health with view=event-log
    const result = normalizeRouteParams('monitoring', { section: 'telemetry' })
    expect(result.section).toBe('fleet-health')
    expect(result.view).toBe('event-log')
  })
})

// -----------------------------------------------------------------------------
// Consolidation redirects — Phase 1 active
//
// These tests verify the redirect shape for Phase 1 consolidation where
// new sections (fleet-health, operations, etc.) replace legacy section IDs.
// -----------------------------------------------------------------------------
describe('consolidation redirects (Phase 1)', () => {
  it.each([
    ['telemetry', { session_id: 'abc' }, 'fleet-health', 'event-log', { session_id: 'abc' }],
    ['telemetry', { operation_id: 'op1' }, 'fleet-health', 'event-log', { operation_id: 'op1' }],
    ['tool-quality', { tool: 'bash' }, 'fleet-health', 'tool-quality', { tool: 'bash' }],
    ['fleet', {}, 'fleet-health', 'comparison', {}],
    ['fsm-hub', {}, 'agents', 'fsm', {}],
    ['metrics', {}, 'runtime', undefined, {}],
  ])(
    'monitoring:%s → %s (view: %s) preserves params',
    (oldSection, extra, expectedSection, expectedView, preserved) => {
      const result = normalizeRouteParams('monitoring', { section: oldSection, ...extra })
      expect(result.section).toBe(expectedSection)
      if (expectedView !== undefined) expect(result.view).toBe(expectedView)
      for (const [k, v] of Object.entries(preserved)) {
        expect(result[k]).toBe(v)
      }
    },
  )

  it('command:intervene → operations preserves workflow params', () => {
    const result = normalizeRouteParams('command', {
      section: 'intervene',
      target_id: 'op-1',
      target_type: 'operation',
    })
    expect(result.section).toBe('operations')
    expect(result.target_id).toBe('op-1')
    expect(result.target_type).toBe('operation')
  })

  it('does not keep command:connectors as an in-surface redirect', () => {
    const result = normalizeRouteParams('command', { section: 'connectors' })
    expect(result.section).toBe('operations')
    expect(result.view).toBeUndefined()
  })

  it('command:inspector → operations?view=inspector (Phase 6)', () => {
    const result = normalizeRouteParams('command', { section: 'inspector' })
    expect(result.section).toBe('operations')
    expect(result.view).toBe('inspector')
  })
})
