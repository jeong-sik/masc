import { describe, expect, it } from 'vitest'

import { defaultParamsForTab, visibleSectionItemsForTab } from './navigation'

describe('lab navigation', () => {
  it('keeps tools as the default section after removing the experiments surface', () => {
    expect(defaultParamsForTab('lab')).toEqual({ section: 'tools' })

    const labSections = visibleSectionItemsForTab('lab')

    expect(labSections.map(item => item.id)).toEqual([
      'tools',
      'autoresearch',
      'harness',
      'inspector',
      'tool-quality',
      'fleet',
    ])

    expect(labSections.map(item => item.label)).toEqual([
      '도구',
      '오토리서치',
      '세이프티 하네스',
      '운영 인스펙터',
      '도구 품질',
      'Fleet 텔레메트리',
    ])
  })
})

describe('command navigation', () => {
  it('keeps operations visible with intervene, governance, and connectors sections', () => {
    expect(defaultParamsForTab('command')).toEqual({ section: 'intervene' })

    const commandSections = visibleSectionItemsForTab('command')

    expect(commandSections.map(item => item.id)).toEqual([
      'intervene',
      'governance',
      'connectors',
    ])

    expect(commandSections.map(item => item.label)).toEqual([
      '실시간 개입',
      '거버넌스',
      '커넥터',
    ])
  })
})

describe('monitoring navigation labels', () => {
  it('uses Korean label for 도구 이벤트 and keeps Prometheus naming', () => {
    const sections = visibleSectionItemsForTab('monitoring')
    const labelFor = (id: string) => sections.find(item => item.id === id)?.label

    expect(labelFor('governance')).toBe('도구 이벤트')
    expect(labelFor('metrics')).toBe('Prometheus')
    expect(labelFor('sessions')).toBe('세션')
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
