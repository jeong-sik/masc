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
})
