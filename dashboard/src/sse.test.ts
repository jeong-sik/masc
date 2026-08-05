import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  journal,
  normalizeSSEDispatchType,
  recordServerPushEvent,
} from './sse'

describe('normalizeSSEDispatchType', () => {
  it('routes Event_bus audit events to the audit handler', () => {
    expect(normalizeSSEDispatchType('oas:masc:audit_event')).toBe('audit_event')
  })

  it('keeps board slash events on their explicit cases', () => {
    expect(normalizeSSEDispatchType('masc/board_post')).toBe('masc/board_post')
  })

  it('strips legacy masc slash prefix for core events', () => {
    expect(normalizeSSEDispatchType('masc/keeper_turn_complete')).toBe('keeper_turn_complete')
  })
})

describe('server-push OAS typed-payload handlers', () => {
  beforeEach(() => {
    journal.value = []
  })

  function emitEvent(payload: Record<string, unknown>): void {
    recordServerPushEvent(payload as Parameters<typeof recordServerPushEvent>[0])
  }

  function lastJournalEntry() {
    // journal.value is newest-first (RingBuffer.toArray ordering)
    return journal.value[0]
  }

  it('creates a journal entry from a typed oas:agent_started payload', () => {
    emitEvent({
      type: 'oas:agent_started',
      event_type: 'agent_started',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: 't1',
      turn: null,
      tool_name: null,
      payload: { agent_name: 'alpha', task_id: 't1' },
    })
    expect(lastJournalEntry()?.text).toBe('Agent run started · t1')
    expect(lastJournalEntry()?.agent).toBe('alpha')
  })

  it('creates a journal entry from a typed oas:agent_completed payload', () => {
    emitEvent({
      type: 'oas:agent_completed',
      event_type: 'agent_completed',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: 't1',
      turn: null,
      tool_name: null,
      payload: { agent_name: 'alpha', task_id: 't1', elapsed_s: 12.5 },
    })
    expect(lastJournalEntry()?.text).toBe('Agent run completed · t1 · 12.5s')
  })

  it('creates a journal entry from a typed oas:agent_failed payload with all error fields', () => {
    emitEvent({
      type: 'oas:agent_failed',
      event_type: 'agent_failed',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: 't1',
      turn: null,
      tool_name: null,
      payload: {
        agent_name: 'alpha',
        task_id: 't1',
        elapsed_s: 3.0,
        error: 'boom',
        error_domain: 'api',
        error_code: 'rate_limited',
        error_retryable: true,
        error_detail: { variant: 'rate_limited', message: 'slow down' },
      },
    })
    expect(lastJournalEntry()?.text).toBe('Agent run failed · t1 · 3.0s · boom')
  })

  it('drops a malformed oas:agent_started payload and logs a warning', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const beforeCount = journal.value.length
    emitEvent({
      type: 'oas:agent_started',
      event_type: 'agent_started',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: 't1',
      turn: null,
      tool_name: null,
      payload: { agent_name: 'alpha', task_id: 42 },
    })
    expect(journal.value).toHaveLength(beforeCount)
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('creates a journal entry from a typed oas:tool_called payload', () => {
    emitEvent({
      type: 'oas:tool_called',
      event_type: 'tool_called',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: null,
      turn: null,
      tool_name: 'bash',
      payload: { agent_name: 'alpha', tool_name: 'bash' },
    })
    expect(lastJournalEntry()?.text).toBe('Tool called: bash')
    expect(lastJournalEntry()?.agent).toBe('alpha')
  })

  it('creates a journal entry from a typed oas:turn_completed payload', () => {
    emitEvent({
      type: 'oas:turn_completed',
      event_type: 'turn_completed',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: null,
      turn: 5,
      tool_name: null,
      payload: { agent_name: 'alpha', turn: 5 },
    })
    expect(lastJournalEntry()?.text).toBe('Turn completed · T5')
  })

  it('creates a journal entry from a typed oas:handoff_requested payload', () => {
    emitEvent({
      type: 'oas:handoff_requested',
      event_type: 'handoff_requested',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: null,
      turn: null,
      tool_name: null,
      payload: { from_agent: 'alpha', to_agent: 'beta', reason: 'load' },
    })
    expect(lastJournalEntry()?.text).toBe('Handoff requested · alpha→beta · load')
  })

  it('creates a journal entry and compaction record from a typed oas:context_compacted payload', () => {
    emitEvent({
      type: 'oas:context_compacted',
      event_type: 'context_compacted',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: null,
      turn: null,
      tool_name: null,
      payload: {
        agent_name: 'alpha',
        before_tokens: 1000,
        after_tokens: 800,
        phase: 'summarize',
        runtime: 'oas-runtime',
      },
    })
    expect(lastJournalEntry()?.text).toBe('OAS compact · 1000→800 · summarize')
  })
})
