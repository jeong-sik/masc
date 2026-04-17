import { describe, it, expect } from 'vitest'
import {
  railStatusLabel,
  statusChipClass,
  freshnessLabel,
  heroTitle,
  heroBody,
  railDetail,
  railFreshness,
} from './harness-health-sections'
import type { HarnessHealthData } from './harness-health-state'

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
