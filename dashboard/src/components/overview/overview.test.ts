import { h } from 'preact'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  computeFunnelCounts,
  formatTargetRatio,
  pickActiveSession,
  progressPct,
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
import type { FusionRunRecord, TelemetryEntry, TelemetrySourceSummary } from '../../api/dashboard'
import type { Goal } from '../../types/core'

// bar-seg ratio helper (mirrors FunnelCard inline logic)
function segPct(counts: FunnelCounts, key: 'created' | 'inProgress' | 'awaiting' | 'completed'): number {
  const total = counts.created + counts.inProgress + counts.awaiting + counts.completed
  return total > 0 ? (counts[key] / total) * 100 : 0
}
import type { Agent, Task, Keeper, Message, BoardPost } from '../../types/core'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionCard,
} from '../../types/dashboard-mission'

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

function makeSession(partial: Partial<DashboardMissionSessionCard>): DashboardMissionSessionCard {
  return {
    session_id: 's-1',
    goal: 'default goal',
    member_names: [],
    related_attention_count: 0,
    member_previews: [],
    operation_badges: [],
    keeper_refs: [],
    ...partial,
  }
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
    content: 'content',
    tags: [],
    votes: 0,
    comment_count: 0,
    created_at: localIsoAt(1),
    updated_at: localIsoAt(1),
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
    const counts = computeFunnelCounts(tasks, null, FIXED_NOW)
    expect(counts.created).toBe(2)
  })

  it('groups claimed + in_progress as inProgress', () => {
    const tasks = [
      makeTask({ id: 'a', status: 'claimed' }),
      makeTask({ id: 'b', status: 'in_progress' }),
      makeTask({ id: 'c', status: 'todo' }),
    ]
    const counts = computeFunnelCounts(tasks, null, FIXED_NOW)
    expect(counts.inProgress).toBe(2)
  })

  it('separates awaiting_verification from other statuses', () => {
    const tasks = [
      makeTask({ id: 'a', status: 'awaiting_verification' }),
      makeTask({ id: 'b', status: 'done', completed_at: localIsoAt(5) }),
    ]
    const counts = computeFunnelCounts(tasks, null, FIXED_NOW)
    expect(counts.awaiting).toBe(1)
    expect(counts.completed).toBe(1)
  })

  it('counts only today-completed done tasks', () => {
    const tasks = [
      makeTask({ id: 'a', status: 'done', completed_at: localIsoAt(5) }),
      makeTask({ id: 'b', status: 'done', completed_at: localIsoAt(23, 0, 0, -1) }),
      makeTask({ id: 'c', status: 'done' }),
    ]
    const counts = computeFunnelCounts(tasks, null, FIXED_NOW)
    expect(counts.completed).toBe(1)
  })

  it('takes target from active session required_count when positive', () => {
    const active = makeSession({ required_count: 12 })
    const counts = computeFunnelCounts([], active, FIXED_NOW)
    expect(counts.target).toBe(12)
  })

  it('returns null target when required_count is 0 or missing', () => {
    expect(computeFunnelCounts([], makeSession({ required_count: 0 }), FIXED_NOW).target).toBeNull()
    expect(computeFunnelCounts([], makeSession({}), FIXED_NOW).target).toBeNull()
    expect(computeFunnelCounts([], null, FIXED_NOW).target).toBeNull()
  })

  it('ignores invalid ISO timestamps', () => {
    const tasks = [
      makeTask({ id: 'a', created_at: 'not-a-date', status: 'todo' }),
      makeTask({ id: 'b', created_at: '', status: 'done', completed_at: 'nope' }),
    ]
    const counts = computeFunnelCounts(tasks, null, FIXED_NOW)
    expect(counts.created).toBe(0)
    expect(counts.completed).toBe(0)
  })

  it('bar-seg ratio sums to ~100% across all funnel stages', () => {
    const tasks = [
      makeTask({ id: 'a', created_at: localIsoAt(1), status: 'in_progress' }),
      makeTask({ id: 'b', created_at: localIsoAt(2), status: 'awaiting_verification' }),
      makeTask({ id: 'c', created_at: localIsoAt(3), status: 'done', completed_at: localIsoAt(4) }),
    ]
    const counts = computeFunnelCounts(tasks, null, FIXED_NOW)
    const total = counts.created + counts.inProgress + counts.awaiting + counts.completed
    const pcts = [counts.inProgress, counts.awaiting, counts.completed, counts.created]
      .map(n => total > 0 ? (n / total) * 100 : 0)
    const sum = pcts.reduce((a, b) => a + b, 0)
    expect(Math.round(sum)).toBe(100)
  })

  it('bar-seg ratio returns 0 when funnel is empty', () => {
    const counts = computeFunnelCounts([], null, FIXED_NOW)
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

describe('pickActiveSession', () => {
  it('returns null for null snapshot', () => {
    expect(pickActiveSession(null)).toBeNull()
  })

  it('returns null for empty sessions', () => {
    const snap = { sessions: [] } as unknown as DashboardMissionResponse
    expect(pickActiveSession(snap)).toBeNull()
  })

  it('prefers first session with active/running/busy status', () => {
    const a = makeSession({ session_id: 'a', status: 'paused' })
    const b = makeSession({ session_id: 'b', status: 'running' })
    const c = makeSession({ session_id: 'c', status: 'active' })
    const snap = { sessions: [a, b, c] } as unknown as DashboardMissionResponse
    expect(pickActiveSession(snap)?.session_id).toBe('b')
  })

  it('falls back to first session when none are active', () => {
    const a = makeSession({ session_id: 'a', status: 'paused' })
    const b = makeSession({ session_id: 'b', status: 'paused' })
    const snap = { sessions: [a, b] } as unknown as DashboardMissionResponse
    expect(pickActiveSession(snap)?.session_id).toBe('a')
  })
})

describe('progressPct', () => {
  it('returns null when no active session', () => {
    expect(progressPct(null)).toBeNull()
  })

  it('returns null when required_count is missing or zero', () => {
    expect(progressPct(makeSession({}))).toBeNull()
    expect(progressPct(makeSession({ required_count: 0 }))).toBeNull()
  })

  it('computes seen/required rounded-[var(--r-1)] percentage', () => {
    expect(progressPct(makeSession({ required_count: 10, seen_count: 3 }))).toBe(30)
    expect(progressPct(makeSession({ required_count: 4, seen_count: 1 }))).toBe(25)
  })

  it('falls back to active_count when seen_count is missing', () => {
    expect(progressPct(makeSession({ required_count: 10, active_count: 4 }))).toBe(40)
  })

  it('caps percentage at 100', () => {
    expect(progressPct(makeSession({ required_count: 3, seen_count: 10 }))).toBe(100)
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
      boardPostList: [makeBoardPost({ id: 'blank-post', title: '', body: '', content: '', updated_at: localIsoAt(3) })],
      keeperList: [makeKeeper({ name: 'no-heartbeat' })],
    })

    expect(events).toEqual([])
  })

  it('uses trimmed board content fallback when title or author is whitespace', () => {
    const events = deriveFleetTickerEvents({
      taskList: [],
      messageList: [],
      boardPostList: [
        makeBoardPost({
          id: 'post-whitespace-title',
          author: '   ',
          title: '   ',
          content: '  usable content  ',
          body: 'body fallback',
          updated_at: localIsoAt(3),
        }),
      ],
      keeperList: [],
    })

    expect(events).toHaveLength(1)
    expect(events[0]?.id).toBe('board:post-whitespace-title')
    expect(events[0]?.actor).toBe('board')
    expect(events[0]?.text).toBe('usable content')
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
          agent: { exists: true, status: 'busy' },
        }),
      ],
    })

    expect(events).toHaveLength(1)
    expect(events[0]?.text).toBe('Paused')
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

  it('marks continue_gate keepers as warn with approval action', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'gate',
      runtime_blocker_continue_gate: true,
      runtime_blocker_class: 'ambiguous_post_commit_timeout',
    }))
    expect(reason.sev).toBe('warn')
    expect(reason.act).toBe('승인 검토')
  })

  it('marks critical lifecycle states as bad', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'dead',
      lifecycle_phase: 'Dead',
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

  it('humanizes known completion-contract composite reason codes', () => {
    const reason = deriveKeeperAttentionReason(makeKeeper({
      name: 'composite',
      attention_reason: 'passive_only',
    }))
    expect(reason.text).toBe('진행 작업 없는 수동 응답')
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

  it('selects keepers with runtime blocker awaiting_operator', () => {
    const keepers = [
      makeKeeper({ name: 'ok' }),
      makeKeeper({ name: 'op', runtime_blocker_class: 'awaiting_operator' }),
    ]
    expect(pickAttentionKeepers(keepers).map(k => k.name)).toEqual(['op'])
  })
})

describe('computeOverviewStats', () => {
  it('returns zeroed stats when empty', () => {
    expect(computeOverviewStats([], [])).toEqual({
      run: 0,
      att: 0,
      hot: 0,
      avgCtx: 0,
      tasks: 0,
      traces: 0,
      total: 0,
    })
  })

  it('counts running keepers and context pressure', () => {
    const keepers = [
      makeKeeper({ name: 'a', status: 'active', context_ratio: 0.9, total_turns: 10 }),
      makeKeeper({ name: 'b', status: 'offline', context_ratio: 0.5, total_turns: 5 }),
    ]
    const stats = computeOverviewStats(keepers, [])
    expect(stats.run).toBe(1)
    expect(stats.total).toBe(2)
    expect(stats.hot).toBe(1)
    expect(stats.traces).toBe(15)
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
})

describe('keeperRuntimeLabel', () => {
  it('uses the shared runtime display priority', () => {
    expect(keeperRuntimeLabel(makeKeeper({
      runtime_canonical: 'oas.primary',
      selected_runtime_canonical: 'oas.secondary',
      runtime_id: 'legacy.runtime',
    }))).toBe('oas.primary')
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
    source: 'oas_event',
    ts_unix: (nowMs - minutesAgo * 60 * 1000) / 1000,
  })
  const sources: TelemetrySourceSummary[] = [
    {
      source: 'oas_event',
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
    status: 'active',
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
    startedAt: 1_700_000_000,
    status: 'running',
    ...partial,
  }
}

describe('computeOverviewDigest', () => {
  it('returns zeroed digest with no data', () => {
    const digest = computeOverviewDigest([], [], [])
    expect(digest.openApprovals).toBe(0)
    expect(digest.approvalsCritical).toBe(false)
    expect(digest.topGoals).toEqual([])
    expect(digest.topGoalLabel).toBeNull()
    expect(digest.fusionRunning).toBe(0)
    expect(digest.fusionDone).toBe(0)
    expect(digest.fusionTotal).toBe(0)
    expect(digest.fusionLatest).toBeNull()
  })

  it('counts operator-awaiting keepers as open approvals', () => {
    const digest = computeOverviewDigest(
      [
        makeKeeper({ name: 'gate', runtime_blocker_continue_gate: true }),
        makeKeeper({ name: 'op', runtime_blocker_class: 'awaiting_operator' }),
        makeKeeper({ name: 'fine' }),
      ],
      [],
      [],
    )
    expect(digest.openApprovals).toBe(2)
    expect(digest.approvalsCritical).toBe(false)
  })

  it('flags approvals critical when a keeper is in a bad runtime state', () => {
    const digest = computeOverviewDigest(
      [makeKeeper({ name: 'dead', lifecycle_phase: 'Dead', runtime_blocker_class: 'exception' })],
      [],
      [],
    )
    expect(digest.approvalsCritical).toBe(true)
  })

  it('orders top goals by priority and labels the leader by due date', () => {
    const digest = computeOverviewDigest(
      [],
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
    const digest = computeOverviewDigest([], [makeGoal({ id: 'lead', priority: 8, due_date: null })], [])
    expect(digest.topGoalLabel).toBe('P8')
  })

  it('summarizes fusion runs by status and picks the newest as latest', () => {
    const digest = computeOverviewDigest(
      [],
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
    expect(head?.querySelector('.ov-sub')?.textContent).toBe('fleet 전체 — 목표 · 승인 · 심의 · 연결 한눈에')
  })

  it('renders exactly 7 cross-surface KPI cells with the prototype labels', () => {
    const { container } = render(h(Overview, null))
    const cells = container.querySelectorAll('[data-testid="overview-kpis"] .ov-kpi')
    expect(cells).toHaveLength(7)
    const labels = [...cells].map(c => c.querySelector('.ov-kpi-k')?.textContent)
    expect(labels).toEqual([
      '실행 중 keeper',
      '주의 필요',
      '열린 승인',
      '최우선 목표',
      '활성 커넥터',
      '예약 승인',
      '진행 심의',
    ])
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
      '승인 큐',
      '예약 · 자동화',
      'Fusion 심의',
      '보드',
      '커넥터',
      'Fleet 요약',
    ])
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
})
