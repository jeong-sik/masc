import { describe, expect, it } from 'vitest'

import { defaultParamsForTab, visibleSectionItemsForTab } from './navigation'

describe('lab navigation', () => {
  it('keeps tools as the default section and exposes experiments separately', () => {
    expect(defaultParamsForTab('lab')).toEqual({ section: 'tools' })

    const labSections = visibleSectionItemsForTab('lab')

    expect(labSections.map(item => item.id)).toEqual([
      'tools',
      'experiments',
      'autoresearch',
      'harness',
    ])

    expect(labSections.map(item => item.label)).toEqual([
      '도구',
      '실험',
      '오토리서치',
      '하네스 헬스',
    ])
  })
})
