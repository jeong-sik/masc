import { describe, it, expect } from 'vitest'
import {
  isTerminalStatus,
  partitionByTerminal,
  queueKindLabel,
  keeperFromBrief,
  agentStateLabel,
  signalTruthLabel,
  evidenceSourceLabel,
  continuityStateLabel,
} from './shared'
import type { DashboardExecutionContinuityBrief } from '../../types'

// ================================================================
// isTerminalStatus
// ================================================================

describe('isTerminalStatus', () => {
  it('returns true for completed', () => {
    expect(isTerminalStatus('completed')).toBe(true)
  })

  it('returns true for interrupted', () => {
    expect(isTerminalStatus('interrupted')).toBe(true)
  })

  it('returns true for failed', () => {
    expect(isTerminalStatus('failed')).toBe(true)
  })

  it('returns true for cancelled', () => {
    expect(isTerminalStatus('cancelled')).toBe(true)
  })

  it('returns false for running', () => {
    expect(isTerminalStatus('running')).toBe(false)
  })

  it('returns false for null', () => {
    expect(isTerminalStatus(null)).toBe(false)
  })

  it('returns false for undefined', () => {
    expect(isTerminalStatus(undefined)).toBe(false)
  })

  it('is case-insensitive', () => {
    expect(isTerminalStatus('Completed')).toBe(true)
    expect(isTerminalStatus('FAILED')).toBe(true)
  })

  it('trims whitespace', () => {
    expect(isTerminalStatus('  completed  ')).toBe(true)
  })
})

// ================================================================
// partitionByTerminal
// ================================================================

describe('partitionByTerminal', () => {
  it('partitions into active and terminal', () => {
    const items = [
      { status: 'running' },
      { status: 'completed' },
      { status: 'failed' },
      { status: 'pending' },
    ]
    const [active, terminal] = partitionByTerminal(items, i => i.status)
    expect(active).toHaveLength(2)
    expect(terminal).toHaveLength(2)
  })

  it('returns empty arrays for empty input', () => {
    const [active, terminal] = partitionByTerminal([], () => null)
    expect(active).toEqual([])
    expect(terminal).toEqual([])
  })

  it('handles all terminal', () => {
    const items = [{ s: 'completed' }, { s: 'failed' }]
    const [active, terminal] = partitionByTerminal(items, i => i.s)
    expect(active).toHaveLength(0)
    expect(terminal).toHaveLength(2)
  })

  it('handles all active', () => {
    const items = [{ s: 'running' }, { s: 'pending' }]
    const [active, terminal] = partitionByTerminal(items, i => i.s)
    expect(active).toHaveLength(2)
    expect(terminal).toHaveLength(0)
  })
})

// ================================================================
// queueKindLabel
// ================================================================

describe('queueKindLabel', () => {
  it('returns 세션 for session', () => {
    expect(queueKindLabel('session')).toBe('세션')
  })

  it('returns 작전 for operation', () => {
    expect(queueKindLabel('operation')).toBe('작전')
  })
})

// ================================================================
// keeperFromBrief
// ================================================================

describe('keeperFromBrief', () => {
  it('builds keeper from brief with all fields', () => {
    const brief = {
      name: 'janitor',
      agent_name: 'janitor-agent',
      status: 'healthy',
      emoji: '🧹',
      korean_name: '청소부',
      context_ratio: 0.5,
    } as DashboardExecutionContinuityBrief
    const keeper = keeperFromBrief(brief)
    expect(keeper.name).toBe('janitor')
    expect(keeper.agent_name).toBe('janitor-agent')
    expect(keeper.status).toBe('healthy')
    expect(keeper.emoji).toBe('🧹')
  })

  it('defaults agent_name to name', () => {
    const brief = { name: 'test' } as DashboardExecutionContinuityBrief
    const keeper = keeperFromBrief(brief)
    expect(keeper.agent_name).toBe('test')
  })

  it('defaults status to unknown', () => {
    const brief = { name: 'test' } as DashboardExecutionContinuityBrief
    const keeper = keeperFromBrief(brief)
    expect(keeper.status).toBe('unknown')
  })

  it('defaults emoji to empty string', () => {
    const brief = { name: 'test' } as DashboardExecutionContinuityBrief
    const keeper = keeperFromBrief(brief)
    expect(keeper.emoji).toBe('')
  })
})

// ================================================================
// agentStateLabel
// ================================================================

describe('agentStateLabel', () => {
  it('returns 작업 중 for working', () => {
    expect(agentStateLabel('working')).toBe('작업 중')
  })

  it('returns 대기 중 for watching', () => {
    expect(agentStateLabel('watching')).toBe('대기 중')
  })

  it('returns 조용함 for quiet', () => {
    expect(agentStateLabel('quiet')).toBe('조용함')
  })

  it('returns 오프라인 for offline', () => {
    expect(agentStateLabel('offline')).toBe('오프라인')
  })
})

// ================================================================
// signalTruthLabel
// ================================================================

describe('signalTruthLabel', () => {
  it('returns 최근 신호 for live', () => {
    expect(signalTruthLabel('live')).toBe('최근 신호(≤5m)')
  })

  it('returns 오래된 신호 for stale', () => {
    expect(signalTruthLabel('stale')).toBe('오래된 신호(>5m)')
  })

  it('returns signal 없음 for absent', () => {
    expect(signalTruthLabel('absent')).toBe('signal 없음')
  })

  it('returns 미상 for null', () => {
    expect(signalTruthLabel(null)).toBe('signal 미상')
  })

  it('returns 미상 for undefined', () => {
    expect(signalTruthLabel(undefined)).toBe('signal 미상')
  })

  it('returns raw value for unknown', () => {
    expect(signalTruthLabel('custom' as any)).toBe('custom')
  })
})

// ================================================================
// evidenceSourceLabel
// ================================================================

describe('evidenceSourceLabel', () => {
  it('returns 최근 출력 for message', () => {
    expect(evidenceSourceLabel('message')).toBe('최근 출력')
  })

  it('returns presence for presence', () => {
    expect(evidenceSourceLabel('presence')).toBe('presence/하트비트')
  })

  it('returns 근거 없음 for none', () => {
    expect(evidenceSourceLabel('none')).toBe('근거 없음')
  })

  it('returns 미상 for null', () => {
    expect(evidenceSourceLabel(null)).toBe('근거 미상')
  })

  it('returns 미상 for undefined', () => {
    expect(evidenceSourceLabel(undefined)).toBe('근거 미상')
  })

  it('returns raw value for unknown', () => {
    expect(evidenceSourceLabel('custom' as any)).toBe('custom')
  })
})

// ================================================================
// continuityStateLabel
// ================================================================

describe('continuityStateLabel', () => {
  it('returns 위험 for critical', () => {
    expect(continuityStateLabel('critical')).toBe('위험')
  })

  it('returns 주의 for warning', () => {
    expect(continuityStateLabel('warning')).toBe('주의')
  })

  it('returns 정상 for healthy', () => {
    expect(continuityStateLabel('healthy')).toBe('정상')
  })

  it('returns 정상 for unknown', () => {
    expect(continuityStateLabel('anything' as any)).toBe('정상')
  })
})
