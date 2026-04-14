import { describe, expect, it } from 'vitest'

import { defaultParamsForTab, normalizeRouteParams, visibleSectionItemsForTab } from './navigation'

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
