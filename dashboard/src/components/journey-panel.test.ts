import { describe, expect, it } from 'vitest'

import type {
  DashboardExecutionContinuityBrief,
  DashboardExecutionSessionBrief,
  DashboardExecutionWorkerSupportBrief,
  JournalEntry,
  Keeper,
  Task,
} from '../types'
import { buildJourneyRecords, filterJourneyRecords } from './journey-panel'

const task = {
  id: 'task-1',
  title: 'Integrate keeper dashboard',
  status: 'in_progress',
  assignee: 'keeper-alpha',
  updated_at: '2026-04-18T09:00:00Z',
  contract: {
    strict: true,
    completion_contract: ['e2e green', 'thread resolved'],
    required_evidence: ['logs', 'screenshots'],
  },
  gate: {
    done: { status: 'ready' },
    completion_contract: ['e2e green', 'thread resolved'],
    unmet_completion_contract: ['thread resolved'],
  },
  execution_links: {
    session_id: 'sess-1',
    operation_id: 'op-1',
  },
  handoff_context: {
    summary: 'Next turn should verify the contract against live logs.',
  },
} satisfies Task

const keeper = {
  name: 'keeper-alpha',
  agent_name: 'keeper-alpha',
  status: 'active',
  phase: 'Running',
  pipeline_stage: 'thinking',
  cascade_name: 'keeper_unified',
  active_model: 'gpt-5.4',
  last_model_used: 'gpt-5.4',
  context_ratio: 0.42,
  context_tokens: 4200,
  context_max: 10000,
  turn_count: 12,
  autonomous_turn_count: 8,
  last_turn_ago_s: 45,
  memory_recent_note: 'Need to keep contract proof and recent review context in sync.',
  metrics_window: {
    memory_pass_rate: 0.75,
    memory_checks: 4,
    fallback_rate: 0.1,
  },
} satisfies Keeper

const executionSession = {
  session_id: 'sess-1',
  goal: 'UI consolidation',
  member_names: ['keeper-alpha'],
  linked_operation_id: 'op-1',
} satisfies DashboardExecutionSessionBrief

const continuity = {
  name: 'keeper-alpha',
  agent_name: 'keeper-alpha',
  state: 'healthy',
  note: 'continuity okay',
  focus: 'ship the unified panel',
  model: 'gpt-5.4',
  continuity_summary: 'Context looks healthy and the keeper is still focused on the current UI push.',
} satisfies DashboardExecutionContinuityBrief

const worker = {
  name: 'keeper-alpha',
  agent_name: 'keeper-alpha',
  state: 'working',
  note: 'actively shipping',
  focus: 'task-run-contract correlation',
  related_session_id: 'sess-1',
  related_operation_id: 'op-1',
} satisfies DashboardExecutionWorkerSupportBrief

const journalEntry = {
  agent: 'keeper-alpha',
  text: 'linked worker_run_id wr-1 to sess-1',
  narrativeText: 'keeper-alpha tied the current worker run to the task session.',
  timestamp: 1_776_500_000_000,
  sessionId: 'sess-1',
  operationId: 'op-1',
  workerRunId: 'wr-1',
} satisfies JournalEntry

describe('buildJourneyRecords', () => {
  it('builds a task-centric journey with run, contract, keeper, and life signals', () => {
    const records = buildJourneyRecords({
      tasks: [task],
      keepers: [keeper],
      executionSessions: [executionSession],
      continuityBriefs: [continuity],
      workerBriefs: [worker],
      missionSessions: [],
      journalEntries: [journalEntry],
    })

    expect(records).toHaveLength(1)
    expect(records[0]?.kind).toBe('task')
    expect(records[0]?.sessionId).toBe('sess-1')
    expect(records[0]?.operationId).toBe('op-1')
    expect(records[0]?.workerRunId).toBe('wr-1')
    expect(records[0]?.keeper?.cascade_name).toBe('keeper_unified')
    expect(records[0]?.life.some((entry) => entry.source === 'journal')).toBe(true)
  })

  it('adds standalone keeper journeys when keepers are not attached to active tasks', () => {
    const records = buildJourneyRecords({
      tasks: [],
      keepers: [keeper],
      executionSessions: [executionSession],
      continuityBriefs: [continuity],
      workerBriefs: [worker],
      missionSessions: [],
      journalEntries: [journalEntry],
    })

    expect(records).toHaveLength(1)
    expect(records[0]?.kind).toBe('keeper')
    expect(records[0]?.title).toBe('keeper-alpha')
    expect(records[0]?.sessionId).toBe('sess-1')
  })
})

describe('filterJourneyRecords', () => {
  const records = buildJourneyRecords({
    tasks: [task],
    keepers: [keeper],
    executionSessions: [executionSession],
    continuityBriefs: [continuity],
    workerBriefs: [worker],
    missionSessions: [],
    journalEntries: [journalEntry],
  })

  it('returns the original reference for an empty query', () => {
    expect(filterJourneyRecords(records, '')).toBe(records)
    expect(filterJourneyRecords(records, '   ')).toBe(records)
  })

  it('matches on keeper, model, and life text', () => {
    expect(filterJourneyRecords(records, 'keeper-alpha')).toHaveLength(1)
    expect(filterJourneyRecords(records, 'gpt-5.4')).toHaveLength(1)
    expect(filterJourneyRecords(records, 'worker run')).toHaveLength(1)
  })

  it('returns empty when the query does not match any journey field', () => {
    expect(filterJourneyRecords(records, 'nonexistent-token')).toHaveLength(0)
  })
})
