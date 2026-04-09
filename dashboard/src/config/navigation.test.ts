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
  it('keeps operations visible with intervene and governance sections', () => {
    expect(defaultParamsForTab('command')).toEqual({ section: 'intervene' })

    const commandSections = visibleSectionItemsForTab('command')

    expect(commandSections.map(item => item.id)).toEqual([
      'intervene',
      'governance',
    ])

    expect(commandSections.map(item => item.label)).toEqual([
      '실시간 개입',
      '거버넌스',
    ])
  })
})
