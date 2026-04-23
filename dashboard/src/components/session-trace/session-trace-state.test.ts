import { describe, expect, it, beforeEach } from 'vitest'
import {
  appendLiveToolCall,
  closeSessionTrace,
  getTraceEvents,
  getFilteredEvents,
  getTraceSummary,
  getKindCounts,
  setTraceFilter,
  getTraceFilter,
  setTraceStatusFilter,
  getTraceStatusFilter,
  setTraceSearchQuery,
  getStatusCounts,
  getTraceLoading,
  getTraceError,
  buildTraceEvents,
  _liveTraceFeeds as liveTraceFeeds,
  _traceSlots as traceSlots,
} from './session-trace-state'

// Reset trace slots before each test
beforeEach(() => {
  traceSlots.value = {}
  liveTraceFeeds.value = {}
})

describe('appendLiveToolCall', () => {
  it('does nothing when trace slot is not open', () => {
    appendLiveToolCall('unknown-keeper', {
      toolName: 'keeper_fs_read',
      durationMs: 100,
      success: true,
      error: null,
      tsUnix: 1712400000,
    })
    expect(getTraceEvents('unknown-keeper')).toEqual([])
  })

  it('appends a tool_call event to an open trace slot', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    appendLiveToolCall('keeper-a', {
      toolName: 'keeper_fs_read',
      durationMs: 250,
      success: true,
      error: null,
      tsUnix: 1712400000,
    })

    const events = getTraceEvents('keeper-a')
    expect(events).toHaveLength(1)
    const e = events[0]!
    expect(e.kind).toBe('tool_call')
    expect(e.toolName).toBe('keeper_fs_read')
    expect(e.duration_ms).toBe(250)
    expect(e.error).toBeNull()
    expect(e.ts).toBe(1712400000 * 1000)
    expect(e.id).toMatch(/^live-/)
  })

  it('appends error info when success is false', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    appendLiveToolCall('keeper-a', {
      toolName: 'keeper_bash',
      durationMs: 5000,
      success: false,
      error: 'command not found',
      tsUnix: 1712400000,
    })

    const events = getTraceEvents('keeper-a')
    expect(events).toHaveLength(1)
    expect(events[0]!.error).toBe('command not found')
  })

  it('appends multiple events in order', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    appendLiveToolCall('keeper-a', {
      toolName: 'keeper_fs_read',
      durationMs: 100,
      success: true,
      error: null,
      tsUnix: 1712400001,
    })
    appendLiveToolCall('keeper-a', {
      toolName: 'keeper_edit',
      durationMs: 200,
      success: true,
      error: null,
      tsUnix: 1712400002,
    })

    const events = getTraceEvents('keeper-a')
    expect(events).toHaveLength(2)
    // Newest-first: tsUnix=1712400002 (keeper_edit) comes first
    expect(events[0]!.toolName).toBe('keeper_edit')
    expect(events[1]!.toolName).toBe('keeper_fs_read')
  })

  it('preserves existing events when appending', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [{
          id: 'existing-1',
          ts: 1712399000000,
          ts_iso: '2024-04-06T10:00:00.000Z',
          kind: 'broadcast',
          sourceLane: 'masc',
          summary: 'hello',
          detail: {},
        }],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    appendLiveToolCall('keeper-a', {
      toolName: 'keeper_bash',
      durationMs: 300,
      success: true,
      error: null,
      tsUnix: 1712400000,
    })

    const events = getTraceEvents('keeper-a')
    expect(events).toHaveLength(2)
    // Newest-first: tool_call (tsUnix=1712400000) > broadcast (ts=1712399000000)
    expect(events[0]!.kind).toBe('tool_call')
    expect(events[1]!.kind).toBe('broadcast')
  })
})

describe('buildTraceEvents', () => {
  it('deduplicates by id', () => {
    const events = buildTraceEvents(
      { agent: 'test', period: { from: '', to: '' }, events: [{ type: 'joined', ts: '2024-04-06T10:00:00Z', detail: {} }], summary: { tasks_completed: 0, tasks_claimed: 0, messages_sent: 0, active_duration_minutes: 0, total_events: 1 } },
      null,
    )
    expect(events.length).toBeGreaterThan(0)
  })

  it('merges timeline and trajectory entries', () => {
    const events = buildTraceEvents(
      { agent: 'test', period: { from: '', to: '' }, events: [{ type: 'broadcast', ts: '2024-04-06T10:00:00Z', detail: { content: 'Starting work on feature X' } }], summary: { tasks_completed: 0, tasks_claimed: 0, messages_sent: 0, active_duration_minutes: 0, total_events: 1 } },
      {
        keeper: 'test', trace_id: 't1', generation: 1, total_entries: 1, showing: 1,
        entries: [{
          ts: 1712397700,
          ts_iso: '2024-04-06T10:01:40Z',
          turn: 1,
          round: 1,
          tool_name: 'keeper_fs_read',
          args: { file_path: '/tmp/test.txt' },
          result: 'file contents',
          duration_ms: 50,
          gate: { status: 'pass' },
          cost_usd: 0.001,
          error: null,
        }],
      },
    )
    expect(events.length).toBe(2)
    const kinds = events.map(e => e.kind).sort()
    expect(kinds).toEqual(['broadcast', 'tool_call'])
  })

  it('maps timeline tool_call activity into tool_call traces', () => {
    const events = buildTraceEvents(
      {
        agent: 'test',
        period: { from: '', to: '' },
        events: [{
          type: 'tool_call',
          ts: '2024-04-06T10:00:00Z',
          detail: {
            tool_name: 'keeper_fs_read',
            duration_ms: 42,
            tool_args_preview: '{"path":"/tmp/test.txt"}',
          },
        }],
        summary: { tasks_completed: 0, tasks_claimed: 0, messages_sent: 0, active_duration_minutes: 0, total_events: 1 },
      },
      null,
    )
    expect(events).toHaveLength(1)
    expect(events[0]!.kind).toBe('tool_call')
    expect(events[0]!.summary).toBe('keeper_fs_read')
    expect(events[0]!.toolArgs).toBe('{"path":"/tmp/test.txt"}')
  })

  it('enriches trajectory rows from tool-call log and suppresses shallow timeline duplicates', () => {
    const events = buildTraceEvents(
      {
        agent: 'test',
        period: { from: '', to: '' },
        events: [{
          type: 'tool_call',
          ts: '2024-04-06T10:01:40Z',
          detail: {
            tool_name: 'keeper_fs_read',
            success: true,
            duration_ms: 50,
            tool_args_preview: '{"path":"/tmp/preview.txt"}',
          },
        }],
        summary: { tasks_completed: 0, tasks_claimed: 0, messages_sent: 0, active_duration_minutes: 0, total_events: 1 },
      },
      {
        keeper: 'test',
        trace_id: 'trace-1',
        generation: 1,
        total_entries: 1,
        showing: 1,
        entries: [{
          ts: 1712397700,
          ts_iso: '2024-04-06T10:01:40Z',
          turn: 1,
          round: 1,
          tool_name: 'keeper_fs_read',
          args: { file_path: '/tmp/trajectory.txt' },
          result: 'trajectory result',
          duration_ms: 50,
          gate: { status: 'pass' },
          cost_usd: 0.001,
          error: null,
        }],
      },
      {
        keeper: 'test',
        count: 1,
        entries: [{
          ts: 1712397700,
          keeper: 'test',
          tool: 'keeper_fs_read',
          input: { file_path: '/tmp/full.txt' },
          output: 'full file contents',
          success: true,
          duration_ms: 50,
          trace_id: 'trace-1',
          session_id: 'trace-1',
          turn: 1,
          keeper_turn_id: 1,
          task_id: 'task-1',
          lane: 'runtime_mcp',
        }],
      },
    )
    const toolEvents = events.filter(e => e.kind === 'tool_call')
    expect(toolEvents).toHaveLength(1)
    expect(toolEvents[0]!.toolArgs).toEqual({ file_path: '/tmp/full.txt' })
    expect(toolEvents[0]!.toolResult).toBe('full file contents')
    expect(toolEvents[0]!.detail.trace_origin).toBe('trajectory+tool_call_log')
    expect(toolEvents[0]!.detail.lane).toBe('runtime_mcp')
  })

  it('creates synthetic tool_call rows from tool-call log when trajectory is missing', () => {
    const events = buildTraceEvents(
      {
        agent: 'test',
        period: { from: '', to: '' },
        events: [],
        summary: { tasks_completed: 0, tasks_claimed: 0, messages_sent: 0, active_duration_minutes: 0, total_events: 0 },
      },
      null,
      {
        keeper: 'test',
        count: 1,
        entries: [{
          ts: 1712397700,
          keeper: 'test',
          tool: 'keeper_bash',
          input: { cmd: 'false' },
          output: 'command exited 1',
          success: false,
          duration_ms: 120,
          trace_id: 'trace-2',
          session_id: 'trace-2',
          turn: 3,
          keeper_turn_id: 3,
          task_id: 'task-2',
          lane: 'runtime_mcp',
        }],
      },
    )
    expect(events).toHaveLength(1)
    expect(events[0]!.kind).toBe('tool_call')
    expect(events[0]!.toolName).toBe('keeper_bash')
    expect(events[0]!.error).toBe('command exited 1')
    expect(events[0]!.detail.trace_origin).toBe('tool_call_log')
    expect(events[0]!.detail.lane).toBe('runtime_mcp')
  })

  it('maps keeper contract verdict activity into lifecycle trace events', () => {
    const events = buildTraceEvents(
      {
        agent: 'test',
        period: { from: '', to: '' },
        events: [{
          type: 'keeper.contract_verdict',
          ts: '2024-04-06T10:00:00Z',
          detail: {
            status: 'inconclusive',
            blocking_gap_artifacts: ['evidence/review_warning.json'],
          },
        }],
        summary: { tasks_completed: 0, tasks_claimed: 0, messages_sent: 0, active_duration_minutes: 0, total_events: 1 },
      },
      null,
    )
    expect(events).toHaveLength(1)
    expect(events[0]!.kind).toBe('lifecycle')
    expect(events[0]!.summary).toContain('CDAL inconclusive')
    expect(events[0]!.summary).toContain('review_warning.json')
  })

  it('maps keeper friction review tripwires into lifecycle trace events', () => {
    const events = buildTraceEvents(
      {
        agent: 'test',
        period: { from: '', to: '' },
        events: [{
          type: 'keeper.friction',
          ts: '2024-04-06T10:00:00Z',
          detail: {
            review_tripwires: ['review_requirement:submit_for_verification'],
            evidence_gap_artifacts: ['evidence/review_warning.json'],
          },
        }],
        summary: { tasks_completed: 0, tasks_claimed: 0, messages_sent: 0, active_duration_minutes: 0, total_events: 1 },
      },
      null,
    )
    expect(events).toHaveLength(1)
    expect(events[0]!.kind).toBe('lifecycle')
    expect(events[0]!.summary).toContain('submit_for_verification')
  })
})

describe('getTraceSummary', () => {
  it('counts tool_call events and accumulates cost', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'read', detail: {}, cost_usd: 0.01 },
          { id: '2', ts: 2000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'edit', detail: {}, cost_usd: 0.02 },
          { id: '3', ts: 3000, ts_iso: '', kind: 'broadcast', sourceLane: 'masc', summary: 'hello', detail: {} },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    const summary = getTraceSummary('keeper-a')
    expect(summary.tool_call_count).toBe(2)
    expect(summary.broadcast_count).toBe(1)
    expect(summary.total_cost_usd).toBeCloseTo(0.03)
  })

  it('accumulates OAS tokens and cost from lifecycle events', () => {
    traceSlots.value = {
      'agent-x': {
        events: [
          {
            id: 'a',
            ts: 1000,
            ts_iso: '',
            kind: 'lifecycle',
            sourceLane: 'oas',
            summary: 'agent completed',
            detail: { input_tokens: 500, output_tokens: 150 },
            cost_usd: 0.003,
          },
          {
            id: 'b',
            ts: 2000,
            ts_iso: '',
            kind: 'lifecycle',
            sourceLane: 'oas',
            summary: 'agent completed',
            detail: { input_tokens: 300, output_tokens: 80 },
            cost_usd: 0.002,
          },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    const summary = getTraceSummary('agent-x')
    expect(summary.oas_input_tokens).toBe(800)
    expect(summary.oas_output_tokens).toBe(230)
    expect(summary.total_cost_usd).toBeCloseTo(0.005)
    expect(summary.lifecycle_count).toBe(2)
  })

  it('accumulates oas_tokens_saved from context compactions', () => {
    traceSlots.value = {
      'agent-z': {
        events: [
          {
            id: 'c1',
            ts: 1000,
            ts_iso: '',
            kind: 'oas_context',
            sourceLane: 'oas',
            summary: 'compact',
            detail: { before_tokens: 1000, after_tokens: 400 },
          },
          {
            id: 'c2',
            ts: 2000,
            ts_iso: '',
            kind: 'oas_context',
            sourceLane: 'oas',
            summary: 'compact',
            detail: { before_tokens: 600, after_tokens: 300 },
          },
          {
            id: 'c3',
            ts: 3000,
            ts_iso: '',
            kind: 'oas_context',
            sourceLane: 'oas',
            summary: 'compact (no-op)',
            detail: { before_tokens: 200, after_tokens: 200 },
          },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    const summary = getTraceSummary('agent-z')
    expect(summary.oas_context_count).toBe(3)
    expect(summary.oas_tokens_saved).toBe(900) // 600 + 300 + 0
  })

  it('counts durable llm_request and error_occurred events', () => {
    traceSlots.value = {
      'agent-y': {
        events: [
          {
            id: 'r1',
            ts: 1000,
            ts_iso: '',
            kind: 'lifecycle',
            sourceLane: 'oas',
            summary: 'LLM 요청',
            detail: { durable_kind: 'llm_request', turn: 1, model: 'qwen', input_tokens: 100 },
          },
          {
            id: 'r2',
            ts: 1500,
            ts_iso: '',
            kind: 'lifecycle',
            sourceLane: 'oas',
            summary: 'LLM 요청',
            detail: { durable_kind: 'llm_request', turn: 2, model: 'qwen', input_tokens: 200 },
          },
          {
            id: 'e1',
            ts: 2000,
            ts_iso: '',
            kind: 'lifecycle',
            sourceLane: 'oas',
            summary: 'OAS 에러',
            detail: { durable_kind: 'error_occurred', turn: 2, error_domain: 'Api', detail: 'timeout' },
          },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    const summary = getTraceSummary('agent-y')
    expect(summary.oas_llm_call_count).toBe(2)
    expect(summary.oas_error_count).toBe(1)
  })
})

describe('getKindCounts', () => {
  it('returns counts per kind plus total', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: '', detail: {} },
          { id: '2', ts: 2000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: '', detail: {} },
          { id: '3', ts: 3000, ts_iso: '', kind: 'heartbeat', sourceLane: 'masc', summary: '', detail: {} },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    const counts = getKindCounts('keeper-a')
    expect(counts.all).toBe(3)
    expect(counts.tool_call).toBe(2)
    expect(counts.heartbeat).toBe(1)
    expect(counts.broadcast).toBe(0)
  })
})

describe('filter', () => {
  it('filters events by kind', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: '', detail: {} },
          { id: '2', ts: 2000, ts_iso: '', kind: 'broadcast', sourceLane: 'masc', summary: '', detail: {} },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    setTraceFilter('keeper-a', 'tool_call')
    expect(getTraceFilter('keeper-a')).toBe('tool_call')
    const filtered = getFilteredEvents('keeper-a')
    expect(filtered).toHaveLength(1)
    expect(filtered[0]!.kind).toBe('tool_call')
  })
})

describe('closeSessionTrace', () => {
  it('removes the agent slot', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [{ id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: '', detail: {} }],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    closeSessionTrace('keeper-a')
    expect(getTraceEvents('keeper-a')).toEqual([])
    expect(getTraceLoading('keeper-a')).toBe(false)
    expect(getTraceError('keeper-a')).toBeNull()
  })
})

describe('status filter', () => {
  it('classifies tool_call as success and events with error as failure', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'read', detail: {} },
          { id: '2', ts: 2000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'fail', detail: {}, error: 'timeout' },
          { id: '3', ts: 3000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'rejected', detail: {}, gate: { status: 'reject', reason: 'unsafe' } },
          { id: '4', ts: 4000, ts_iso: '', kind: 'broadcast', sourceLane: 'masc', summary: 'hello', detail: {} },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    const counts = getStatusCounts('keeper-a')
    expect(counts.success).toBe(1)
    expect(counts.failure).toBe(1)
    expect(counts.gate_rejected).toBe(1)
    expect(counts.all).toBe(3) // broadcast has no status
  })

  it('filters events by status', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'ok', detail: {} },
          { id: '2', ts: 2000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'fail', detail: {}, error: 'err' },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    setTraceStatusFilter('keeper-a', 'failure')
    expect(getTraceStatusFilter('keeper-a')).toBe('failure')
    const filtered = getFilteredEvents('keeper-a')
    expect(filtered).toHaveLength(1)
    expect(filtered[0]!.error).toBe('err')
  })

  it('combines category filter and status filter', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'ok', detail: {} },
          { id: '2', ts: 2000, ts_iso: '', kind: 'oas_tool', sourceLane: 'oas', summary: 'oas-ok', detail: {} },
          { id: '3', ts: 3000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'fail', detail: {}, error: 'err' },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    setTraceFilter('keeper-a', 'tool_call')
    setTraceStatusFilter('keeper-a', 'success')
    const filtered = getFilteredEvents('keeper-a')
    expect(filtered).toHaveLength(1)
    expect(filtered[0]!.id).toBe('1')
  })
})

describe('search filter', () => {
  it('matches against summary, toolName, and error fields', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'read file', detail: {}, toolName: 'fs_read' },
          { id: '2', ts: 2000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'edit code', detail: {}, toolName: 'edit_file' },
          { id: '3', ts: 3000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'bash error', detail: {}, error: 'command not found' },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    // Match by summary
    setTraceSearchQuery('keeper-a', 'read')
    expect(getFilteredEvents('keeper-a')).toHaveLength(1)

    // Match by toolName
    setTraceSearchQuery('keeper-a', 'edit')
    expect(getFilteredEvents('keeper-a')).toHaveLength(1)

    // Match by error
    setTraceSearchQuery('keeper-a', 'not found')
    expect(getFilteredEvents('keeper-a')).toHaveLength(1)

    // No match
    setTraceSearchQuery('keeper-a', 'nonexistent')
    expect(getFilteredEvents('keeper-a')).toHaveLength(0)
  })

  it('is case-insensitive', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'Read File', detail: {} },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    setTraceSearchQuery('keeper-a', 'read')
    expect(getFilteredEvents('keeper-a')).toHaveLength(1)

    setTraceSearchQuery('keeper-a', 'FILE')
    expect(getFilteredEvents('keeper-a')).toHaveLength(1)
  })

  it('combines with category and status filters', () => {
    traceSlots.value = {
      'keeper-a': {
        events: [
          { id: '1', ts: 1000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'read config', detail: {}, toolName: 'fs_read' },
          { id: '2', ts: 2000, ts_iso: '', kind: 'tool_call', sourceLane: 'masc', summary: 'read config', detail: {}, toolName: 'fs_read', error: 'denied' },
          { id: '3', ts: 3000, ts_iso: '', kind: 'broadcast', sourceLane: 'masc', summary: 'read this message', detail: {} },
        ],
        loading: false,
        error: null,
        filter: 'all',
        statusFilter: 'all',
        searchQuery: '',
        fetchToken: 0,
      },
    }

    // Search + category filter
    setTraceFilter('keeper-a', 'tool_call')
    setTraceSearchQuery('keeper-a', 'config')
    expect(getFilteredEvents('keeper-a')).toHaveLength(2)

    // Search + category + status filter
    setTraceStatusFilter('keeper-a', 'success')
    expect(getFilteredEvents('keeper-a')).toHaveLength(1)
    expect(getFilteredEvents('keeper-a')[0]!.id).toBe('1')
  })
})
