import { describe, expect, it } from 'vitest'
import {
  hiddenMissionSectionLabels,
  missionJumpNavItems,
} from './mission'

describe('hiddenMissionSectionLabels', () => {
  it('marks empty mission sections for hiding', () => {
    expect(hiddenMissionSectionLabels({
      activityCount: 0,
      attentionCount: 0,
    })).toEqual([
      '최근 활동',
      '세션 우선순위',
    ])
  })

  it('keeps populated sections visible', () => {
    expect(hiddenMissionSectionLabels({
      activityCount: 3,
      attentionCount: 0,
    })).toEqual([
      '세션 우선순위',
    ])
  })
})

describe('missionJumpNavItems', () => {
  it('keeps the session anchor even when every secondary section is empty', () => {
    expect(missionJumpNavItems({
      sessionCount: 0,
      activityCount: 0,
      attentionCount: 0,
    })).toEqual([
      { id: 'mission-sessions', label: '세션', count: 0 },
    ])
  })

  it('adds only the populated secondary sections', () => {
    expect(missionJumpNavItems({
      sessionCount: 1,
      activityCount: 4,
      attentionCount: 0,
    })).toEqual([
      { id: 'mission-sessions', label: '세션', count: 1 },
      { id: 'mission-output', label: '활동', count: 4 },
    ])
  })
})
