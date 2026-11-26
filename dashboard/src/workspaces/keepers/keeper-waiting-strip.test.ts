import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import { groupMembers, groupWaitingRows, KeeperWaitingStrip } from './keeper-waiting-strip'
import type { KeeperWaitingInventoryData, KeeperWaitingRow } from './types'

function row(
  source: string,
  waitingOn: string,
  what: string,
  since: number | null,
  extra: Partial<KeeperWaitingRow> = {},
): KeeperWaitingRow {
  return {
    keeper_name: 'k', source, waiting_on: waitingOn, what, wake_producer: 'p',
    since, due_at: null, next_action: 'keeper_drain_event_queue', detail_lines: [],
    ...extra,
  }
}

function inventory(rows: readonly KeeperWaitingRow[]): KeeperWaitingInventoryData {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v4',
    keeper_count: 1,
    waiting_keeper_count: 1,
    row_count: rows.length,
    total_row_count: rows.length,
    oldest_age_seconds: null,
    rows,
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
    expect(groupMembers(groups[0]!)).toEqual([])
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

  // The server sends since = null for a reservation whose time has not come
  // and since = due_at once it is due (server_keeper_waiting_inventory.ml).
  it('counts a reservation group only from reservations that are due', () => {
    const future = row('schedule_waiting', 'keeper_wake', '예약 실행 · weekly', null, { due_at: 9_000 })
    const due = row('schedule_waiting', 'keeper_wake', '예약 실행 · weekly', 5_000, { due_at: 5_000 })
    expect(groupWaitingRows([future])[0]!.earliestSince).toBeNull()
    expect(groupWaitingRows([due])[0]!.earliestSince).toBe(5_000)
    expect(groupWaitingRows([future, due])[0]!.earliestSince).toBe(5_000)
  })
})

describe('groupMembers', () => {
  it('keeps every reason when rows of one kind share a sentence', () => {
    const [group] = groupWaitingRows([
      row('event_queue_pending', 'completion_authority_rejected', '완료 거절됨', 1, { detail_lines: ['거절 이유: 시험 없음'] }),
      row('event_queue_pending', 'completion_authority_rejected', '완료 거절됨', 2, { detail_lines: ['거절 이유: 증거 링크 없음'] }),
      row('event_queue_pending', 'completion_authority_rejected', '완료 거절됨', 3),
    ])
    expect(group!.sharedWhat).toBe('완료 거절됨')
    expect(groupMembers(group!).map((member) => [member.label, member.details])).toEqual([
      [null, ['거절 이유: 시험 없음']],
      [null, ['거절 이유: 증거 링크 없음']],
    ])
  })

  it('keeps each row sentence and its reasons when the sentences differ', () => {
    const [group] = groupWaitingRows([
      row('runtime_quota_spent', 'quota_window', 'a 경로 소진', 1, { detail_lines: ['a · rate_limit · 복귀 10:00'] }),
      row('runtime_quota_spent', 'quota_window', 'b 경로 소진', 2, { detail_lines: ['b · rate_limit · 복귀 11:00'] }),
    ])
    expect(groupMembers(group!).map((member) => [member.label, member.details])).toEqual([
      ['a 경로 소진', ['a · rate_limit · 복귀 10:00']],
      ['b 경로 소진', ['b · rate_limit · 복귀 11:00']],
    ])
  })
})

describe('KeeperWaitingStrip', () => {
  let host: HTMLDivElement | null = null

  afterEach(() => {
    if (host) {
      render(null, host)
      host.remove()
      host = null
    }
  })

  function mount(rows: readonly KeeperWaitingRow[], nowUnix = 10_000): HTMLDivElement {
    host = document.createElement('div')
    document.body.appendChild(host)
    render(html`<${KeeperWaitingStrip} inventory=${inventory(rows)} nowUnix=${nowUnix} />`, host)
    return host
  }

  it('shows the reason of every row in a group of two', () => {
    const root = mount([
      row('event_queue_pending', 'completion_authority_rejected', '완료 거절됨', 1, { detail_lines: ['거절 이유: 시험 없음'] }),
      row('event_queue_pending', 'completion_authority_rejected', '완료 거절됨', 2, { detail_lines: ['거절 이유: 증거 링크 없음'] }),
    ])
    const text = root.querySelector('[data-testid="chat-waiting-groups"]')!.textContent ?? ''
    expect(text).toContain('거절 이유: 시험 없음')
    expect(text).toContain('거절 이유: 증거 링크 없음')
  })

  it('shows no age for a reservation whose time has not come', () => {
    const root = mount([
      row('schedule_waiting', 'keeper_wake', '예약 실행 · weekly', null, { due_at: 20_000 }),
    ])
    expect(root.querySelector('.kp-waiting-age')).toBeNull()
  })

  it('makes the scrolling list a named region the keyboard can focus', () => {
    const root = mount([row('event_queue_pending', 'board_signal', 'Board 알림 대기 (즉시)', 500)])
    const region = root.querySelector<HTMLElement>('[data-testid="chat-waiting-groups"]')!
    expect(region.getAttribute('role')).toBe('region')
    expect(region.getAttribute('aria-label')).toBe('대기 목록')
    expect(region.tabIndex).toBe(0)
    root.querySelector('details')!.open = true
    region.focus()
    expect(document.activeElement).toBe(region)
  })
})
