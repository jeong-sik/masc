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
    expect(events[0]!.toolName).toBe('keeper_fs_read')
    expect(events[1]!.toolName).toBe('keeper_edit')
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
    expect(events[0]!.kind).toBe('broadcast')
    expect(events[1]!.kind).toBe('tool_call')
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
        fetchToken: 0,
      },
    }

    const summary = getTraceSummary('agent-x')
    expect(summary.oas_input_tokens).toBe(800)
    expect(summary.oas_output_tokens).toBe(230)
    expect(summary.total_cost_usd).toBeCloseTo(0.005)
    expect(summary.lifecycle_count).toBe(2)
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
        fetchToken: 0,
      },
    }

    closeSessionTrace('keeper-a')
    expect(getTraceEvents('keeper-a')).toEqual([])
    expect(getTraceLoading('keeper-a')).toBe(false)
    expect(getTraceError('keeper-a')).toBeNull()
  })
})
