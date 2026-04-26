import { describe, it, expect } from 'vitest'
import {
  railStatusLabel,
  statusChipClass,
  freshnessLabel,
  heroTitle,
  heroBody,
  railDetail,
  railFreshness,
  statusCardClass,
  emptyReasonText,
  verdictTone,
  verdictSummary,
  filterVerdicts,
  filterPreCompactEvents,
  filterHandoffEvents,
} from './harness-health-sections'
import type {
  HarnessHealthData,
  HarnessVerdictItem,
  PreCompactEvent,
  HandoffEvent,
} from './harness-health-state'

function makeVerdict(overrides: Partial<HarnessVerdictItem> = {}): HarnessVerdictItem {
  return {
    timestamp: 1_700_000_000_000,
    task_id: 'task-1',
    task_title: 'Task One',
    agent_name: 'agent-alpha',
    gate: 'code_quality',
    verdict: 'approve',
    evaluator_cascade: 'evaluator-cascade',
    ...overrides,
  }
}

function makeData(overrides: Partial<HarnessHealthData['overview']> = {}): HarnessHealthData {
  return {
    generated_at: Date.now(),
    scope_note: 'test',
    overview: {
      evaluator_status: 'healthy',
      pre_compact_status: 'idle',
      handoff_status: 'idle',
      last_signal_at: Date.now(),
      evaluator_last_event_at: Date.now(),
      pre_compact_last_event_at: null,
      handoff_last_event_at: null,
      fallback_ratio: 0,
      latest_pre_compact_ratio: null,
      latest_handoff_generation: null,
      ...overrides,
    },
    calibration: {
      total_verdicts: 0,
      approve_count: 0,
      reject_count: 0,
      gate_distribution: {},
      labeled_count: 0,
      false_positive_count: 0,
      false_negative_count: 0,
      agreement_rate: 0,
    },
    recent_verdicts: [],
    pre_compact: { description: '', recent_events: [], total_recent: 0, status: 'idle', last_event_at: null },
    recent_handoffs: { description: '', recent_events: [], total_recent: 0, status: 'idle', last_event_at: null },
  }
}

// ================================================================
// railStatusLabel
// ================================================================

describe('railStatusLabel', () => {
  it('returns "정상" for healthy', () => {
    expect(railStatusLabel('healthy')).toBe('정상')
  })

  it('returns "주의" for warning', () => {
    expect(railStatusLabel('warning')).toBe('주의')
  })

  it('returns "오래됨" for stale', () => {
    expect(railStatusLabel('stale')).toBe('오래됨')
  })

  it('returns "대기" for idle', () => {
    expect(railStatusLabel('idle')).toBe('대기')
  })

  it('returns "대기" for unknown', () => {
    expect(railStatusLabel('unknown' as any)).toBe('대기')
  })
})

// ================================================================
// statusChipClass
// ================================================================

describe('statusChipClass', () => {
  it('returns ok class for healthy', () => {
    expect(statusChipClass('healthy')).toContain('ok')
  })

  it('returns warn class for warning', () => {
    expect(statusChipClass('warning')).toContain('warn')
  })

  it('returns muted class for stale', () => {
    expect(statusChipClass('stale')).toContain('text-muted')
  })

  it('returns dim class for idle', () => {
    expect(statusChipClass('idle')).toContain('text-dim')
  })

  it('returns dim class for unknown', () => {
    expect(statusChipClass('unknown' as any)).toContain('text-dim')
  })
})

// ================================================================
// freshnessLabel
// ================================================================

describe('freshnessLabel', () => {
  it('returns fallback for null', () => {
    expect(freshnessLabel(null)).toBe('기록 없음')
  })

  it('returns fallback for undefined', () => {
    expect(freshnessLabel(undefined)).toBe('기록 없음')
  })

  it('returns custom fallback', () => {
    expect(freshnessLabel(null, '데이터 없음')).toBe('데이터 없음')
  })

  it('returns time ago for valid timestamp', () => {
    const now = Date.now()
    const result = freshnessLabel(now)
    expect(result).not.toBe('기록 없음')
    expect(result.length).toBeGreaterThan(0)
  })
})

// ================================================================
// heroTitle
// ================================================================

describe('heroTitle', () => {
  it('returns warning title when any status is warning', () => {
    const data = makeData({ evaluator_status: 'warning' })
    expect(heroTitle(data)).toBe('감시 채널에 주의가 필요합니다.')
  })

  it('returns stale title when any status is stale', () => {
    const data = makeData({ pre_compact_status: 'stale' })
    expect(heroTitle(data)).toBe('신호는 있지만 최신성이 떨어집니다.')
  })

  it('returns idle title when all statuses are idle', () => {
    const data = makeData({
      evaluator_status: 'idle',
      last_signal_at: null,
    })
    expect(heroTitle(data)).toBe('아직 감시 기록이 없습니다.')
  })

  it('returns healthy title when all are healthy/idle', () => {
    const data = makeData()
    expect(heroTitle(data)).toBe('감시 채널이 정상 작동 중입니다.')
  })
})

// ================================================================
// heroBody
// ================================================================

describe('heroBody', () => {
  it('describes evaluator warning with fallback ratio', () => {
    const data = makeData({ evaluator_status: 'warning', fallback_ratio: 0.45 })
    const result = heroBody(data)
    expect(result).toContain('45%')
    expect(result).toContain('대체')
  })

  it('describes handoff warning', () => {
    const data = makeData({ handoff_status: 'warning' })
    expect(heroBody(data)).toContain('세대 교체')
  })

  it('describes pre_compact warning', () => {
    const data = makeData({ pre_compact_status: 'warning' })
    expect(heroBody(data)).toContain('압축')
  })

  it('describes no signal state', () => {
    const data = makeData({ last_signal_at: null })
    expect(heroBody(data)).toContain('keeper')
  })

  it('describes normal state with last signal', () => {
    const data = makeData({ last_signal_at: Date.now() })
    expect(heroBody(data)).toContain('마지막 안전 신호')
  })
})

// ================================================================
// railDetail
// ================================================================

describe('railDetail', () => {
  it('returns verdict count for evaluator', () => {
    const data = makeData()
    data.calibration.total_verdicts = 42
    expect(railDetail(data, 'evaluator')).toBe('판정 42건')
  })

  it('returns no verdicts for evaluator with zero', () => {
    const data = makeData()
    expect(railDetail(data, 'evaluator')).toBe('판정 기록 없음')
  })

  it('returns context ratio for pre_compact', () => {
    const data = makeData({ latest_pre_compact_ratio: 0.73 })
    expect(railDetail(data, 'pre_compact')).toBe('컨텍스트 73%')
  })

  it('returns no compact for pre_compact with null', () => {
    const data = makeData()
    expect(railDetail(data, 'pre_compact')).toBe('최근 압축 없음')
  })

  it('returns generation for handoff', () => {
    const data = makeData({ latest_handoff_generation: 5 })
    expect(railDetail(data, 'handoff')).toBe('5세대')
  })

  it('returns no handoff for null generation', () => {
    const data = makeData()
    expect(railDetail(data, 'handoff')).toBe('최근 교체 없음')
  })
})

// ================================================================
// railFreshness
// ================================================================

describe('railFreshness', () => {
  it('returns freshness for evaluator', () => {
    const ts = Date.now()
    const data = makeData({ evaluator_last_event_at: ts })
    const result = railFreshness(data, 'evaluator')
    expect(result).not.toBe('기록 없음')
  })

  it('returns freshness for pre_compact', () => {
    const ts = Date.now()
    const data = makeData({ pre_compact_last_event_at: ts })
    const result = railFreshness(data, 'pre_compact')
    expect(result).not.toBe('기록 없음')
  })

  it('returns freshness for handoff', () => {
    const ts = Date.now()
    const data = makeData({ handoff_last_event_at: ts })
    const result = railFreshness(data, 'handoff')
    expect(result).not.toBe('기록 없음')
  })

  it('returns fallback when no event', () => {
    const data = makeData({ evaluator_last_event_at: null })
    expect(railFreshness(data, 'evaluator')).toBe('기록 없음')
  })
})

describe('statusCardClass', () => {
  it('returns ok border for healthy', () => {
    expect(statusCardClass('healthy')).toBe('border-[var(--ok-30)] bg-[var(--ok-12)]')
  })

  it('returns warn border for warning', () => {
    expect(statusCardClass('warning')).toBe('border-[var(--warn-30)] bg-[var(--warn-12)]')
  })

  it('returns white border for stale', () => {
    expect(statusCardClass('stale')).toBe('border-[var(--white-12)] bg-[var(--white-4)]')
  })

  it('returns dim border for idle', () => {
    expect(statusCardClass('idle')).toBe('border-[var(--white-8)] bg-[var(--white-4)]')
  })

  it('returns dim border for unknown', () => {
    expect(statusCardClass('broken' as never)).toBe('border-[var(--white-8)] bg-[var(--white-4)]')
  })
})

describe('emptyReasonText', () => {
  it('returns window_empty message', () => {
    expect(emptyReasonText('window_empty')).toBe('선택된 범위에는 신호가 없습니다.')
  })

  it('returns no_recent_events message', () => {
    expect(emptyReasonText('no_recent_events')).toBe('기록은 있지만 최근 신호가 없습니다.')
  })

  it('returns default message for no_runtime_activity', () => {
    expect(emptyReasonText('no_runtime_activity')).toBe('아직 이 감시 채널을 통과한 실행이 없습니다.')
  })

  it('returns default message for null', () => {
    expect(emptyReasonText(null)).toBe('아직 이 감시 채널을 통과한 실행이 없습니다.')
  })

  it('returns default message for undefined', () => {
    expect(emptyReasonText(undefined)).toBe('아직 이 감시 채널을 통과한 실행이 없습니다.')
  })

  it('returns default message for unknown reason', () => {
    expect(emptyReasonText('something_else')).toBe('아직 이 감시 채널을 통과한 실행이 없습니다.')
  })
})

describe('verdictTone', () => {
  it('returns ok for approve', () => {
    expect(verdictTone('approve')).toBe('bg-[var(--color-status-ok)]')
  })

  it('returns ok for approve:conditional', () => {
    expect(verdictTone('approve:conditional')).toBe('bg-[var(--color-status-ok)]')
  })

  it('returns bad for reject', () => {
    expect(verdictTone('reject')).toBe('bg-[var(--color-status-err)]')
  })

  it('returns bad for reject:vague notes', () => {
    expect(verdictTone('reject:vague notes')).toBe('bg-[var(--color-status-err)]')
  })
})

describe('verdictSummary', () => {
  it('passes through non-reject verdicts', () => {
    expect(verdictSummary('approve')).toBe('approve')
  })

  it('strips reject: prefix', () => {
    expect(verdictSummary('reject:vague notes')).toBe('vague notes')
  })

  it('strips reject: prefix and trims', () => {
    expect(verdictSummary('reject:  too long  ')).toBe('too long')
  })

  it('returns reject for empty reason', () => {
    expect(verdictSummary('reject:')).toBe('reject')
  })

  it('returns reject for whitespace-only reason', () => {
    expect(verdictSummary('reject:   ')).toBe('reject')
  })
})

// ================================================================
// filterVerdicts
// ================================================================

describe('filterVerdicts', () => {
  const items: HarnessVerdictItem[] = [
    makeVerdict({ task_id: 't-1', task_title: 'Refactor keeper loop', agent_name: 'alpha', gate: 'code_quality', evaluator_cascade: 'cas-a', verdict: 'approve' }),
    makeVerdict({ task_id: 't-2', task_title: 'Add dashboard filter', agent_name: 'beta', gate: 'documentation', evaluator_cascade: 'cas-b', verdict: 'reject:vague notes' }),
    makeVerdict({ task_id: 't-3', task_title: 'Token counter fix', agent_name: 'gamma', gate: 'code_quality', evaluator_cascade: 'cas-c', verdict: 'approve:conditional' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterVerdicts(items, '')).toBe(items)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterVerdicts(items, '   ')).toBe(items)
  })

  it('matches by task_title substring (case-insensitive)', () => {
    const result = filterVerdicts(items, 'DASHBOARD')
    expect(result.map(r => r.task_id)).toEqual(['t-2'])
  })

  it('matches by agent_name substring', () => {
    const result = filterVerdicts(items, 'gamma')
    expect(result.map(r => r.task_id)).toEqual(['t-3'])
  })

  it('matches by gate substring returning multiple rows', () => {
    const result = filterVerdicts(items, 'code_quality')
    expect(result.map(r => r.task_id)).toEqual(['t-1', 't-3'])
  })

  it('matches by evaluator_cascade substring', () => {
    const result = filterVerdicts(items, 'cas-b')
    expect(result.map(r => r.task_id)).toEqual(['t-2'])
  })

  it('matches by verdict substring', () => {
    const result = filterVerdicts(items, 'reject')
    expect(result.map(r => r.task_id)).toEqual(['t-2'])
  })

  it('matches by task_id substring', () => {
    const result = filterVerdicts(items, 't-1')
    expect(result.map(r => r.task_id)).toEqual(['t-1'])
  })

  it('returns empty when no field matches', () => {
    expect(filterVerdicts(items, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterVerdicts(items, '  alpha  ')).toHaveLength(1)
  })

  it('does not mutate the input array', () => {
    const copy = items.slice()
    filterVerdicts(items, 'alpha')
    expect(items).toEqual(copy)
  })

  it('handles items with empty string fields safely', () => {
    const sparse: HarnessVerdictItem[] = [
      makeVerdict({ task_id: '', task_title: '', agent_name: '', gate: '', evaluator_cascade: '', verdict: 'approve' }),
    ]
    expect(filterVerdicts(sparse, 'approve')).toHaveLength(1)
    expect(filterVerdicts(sparse, 'anything-else')).toHaveLength(0)
  })
})

// ================================================================
// filterPreCompactEvents
// ================================================================

function makePreCompact(overrides: Partial<PreCompactEvent> = {}): PreCompactEvent {
  return {
    timestamp: 1_700_000_000_000,
    keeper_name: 'keeper-alpha',
    context_ratio: 0.5,
    message_count: 10,
    token_count: 1000,
    strategies: ['summarize'],
    model_family: 'claude-sonnet',
    trigger: 'ratio_threshold',
    ...overrides,
  }
}

describe('filterPreCompactEvents', () => {
  const items: PreCompactEvent[] = [
    makePreCompact({ keeper_name: 'keeper-alpha', trigger: 'ratio_threshold', model_family: 'claude-sonnet', strategies: ['summarize', 'drop_old'] }),
    makePreCompact({ keeper_name: 'keeper-beta', trigger: 'manual', model_family: 'glm-4.6', strategies: ['handoff'] }),
    makePreCompact({ keeper_name: 'keeper-gamma', trigger: 'token_cap', model_family: 'qwen-3', strategies: [] }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterPreCompactEvents(items, '')).toBe(items)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterPreCompactEvents(items, '   ')).toBe(items)
  })

  it('matches by keeper_name (case-insensitive)', () => {
    const result = filterPreCompactEvents(items, 'ALPHA')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-alpha'])
  })

  it('matches by trigger substring', () => {
    const result = filterPreCompactEvents(items, 'manual')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-beta'])
  })

  it('matches by model_family substring', () => {
    const result = filterPreCompactEvents(items, 'glm')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-beta'])
  })

  it('matches by strategies entry substring', () => {
    const result = filterPreCompactEvents(items, 'drop_old')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-alpha'])
  })

  it('matches strategies case-insensitively', () => {
    const result = filterPreCompactEvents(items, 'HANDOFF')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-beta'])
  })

  it('returns empty when no field matches', () => {
    expect(filterPreCompactEvents(items, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterPreCompactEvents(items, '  gamma  ')).toHaveLength(1)
  })

  it('does not mutate the input array', () => {
    const copy = items.slice()
    filterPreCompactEvents(items, 'alpha')
    expect(items).toEqual(copy)
  })
})

// ================================================================
// filterHandoffEvents
// ================================================================

function makeHandoff(overrides: Partial<HandoffEvent> = {}): HandoffEvent {
  return {
    timestamp: 1_700_000_000_000,
    keeper_name: 'keeper-alpha',
    trace_id: 'abc12345deadbeef',
    generation: 3,
    next_generation: 4,
    prev_trace_id: 'oldtrace0000',
    new_trace_id: 'newtrace9999',
    to_model: 'claude-sonnet',
    ...overrides,
  }
}

describe('filterHandoffEvents', () => {
  const items: HandoffEvent[] = [
    makeHandoff({ keeper_name: 'keeper-alpha', to_model: 'claude-sonnet', trace_id: 'alpha-trace-aaaa', prev_trace_id: 'prev-alpha', new_trace_id: 'new-alpha' }),
    makeHandoff({ keeper_name: 'keeper-beta', to_model: 'glm-4.6', trace_id: 'beta-trace-bbbb', prev_trace_id: 'prev-beta', new_trace_id: 'new-beta' }),
    makeHandoff({ keeper_name: 'keeper-gamma', to_model: null, trace_id: 'gamma-trace-cccc', prev_trace_id: null, new_trace_id: null }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterHandoffEvents(items, '')).toBe(items)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterHandoffEvents(items, '   ')).toBe(items)
  })

  it('matches by keeper_name (case-insensitive)', () => {
    const result = filterHandoffEvents(items, 'BETA')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-beta'])
  })

  it('matches by to_model substring', () => {
    const result = filterHandoffEvents(items, 'glm')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-beta'])
  })

  it('matches by trace_id substring', () => {
    const result = filterHandoffEvents(items, 'gamma-trace')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-gamma'])
  })

  it('matches by prev_trace_id substring', () => {
    const result = filterHandoffEvents(items, 'prev-alpha')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-alpha'])
  })

  it('matches by new_trace_id substring', () => {
    const result = filterHandoffEvents(items, 'new-beta')
    expect(result.map(r => r.keeper_name)).toEqual(['keeper-beta'])
  })

  it('handles null to_model safely', () => {
    expect(filterHandoffEvents(items, 'keeper-gamma')).toHaveLength(1)
  })

  it('returns empty when no field matches', () => {
    expect(filterHandoffEvents(items, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterHandoffEvents(items, '  alpha  ')).toHaveLength(1)
  })

  it('does not mutate the input array', () => {
    const copy = items.slice()
    filterHandoffEvents(items, 'alpha')
    expect(items).toEqual(copy)
  })
})
