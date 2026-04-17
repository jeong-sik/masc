import { describe, expect, it } from 'vitest'
import {
  liveStateClass,
  missionTargetTypeLabel,
  signalClassLabel,
  dotStateBg,
} from './mission-utils'

describe('missionTargetTypeLabel', () => {
  it('maps namespace to 프로젝트', () => {
    expect(missionTargetTypeLabel('namespace')).toBe('프로젝트')
  })

  it('maps room to 프로젝트', () => {
    expect(missionTargetTypeLabel('room')).toBe('프로젝트')
  })

  it('maps session to 세션', () => {
    expect(missionTargetTypeLabel('session')).toBe('세션')
  })

  it('maps operation to 작전', () => {
    expect(missionTargetTypeLabel('operation')).toBe('작전')
  })

  it('maps keeper to 키퍼', () => {
    expect(missionTargetTypeLabel('keeper')).toBe('키퍼')
  })

  it('maps agent to 에이전트', () => {
    expect(missionTargetTypeLabel('agent')).toBe('에이전트')
  })

  it('returns 대상 for null', () => {
    expect(missionTargetTypeLabel(null)).toBe('대상')
  })

  it('returns 대상 for undefined', () => {
    expect(missionTargetTypeLabel(undefined)).toBe('대상')
  })

  it('returns 대상 for empty string', () => {
    expect(missionTargetTypeLabel('')).toBe('대상')
  })

  it('passes through unknown values', () => {
    expect(missionTargetTypeLabel('custom_type')).toBe('custom_type')
  })

  it('is case-insensitive', () => {
    expect(missionTargetTypeLabel('KEEPER')).toBe('키퍼')
    expect(missionTargetTypeLabel('Agent')).toBe('에이전트')
  })

  it('trims whitespace', () => {
    expect(missionTargetTypeLabel('  session  ')).toBe('세션')
  })
})

describe('signalClassLabel', () => {
  it('maps metadata_gap to Korean label', () => {
    expect(signalClassLabel('metadata_gap')).toBe('메타데이터 부족')
  })

  it('maps mixed to Korean label', () => {
    expect(signalClassLabel('mixed')).toBe('신호 혼재')
  })

  it('returns null for empty string', () => {
    expect(signalClassLabel('')).toBeNull()
  })

  it('returns null for null', () => {
    expect(signalClassLabel(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(signalClassLabel(undefined)).toBeNull()
  })

  it('passes through unknown values', () => {
    expect(signalClassLabel('unknown_signal')).toBe('unknown_signal')
  })

  it('is case-insensitive', () => {
    expect(signalClassLabel('METADATA_GAP')).toBe('메타데이터 부족')
    expect(signalClassLabel('Mixed')).toBe('신호 혼재')
  })

  it('trims whitespace', () => {
    expect(signalClassLabel('  mixed  ')).toBe('신호 혼재')
  })
})

describe('liveStateClass', () => {
  it('returns offline class for offline status', () => {
    expect(liveStateClass('offline')).toBe('mission-state-offline')
  })

  it('returns offline class for inactive status', () => {
    expect(liveStateClass('inactive')).toBe('mission-state-offline')
  })

  it('returns offline class for archived status', () => {
    expect(liveStateClass('archived')).toBe('mission-state-offline')
  })

  it('returns idle class for idle status', () => {
    expect(liveStateClass('idle')).toBe('mission-state-idle')
  })

  it('returns idle class for quiet status', () => {
    expect(liveStateClass('quiet')).toBe('mission-state-idle')
  })

  it('returns idle class for stale status', () => {
    expect(liveStateClass('stale')).toBe('mission-state-idle')
  })

  it('treats paused and blocked keepers as idle-style mission state', () => {
    expect(liveStateClass('paused')).toBe('mission-state-idle')
    expect(liveStateClass('blocked')).toBe('mission-state-idle')
  })

  it('returns alive class for active status', () => {
    expect(liveStateClass('active')).toBe('mission-state-alive')
  })

  it('returns alive class for running status', () => {
    expect(liveStateClass('running')).toBe('mission-state-alive')
  })

  it('returns alive class for ok status', () => {
    expect(liveStateClass('ok')).toBe('mission-state-alive')
  })

  it('returns alive class for healthy status', () => {
    expect(liveStateClass('healthy')).toBe('mission-state-alive')
  })

  it('falls back to health when status is missing', () => {
    expect(liveStateClass(null, 'healthy')).toBe('mission-state-alive')
    expect(liveStateClass(undefined, 'idle')).toBe('mission-state-idle')
  })

  it('returns empty string for unknown status', () => {
    expect(liveStateClass('unknown')).toBe('')
  })

  it('returns empty string for null/undefined', () => {
    expect(liveStateClass(null)).toBe('')
    expect(liveStateClass(undefined)).toBe('')
  })

  it('is case-insensitive', () => {
    expect(liveStateClass('ACTIVE')).toBe('mission-state-alive')
    expect(liveStateClass('Idle')).toBe('mission-state-idle')
  })
})

describe('dotStateBg', () => {
  it('returns warn bg for idle state', () => {
    expect(dotStateBg('mission-state-idle')).toBe('bg-[var(--warn)]')
  })

  it('returns gray bg for offline state', () => {
    expect(dotStateBg('mission-state-offline')).toBe('bg-[#555]')
  })

  it('returns empty string for alive state', () => {
    expect(dotStateBg('mission-state-alive')).toBe('')
  })

  it('returns empty string for unknown class', () => {
    expect(dotStateBg('')).toBe('')
    expect(dotStateBg('custom-class')).toBe('')
  })
})
