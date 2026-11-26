import { describe, expect, it } from 'vitest'
import {
  decodeGatePayload,
  decodeToolApprovals,
  gateDispositionText,
  gatePhaseLabel,
  toolApprovalTimeoutText,
} from './inbox-tab'
import { decodeGoalItem, decodeTaskItem, toolApprovalTimeout } from './types'

const goalRow = (extra: Record<string, unknown>) => ({
  id: 'g1',
  title: 'Goal one',
  phase: 'executing',
  ...extra,
})

function decodeGoal(extra: Record<string, unknown>) {
  const res = decodeGoalItem(goalRow(extra))
  if (!res.ok) throw new Error(res.error)
  return res.value
}

describe('Work › Goals tree fields', () => {
  it('reads pending approvals and how long the goal has been idle', () => {
    const goal = decodeGoal({
      pending_approval_count: 3,
      stagnation_seconds: 5400,
      activity_observation: 'runtime',
      last_activity_at: '2026-11-26T01:00:00Z',
    })
    expect(goal.pendingApprovalCount).toBe(3)
    expect(goal.activity).toEqual({
      kind: 'observed',
      source: 'runtime',
      lastActivityAt: '2026-11-26T01:00:00Z',
      stagnationSeconds: 5400,
    })
  })

  it('keeps a server that found no activity apart from a payload without the fields', () => {
    const none = decodeGoal({ activity_observation: 'unavailable', stagnation_seconds: null })
    expect(none.activity).toEqual({ kind: 'unavailable' })
    const planningFallback = decodeGoal({})
    expect(planningFallback.activity).toEqual({ kind: 'unknown' })
    expect(planningFallback.pendingApprovalCount).toBeNull()
  })

  it('does not invent an activity source or a negative count', () => {
    expect(decodeGoal({ activity_observation: 'telepathy', stagnation_seconds: 10 }).activity).toEqual({ kind: 'unknown' })
    expect(decodeGoal({ activity_observation: 'task' }).activity).toEqual({ kind: 'unknown' })
    expect(decodeGoal({ pending_approval_count: -1 }).pendingApprovalCount).toBeNull()
    expect(decodeGoal({ pending_approval_count: 0 }).pendingApprovalCount).toBe(0)
  })
})

describe('Work › Tasks handoff_context', () => {
  const task = (handoff: unknown) => decodeTaskItem({ id: 't1', title: 'T', status: 'todo', handoff_context: handoff })

  it('reads why the task was released and the next step', () => {
    const decoded = task({ summary: 's', reason: 'blocked on review', next_step: 'rerun CI', failure_mode: 'ci_red', evidence_refs: ['run/1'] })
    expect(decoded?.handoff).toMatchObject({
      kind: 'readable',
      context: { reason: 'blocked on review', next_step: 'rerun CI', failure_mode: 'ci_red', evidence_refs: ['run/1'] },
    })
  })

  it('separates no note from a stored note it cannot read', () => {
    expect(task(undefined)?.handoff).toEqual({ kind: 'absent' })
    expect(task({ summary: 42 })?.handoff).toEqual({ kind: 'unreadable' })
  })
})

describe('Inbox › tool approval timeout', () => {
  const askedAt = 1_800_000_000

  it('counts down from asked_at + timeout_sec with the given now', () => {
    expect(toolApprovalTimeout({ askedAt, timeoutSec: 300 }, (askedAt + 60) * 1000))
      .toEqual({ kind: 'pending', timeoutSec: 300, remainingSec: 240 })
    expect(toolApprovalTimeout({ askedAt, timeoutSec: 300 }, (askedAt + 400) * 1000))
      .toEqual({ kind: 'expired', timeoutSec: 300, overdueSec: 100 })
  })

  it('reports unknown when the row has no readable asked_at or timeout', () => {
    expect(toolApprovalTimeout({ askedAt: null, timeoutSec: 300 }, 0)).toEqual({ kind: 'unknown' })
    expect(toolApprovalTimeout({ askedAt, timeoutSec: null }, 0)).toEqual({ kind: 'unknown' })
    expect(toolApprovalTimeoutText({ askedAt: null, timeoutSec: 300 }, 0)).toBe('대기 한도 확인 불가')
  })

  it('keeps a missing asked_at as null instead of the epoch', () => {
    const [row] = decodeToolApprovals({
      pending: [{ keeper: 'k', tool_call_id: 'c1', approval_id: 'a1', tool: 'bash', args: '{}', question: 'q', because: '', timeout_sec: 120 }],
    })
    expect(row?.askedAt).toBeNull()
    expect(row?.timeoutSec).toBe(120)
  })
})

describe('Inbox › gate payload', () => {
  const queueRow = (extra: Record<string, unknown>) => ({ id: 'ap1', keeper_name: 'k', tool_name: 'bash', ...extra })
  const payload = (extra: Record<string, unknown>) => ({
    approval_queue_state: { state: 'ready' },
    approval_queue: [],
    recent_resolved_state: { state: 'ready' },
    recent_resolved: [],
    ...extra,
  })

  it('missing phase is not human_required', () => {
    const gate = decodeGatePayload(payload({ approval_queue: [queueRow({})] }))
    expect(gate.pending[0]?.phase).toBeNull()
    expect(gatePhaseLabel(gate.pending[0]?.phase ?? null)).not.toContain('Human required')
  })

  it('reads a current phase and the Auto Judge disposition', () => {
    const gate = decodeGatePayload(payload({
      approval_queue: [queueRow({
        phase: 'blocked',
        summary_attempt_disposition: {
          code: 'pre_worker_unavailable',
          reason_code: 'auto_judge_unavailable',
          operator_detail: 'judge lane down',
        },
      })],
    }))
    const row = gate.pending[0]
    expect(row?.phase).toBe('blocked')
    expect(row && gateDispositionText(row.disposition)).toBe('pre_worker_unavailable · judge lane down')
    expect(gateDispositionText(null)).toBe('확인 불가')
  })

  it('missing decision_source is not a human decision', () => {
    const gate = decodeGatePayload(payload({
      recent_resolved: [
        { id: 'r1', keeper_name: 'k', tool_name: 'bash', decision_kind: 'approve' },
        { id: 'r2', keeper_name: 'k', tool_name: 'bash', decision_kind: 'approve', decision_source: 'auto_judge' },
      ],
    }))
    expect(gate.resolved.map((row) => row.decisionSource)).toEqual([null, 'auto_judge'])
  })

  it('reads an unavailable judge lane and its reason', () => {
    const gate = decodeGatePayload(payload({
      hitl: { judge_lane: { status: 'unavailable', lane_id: 'hitl_summary', reason: 'registry not published' } },
    }))
    expect(gate.judgeLane).toEqual({ status: 'unavailable', lane_id: 'hitl_summary', reason: 'registry not published' })
    expect(decodeGatePayload(payload({})).judgeLane).toBeNull()
  })
})
