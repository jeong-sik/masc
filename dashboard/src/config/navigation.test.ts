import { describe, expect, it } from 'vitest'

import { SECTION_REDIRECTS, defaultParamsForTab, normalizeRouteParams, visibleSectionItemsForTab } from './navigation'

describe('code (IDE plane) navigation', () => {
  it('exposes a single ide-shell section under the code surface (Phase 1, PR-1)', () => {
    expect(defaultParamsForTab('code')).toEqual({ section: 'ide-shell' })

    const codeSections = visibleSectionItemsForTab('code')

    expect(codeSections.map(item => item.id)).toEqual(['ide-shell'])
    expect(codeSections.map(item => item.label)).toEqual(['코드 IDE'])
  })

  it('normalizes unknown code section to default ide-shell', () => {
    const result = normalizeRouteParams('code', { section: 'bogus' })
    expect(result.section).toBe('ide-shell')
  })
})

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
  it('has only operations section (Phase 6+7: inspector absorbed; connectors split out)', () => {
    expect(defaultParamsForTab('command')).toEqual({ section: 'operations' })

    const commandSections = visibleSectionItemsForTab('command')

    expect(commandSections.map(item => item.id)).toEqual([
      'operations',
    ])

    expect(commandSections.map(item => item.label)).toEqual([
      '운영 행동',
    ])
  })
})

describe('connectors navigation (Phase 7, post-2026-04-30 merge)', () => {
  it('exposes connectors as a top-level surface with a single all-connectors section', () => {
    expect(defaultParamsForTab('connectors')).toEqual({ section: 'connector-status' })

    const sections = visibleSectionItemsForTab('connectors')
    expect(sections.map(item => item.id)).toEqual(['connector-status'])
    expect(sections.map(item => item.label)).toEqual(['전체'])
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
})

describe('monitoring navigation labels', () => {
  it('uses Korean labels for consolidated monitoring sections', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('live')).toBe('라이브 협업')
    expect(labelFor('observatory')).toBe('관찰소 (beta)')
    expect(labelFor('journey')).toBe('여정 맵')
    expect(labelFor('fleet-health')).toBe('플릿 텔레메트리')
    expect(labelFor('safe-autonomy')).toBe('세이프 오토노미')
    // "캐스케이드" and "에이전트 디렉터리" replaced the duplicated
    // "런타임" labels (one section renamed to cascade, the other to
    // agent directory) so monitoring no longer has two sidebar items
    // whose labels collide on the same word.
    expect(labelFor('runtime')).toBe('캐스케이드')
    expect(labelFor('agents')).toBe('에이전트 디렉터리')
  })

  it('does not expose sessions section (removed in Phase 0 of RFC-MASC-006)', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)

    expect(ids).not.toContain('sessions')
  })

  it('surfaces fleet-health as consolidated monitoring section (Phase 1)', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const ids = sections.map(item => item.id)

    expect(ids).toContain('journey')
    expect(ids).toContain('live')
    expect(ids).toContain('fleet-health')
    expect(ids).toContain('safe-autonomy')
    expect(ids).toContain('runtime')
    expect(ids).toContain('observatory')
    // Legacy sections removed in Phase 1
    expect(ids).not.toContain('activity')
    expect(ids).not.toContain('tool-quality')
    expect(ids).not.toContain('fleet')
    expect(ids).not.toContain('telemetry')
    expect(ids).not.toContain('metrics')
    expect(ids).not.toContain('governance')
  })

  it('puts live collaboration first before slower analysis surfaces', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    expect(sections[0]?.id).toBe('live')
    expect(sections[1]?.id).toBe('journey')
    expect(sections[2]?.id).toBe('observatory')
  })

  it('monitoring sidebar labels are unique (no overloaded term like "런타임")', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labels = sections.map(item => item.label)
    const uniq = new Set(labels)
    expect(uniq.size).toBe(labels.length)
    // Regression guard: the word "런타임" used to label both
    // section[id=runtime] and section[id=agents], making it impossible
    // to tell process-instance liveness apart from cascade routing by
    // reading the sidebar alone.
    const runtimeOccurrences = labels.filter(l => l === '런타임').length
    expect(runtimeOccurrences).toBe(0)
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

  it('redirects legacy activity URL to observatory and upgrades ag_range to range', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'activity',
      ag_range: '6h',
      keeper: 'nova',
    })
    expect(result.section).toBe('observatory')
    expect(result.range).toBe('6h')
    expect(result.ag_range).toBeUndefined()
    expect(result.keeper).toBe('nova')
  })

  it('drops unsupported legacy all-range when redirecting activity to observatory', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'activity',
      ag_range: 'all',
    })
    expect(result.section).toBe('observatory')
    expect(result.range).toBeUndefined()
    expect(result.ag_range).toBeUndefined()
  })
})

describe('SECTION_REDIRECTS table (consolidation Phase -1)', () => {
  it('exposes the sessions → agents redirect as reference contract', () => {
    expect(SECTION_REDIRECTS['monitoring:sessions']).toEqual({ section: 'agents' })
  })

  it('exposes the activity → observatory redirect as reference contract', () => {
    expect(SECTION_REDIRECTS['monitoring:activity']).toEqual({ section: 'observatory' })
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

  it('preserves keeper filter through the activity → observatory redirect', () => {
    const result = normalizeRouteParams('monitoring', {
      section: 'activity',
      keeper: 'nova',
      ag_range: '24h',
    })
    expect(result.section).toBe('observatory')
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

  it('workspace:goals → planning', () => {
    const result = normalizeRouteParams('workspace', { section: 'goals' })
    expect(result.section).toBe('planning')
  })

  it('command:connectors → operations?view=connectors (Phase 6)', () => {
    const result = normalizeRouteParams('command', { section: 'connectors' })
    expect(result.section).toBe('operations')
    expect(result.view).toBe('connectors')
  })

  it('command:inspector → operations?view=inspector (Phase 6)', () => {
    const result = normalizeRouteParams('command', { section: 'inspector' })
    expect(result.section).toBe('operations')
    expect(result.view).toBe('inspector')
  })
})
