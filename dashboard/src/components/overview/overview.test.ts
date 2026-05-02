import { describe, expect, it } from 'vitest'
import {
  computeFunnelCounts,
  formatTargetRatio,
  pickActiveSession,
  progressPct,
  pickActiveKeepers,
  severityToneClass,
  deriveAgentAlerts,
  deriveTaskAlerts,
  type FunnelCounts,
} from './overview'
import type { Agent, Task, Keeper } from '../../types/core'
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

  it('respects max parameter', () => {
    const keepers: Keeper[] = Array.from({ length: 5 }, (_, i) =>
      makeKeeper({ name: `k${i}`, last_heartbeat: `2026-04-18T0${i}:00:00+09:00` }),
    )
    expect(pickActiveKeepers(keepers, 2)).toHaveLength(2)
  })
})

describe('severityToneClass', () => {
  it.each<[string | null | undefined, string]>([
    ['critical', 'text-[var(--color-status-err)]'],
    ['HIGH', 'text-[var(--color-status-err)]'],
    ['warn', 'text-[var(--color-status-warn)]'],
    ['medium', 'text-[var(--color-status-warn)]'],
    ['info', 'text-[var(--color-fg-muted)]'],
    ['', 'text-[var(--color-fg-muted)]'],
    [null, 'text-[var(--color-fg-muted)]'],
    [undefined, 'text-[var(--color-fg-muted)]'],
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
