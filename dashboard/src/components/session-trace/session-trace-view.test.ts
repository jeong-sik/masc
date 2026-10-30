// @vitest-environment happy-dom
import { h } from 'preact'
import { render, waitFor } from '@testing-library/preact'
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import type { AgentTimelineEvent, AgentTimelineResponse } from '../../api/dashboard'
import { SessionTraceView } from './session-trace-view'
import { closeSessionTrace, traceSlots } from './session-trace-state'
import { liveTraceFeeds } from './session-trace-live-store'

const dashboardApiMocks = vi.hoisted(() => ({
  fetchAgentTimeline: vi.fn(),
  fetchKeeperToolCalls: vi.fn(),
  fetchKeeperTrajectory: vi.fn(),
}))

vi.mock('../../api/dashboard', () => dashboardApiMocks)

vi.mock('../common/time-ago', () => ({
  TimeAgo: ({ timestamp }: { timestamp: string }) =>
    h('span', { 'data-testid': 'time-ago' }, timestamp),
}))

function timelineResponse(events: AgentTimelineEvent[] = []): AgentTimelineResponse {
  return {
    agent: 'keeper-a',
    period: { from: '', to: '' },
    events,
    summary: {
      tasks_completed: 0,
      tasks_claimed: 0,
      messages_sent: 0,
      active_duration_minutes: 0,
      total_events: events.length,
    },
  }
}

beforeEach(() => {
  traceSlots.value = {}
  liveTraceFeeds.value = {}
  dashboardApiMocks.fetchAgentTimeline.mockResolvedValue(
    timelineResponse([
      {
        ts: '2026-04-03T00:00:00Z',
        type: 'task_completed',
        detail: { task_id: 'task-1', title: 'Do thing' },
      },
    ]),
  )
  dashboardApiMocks.fetchKeeperToolCalls.mockResolvedValue({ entries: [] })
  dashboardApiMocks.fetchKeeperTrajectory.mockResolvedValue(null)
})

afterEach(() => {
  closeSessionTrace('keeper-a')
  vi.clearAllMocks()
})

describe('SessionTraceView', () => {
  it('applies v2-monitoring-trace-surface marker class', async () => {
    const { container } = render(
      h(SessionTraceView, { agentName: 'keeper-a', isKeeper: false }),
    )
    await waitFor(() => {
      expect(container.querySelector('.v2-monitoring-trace-surface')).not.toBeNull()
    })
  })

  // 예전에는 `keeper.status` 문자열을 받아 이 컴포넌트가 직접 분류했다. 그
  // 단어는 health 와 phase 를 한 번 접은 값이라, 살아 있는 키퍼가 offline 으로
  // 적힌 행에서 "기동 시 기록 시작" 이라는 틀린 안내가 나왔다.
  it('꺼진 키퍼에게만 기동 안내를 쓴다', async () => {
    dashboardApiMocks.fetchAgentTimeline.mockResolvedValue(timelineResponse([]))
    const { container } = render(
      h(SessionTraceView, { agentName: 'keeper-a', isKeeper: true, keeperOffline: true }),
    )
    await waitFor(() => {
      expect(container.textContent).not.toContain('불러오는 중')
    })
    expect(container.textContent).toContain('오프라인 — 기동 시 기록 시작')
  })

  it('살아 있는 키퍼에게는 활동이 없다고만 쓴다', async () => {
    dashboardApiMocks.fetchAgentTimeline.mockResolvedValue(timelineResponse([]))
    const { container } = render(
      h(SessionTraceView, { agentName: 'keeper-a', isKeeper: true, keeperOffline: false }),
    )
    await waitFor(() => {
      expect(container.textContent).not.toContain('불러오는 중')
    })
    expect(container.textContent).toContain('기록된 활동 없음')
    expect(container.textContent).not.toContain('기동 시 기록 시작')
  })
})
