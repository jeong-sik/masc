import { h } from 'preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  computeFunnelCounts,
  formatTargetRatio,
  pickActiveKeepers,
  severityToneClass,
  deriveAgentAlerts,
  deriveTaskAlerts,
  deriveFleetTickerEvents,
  deriveKeeperAttentionReason,
  pickAttentionKeepers,
  computeOverviewStats,
  computeOverviewDigest,
  buildOverviewTelemetrySnapshot,
  keeperRuntimeLabel,
  OVERVIEW_TELEMETRY_BAR_COUNT,
  OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET,
  OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT,
  type FunnelCounts,
  Overview,
} from './overview'
import type {
  DashboardScheduledAutomationAvailableData,
  DashboardScheduledAutomationProjection,
  DashboardScheduledAutomationRequest,
  DashboardScheduleRunnerStatus,
  FusionRunRecord,
  TelemetryEntry,
  TelemetrySourceSummary,
} from '../../api/dashboard'
import { keepers, boardPosts, boardTotal, lastBoardRefreshAt, shellRuntimeResolution } from '../../store'
import type { Goal } from '../../types/core'
import { dashboardFullHealthResource } from '../dashboard-full-health-state'

const overviewMocks = vi.hoisted(() => ({
  scheduledAutomationProjection: { value: null as null | DashboardScheduledAutomationProjection },
}))

vi.mock('../schedule/schedule-state', () => ({
  scheduledAutomationProjection: overviewMocks.scheduledAutomationProjection,
  subscribeScheduledAutomationRefresh: () => () => {},
}))

afterEach(() => {
  dashboardFullHealthResource.reset()
})

// bar-seg ratio helper (mirrors FunnelCard inline logic)
function segPct(counts: FunnelCounts, key: 'created' | 'inProgress' | 'awaiting' | 'completed'): number {
  const total = counts.created + counts.inProgress + counts.awaiting + counts.completed
  return total > 0 ? (counts[key] / total) * 100 : 0
}
import type { Agent, Task, Keeper, Message, BoardPost } from '../../types/core'

const FIXED_NOW = new Date(2026, 3, 18, 10, 0, 0, 0).getTime()

function localIsoAt(
  hour: number,
  minute: number = 0,
  second: number = 0,
  dayOffset: number = 0,
): string {
  const d = new Date(FIXED_NOW)
  d.setDate(d.getDate() + dayOffset)
  d.setHours(hour, minute, second, 0)
  return d.toISOString()
}

function makeTask(partial: Partial<Task>): Task {
  return { id: 't-1', title: 't', ...partial }
}

function makeKeeper(partial: Partial<Keeper>): Keeper {
  return { name: 'k', status: 'active', ...partial }
}

function makeMessage(partial: Partial<Message>): Message {
  return { id: 'm-1', content: 'message', ...partial }
}

function makeBoardPost(partial: Partial<BoardPost>): BoardPost {
  return {
    id: 'p-1',
    author: 'keeper',
    title: 'post',
    body: 'body',
    tags: [],
    votes: 0,
    comment_count: 0,
    created_at: localIsoAt(1),
    updated_at: localIsoAt(1),
    ...partial,
  }
}

function makeScheduledAutomation(
  partial: Partial<DashboardScheduledAutomationAvailableData> = {},
): DashboardScheduledAutomationProjection {
  const data: DashboardScheduledAutomationAvailableData = {
    status: 'ok',
    schedule_store_known: true,
    schedule_store_read_error: null,
    request_count: 3,
    request_limit: 10,
    truncated: false,
    counts: {
      scheduled: 1,
      due: 1,
      running: 0,
      succeeded: 1,
    },
    warnings: [],
    fsm: {
      state: 'due',
      active_count: 1,
      terminal_count: 1,
      next_due_at: '2026-07-18T12:00:00Z',
    },
    requests: [
      {
        schedule_id: 's-1',
        status: 'scheduled',
        source: 'operator',
      },
      {
        schedule_id: 's-2',
        status: 'due',
        source: 'operator',
        payload_support: 'unsupported',
      },
      {
        schedule_id: 's-3',
        status: 'succeeded',
        source: 'operator',
        payload_support: 'unknown',
      },
    ],
    ...partial,
  }
  return {
    state: 'available',
    data,
    page: {
      visibleCount: data.requests.length,
      totalCount: data.request_count,
      limit: data.request_limit,
      truncated: data.truncated,
    },
  }
}

function makeScheduleRunner(partial: Partial<DashboardScheduleRunnerStatus> = {}): DashboardScheduleRunnerStatus {
  return {
    schema: 'masc.schedule.runner_status.v1',
    status: 'ok',
    tick_in_flight: false,
    tick_count: 3,
    success_count: 2,
    failure_count: 0,
    crash_count: 0,
    last_tick_started_at: 1_700_000_100,
    last_tick_finished_at: 1_700_000_200,
    last_success_at: 1_700_000_200,
    last_error: null,
    last_error_at: null,
    last_duration_sec: 0.12,
    last_counts: {
      due_changed: 1,
      emitted: 2,
      rescheduled: 0,
      dispatch_succeeded: 1,
      dispatch_failed: 0,
      dispatch_unsupported: 0,
      dispatch_start_rejected: 0,
      wake_enqueued: 3,
      wake_skipped_no_keeper: 0,
      wake_skipped_missing_schedule: 0,
      wake_skipped_non_keeper_actor: 0,
      wake_skipped_unregistered_keeper: 0,
      wake_failed: 0,
    },
    ...partial,
  }
}

describe('computeFunnelCounts', () => {
  it('counts today-created tasks regardless of status', () => {
    const tasks = [
      makeTask({ id: 'a', created_at: localIsoAt(1), status: 'todo' }),
      makeTask({ id: 'b', created_at: localIsoAt(9, 59), status: 'in_progress' }),
      makeTask({ id: 'c', created_at: localIsoAt(23, 59, 59, -1), status: 'todo' }),
    ]
    const counts = computeFunnelCounts(tasks, FIXED_NOW)
    expect(counts.created).toBe(2)
  })

  it('groups claimed + in_progress as inProgress', () => {
    const tasks = [
      makeTask({ id: 'a', status: 'claimed' }),
      makeTask({ id: 'b', status: 'in_progress' }),
      makeTask({ id: 'c', status: 'todo' }),
    ]
    const counts = computeFunnelCounts(tasks, FIXED_NOW)
    expect(counts.inProgress).toBe(2)
  })

  it('separates awaiting_verification from other statuses', () => {
    const tasks = [
      makeTask({ id: 'a', status: 'awaiting_verification' }),
      makeTask({ id: 'b', status: 'done', completed_at: localIsoAt(5) }),
    ]
    const counts = computeFunnelCounts(tasks, FIXED_NOW)
    expect(counts.awaiting).toBe(1)
    expect(counts.completed).toBe(1)
  })

  it('counts only today-completed done tasks', () => {
    const tasks = [
      makeTask({ id: 'a', status: 'done', completed_at: localIsoAt(5) }),
      makeTask({ id: 'b', status: 'done', completed_at: localIsoAt(23, 0, 0, -1) }),
      makeTask({ id: 'c', status: 'done' }),
    ]
    const counts = computeFunnelCounts(tasks, FIXED_NOW)
    expect(counts.completed).toBe(1)
  })

  it('has no synthetic target', () => {
    expect(computeFunnelCounts([], FIXED_NOW).target).toBeNull()
  })

  it('ignores invalid ISO timestamps', () => {
    const tasks = [
      makeTask({ id: 'a', created_at: 'not-a-date', status: 'todo' }),
      makeTask({ id: 'b', created_at: '', status: 'done', completed_at: 'nope' }),
    ]
    const counts = computeFunnelCounts(tasks, FIXED_NOW)
    expect(counts.created).toBe(0)
    expect(counts.completed).toBe(0)
  })

  it('bar-seg ratio sums to ~100% across all funnel stages', () => {
    const tasks = [
      makeTask({ id: 'a', created_at: localIsoAt(1), status: 'in_progress' }),
      makeTask({ id: 'b', created_at: localIsoAt(2), status: 'awaiting_verification' }),
      makeTask({ id: 'c', created_at: localIsoAt(3), status: 'done', completed_at: localIsoAt(4) }),
    ]
    const counts = computeFunnelCounts(tasks, FIXED_NOW)
    const total = counts.created + counts.inProgress + counts.awaiting + counts.completed
    const pcts = [counts.inProgress, counts.awaiting, counts.completed, counts.created]
      .map(n => total > 0 ? (n / total) * 100 : 0)
    const sum = pcts.reduce((a, b) => a + b, 0)
    expect(Math.round(sum)).toBe(100)
  })

  it('bar-seg ratio returns 0 when funnel is empty', () => {
    const counts = computeFunnelCounts([], FIXED_NOW)
    expect(segPct(counts, 'created')).toBe(0)
    expect(segPct(counts, 'completed')).toBe(0)
  })
})

describe('formatTargetRatio', () => {
  const base: FunnelCounts = {
    created: 0,
    inProgress: 0,
    awaiting: 0,
    completed: 0,
    target: null,
  }

  it('returns just the completed count when target is null', () => {
    expect(formatTargetRatio({ ...base, completed: 3 })).toBe('3')
  })

  it('formats ratio as n/m (p%)', () => {
    expect(formatTargetRatio({ ...base, completed: 4, target: 10 })).toBe('4/10 (40%)')
  })

  it('caps percentage at 100 when completed exceeds target', () => {
    expect(formatTargetRatio({ ...base, completed: 20, target: 5 })).toBe('20/5 (100%)')
  })
})

describe('pickActiveKeepers', () => {
  it('returns empty when no keepers', () => {
    expect(pickActiveKeepers([])).toEqual([])
  })

  it('sorts by latest heartbeat descending', () => {
    const keepers: Keeper[] = [
      makeKeeper({ name: 'old', last_heartbeat: '2026-04-18T08:00:00+09:00' }),
      makeKeeper({ name: 'new', last_heartbeat: '2026-04-18T09:59:00+09:00' }),
      makeKeeper({ name: 'middle', last_heartbeat: '2026-04-18T09:00:00+09:00' }),
    ]
    const picked = pickActiveKeepers(keepers, 3)
    expect(picked.map(k => k.name)).toEqual(['new', 'middle', 'old'])
  })

  it('deprioritizes paused keepers even with recent heartbeat', () => {
    const keepers: Keeper[] = [
      makeKeeper({
        name: 'paused-recent',
        paused: true,
        last_heartbeat: '2026-04-18T09:59:00+09:00',
      }),
      makeKeeper({ name: 'active-older', last_heartbeat: '2026-04-18T08:00:00+09:00' }),
    ]
    const picked = pickActiveKeepers(keepers, 2)
    expect(picked[0]?.name).toBe('active-older')
  })

  it('deprioritizes phase-paused keepers even when the paused flag is absent', () => {
    const keepers: Keeper[] = [
      makeKeeper({
        name: 'phase-paused-recent',
        status: 'offline',
        phase: 'Paused',
        pipeline_stage: 'paused',
        last_heartbeat: '2026-04-18T09:59:00+09:00',
      }),
      makeKeeper({ name: 'active-older', status: 'busy', last_heartbeat: '2026-04-18T08:00:00+09:00' }),
    ]
    const picked = pickActiveKeepers(keepers, 2)
    expect(picked[0]?.name).toBe('active-older')
  })

  it('respects max parameter', () => {
    const keepers: Keeper[] = Array.from({ length: 5 }, (_, i) =>
      makeKeeper({ name: `k${i}`, last_heartbeat: `2026-04-18T0${i}:00:00+09:00` }),
    )
    expect(pickActiveKeepers(keepers, 2)).toHaveLength(2)
  })
})

describe('deriveFleetTickerEvents', () => {
  it('combines recent task, message, board, and keeper events in newest-first order', () => {
    const events = deriveFleetTickerEvents({
      taskList: [makeTask({ id: 'task-old', title: 'Old task', updated_at: localIsoAt(1), status: 'in_progress' })],
      messageList: [makeMessage({ id: 'msg-new', from: 'sangsu', content: 'new message', timestamp: localIsoAt(4) })],
      boardPostList: [makeBoardPost({ id: 'post-mid', title: 'Board post', updated_at: localIsoAt(3), created_at: localIsoAt(2) })],
      keeperList: [makeKeeper({ name: 'keeper-mid', last_heartbeat: localIsoAt(2), status: 'active' })],
    })

    expect(events.map(event => event.id)).toEqual([
      'message:msg-new',
      'board:post-mid',
      'keeper:keeper-mid',
      'task:task-old',
    ])
  })

  it('drops events without valid timestamps or readable text', () => {
    const events = deriveFleetTickerEvents({
      taskList: [makeTask({ id: 'bad-task', title: 'Bad', updated_at: 'not-a-date' })],
      messageList: [makeMessage({ id: 'blank-message', content: '   ', timestamp: localIsoAt(4) })],
      boardPostList: [makeBoardPost({ id: 'blank-post', title: '', body: '', updated_at: localIsoAt(3) })],
      keeperList: [makeKeeper({ name: 'no-heartbeat' })],
    })

    expect(events).toEqual([])
  })

  it('uses trimmed board body fallback when title or author is whitespace', () => {
    const events = deriveFleetTickerEvents({
      taskList: [],
      messageList: [],
      boardPostList: [
        makeBoardPost({
          id: 'post-whitespace-title',
          author: '   ',
          title: '   ',
          body: 'body fallback',
          updated_at: localIsoAt(3),
        }),
      ],
      keeperList: [],
    })

    expect(events).toHaveLength(1)
    expect(events[0]?.id).toBe('board:post-whitespace-title')
    expect(events[0]?.actor).toBe('board')
    expect(events[0]?.text).toBe('body fallback')
  })

  it('limits output and maps operational tones', () => {
    const events = deriveFleetTickerEvents({
      max: 2,
      taskList: [
        makeTask({ id: 'done', title: 'Done task', updated_at: localIsoAt(4), status: 'done' }),
        makeTask({ id: 'verify', title: 'Verify task', updated_at: localIsoAt(3), status: 'awaiting_verification' }),
        makeTask({ id: 'cancelled', title: 'Cancelled task', updated_at: localIsoAt(2), status: 'cancelled' }),
      ],
      messageList: [],
      boardPostList: [],
      keeperList: [],
    })

    expect(events).toHaveLength(2)
    expect(events.map(event => event.id)).toEqual(['task:done', 'task:verify'])
    expect(events.map(event => event.tone)).toEqual(['ok', 'warn'])
  })

  it('uses keeper pause truth for heartbeat ticker text and tone', () => {
    const events = deriveFleetTickerEvents({
      taskList: [],
      messageList: [],
      boardPostList: [],
      keeperList: [
        makeKeeper({
          name: 'sangsu',
          status: 'offline',
          phase: 'Paused',
          pipeline_stage: 'paused',
          last_heartbeat: localIsoAt(4),
        }),
      ],
    })

    expect(events).toHaveLength(1)
    expect(events[0]?.text).toBe('일시정지')
    expect(events[0]?.tone).toBe('warn')
  })
})

describe('severityToneClass', () => {
  it.each<[string | null | undefined, string]>([
    ['critical', 'text-destructive'],
    ['HIGH', 'text-destructive'],
    ['warn', 'text-warning'],
    ['medium', 'text-warning'],
    ['info', 'text-text-tertiary'],
    ['', 'text-text-tertiary'],
    [null, 'text-text-tertiary'],
    [undefined, 'text-text-tertiary'],
  ])('maps severity %s to expected tone', (input, expected) => {
    expect(severityToneClass(input)).toBe(expected)
  })
})

// ─── Alert Panel helpers ──────────────────────────────────────────────────────

function makeAgent(partial: Partial<Agent> = {}): Agent {
  return { name: 'agent-1', current_task: null, ...partial }
}

describe('deriveAgentAlerts', () => {
  it('returns empty array when no agents', () => {
    expect(deriveAgentAlerts([])).toEqual([])
  })

  it('returns empty array when all agents are healthy', () => {
    const agents: Agent[] = [
      makeAgent({ name: 'a1', status: 'active' }),
      makeAgent({ name: 'a2', status: 'busy' }),
      makeAgent({ name: 'a3', status: 'idle' }),
    ]
    expect(deriveAgentAlerts(agents)).toHaveLength(0)
  })

  it('returns critical alert for offline agent', () => {
    const alerts = deriveAgentAlerts([makeAgent({ name: 'a1', status: 'offline' })])
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.severity).toBe('critical')
    expect(alerts[0]!.name).toBe('a1')
    expect(alerts[0]!.reason).toBe('Offline')
  })

  it('returns critical alert for inactive agent', () => {
    const alerts = deriveAgentAlerts([makeAgent({ name: 'a1', status: 'inactive' })])
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.severity).toBe('critical')
    expect(alerts[0]!.reason).toBe('Inactive')
  })

  it('uses koreanName as display when available', () => {
    const alerts = deriveAgentAlerts([makeAgent({ name: 'a1', status: 'offline', koreanName: '수호자' })])
    expect(alerts[0]!.display).toBe('수호자')
  })

  it('falls back to name when koreanName is empty', () => {
    const alerts = deriveAgentAlerts([makeAgent({ name: 'a1', status: 'offline', koreanName: '' })])
    expect(alerts[0]!.display).toBe('a1')
  })

  it('returns multiple alerts for multiple failing agents', () => {
    const agents: Agent[] = [
      makeAgent({ name: 'a1', status: 'offline' }),
      makeAgent({ name: 'a2', status: 'inactive' }),
      makeAgent({ name: 'a3', status: 'active' }),
    ]
    expect(deriveAgentAlerts(agents)).toHaveLength(2)
  })
})

describe('deriveTaskAlerts', () => {
  const NOW = new Date('2026-04-18T12:00:00Z').getTime()
  const STALE_UPDATED = new Date('2026-04-18T11:00:00Z').toISOString() // 60 min ago → stale
  const FRESH_UPDATED = new Date('2026-04-18T11:55:00Z').toISOString() // 5 min ago → not stale

  it('returns empty array when no tasks', () => {
    expect(deriveTaskAlerts([], NOW)).toEqual([])
  })

  it('returns empty array when no awaiting_verification tasks', () => {
    const tasks: Task[] = [makeTask({ status: 'in_progress' }), makeTask({ status: 'done' })]
    expect(deriveTaskAlerts(tasks, NOW)).toHaveLength(0)
  })

  it('returns warn alert for stale awaiting_verification task', () => {
    const tasks: Task[] = [makeTask({ id: 't1', status: 'awaiting_verification', updated_at: STALE_UPDATED })]
    const alerts = deriveTaskAlerts(tasks, NOW)
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.severity).toBe('warn')
    expect(alerts[0]!.status).toBe('awaiting_verification')
  })

  it('does not alert for recently updated awaiting_verification task', () => {
    const tasks: Task[] = [makeTask({ id: 't1', status: 'awaiting_verification', updated_at: FRESH_UPDATED })]
    expect(deriveTaskAlerts(tasks, NOW)).toHaveLength(0)
  })

  it('treats missing updated_at as stale', () => {
    const tasks: Task[] = [makeTask({ id: 't1', status: 'awaiting_verification' })]
    const alerts = deriveTaskAlerts(tasks, NOW)
    expect(alerts).toHaveLength(1)
  })

  it('treats invalid updated_at as stale', () => {
    const tasks: Task[] = [
      makeTask({ id: 't1', status: 'awaiting_verification', updated_at: 'not-a-date' }),
    ]
    const alerts = deriveTaskAlerts(tasks, NOW)
    expect(alerts).toHaveLength(1)
  })

  it('returns task id and title in alert', () => {
    const tasks: Task[] = [makeTask({ id: 't99', title: 'Fix bug', status: 'awaiting_verification', updated_at: STALE_UPDATED })]
    const alerts = deriveTaskAlerts(tasks, NOW)
    expect(alerts[0]!.id).toBe('t99')
    expect(alerts[0]!.title).toBe('Fix bug')
  })

  it('returns assignee in alert when present', () => {
    const tasks: Task[] = [makeTask({ id: 't1', status: 'awaiting_verification', updated_at: STALE_UPDATED, assignee: 'agent-x' })]
    expect(deriveTaskAlerts(tasks, NOW)[0]!.assignee).toBe('agent-x')
  })
})

describe('deriveKeeperAttentionReason', () => {
  it('returns default warn reason when keeper has no attention signal', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({ name: 'plain' }))
    expect(reason.sev).toBe('warn')
    expect(reason.text).toBe('주의 사유 미보고')
    expect(reason.act).toBe('상태 상세')
  })

  it('uses runtime blocker semantics without a separate continuation approval state', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'gate',
      runtime_blocker_class: 'fiber_unresolved',
    }))
    expect(reason.sev).toBe('warn')
    expect(reason.act).toBe('상태 상세')
  })

  it('marks critical lifecycle states as bad', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'crashed',
      lifecycle_phase: 'Crashed',
      runtime_blocker_class: 'exception',
    }))
    expect(reason.sev).toBe('bad')
    expect(reason.act).toBe('재시작')
  })

  it('surfaces trust attention_reason as warn', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'trust',
      trust: {
        needs_attention: true,
        attention_reason: '승인 대기 3건',
        next_human_action: '승인 검토',
      },
    }))
    expect(reason.sev).toBe('warn')
    expect(reason.text).toBe('승인 대기 3건')
    expect(reason.act).toBe('승인 검토')
  })

  it('humanizes known attention_reason / next_human_action wire codes', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'coded',
      attention_reason: 'runtime_blocked',
      next_human_action: 'inspect_latest_error',
    }))
    expect(reason.text).toBe('런타임 근거 확인 필요')
    expect(reason.act).toBe('최근 오류 확인')
  })

  it('humanizes known runtime reason codes', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'composite',
      attention_reason: 'provider_runtime_error',
    }))
    expect(reason.text).toBe('런타임 호출 오류')
  })
})

describe('pickAttentionKeepers', () => {
  it('returns empty array when no keepers need attention', () => {
    expect(pickAttentionKeepers([makeKeeper({ name: 'k1' })])).toEqual([])
  })

  it('selects keepers with needs_attention flag', () => {
    const keepers = [
      makeKeeper({ name: 'ok' }),
      makeKeeper({ name: 'att', needs_attention: true }),
    ]
    expect(pickAttentionKeepers(keepers).map(k => k.name)).toEqual(['att'])
  })

})

describe('computeOverviewStats', () => {
  it('returns zeroed stats when empty', () => {
    expect(computeOverviewStats([], [])).toEqual({
      att: 0,
      hot: 0,
      avgCtx: null,
      tasks: 0,
      traces: 0,
      total: 0,
    })
  })

  it('counts roster totals and context pressure without a running count', () => {
    const keepers = [
      makeKeeper({ name: 'a', status: 'active', context_ratio: 0.9, total_turns: 10 }),
      makeKeeper({ name: 'b', status: 'offline', context_ratio: 0.5, total_turns: 5 }),
    ]
    const stats = computeOverviewStats(keepers, [])
    expect(stats.total).toBe(2)
    expect(stats.hot).toBe(1)
    expect(stats.traces).toBe(15)
    // Execution counts are not derivable from roster rows; they come from the
    // runtime-health fleet projection instead.
    expect('run' in stats).toBe(false)
  })

  it('counts tasks assigned to keepers', () => {
    const keepers = [makeKeeper({ name: 'a' })]
    const taskList = [
      makeTask({ id: 't1', assignee: 'a' }),
      makeTask({ id: 't2', assignee: 'a' }),
      makeTask({ id: 't3', assignee: 'other' }),
    ]
    expect(computeOverviewStats(keepers, taskList).tasks).toBe(2)
  })

  it('computes average context of running keepers', () => {
    const keepers = [
      makeKeeper({ name: 'a', status: 'active', context_ratio: 0.8 }),
      makeKeeper({ name: 'b', status: 'active', context_ratio: 0.6 }),
    ]
    expect(computeOverviewStats(keepers, []).avgCtx).toBe(70)
  })

  it('does not report zero average when running context is unobserved', () => {
    const keepers = [
      makeKeeper({ name: 'rondo', status: 'active', context_ratio: null }),
    ]

    expect(computeOverviewStats(keepers, []).avgCtx).toBeNull()
  })
})

describe('keeperRuntimeLabel', () => {
  it('uses the shared runtime display priority', () => {
    expect(keeperRuntimeLabel(makeKeeper({
      runtime_canonical: 'agentCore.primary',
      selected_runtime_canonical: 'agentCore.secondary',
      runtime_id: 'legacy.runtime',
    }))).toBe('agentCore.primary')
  })

  it('does not expose raw keeper model fields as runtime labels', () => {
    expect(keeperRuntimeLabel(makeKeeper({
      active_model_label: 'deepseek-v4-flash',
      active_model: 'claude-sonnet-4',
      model: 'fallback',
    }))).toBe('')
  })

  it('returns an empty string when no runtime field is present', () => {
    expect(keeperRuntimeLabel(makeKeeper({}))).toBe('')
  })
})

describe('buildOverviewTelemetrySnapshot', () => {
  const nowMs = Date.parse('2026-04-18T10:00:00Z')
  const entry = (minutesAgo: number): TelemetryEntry => ({
    source: 'agent_core_event',
    ts_unix: (nowMs - minutesAgo * 60 * 1000) / 1000,
  })
  const sources: TelemetrySourceSummary[] = [
    {
      source: 'agent_core_event',
      entry_count: 10,
      latest_age_s: 8,
      health: 'ok',
      active_coverage_gap_count: 0,
    },
    {
      source: 'tool_call_io',
      entry_count: 3,
      health: 'ok',
      active_coverage_gap_count: 1,
    },
  ]

  it('builds 5-minute buckets from real telemetry timestamps', () => {
    const snapshot = buildOverviewTelemetrySnapshot({
      entries: [entry(1), entry(2), entry(8), entry(200)],
      sources,
      nowMs,
      totalMatchingEntries: 4,
    })

    expect(snapshot.bars).toHaveLength(OVERVIEW_TELEMETRY_BAR_COUNT)
    expect(snapshot.peakPerBucket).toBe(2)
    expect(snapshot.averagePerBucket).toBe(0.1)
    expect(snapshot.eventCount).toBe(4)
    expect(snapshot.latestAgeSeconds).toBe(8)
    expect(snapshot.healthySourceCount).toBe(2)
    expect(snapshot.sourceCount).toBe(2)
    expect(snapshot.activeCoverageGaps).toBe(1)
    expect(snapshot.bars.at(-1)).toBe(1)
  })

  it('does not invent bars when there are no matching telemetry rows', () => {
    const snapshot = buildOverviewTelemetrySnapshot({
      entries: [],
      sources: [],
      nowMs,
    })

    expect(snapshot.bars).toHaveLength(OVERVIEW_TELEMETRY_BAR_COUNT)
    expect(snapshot.bars.every(value => value === 0)).toBe(true)
    expect(snapshot.peakPerBucket).toBe(0)
    expect(snapshot.averagePerBucket).toBe(0)
    expect(snapshot.sourceHealth).toBe('unknown')
  })

  it('keeps the overview event sample tied to the rendered bar budget', () => {
    expect(OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT)
      .toBe(OVERVIEW_TELEMETRY_BAR_COUNT * OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET)
  })

  it('preserves the API truncation signal for sample-derived metrics', () => {
    const snapshot = buildOverviewTelemetrySnapshot({
      entries: [entry(1), entry(2)],
      sources,
      nowMs,
      totalMatchingEntries: OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT + 1,
      truncated: true,
    })

    expect(snapshot.truncated).toBe(true)
    expect(snapshot.eventCount).toBe(OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT + 1)
  })
})

describe('Overview v2 marker classes', () => {
  afterEach(() => {
    cleanup()
  })

  it('applies v2 surface and panel marker classes on render', () => {
    const { container } = render(h(Overview, null))

    expect(container.querySelector('.v2-overview-surface')).not.toBeNull()
    expect(container.querySelector('.v2-overview-primary-grid')).not.toBeNull()
    expect(container.querySelector('.v2-overview-domains')).not.toBeNull()
  })

  it('renders keeper-v2 port marker classes', () => {
    const { container } = render(h(Overview, null))

    expect(container.querySelector('.v2-overview-head')).not.toBeNull()
    expect(container.querySelector('.v2-overview-kpis')).not.toBeNull()
    expect(container.querySelector('.v2-overview-attention')).not.toBeNull()
    expect(container.querySelector('.v2-overview-telemetry')).not.toBeNull()
    expect(container.querySelector('.v2-overview-domains')).not.toBeNull()
  })
})

describe('Overview backend composite health', () => {
  function stubOverviewFetch(operatorActionRequired: boolean) {
    vi.stubGlobal('fetch', vi.fn().mockImplementation((input: RequestInfo | URL) => {
      const url = `${input}`
      if (url.includes('/health?full=1')) {
        return Promise.resolve(new Response(JSON.stringify({
          overall_status: 'degraded',
          operator_action_required: operatorActionRequired,
          operator_action_reasons: operatorActionRequired ? ['keeper_event_queue'] : [],
          full_health_snapshot: {
            status: 'ready',
            stale_reason: null,
            last_good_available: true,
            component_timed_out: false,
          },
        }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      }
      if (url.includes('/api/v1/dashboard/telemetry/summary')) {
        return Promise.resolve(new Response(JSON.stringify({
          generated_at: '2026-08-14T00:00:00Z',
          sources: [],
          total_entries: 0,
        }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      }
      if (url.includes('/api/v1/dashboard/telemetry?')) {
        return Promise.resolve(new Response(JSON.stringify({
          generated_at: '2026-08-14T00:00:00Z',
          count: 0,
          entries: [],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      }
      return Promise.reject(new Error(`unexpected url: ${url}`))
    }))
  }

  afterEach(() => {
    cleanup()
    dashboardFullHealthResource.reset()
    vi.unstubAllGlobals()
  })

  it('joins one backend action requirement into the KPI and attention panel', async () => {
    stubOverviewFetch(true)
    const { container } = render(h(Overview, null))

    await waitFor(() => {
      expect(container.querySelector('[data-testid="kpi-att"] .ov-kpi-v')?.textContent).toBe('1')
      expect(container.querySelector('[data-testid="attention-row-runtime-health"]')?.textContent)
        .toContain('Runtime health degraded')
    })
  })

  it('keeps a non-action degraded verdict visible without counting operator work', async () => {
    stubOverviewFetch(false)
    const { container } = render(h(Overview, null))

    await waitFor(() => {
      expect(container.querySelector('[data-testid="kpi-att"] .ov-kpi-v')?.textContent).toBe('0')
      expect(container.querySelector('[data-testid="overview-attention"] h3')?.textContent)
        .toBe('상태 참고')
      expect(container.querySelector('[data-testid="attention-row-runtime-health"]')).not.toBeNull()
    })
  })
})

describe('Overview StyleSeed surfaces', () => {
  afterEach(() => {
    cleanup()
  })

  it('applies StyleSeed surface/page tokens to root', () => {
    const { container } = render(h(Overview, null))
    const root = container.querySelector('.v2-overview-surface')
    expect(root?.classList.contains('ss-surface')).toBe(true)
    expect(root?.classList.contains('ov')).toBe(true)
    expect(root?.classList.contains('text-text-primary')).toBe(true)
  })

  it('renders the prototype primary sequence (kpis → grid → domains)', () => {
    const { container } = render(h(Overview, null))
    const sequence = [...container.querySelectorAll(
      '[data-testid="overview-kpis"], [data-testid="overview-primary-grid"], [data-testid="overview-domains"]',
    )].map(el => el.getAttribute('data-testid'))

    expect(sequence).toEqual([
      'overview-kpis',
      'overview-primary-grid',
      'overview-domains',
    ])
    expect(container.querySelector('.v2-overview-kpis')?.classList.contains('ov-kpis')).toBe(true)
    expect(container.querySelector('.v2-overview-domains')?.classList.contains('ov-domains')).toBe(true)
  })

  it('uses the prototype two-column overview grid container', () => {
    const { container } = render(h(Overview, null))
    const grid = container.querySelector('[data-testid="overview-primary-grid"]')
    expect(grid?.classList.contains('ov-grid')).toBe(true)
    expect(grid?.classList.contains('v2-overview-primary-grid')).toBe(true)
  })
})

// ─── Cross-surface digest ─────────────────────────────────────────────────────

function makeGoal(partial: Partial<Goal>): Goal {
  return {
    id: 'g-1',
    title: 'goal',
    priority: 5,
    phase: 'observe',
    created_at: localIsoAt(1),
    updated_at: localIsoAt(1),
    ...partial,
  }
}

function makeFusionRun(partial: Partial<FusionRunRecord>): FusionRunRecord {
  return {
    runId: 'fr-1',
    keeper: 'sangsu',
    preset: 'default',
    topology: null,
    startedAt: 1_700_000_000,
    status: 'running',
    ...partial,
  }
}

describe('computeOverviewDigest', () => {
  it('returns zeroed digest with no data', () => {
    const digest = computeOverviewDigest(0, [], [])
    expect(digest.openGateRequests).toBe(0)
    expect(digest.topGoals).toEqual([])
    expect(digest.topGoalLabel).toBeNull()
    expect(digest.fusionRunning).toBe(0)
    expect(digest.fusionDone).toBe(0)
    expect(digest.fusionTotal).toBe(0)
    expect(digest.fusionLatest).toBeNull()
  })

  it('uses the exact Gate queue count supplied by its SSOT', () => {
    const digest = computeOverviewDigest(
      2,
      [],
      [],
    )
    expect(digest.openGateRequests).toBe(2)
  })

  it('preserves an unavailable Gate queue instead of fabricating zero', () => {
    const digest = computeOverviewDigest(null, [], [])
    expect(digest.openGateRequests).toBeNull()
  })

  it('orders top goals by priority and labels the leader by due date', () => {
    const digest = computeOverviewDigest(
      0,
      [
        makeGoal({ id: 'low', priority: 2 }),
        makeGoal({ id: 'lead', priority: 9, due_date: '2026-07-01' }),
        makeGoal({ id: 'mid', priority: 5 }),
      ],
      [],
    )
    expect(digest.topGoals.map(g => g.id)).toEqual(['lead', 'mid', 'low'])
    expect(digest.topGoalLabel).toBe('2026-07-01')
  })

  it('falls back to priority label when the leader has no due date', () => {
    const digest = computeOverviewDigest(0, [makeGoal({ id: 'lead', priority: 8, due_date: null })], [])
    expect(digest.topGoalLabel).toBe('P8')
  })

  it('summarizes fusion runs by status and picks the newest as latest', () => {
    const digest = computeOverviewDigest(
      0,
      [],
      [
        makeFusionRun({ runId: 'older', status: 'completed', startedAt: 100 }),
        makeFusionRun({ runId: 'newest', status: 'running', startedAt: 300 }),
        makeFusionRun({ runId: 'mid', status: 'running', startedAt: 200 }),
      ],
    )
    expect(digest.fusionRunning).toBe(2)
    expect(digest.fusionDone).toBe(1)
    expect(digest.fusionTotal).toBe(3)
    expect(digest.fusionLatest?.runId).toBe('newest')
  })

  it('summarizes scheduled-automation projection in the overview digest', () => {
    const digest = computeOverviewDigest(
      0,
      [],
      [],
      makeScheduledAutomation({
        request_count: 5,
        request_limit: 10,
        payload_support: {
          unsupported_request_count: 2,
          unknown_request_count: 3,
        },
      }),
    )
    expect(digest.scheduledAutomation.state).toBe('available')
    if (digest.scheduledAutomation.state !== 'available') {
      throw new Error('expected available schedule projection')
    }
    expect(digest.scheduledAutomation.totalCount).toBe(5)
    expect(digest.scheduledAutomation.limit).toBe(10)
    expect(digest.scheduledAutomation.fsmState).toBe('due')
    expect(digest.scheduledAutomation.dueCount).toBe(1)
    expect(digest.scheduledAutomation.runningCount).toBe(0)
    expect(digest.scheduledAutomation.scheduledCount).toBe(1)
    expect(digest.scheduledAutomation.unsupportedPayloadCount).toBe(2)
    expect(digest.scheduledAutomation.unknownPayloadCount).toBe(3)
    expect(digest.scheduledAutomation.tone).toBe('warn')
  })

  it('does not normalize invalid schedule status wire values', () => {
    const digest = computeOverviewDigest(
      0,
      [],
      [],
      makeScheduledAutomation({
        counts: {},
        requests: [
          {
            schedule_id: 'status-skew',
            status: ' Scheduled ' as DashboardScheduledAutomationRequest['status'],
            source: 'operator',
          },
        ],
      }),
    )
    expect(digest.scheduledAutomation.state).toBe('available')
    if (digest.scheduledAutomation.state !== 'available') {
      throw new Error('expected available schedule projection')
    }
    expect(digest.scheduledAutomation.scheduledCount).toBe(0)
  })

  it('keeps an unreadable schedule ledger unavailable instead of summarizing zero', () => {
    const digest = computeOverviewDigest(0, [], [], {
      state: 'unavailable',
      reason: 'schedule store read failed: corrupt ledger',
    })

    expect(digest.scheduledAutomation).toEqual({
      state: 'unavailable',
      reason: 'schedule store read failed: corrupt ledger',
      tone: 'bad',
    })
  })

  it('summarizes schedule runner status from /health as a digest field', () => {
    const digest = computeOverviewDigest(
      0,
      [],
      [],
      makeScheduledAutomation(),
      makeScheduleRunner({
        status: 'degraded',
        failure_count: 2,
        crash_count: 1,
        tick_in_flight: true,
      }),
    )
    expect(digest.scheduleRunner.hasProjection).toBe(true)
    expect(digest.scheduleRunner.status).toBe('degraded')
    expect(digest.scheduleRunner.tickInFlight).toBe(true)
    expect(digest.scheduleRunner.tickCount).toBe(3)
    expect(digest.scheduleRunner.failureCount).toBe(2)
    expect(digest.scheduleRunner.crashCount).toBe(1)
    expect(digest.scheduleRunner.tone).toBe('volt')
  })

  it('falls back to a warn schedule-runner digest when full health is unavailable', () => {
    const digest = computeOverviewDigest(0, [], [], null, null)
    expect(digest.scheduleRunner.hasProjection).toBe(false)
    expect(digest.scheduleRunner.tone).toBe('warn')
    expect(digest.scheduleRunner.status).toBe('unknown')
  })
})

// ─── Prototype overview surface (header / KPIs / domains) ─────────────────────

describe('Overview prototype surface', () => {
  afterEach(() => {
    cleanup()
  })

  it('renders the eyebrow + display header verbatim from the prototype', () => {
    const { container } = render(h(Overview, null))
    const head = container.querySelector('[data-testid="overview-head"]')
    expect(head?.querySelector('.ov-eyebrow')?.textContent).toBe('운영 홈')
    expect(head?.querySelector('h1')?.textContent).toBe('지금, 전체')
    expect(head?.querySelector('.ov-sub')?.textContent).toBe('fleet 전체 — 목표 · Gate · Fusion · 연결 한눈에')
  })

  it('renders exactly 7 cross-surface KPI cells with the prototype labels', () => {
    const { container } = render(h(Overview, null))
    const cells = container.querySelectorAll('[data-testid="overview-kpis"] .ov-kpi')
    expect(cells).toHaveLength(7)
    const labels = [...cells].map(c => c.querySelector('.ov-kpi-k')?.textContent)
    expect(labels).toEqual([
      '실행 중 keeper',
      '주의 필요',
      '열린 Gate',
      '최우선 목표',
      '활성 커넥터',
      '예약 HITL',
      '진행 심의',
    ])
  })

  it('shows keeper execution counts from the runtime-health fleet projection', () => {
    keepers.value = [
      makeKeeper({ name: 'a', status: 'active' }),
      makeKeeper({ name: 'b', status: 'active' }),
    ]
    shellRuntimeResolution.value = {
      fleet_safety: {
        paused_keepers_health: { count: 1 },
        keeper_fleet_safety: {
          running_keeper_fiber_count: 4,
          recovering_keeper_fiber_count: 3,
          executable_keeper_fiber_count: 7,
        },
      },
    } as never

    const { container } = render(h(Overview, null))
    // The roster holds 2 active-looking rows; the projection reports 4 running.
    // The projection wins.
    expect(container.querySelector('[data-testid="kpi-run"] .ov-kpi-v')?.textContent).toBe('4 / 2')
    expect(container.querySelector('[data-testid="fleet-stat-running"] .v')?.textContent).toBe('4')
    expect(container.querySelector('[data-testid="fleet-stat-recovering"] .v')?.textContent).toBe('3')
    expect(container.querySelector('[data-testid="fleet-stat-paused"] .v')?.textContent).toBe('1')

    keepers.value = []
    shellRuntimeResolution.value = null
  })

  it('shows no keeper execution count when the fleet projection is missing', () => {
    // Three rows that the roster heuristic would have counted as running. With
    // no fleet projection the surface must say it does not know, not print an
    // estimate derived from these status strings.
    keepers.value = [
      makeKeeper({ name: 'a', status: 'active' }),
      makeKeeper({ name: 'b', status: 'busy' }),
      makeKeeper({ name: 'c', status: 'idle' }),
    ]
    shellRuntimeResolution.value = null

    const { container } = render(h(Overview, null))
    expect(container.querySelector('[data-testid="kpi-run"] .ov-kpi-v')?.textContent).toBe('— / 3')
    expect(container.querySelector('[data-testid="fleet-stat-running"] .v')?.textContent).toBe('—')
    expect(container.querySelector('[data-testid="fleet-stat-recovering"] .v')?.textContent).toBe('—')
    expect(container.querySelector('[data-testid="fleet-stat-paused"] .v')?.textContent).toBe('—')

    keepers.value = []
  })

  it('renders a projection-reported zero as zero, not as unknown', () => {
    keepers.value = [makeKeeper({ name: 'a', status: 'active' })]
    shellRuntimeResolution.value = {
      fleet_safety: {
        keeper_fleet_safety: {
          running_keeper_fiber_count: 0,
          recovering_keeper_fiber_count: 0,
          paused_keeper_count: 0,
        },
      },
    } as never

    const { container } = render(h(Overview, null))
    expect(container.querySelector('[data-testid="kpi-run"] .ov-kpi-v')?.textContent).toBe('0 / 1')
    expect(container.querySelector('[data-testid="fleet-stat-running"] .v')?.textContent).toBe('0')

    keepers.value = []
    shellRuntimeResolution.value = null
  })

  it('does not fetch the tool inventory when the home surface loads', async () => {
    const previousFetch = global.fetch
    const fetchMock = vi.fn().mockImplementation(() =>
      Promise.resolve(new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })),
    )
    vi.stubGlobal('fetch', fetchMock)

    try {
      render(h(Overview, null))
      await waitFor(() => expect(fetchMock).toHaveBeenCalled())

      // Root reached schedule state through /api/v1/dashboard/tools before the
      // projection got its own route, so entering the home surface pulled the
      // whole tool registry.
      const requested = fetchMock.mock.calls.map(call => String(call[0]))
      expect(requested.some(url => url.includes('/api/v1/dashboard/tools'))).toBe(false)
    } finally {
      if (previousFetch) {
        vi.stubGlobal('fetch', previousFetch)
      } else {
        vi.unstubAllGlobals()
      }
    }
  })

  it('marks deep-link KPI cells as buttons', () => {
    const { container } = render(h(Overview, null))
    const runCell = container.querySelector('[data-testid="kpi-run"]')
    expect(runCell?.classList.contains('link')).toBe(true)
    expect(runCell?.getAttribute('role')).toBe('button')
  })

  it('renders the 도메인 현황 section header', () => {
    const { container } = render(h(Overview, null))
    const header = container.querySelector('[data-testid="overview-domains-header"]')
    expect(header?.classList.contains('ov-section-h')).toBe(true)
    expect(header?.textContent).toBe('도메인 현황')
  })

  it('renders all 7 domain cards in prototype order', () => {
    const { container } = render(h(Overview, null))
    const cards = container.querySelectorAll('[data-testid="overview-domains"] .ov-dcard')
    expect(cards).toHaveLength(7)
    const titles = [...cards].map(c => c.querySelector('.ov-dcard-h h3')?.textContent)
    expect(titles).toEqual([
      '작업 · 목표',
      'Gate · HITL',
      '예약 · 자동화',
      'Fusion 심의',
      '보드',
      '커넥터',
      'Fleet 요약',
    ])
  })

  it('renders live scheduled-automation summary from the schedule projection', () => {
    const previousScheduledAutomation = overviewMocks.scheduledAutomationProjection.value
    overviewMocks.scheduledAutomationProjection.value = makeScheduledAutomation({
      fsm: {
        state: 'active',
        active_count: 2,
        terminal_count: 1,
        next_due_at: '2026-07-18T12:00:00Z',
      },
      counts: {
        due: 2,
        running: 1,
        scheduled: 0,
      },
      warnings: ['warn'],
    })

    try {
      const { container } = render(h(Overview, null))
      const card = container.querySelector('[data-testid="domain-schedule"]')
      const count = card?.querySelector('.ov-dcount')?.textContent
      const bodyText = card?.textContent ?? ''

      expect(count).toBe('3')
      expect(bodyText).toContain('Due 2')
      expect(bodyText).toContain('Running 1')
      expect(bodyText).toContain('projection warning 1')
      expect(bodyText).toContain('표시 3 / 전체 3 · 최대 10')
      expect(bodyText).not.toContain('예약 자동화 projection 미연결')
    } finally {
      overviewMocks.scheduledAutomationProjection.value = previousScheduledAutomation
    }
  })

  it('renders an unreadable schedule ledger as an error with no zero count', () => {
    const previousProjection = overviewMocks.scheduledAutomationProjection.value
    overviewMocks.scheduledAutomationProjection.value = {
      state: 'unavailable',
      reason: 'schedule store read failed: corrupt ledger',
    }

    try {
      const { container } = render(h(Overview, null))
      const card = container.querySelector('[data-testid="domain-schedule"]')

      expect(card?.querySelector('.ov-dcount')?.textContent).toBe('—')
      expect(card?.querySelector('[data-testid="overview-schedule-unavailable"]')).not.toBeNull()
      expect(card?.textContent).toContain('schedule store read failed: corrupt ledger')
      expect(card?.textContent).not.toContain('Due 0')
    } finally {
      overviewMocks.scheduledAutomationProjection.value = previousProjection
    }
  })

  it('renders schedule_runner liveness row in the 예약 · 자동화 card when full health returns runner status', async () => {
    const previousScheduledAutomation = overviewMocks.scheduledAutomationProjection.value
    const previousFetch = global.fetch
    const fetchMock = vi.fn().mockImplementation((input: RequestInfo | URL) => {
      const url = `${input}`
      if (url.includes('/health?full=1')) {
        return Promise.resolve(new Response(JSON.stringify({
          health_detail: 'full',
          schedule_runner: {
            schema: 'masc.schedule.runner_status.v1',
            status: 'ok',
            tick_in_flight: true,
            tick_count: 4,
            success_count: 3,
            failure_count: 0,
            crash_count: 0,
            last_error: null,
            last_error_age_sec: null,
          },
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }))
      }
      if (url.includes('/api/v1/dashboard/telemetry?')) {
        return Promise.resolve(new Response(JSON.stringify({
          generated_at: '2026-07-21T00:00:00Z',
          count: 0,
          entries: [],
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }))
      }
      if (url.includes('/api/v1/dashboard/telemetry/summary')) {
        return Promise.resolve(new Response(JSON.stringify({
          generated_at: '2026-07-21T00:00:00Z',
          sources: [],
          total_entries: 0,
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }))
      }
      return Promise.reject(new Error(`unexpected url: ${url}`))
    })
    try {
      overviewMocks.scheduledAutomationProjection.value = makeScheduledAutomation({
        request_count: 1,
        request_limit: 1,
        counts: { scheduled: 1 },
        fsm: {
          state: 'active',
          active_count: 1,
          terminal_count: 0,
          next_due_at: null,
        },
      })
      vi.stubGlobal('fetch', fetchMock)

      const { container } = render(h(Overview, null))
      await waitFor(() => {
        const card = container.querySelector('[data-testid="domain-schedule"]')
        expect(card?.textContent).toContain('runner: ok')
      })
      expect(fetchMock.mock.calls.filter(call => String(call[0]).includes('/health?full=1')))
        .toHaveLength(1)
    } finally {
      overviewMocks.scheduledAutomationProjection.value = previousScheduledAutomation
      if (previousFetch) {
        vi.stubGlobal('fetch', previousFetch)
      } else {
        vi.unstubAllGlobals()
      }
    }
  })

  it('places the domain section last, after the primary grid', () => {
    const { container } = render(h(Overview, null))
    const order = [...container.querySelectorAll(
      '[data-testid="overview-primary-grid"], [data-testid="overview-domains"]',
    )].map(el => el.getAttribute('data-testid'))
    expect(order).toEqual(['overview-primary-grid', 'overview-domains'])
  })

  // Gap 1: KPI grid uses 6-column layout (surfaces.css:88 `repeat(6, 1fr)`)
  it('KPI grid declares 6-column repeat matching prototype surfaces.css:88', () => {
    const { container } = render(h(Overview, null))
    const grid = container.querySelector('[data-testid="overview-kpis"]') as HTMLElement | null
    expect(grid).not.toBeNull()
    // The grid class is ov-kpis; CSS sets grid-template-columns: repeat(6, 1fr)
    expect(grid?.classList.contains('ov-kpis')).toBe(true)
    // 7 cells exist — 7th wraps to second row in a 6-col grid (prototype intent)
    expect(container.querySelectorAll('[data-testid="overview-kpis"] .ov-kpi')).toHaveLength(7)
  })

  // Gap 2: attention panel title includes full subtitle (overview.jsx:119)
  it('attention panel h3 includes the full prototype title with subtitle', () => {
    const { container } = render(h(Overview, null))
    const attn = container.querySelector('[data-testid="overview-attention"]')
    const h3 = attn?.querySelector('.ov-card-h h3')
    expect(h3?.textContent).toBe('주의 필요 · 지금 손이 필요한 것')
  })

  // Gap 3: telemetry panel shows "로그 보기 →" button link (overview.jsx:143)
  it('telemetry panel header shows a "로그 보기 →" link button', () => {
    const { container } = render(h(Overview, null))
    const tel = container.querySelector('[data-testid="overview-telemetry"]')
    const btn = tel?.querySelector('button.ov-link')
    expect(btn).not.toBeNull()
    expect(btn?.textContent).toBe('로그 보기 →')
  })

  // The attention row's mono sublabel exists to show the wire name next to a
  // localized display name; when they are identical it printed "base base".
  it('attention row hides the ns sublabel when display name equals keeper name', () => {
    const previousKeepers = keepers.value
    keepers.value = [
      makeKeeper({ name: 'base', needs_attention: true }),
      makeKeeper({ name: 'nick0cave', koreanName: '닉케이브', needs_attention: true }),
    ]
    try {
      const { container } = render(h(Overview, null))
      const plain = container.querySelector('[data-testid="attention-row-base"] .ov-attn-name')
      expect(plain?.textContent?.trim()).toBe('base')
      expect(plain?.querySelector('.ov-attn-ns')).toBeNull()
      const localized = container.querySelector('[data-testid="attention-row-nick0cave"] .ov-attn-name')
      expect(localized?.querySelector('.ov-attn-ns')?.textContent).toBe('nick0cave')
    } finally {
      keepers.value = previousKeepers
    }
  })
})

// The overview route subscribes to GLOBAL + `execution` slices only and never
// calls refreshBoard, so `boardPosts` is empty on every fresh load of #overview.
// The card used to render that empty length as "전체 포스트 0" while #board and
// the post store both held posts, so an operator reading the home screen saw a
// fabricated zero rather than "not loaded".
describe('Overview board domain card', () => {
  afterEach(() => {
    cleanup()
    boardPosts.value = []
    boardTotal.value = null
    lastBoardRefreshAt.value = null
  })

  function boardCardText(container: Element): string {
    return container.querySelector('[data-testid="domain-board"] .ov-dcard-body')?.textContent?.trim() ?? ''
  }

  it('reports not-loaded instead of 0 when the board store was never hydrated', () => {
    boardPosts.value = []
    boardTotal.value = null
    lastBoardRefreshAt.value = null

    const { container } = render(h(Overview, null))
    const body = container.querySelector('[data-testid="domain-board"] .ov-dcard-body')

    expect(body?.querySelector('.ov-empty')).not.toBeNull()
    expect(boardCardText(container)).not.toContain('0')
    expect(container.querySelector('[data-testid="domain-board"] .ov-stat-row')).toBeNull()
  })

  it('labels the loaded rows as loaded, not total, while the server pages the result', () => {
    boardPosts.value = [
      { id: 'p-1', author: 'a', title: 't1', content: 'c1', created_at: '2026-08-05T00:00:00Z' },
      { id: 'p-2', author: 'b', title: 't2', content: 'c2', created_at: '2026-08-05T00:00:01Z' },
    ] as unknown as typeof boardPosts.value
    boardTotal.value = null
    lastBoardRefreshAt.value = '2026-08-05T00:00:02Z'

    const { container } = render(h(Overview, null))
    const text = boardCardText(container)

    expect(text).toContain('불러온 포스트')
    expect(text).toContain('2')
    expect(text).not.toContain('전체 포스트')
  })

  it('shows the server total when the response carried one', () => {
    boardPosts.value = [
      { id: 'p-1', author: 'a', title: 't1', content: 'c1', created_at: '2026-08-05T00:00:00Z' },
    ] as unknown as typeof boardPosts.value
    boardTotal.value = 441
    lastBoardRefreshAt.value = '2026-08-05T00:00:02Z'

    const { container } = render(h(Overview, null))
    const text = boardCardText(container)

    expect(text).toContain('전체 포스트')
    expect(text).toContain('441')
  })
})
