import { describe, it, expect } from 'vitest'
import {
  normalizeMission,
  normalizeMissionSessionDetail,
  normalizeMissionBriefing,
} from './mission-normalizers'

// ================================================================
// normalizeMission
// ================================================================

describe('normalizeMission', () => {
  it('returns safe defaults for null', () => {
    const result = normalizeMission(null)
    expect(result.generated_at).toBeUndefined()
    expect(result.summary).toBeDefined()
    expect(result.incidents).toEqual([])
    expect(result.recommended_actions).toEqual([])
    expect(result.sessions).toEqual([])
    expect(result.agent_briefs).toEqual([])
    expect(result.keeper_briefs).toEqual([])
    expect(result.internal_signals).toEqual([])
    expect(result.attention_queue).toEqual([])
  })

  it('returns safe defaults for undefined', () => {
    const result = normalizeMission(undefined)
    expect(result.summary).toBeDefined()
    expect(result.incidents).toEqual([])
  })

  it('returns safe defaults for string input', () => {
    const result = normalizeMission('not an object')
    expect(result.summary).toBeDefined()
    expect(result.sessions).toEqual([])
  })

  it('extracts generated_at', () => {
    const result = normalizeMission({ generated_at: '2026-04-17T12:00:00Z' })
    expect(result.generated_at).toBe('2026-04-17T12:00:00Z')
  })

  it('extracts summary fields', () => {
    const result = normalizeMission({
      summary: {
        room_health: 'healthy',
        cluster: 'local',
        project: 'masc-mcp',
        paused: false,
        tempo_interval_s: 30,
        active_agents: 3,
        active_operations: 1,
      },
    })
    expect(result.summary.room_health).toBe('healthy')
    expect(result.summary.cluster).toBe('local')
    expect(result.summary.project).toBe('masc-mcp')
    expect(result.summary.paused).toBe(false)
    expect(result.summary.tempo_interval_s).toBe(30)
    expect(result.summary.active_agents).toBe(3)
  })

  it('defaults summary fields to undefined/0', () => {
    const result = normalizeMission({ summary: {} })
    expect(result.summary.room_health).toBeUndefined()
    expect(result.summary.paused).toBeUndefined()
    expect(result.summary.active_agents).toBeUndefined()
  })

  it('extracts incidents array', () => {
    const result = normalizeMission({
      incidents: [
        { kind: 'error', summary: 'High CPU', target_type: 'keeper' },
      ],
    })
    expect(result.incidents).toHaveLength(1)
    expect(result.incidents[0]!.kind).toBe('error')
    expect(result.incidents[0]!.summary).toBe('High CPU')
  })

  it('filters out invalid incidents', () => {
    const result = normalizeMission({
      incidents: [
        { kind: 'error' }, // missing summary, target_type
      ],
    })
    expect(result.incidents).toEqual([])
  })

  it('extracts recommended_actions', () => {
    const result = normalizeMission({
      recommended_actions: [
        { action_type: 'broadcast', target_type: 'room', reason: 'Alert' },
      ],
    })
    expect(result.recommended_actions).toHaveLength(1)
    expect(result.recommended_actions[0]!.action_type).toBe('broadcast')
  })

  it('extracts command_focus', () => {
    const result = normalizeMission({
      command_focus: {
        health: 'ok',
        active_operations: 2,
        pending_approvals: 5,
      },
    })
    expect(result.command_focus.health).toBe('ok')
    expect(result.command_focus.active_operations).toBe(2)
  })

  it('extracts operator_targets with keepers', () => {
    const result = normalizeMission({
      operator_targets: {
        keepers: [
          { name: 'janitor', status: 'Running', generation: 5 },
        ],
      },
    })
    expect(result.operator_targets.keepers).toHaveLength(1)
    expect(result.operator_targets.keepers[0]!.name).toBe('janitor')
  })

  it('extracts pending_confirms from operator_targets', () => {
    const result = normalizeMission({
      operator_targets: {
        pending_confirms: [
          { confirm_token: 'tok-1', actor: 'agent-1' },
        ],
      },
    })
    expect(result.operator_targets.pending_confirms).toHaveLength(1)
    expect(result.operator_targets.pending_confirms[0]!.confirm_token).toBe('tok-1')
  })

  it('filters invalid pending_confirms (missing token)', () => {
    const result = normalizeMission({
      operator_targets: {
        pending_confirms: [
          { actor: 'agent-1' }, // no confirm_token
        ],
      },
    })
    expect(result.operator_targets.pending_confirms).toEqual([])
  })

  it('extracts available_actions from operator_targets', () => {
    const result = normalizeMission({
      operator_targets: {
        available_actions: [
          { action_type: 'pause', target_type: 'keeper', description: 'Pause keeper' },
        ],
      },
    })
    expect(result.operator_targets.available_actions).toHaveLength(1)
    expect(result.operator_targets.available_actions[0]!.action_type).toBe('pause')
  })

  it('parses a full mission response', () => {
    const result = normalizeMission({
      generated_at: '2026-04-17T12:00:00Z',
      summary: { room_health: 'healthy' },
      incidents: [],
      recommended_actions: [],
      command_focus: { health: 'ok' },
      operator_targets: {},
      attention_queue: [],
      sessions: [],
      agent_briefs: [],
      keeper_briefs: [],
      internal_signals: [],
    })
    expect(result.generated_at).toBe('2026-04-17T12:00:00Z')
    expect(result.summary.room_health).toBe('healthy')
    expect(result.command_focus.health).toBe('ok')
  })
})

// ================================================================
// normalizeMissionSessionDetail
// ================================================================

describe('normalizeMissionSessionDetail', () => {
  it('returns safe defaults for null', () => {
    const result = normalizeMissionSessionDetail(null)
    expect(result.generated_at).toBeUndefined()
    expect(result.session_id).toBe('')
    expect(result.timeline).toEqual([])
    expect(result.participants).toEqual([])
    expect(result.operations).toEqual([])
    expect(result.keepers).toEqual([])
    expect(result.error).toBeNull()
  })

  it('returns safe defaults for string input', () => {
    const result = normalizeMissionSessionDetail('invalid')
    expect(result.session_id).toBe('')
    expect(result.timeline).toEqual([])
  })

  it('extracts session_id', () => {
    const result = normalizeMissionSessionDetail({ session_id: 'sess-123' })
    expect(result.session_id).toBe('sess-123')
  })

  it('extracts generated_at', () => {
    const result = normalizeMissionSessionDetail({ generated_at: '2026-04-17' })
    expect(result.generated_at).toBe('2026-04-17')
  })

  it('extracts error string', () => {
    const result = normalizeMissionSessionDetail({ error: 'Connection failed' })
    expect(result.error).toBe('Connection failed')
  })

  it('defaults error to null', () => {
    const result = normalizeMissionSessionDetail({})
    expect(result.error).toBeNull()
  })

  it('extracts worker_runs when valid', () => {
    const result = normalizeMissionSessionDetail({
      worker_runs: {
        requested_count: 5,
        completed_success_count: 3,
        completed_failed_count: 1,
      },
    })
    expect(result.worker_runs).not.toBeNull()
    expect(result.worker_runs!.requested_count).toBe(5)
    expect(result.worker_runs!.completed_success_count).toBe(3)
  })

  it('returns null worker_runs for invalid input', () => {
    const result = normalizeMissionSessionDetail({
      worker_runs: 'invalid',
    })
    expect(result.worker_runs).toBeNull()
  })
})

// ================================================================
// normalizeMissionBriefing
// ================================================================

describe('normalizeMissionBriefing', () => {
  it('returns safe defaults for null', () => {
    const result = normalizeMissionBriefing(null)
    expect(result.generated_at).toBeUndefined()
    expect(result.status).toBe('error')
    expect(result.summary).toBeNull()
    expect(result.sections).toEqual([])
    expect(result.criteria).toEqual([])
    expect(result.metadata_gaps).toEqual([])
    expect(result.error).toBeNull()
  })

  it('returns safe defaults for undefined', () => {
    const result = normalizeMissionBriefing(undefined)
    expect(result.status).toBe('error')
  })

  it('defaults status to error for unrecognized value', () => {
    const result = normalizeMissionBriefing({ status: 'weird' })
    expect(result.status).toBe('error')
  })

  it('accepts ok status', () => {
    const result = normalizeMissionBriefing({ status: 'ok' })
    expect(result.status).toBe('ok')
  })

  it('accepts pending status', () => {
    const result = normalizeMissionBriefing({ status: 'pending' })
    expect(result.status).toBe('pending')
  })

  it('accepts unavailable status', () => {
    const result = normalizeMissionBriefing({ status: 'unavailable' })
    expect(result.status).toBe('unavailable')
  })

  it('accepts error status', () => {
    const result = normalizeMissionBriefing({ status: 'error' })
    expect(result.status).toBe('error')
  })

  it('extracts summary and model', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      summary: 'All systems healthy',
      model: 'gpt-4',
    })
    expect(result.summary).toBe('All systems healthy')
    expect(result.model).toBe('gpt-4')
  })

  it('extracts boolean flags', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      cached: true,
      stale: false,
      refreshing: true,
    })
    expect(result.cached).toBe(true)
    expect(result.stale).toBe(false)
    expect(result.refreshing).toBe(true)
  })

  it('extracts criteria array', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      criteria: ['health', 'stability'],
    })
    expect(result.criteria).toEqual(['health', 'stability'])
  })

  it('extracts basis block', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      basis: {
        namespace: 'test-ns',
        crew_count: 5,
        agent_count: 3,
        keeper_count: 2,
      },
    })
    expect(result.basis!.namespace).toBe('test-ns')
    expect(result.basis!.crew_count).toBe(5)
    expect(result.basis!.agent_count).toBe(3)
    expect(result.basis!.keeper_count).toBe(2)
  })

  it('defaults basis fields', () => {
    const result = normalizeMissionBriefing({ status: 'ok' })
    expect(result.basis!.namespace).toBeNull()
    expect(result.basis!.crew_count).toBeUndefined()
  })

  it('extracts sections with valid status', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      sections: [
        { id: 'health', label: 'Health', summary: 'All good', status: 'ok' },
        { id: 'risk', label: 'Risk', summary: 'Low risk', status: 'risk' },
        { id: 'watch', label: 'Watch', summary: 'Monitoring', status: 'watch' },
      ],
    })
    expect(result.sections).toHaveLength(3)
    expect(result.sections[0]!.id).toBe('health')
    expect(result.sections[0]!.status).toBe('ok')
    expect(result.sections[1]!.status).toBe('risk')
  })

  it('defaults section status to unclear for unrecognized value', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      sections: [
        { id: 'x', label: 'X', summary: 'S', status: 'bogus' },
      ],
    })
    expect(result.sections[0]!.status).toBe('unclear')
  })

  it('filters out invalid sections (missing required fields)', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      sections: [
        { id: 'health', label: 'Health' }, // missing summary
      ],
    })
    expect(result.sections).toEqual([])
  })

  it('extracts metadata_gaps with valid scope_type and severity', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      metadata_gaps: [
        { kind: 'missing', summary: 'No data', scope_type: 'session', severity: 'info' },
      ],
    })
    expect(result.metadata_gaps).toHaveLength(1)
    expect(result.metadata_gaps[0]!.kind).toBe('missing')
    expect(result.metadata_gaps[0]!.scope_type).toBe('session')
    expect(result.metadata_gaps[0]!.severity).toBe('info')
  })

  it('rejects metadata_gaps with invalid scope_type', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      metadata_gaps: [
        { kind: 'k', summary: 's', scope_type: 'invalid', severity: 'info' },
      ],
    })
    expect(result.metadata_gaps).toEqual([])
  })

  it('rejects metadata_gaps with invalid severity', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      metadata_gaps: [
        { kind: 'k', summary: 's', scope_type: 'session', severity: 'critical' },
      ],
    })
    expect(result.metadata_gaps).toEqual([])
  })

  it('extracts section signal_class and evidence_quality', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      sections: [
        {
          id: 's1',
          label: 'S1',
          summary: 'Summary',
          signal_class: 'metadata_gap',
          evidence_quality: 'strong',
          evidence: ['e1', 'e2'],
        },
      ],
    })
    const section = result.sections[0]!
    expect(section.signal_class).toBe('metadata_gap')
    expect(section.evidence_quality).toBe('strong')
    expect(section.evidence).toEqual(['e1', 'e2'])
  })

  it('ignores invalid signal_class values', () => {
    const result = normalizeMissionBriefing({
      status: 'ok',
      sections: [
        { id: 's1', label: 'S1', summary: 'S', signal_class: 'invalid' },
      ],
    })
    expect(result.sections[0]!.signal_class).toBeUndefined()
  })

  it('extracts ttl_sec', () => {
    const result = normalizeMissionBriefing({ status: 'ok', ttl_sec: 300 })
    expect(result.ttl_sec).toBe(300)
  })

  it('extracts error and last_error', () => {
    const result = normalizeMissionBriefing({
      status: 'error',
      error: 'Failed to generate',
      last_error: 'Previous failure',
    })
    expect(result.error).toBe('Failed to generate')
    expect(result.last_error).toBe('Previous failure')
  })
})
