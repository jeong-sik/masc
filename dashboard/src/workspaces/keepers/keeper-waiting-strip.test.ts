import { describe, expect, it } from 'vitest'
import { groupWaitingRows } from './keeper-waiting-strip'
import type { KeeperWaitingRow } from './types'

function row(source: string, waitingOn: string, what: string, since: number | null): KeeperWaitingRow {
  return {
    keeper_name: 'k', source, waiting_on: waitingOn, what, wake_producer: 'p',
    since, due_at: null, next_action: 'keeper_drain_event_queue', detail_lines: [],
  }
}

describe('groupWaitingRows', () => {
  it('collapses rows of one kind into a group with a count and the earliest since', () => {
    const rows = [
      ...Array.from({ length: 123 }, (_, i) => row('event_queue_pending', 'tool_result_ready', '이전 실행 결과 회수 (즉시)', 1000 + i)),
      row('event_queue_pending', 'board_signal', 'Board 알림 대기 (즉시)', 500),
    ]
    const groups = groupWaitingRows(rows)
    expect(groups.map((g) => [g.waitingOn, g.rows.length, g.earliestSince, g.sharedWhat])).toEqual([
      ['tool_result_ready', 123, 1000, '이전 실행 결과 회수 (즉시)'],
      ['board_signal', 1, 500, 'Board 알림 대기 (즉시)'],
    ])
    expect(groups[0]!.nextActions).toEqual(['keeper_drain_event_queue'])
  })

  it('has no shared sentence when the rows of a kind say different things', () => {
    const groups = groupWaitingRows([
      row('event_queue_pending', 'keeper_delegate_completed', 'mother의 답 도착', 10),
      row('event_queue_pending', 'keeper_delegate_completed', 'sister의 답 도착', null),
    ])
    expect(groups).toHaveLength(1)
    expect(groups[0]!.sharedWhat).toBeNull()
    expect(groups[0]!.earliestSince).toBe(10)
  })

  it('keeps the same waiting_on from different sources apart', () => {
    const groups = groupWaitingRows([
      row('event_queue_pending', 'x', 'a', null),
      row('schedule_waiting', 'x', 'a', null),
    ])
    expect(groups).toHaveLength(2)
  })
})
