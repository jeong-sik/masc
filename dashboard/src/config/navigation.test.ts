import { describe, expect, it } from 'vitest'

import { SECTION_REDIRECTS, defaultParamsForTab, normalizeRouteParams, visibleSectionItemsForTab } from './navigation'

describe('lab navigation', () => {
  it('contains only research surfaces after Phase 1 reorg', () => {
    expect(defaultParamsForTab('lab')).toEqual({ section: 'tools' })

    const labSections = visibleSectionItemsForTab('lab')

    expect(labSections.map(item => item.id)).toEqual([
      'tools',
      'autoresearch',
      'harness',
    ])

    expect(labSections.map(item => item.label)).toEqual([
      '도구',
      '오토리서치',
      '세이프티 하네스',
    ])
  })
})

describe('command navigation', () => {
  it('includes inspector alongside operations (consolidated) and connectors', () => {
    expect(defaultParamsForTab('command')).toEqual({ section: 'operations' })

    const commandSections = visibleSectionItemsForTab('command')

    expect(commandSections.map(item => item.id)).toEqual([
      'operations',
      'connectors',
      'inspector',
    ])

    expect(commandSections.map(item => item.label)).toEqual([
      '운영 행동',
      '커넥터',
      '운영 인스펙터',
    ])
  })
})

describe('monitoring navigation labels', () => {
  it('uses Korean labels for consolidated monitoring sections', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('fleet-health')).toBe('Fleet 건강')
    expect(labelFor('runtime')).toBe('런타임')
    expect(labelFor('agents')).toBe('에이전트 & 키퍼')
  })

  it('does not expose sessions section (removed in Phase 0 of RFC-MASC-006)', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)

    expect(ids).not.toContain('sessions')
  })

  it('surfaces fleet-health as consolidated monitoring section (Phase 1)', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)

    expect(ids).toContain('fleet-health')
    expect(ids).toContain('runtime')
    // Legacy sections removed in Phase 1
    expect(ids).not.toContain('tool-quality')
    expect(ids).not.toContain('fleet')
    expect(ids).not.toContain('telemetry')
    expect(ids).not.toContain('metrics')
    expect(ids).not.toContain('governance')
  })
})

describe('workspace navigation labels', () => {
  it('uses consolidated planning label (absorbs goals)', () => {
    const sections = visibleSectionItemsForTab('workspace')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('planning')).toBe('계획 & 목표')
    // goals is no longer a standalone section
    const ids = sections.map(item => item.id)
    expect(ids).not.toContain('goals')
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
      expect(key).toMatch(/^(monitoring|command|workspace|lab):/)
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
    ['fsm-hub', {}, 'agents', undefined, {}],
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

  it('workspace:goals → planning', () => {
    const result = normalizeRouteParams('workspace', { section: 'goals' })
    expect(result.section).toBe('planning')
  })
})
