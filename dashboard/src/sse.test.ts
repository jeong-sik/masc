import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  _resetJournalForTests,
  journal,
  normalizeSSEDispatchType,
  recordServerPushEvent,
} from './sse'
import { appendThreadEntry, keeperThreads } from './keeper-state'
import { operationDeliveryProvenance } from './keeper-delivery-provenance'

describe('Keeper operation server push', () => {
  const operationId = 'kmsg-operation-1'

  beforeEach(() => {
    keeperThreads.value = {}
    appendThreadEntry('sangsu', {
      id: 'operation-reply',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: 'Queued',
      rawText: 'Queued',
      timestamp: null,
      delivery: 'queued',
      streamState: null,
      deliveryProvenance: operationDeliveryProvenance(
        operationId,
        'terminal_assistant',
      ),
      details: null,
    })
  })

  it('routes the nested AG-UI delta to the exact operation bubble', () => {
    recordServerPushEvent({
      type: 'keeper_chat_operation_event',
      name: 'sangsu',
      operation_id: operationId,
      ag_ui_event: {
        type: 'TEXT_MESSAGE_CONTENT',
        threadId: 'keeper-consumer:sangsu',
        runId: 'run-1',
        messageId: 'message-1',
        delta: '실제 답변',
        timestamp: 1,
      },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'operation-reply')
    expect(entry?.text).toBe('실제 답변')
    expect(entry?.delivery).toBe('streaming')
  })
})

describe('normalizeSSEDispatchType', () => {
  it('routes Event_bus audit events to the audit handler', () => {
    expect(normalizeSSEDispatchType('agent_core:masc:audit_event')).toBe('audit_event')
  })

  it('keeps board slash events on their explicit cases', () => {
    expect(normalizeSSEDispatchType('masc/board_post')).toBe('masc/board_post')
  })

  it('strips legacy masc slash prefix for core events', () => {
    expect(normalizeSSEDispatchType('masc/keeper_turn_complete')).toBe('keeper_turn_complete')
  })
})

describe('server-push Agent Core typed-payload handlers', () => {
  beforeEach(() => {
    _resetJournalForTests()
  })

  function emitEvent(payload: Record<string, unknown>): void {
    recordServerPushEvent(payload as unknown as Parameters<typeof recordServerPushEvent>[0])
  }

  function lastJournalEntry() {
    // journal.value is newest-first (RingBuffer.toArray ordering)
    return journal.value[0]
  }

  it('creates a journal entry from a typed agent_core:agent_started payload', () => {
    emitEvent({
      type: 'agent_core:agent_started',
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

  it('creates a journal entry from a typed agent_core:agent_completed payload', () => {
    emitEvent({
      type: 'agent_core:agent_completed',
      event_type: 'agent_completed',
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
        elapsed_s: 12.5,
        success: true,
        result: 'ok',
      },
    })
    expect(journal.value).toHaveLength(1)
    expect(lastJournalEntry()?.text).toBe('Agent run completed · t1 · 12.5s')
  })

  it('records a cooperative yield without calling it completion', () => {
    emitEvent({
      type: 'agent_core:agent_yielded',
      event_type: 'agent_yielded',
      ts_unix: 1_000,
      correlation_id: 'c1',
      run_id: 'r1',
      agent_name: 'alpha',
      task_id: 't1',
      turn: 2,
      tool_name: null,
      payload: { agent_name: 'alpha', task_id: 't1', turn: 2, elapsed_s: 1.5 },
    })
    expect(lastJournalEntry()?.text).toBe('Agent run yielded · T2 · 1.5s')
  })

  it('records a typed input request without calling it failure', () => {
    emitEvent({
      type: 'agent_core:agent_input_required',
      event_type: 'agent_input_required',
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
        elapsed_s: 1.5,
        request_id: 'request-1',
        participant_name: 'operator',
        question: 'Continue?',
        schema: null,
        timeout_s: null,
        created_at: 1_000,
      },
    })
    expect(lastJournalEntry()?.text).toBe('Agent input required · request-1')
  })

  it('creates a journal entry from a typed agent_core:agent_failed payload with all error fields', () => {
    emitEvent({
      type: 'agent_core:agent_failed',
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
    expect(journal.value).toHaveLength(1)
    expect(lastJournalEntry()?.text).toBe('Agent run failed · t1 · 3.0s · boom')
  })

  it('drops a malformed agent_core:agent_started payload and logs a warning', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const beforeCount = journal.value.length
    emitEvent({
      type: 'agent_core:agent_started',
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

  it('creates a journal entry from a typed agent_core:tool_called payload', () => {
    emitEvent({
      type: 'agent_core:tool_called',
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

  it('creates a journal entry from a typed agent_core:turn_completed payload', () => {
    emitEvent({
      type: 'agent_core:turn_completed',
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

  it('creates a journal entry from a typed agent_core:handoff_requested payload', () => {
    emitEvent({
      type: 'agent_core:handoff_requested',
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

  it('creates a journal entry from a typed agent_core:context_compacted payload', () => {
    emitEvent({
      type: 'agent_core:context_compacted',
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
        runtime: 'agent-core-runtime',
      },
    })
    expect(lastJournalEntry()?.text).toBe('Agent Core compact · 1000→800 · summarize')
  })
})
