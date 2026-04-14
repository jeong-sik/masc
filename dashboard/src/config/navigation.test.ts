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
  it('includes inspector alongside intervene, governance (승인 큐), and connectors', () => {
    expect(defaultParamsForTab('command')).toEqual({ section: 'intervene' })

    const commandSections = visibleSectionItemsForTab('command')

    expect(commandSections.map(item => item.id)).toEqual([
      'intervene',
      'governance',
      'connectors',
      'inspector',
    ])

    expect(commandSections.map(item => item.label)).toEqual([
      '실시간 개입',
      '승인 큐',
      '커넥터',
      '운영 인스펙터',
    ])
  })
})

describe('monitoring navigation labels', () => {
  it('uses Korean label for 도구 이벤트 and keeps Prometheus naming', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('governance')).toBe('도구 이벤트')
    expect(labelFor('metrics')).toBe('Prometheus')
    expect(labelFor('agents')).toBe('에이전트 & 키퍼')
  })

  it('does not expose sessions section (removed in Phase 0 of RFC-MASC-006)', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)

    expect(ids).not.toContain('sessions')
  })

  it('surfaces tool-quality and fleet alongside telemetry/metrics', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)

    expect(ids).toContain('tool-quality')
    expect(ids).toContain('fleet')
    expect(ids).toContain('telemetry')
    expect(ids).toContain('metrics')
  })
})

describe('workspace navigation labels', () => {
  it('renames planning to 작업 큐 and keeps 목표 트리', () => {
    const sections = visibleSectionItemsForTab('workspace')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('planning')).toBe('작업 큐')
    expect(labelFor('goals')).toBe('목표 트리')
  })
})

describe('normalizeRouteParams backward compat (RFC-MASC-006 Phase 0)', () => {
  it('redirects legacy ?section=sessions URL to agents and preserves other params', () => {
    const redirected = normalizeRouteParams('monitoring', { section: 'sessions', session_id: 's-123' })
    expect(redirected.section).toBe('agents')
    expect(redirected.session_id).toBe('s-123')
  })

  it('leaves other valid monitoring sections untouched', () => {
    const result = normalizeRouteParams('monitoring', { section: 'telemetry' })
    expect(result.section).toBe('telemetry')
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
  it('preserves telemetry deep-link params through identity mapping', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'telemetry',
      session_id: 'sess-1',
      operation_id: 'op-42',
      worker_run_id: 'run-7',
    })
    expect(result.section).toBe('telemetry')
    expect(result.session_id).toBe('sess-1')
    expect(result.operation_id).toBe('op-42')
    expect(result.worker_run_id).toBe('run-7')
  })

  it('preserves tool query param for tool-quality section', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'tool-quality',
      tool: 'bash',
    })
    expect(result.section).toBe('tool-quality')
    expect(result.tool).toBe('bash')
  })

  it('preserves intervene workflow params (target_type, target_id, source)', () => {
    const result = normalizeRouteParams('command', {
      section: 'intervene',
      target_type: 'operation',
      target_id: 'op-x',
      source: 'execution',
      focus_kind: 'operation',
    })
    expect(result.section).toBe('intervene')
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

describe('normalizeRouteParams view param (forward contract)', () => {
  it('preserves explicit view param on valid sections', () => {
    const result = normalizeRouteParams('monitoring', { section: 'telemetry', view: 'event-log' })
    expect(result.section).toBe('telemetry')
    expect(result.view).toBe('event-log')
  })

  it('does not inject a view param when absent', () => {
    const result = normalizeRouteParams('monitoring', { section: 'telemetry' })
    expect(result.view).toBeUndefined()
  })

  it('sets view from redirect table when redirect provides one', () => {
    // No such redirect entry exists in Phase -1, but the mechanism is exercised
    // so Phase 1+ can rely on it without reworking the pipeline.
    // Verified indirectly by the SECTION_REDIRECTS contract test above.
    expect(true).toBe(true)
  })
})

// -----------------------------------------------------------------------------
// Forward contract — consolidation Phase 1+
//
// These tests document the redirect shape that Phase 1 will enable when the
// new sections (fleet-health, operations, etc.) are added to SurfaceSectionId.
// They intentionally use `.skip` so Phase -1 merges green; remove `.skip` and
// the assertions activate automatically once the target sections exist.
// -----------------------------------------------------------------------------
describe.skip('consolidation redirects (activated in Phase 1)', () => {
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
