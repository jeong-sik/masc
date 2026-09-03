import { describe, expect, it } from 'vitest'

import type { DashboardScheduledAutomationRequest } from '../../api'
import type { KeeperLifecycleEvent } from '../../api/keeper'
import type { CompositeObservation, SwimlaneSegment } from '../fsm-hub-types'
import { queueDrainStatusOf } from '../schedule/queue-drain-status'
import {
  DRAIN_PRESENT,
  DRAIN_QUEUE_AXIS,
  DRAIN_REACTION_AXIS,
  LANE_QUEUE_WINDOW_S,
  drainRowOfRequest,
  drainStateOfEvidence,
  laneAgoText,
  laneLifecycleItemOf,
  laneReading,
  laneSecText,
  laneStageBreakdown,
  laneUntilText,
  laneValueLabel,
  laneValueTone,
  positionLaneSegments,
  sortedDrainRows,
  waitAxisMaxMinutes,
  waitAxisPosition,
  waitingAgeMinutes,
  waitingDueMinutes,
  waitingRowsOldestFirst,
} from './lane-queue-model'
import type { DashboardKeeperWaitingKeeper, DashboardKeeperWaitingRow } from '../../api'

const NOW = 1_800_000_000

function observation(ts: number, overrides: Partial<Omit<CompositeObservation, 'ts'>> = {}): CompositeObservation {
  return {
    ts,
    phase: 'running',
    turn: 'idle',
    decision: 'undecided',
    runtime: 'idle',
    ...overrides,
  }
}

function waitingRow(overrides: Partial<DashboardKeeperWaitingRow> = {}): DashboardKeeperWaitingRow {
  return {
    source: 'event_queue_pending',
    waiting_on: 'masc.task_assigned',
    what: '새로 배정된 작업',
    next_action: 'keeper_process_event',
    ...overrides,
  }
}

function drainRequest(
  queue: string | null,
  reaction: string | null,
): DashboardScheduledAutomationRequest {
  return {
    schedule_id: 'sch_test',
    status: 'succeeded',
    source: 'test',
    ...(queue === null
      ? {}
      : { keeper_queue_evidence: { projection_status: queue } }),
    ...(reaction === null
      ? {}
      : { keeper_reaction_evidence: { projection_status: reaction } }),
  } as DashboardScheduledAutomationRequest
}

describe('laneReading', () => {
  it('returns null when nothing has been observed', () => {
    expect(laneReading([], 'turn', false, NOW)).toBeNull()
  })

  it('reads the current value with elapsed hold time', () => {
    const observations = [observation(NOW - 100), observation(NOW - 40, { turn: 'executing' })]
    const reading = laneReading(observations, 'turn', true, NOW)
    expect(reading).toMatchObject({ value: 'executing', observedForSec: 40, stalled: false, transitionCount: 1 })
    expect(reading?.meaning).toBe('모델을 부르거나 도구를 쓰는 중')
  })

  it('flags a stall once the value holds past the lane threshold', () => {
    const observations = [observation(NOW - 100), observation(NOW - 50, { turn: 'executing' })]
    const reading = laneReading(observations, 'turn', true, NOW)
    expect(reading?.stalled).toBe(true)
    expect(reading?.meaning).toBe('이 상태에서 너무 오래 멈춰 있습니다')
    expect(reading?.meaningDev).toContain('정체')
  })

  it('uses the live flag to disambiguate idle readings', () => {
    const observations = [observation(NOW - 10)]
    expect(laneReading(observations, 'turn', true, NOW)?.meaning).toContain('턴은 열려 있지만')
    expect(laneReading(observations, 'turn', false, NOW)?.meaning).toBe('지금 맡은 턴이 없다')
  })

  it('falls back for values outside the closed vocabulary', () => {
    const observations = [observation(NOW - 10, { runtime: 'brand_new_state' })]
    const reading = laneReading(observations, 'runtime', false, NOW)
    expect(reading?.value).toBe('brand_new_state')
    expect(reading?.meaning).toBe('상태만 확인됨')
    expect(laneValueLabel('brand_new_state')).toBe('brand_new_state')
    expect(laneValueTone('brand_new_state')).toBe('info')
  })
})

describe('positionLaneSegments', () => {
  const segments: SwimlaneSegment[] = [
    { from: NOW - 3000, to: NOW - 600, value: 'idle' },
    { from: NOW - 600, to: NOW - 60, value: 'executing' },
    { from: NOW - 60, to: NOW, value: 'finalizing' },
  ]
  const windowStart = NOW - LANE_QUEUE_WINDOW_S

  it('clips segments that started before the window', () => {
    const positioned = positionLaneSegments(segments, windowStart, NOW)
    expect(positioned).toHaveLength(3)
    const [first, , last] = positioned
    expect(first?.clipped).toBe(true)
    expect(first?.leftPct).toBe(0)
    expect(first?.widthPct).toBeCloseTo(((LANE_QUEUE_WINDOW_S - 600) / LANE_QUEUE_WINDOW_S) * 100)
    expect(first?.durSec).toBe(2400)
    expect(last?.last).toBe(true)
    expect((last?.leftPct ?? 0) + (last?.widthPct ?? 0)).toBeCloseTo(100)
  })

  it('drops segments fully outside the window', () => {
    const ancient: SwimlaneSegment[] = [{ from: NOW - 5000, to: NOW - 4000, value: 'idle' }]
    expect(positionLaneSegments(ancient, windowStart, NOW)).toHaveLength(0)
  })
})

describe('laneSecText / laneAgoText / laneUntilText', () => {
  it('formats compact durations', () => {
    expect(laneSecText(12)).toBe('12s')
    expect(laneSecText(240)).toBe('4m')
    expect(laneSecText(5400)).toBe('1.5h')
  })

  it('formats ages and deadlines in the design vocabulary', () => {
    expect(laneAgoText(null)).toBe('시각 미기록')
    expect(laneAgoText(11)).toBe('11분 전')
    expect(laneAgoText(130)).toBe('2시간 전')
    expect(laneAgoText(3000)).toBe('2일 전')
    expect(laneUntilText(1049)).toBe('17시간 후')
  })
})

describe('waiting inventory derivations', () => {
  it('sorts waiting rows oldest first, missing timestamps last', () => {
    const rows = [
      waitingRow({ waiting_on: 'b', since: NOW - 60 }),
      waitingRow({ waiting_on: 'a', since: NOW - 3600 }),
      waitingRow({ waiting_on: 'c' }),
    ]
    expect(waitingRowsOldestFirst(rows).map(r => r.waiting_on)).toEqual(['a', 'b', 'c'])
  })

  it('computes ages from since or since_iso', () => {
    expect(waitingAgeMinutes(waitingRow({ since: NOW - 600 }), NOW)).toBe(10)
    expect(waitingAgeMinutes(waitingRow({ since: null, since_iso: new Date((NOW - 3600) * 1000).toISOString() }), NOW)).toBe(60)
    expect(waitingAgeMinutes(waitingRow({ since: null, since_iso: null }), NOW)).toBeNull()
  })

  it('keeps the log axis at least one day wide', () => {
    expect(waitAxisMaxMinutes([null, 30])).toBe(1440)
    expect(waitAxisMaxMinutes([3000])).toBe(3000)
    expect(waitAxisPosition(0, 1440)).toBe(0)
    expect(waitAxisPosition(1440, 1440)).toBeCloseTo(100)
  })

  it('computes due-soon minutes from due_at or due_at_iso', () => {
    expect(waitingDueMinutes(waitingRow({ due_at: NOW + 600 }), NOW)).toBe(10)
    expect(waitingDueMinutes(waitingRow({ due_at: null, due_at_iso: new Date((NOW + 3600) * 1000).toISOString() }), NOW)).toBe(60)
    expect(waitingDueMinutes(waitingRow({ due_at: null, due_at_iso: null }), NOW)).toBeNull()
  })

  it('groups sources into pipeline stages and keeps unknown sources visible', () => {
    const entry = {
      keeper_name: 'k',
      state: 'waiting',
      waiting_on: [],
      waiting_count: 5,
      sources: { event_queue_pending: 3, hitl_pending: 1, future_source: 1 },
    } as unknown as DashboardKeeperWaitingKeeper
    const { byStage, unknown } = laneStageBreakdown(entry)
    expect(byStage.queue.map(i => i.source)).toEqual(['event_queue_pending'])
    expect(byStage.queue[0]?.count).toBe('3')
    expect(byStage.operator.map(i => i.source)).toEqual(['hitl_pending'])
    expect(byStage.external).toHaveLength(0)
    expect(unknown.map(i => i.source)).toEqual(['future_source'])
  })
})

describe('drain evidence', () => {
  it('mirrors queueDrainStatusOf for every matrix axis combination', () => {
    for (const queue of DRAIN_QUEUE_AXIS) {
      for (const reaction of DRAIN_REACTION_AXIS) {
        const viaRequest = queueDrainStatusOf(drainRequest(queue, reaction))?.state ?? null
        expect(drainStateOfEvidence(queue, reaction), `${queue} × ${reaction}`).toBe(viaRequest)
      }
    }
    expect(drainStateOfEvidence(null, null)).toBeNull()
  })

  it('drops requests without queue evidence', () => {
    expect(drainRowOfRequest(drainRequest(null, null))).toBeNull()
  })

  it('flattens keeper, payload and wake time from the evidence', () => {
    const request = {
      schedule_id: 'sch_77a0',
      status: 'succeeded',
      source: 'test',
      payload_summary: 'daily-news 발행',
      payload_target: 'sangsu',
      last_wake: { schedule_id: 'sch_77a0', status: 'succeeded', started_at: NOW - 60 },
      keeper_queue_evidence: { projection_status: 'matched_pending', keeper_name: 'sangsu' },
    } as unknown as DashboardScheduledAutomationRequest
    const row = drainRowOfRequest(request)
    expect(row).toMatchObject({
      scheduleId: 'sch_77a0',
      keeper: 'sangsu',
      payload: 'daily-news 발행',
      state: 'pending',
    })
    expect(row?.atIso).toBe(new Date((NOW - 60) * 1000).toISOString())
  })

  it('sorts actionable verdicts before healthy completions', () => {
    const rows = sortedDrainRows([
      { ...drainRequest('not_found', 'matched_turn_started'), schedule_id: 'drained' },
      { ...drainRequest('matched_pending', null), schedule_id: 'pending' },
      { ...drainRequest('not_found', 'matched_stimulus'), schedule_id: 'missed' },
      { ...drainRequest('read_error', null), schedule_id: 'err' },
    ])
    expect(rows.map(r => r.scheduleId)).toEqual(['missed', 'err', 'pending', 'drained'])
    expect(DRAIN_PRESENT.missed.tone).toBe('bad')
    expect(DRAIN_PRESENT.drained.tone).toBe('ok')
  })
})

describe('laneLifecycleItemOf', () => {
  it('maps supervisor events to design labels and tones', () => {
    const event: KeeperLifecycleEvent = { ts: NOW - 540, event: 'restarted', phase: 'Failing', detail: '재시작' }
    expect(laneLifecycleItemOf(event, NOW)).toMatchObject({
      label: '재시작됨',
      tone: 'warn',
      phase: 'Failing',
      ageMinutes: 9,
    })
  })

  it('keeps unknown events opaque instead of dropping them', () => {
    const event: KeeperLifecycleEvent = { ts: 0, event: 'future_event', phase: null, detail: '' }
    const item = laneLifecycleItemOf(event, NOW)
    expect(item.label).toBe('future event')
    expect(item.tone).toBe('info')
    expect(item.ageMinutes).toBeNull()
  })
})
