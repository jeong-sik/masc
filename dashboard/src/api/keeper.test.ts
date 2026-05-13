import { afterEach, describe, expect, it, vi } from 'vitest'

const { runOperatorAction, currentDashboardActor } = vi.hoisted(() => ({
  runOperatorAction: vi.fn(),
  currentDashboardActor: vi.fn(() => 'dashboard'),
}))

vi.mock('./core', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./core')>()
  return {
    ...actual,
    currentDashboardActor,
    runOperatorAction,
  }
})

import {
  bootKeeper,
  clearKeeper,
  deleteKeeperHistorySnapshots,
  fetchKeeperCheckpoints,
  fetchKeeperRuntimeTrace,
  pauseKeeper,
  parseKeeperRuntimeTrace,
  resumeKeeper,
  sendKeeperMessageDetailed,
  shutdownKeeper,
  streamKeeperMessage,
  wakeKeeper,
} from './keeper'

afterEach(() => {
  vi.clearAllMocks()
  vi.unstubAllGlobals()
  try {
    window.localStorage?.removeItem?.('masc_dashboard_agent_name')
  } catch {
    // Ignore storage cleanup failures in the test environment.
  }
})

describe('sendKeeperMessageDetailed', () => {
  it('forces direct reply mode for operator-mediated direct chats', async () => {
    runOperatorAction.mockResolvedValueOnce({
      result: {
        reply: 'pong',
        model_used: 'test-model',
      },
    })

    const reply = await sendKeeperMessageDetailed('sangsu', 'ping')

    expect(currentDashboardActor).toHaveBeenCalled()
    expect(runOperatorAction).toHaveBeenCalledWith({
      actor: 'dashboard',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'sangsu',
      payload: {
        message: 'ping',
        direct_reply: true,
      },
    })
    expect(reply.text).toBe('pong')
  })
})

describe('streamKeeperMessage', () => {
  it('posts direct reply mode to the keeper chat stream endpoint', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-eager-manta%E3%85%8A')

    const fetchMock = vi.fn().mockResolvedValue(
      new Response('data: {"type":"RUN_FINISHED"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const events: string[] = []
    await streamKeeperMessage('sangsu', 'ping', {
      onEvent: event => {
        events.push(event.type)
      },
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = init.headers as Record<string, string>
    expect(JSON.parse(String(init.body))).toEqual({
      name: 'sangsu',
      message: 'ping',
      direct_reply: true,
    })
    const actorHeader = headers['X-MASC-Agent'] ?? headers['x-masc-agent']
    expect(actorHeader).toBe('dashboard-eager-manta')
    expect(actorHeader).not.toContain('%')
    expect(events).toEqual(['RUN_FINISHED'])
  })
})

describe('keeper runtime trace', () => {
  it('parses runtime trace evidence with resilient defaults', () => {
    const result = parseKeeperRuntimeTrace({
      keeper: 'sangsu',
      trace_id: 'trace-1',
      turn_id: 7,
      manifest_path: '/tmp/runtime-manifest.jsonl',
      manifest_path_present: true,
      manifest_total_rows: 10,
      manifest_returned_rows: 8,
      receipt_returned_rows: 1,
	      turn_identity: {
        requested_keeper_turn_id: 7,
        manifest_keeper_turn_ids: [7],
        receipt_turn_counts: [7],
        max_oas_turn_count: 3,
        provider_attempt_started_count: 1,
        provider_attempt_finished_count: 1,
        event_bus_correlated_count: 1,
        memory_injected_count: 1,
        memory_flushed_count: 1,
        receipt_appended_count: 1,
        turn_finished_count: 1,
	      },
	      provider_attempts: {
	        started_count: 1,
	        finished_count: 1,
	        terminal_status: 'timeout',
	        terminal_error: 'Timeout after 120.0s',
	        terminal_exception_kind: 'outer_oas_timeout',
	        attempts: [
	          {
	            ts: '2026-05-12T00:00:00Z',
	            event: 'provider_attempt_finished',
	            cascade_name: 'coding_plan',
	            status: 'timeout',
	            error: 'Timeout after 120.0s',
	            exception_kind: 'outer_oas_timeout',
	          },
	        ],
	      },
	      event_bus: {
        event_bus_correlated_count: 1,
        correlation_ids: ['corr-1'],
        run_ids: ['run-1'],
        context_compact_started_count: 1,
        context_compacted_count: 1,
      },
      memory: {
        memory_injected_count: 1,
        memory_flush_success_count: 1,
        episodes_flushed: 2,
      },
      health: 'ok',
      stale_reason: null,
    })

    expect(result.keeper).toBe('sangsu')
	    expect(result.turn_identity.provider_lane_resolved_count).toBe(0)
	    expect(result.turn_identity.provider_attempt_started_count).toBe(1)
	    expect(result.provider_attempts.terminal_status).toBe('timeout')
	    expect(result.provider_attempts.attempts[0]?.exception_kind).toBe('outer_oas_timeout')
	    expect(result.event_bus.correlation_ids).toEqual(['corr-1'])
    expect(result.memory.memory_flushed_count).toBe(0)
    expect(result.memory.episodes_flushed).toBe(2)
    expect(result.health).toBe('ok')
  })

  it('parses runtime lens evidence with safe defaults and gap codes', () => {
    const result = parseKeeperRuntimeTrace({
      keeper: 'sangsu',
      trace_id: 'trace-lens',
      turn_id: 9,
      manifest_path: '/tmp/runtime-manifest.jsonl',
      manifest_path_present: true,
      manifest_total_rows: 4,
      manifest_returned_rows: 4,
      receipt_returned_rows: 0,
      turn_identity: {},
      provider_attempts: {},
      event_bus: {},
      memory: {},
      runtime_lens: {
        axes: {
          tool_surface: {
            requested_tools: ['read_file'],
            required_tools: ['keeper_task_done'],
            materialized_tools: ['read_file'],
            missing_required_tools: ['keeper_task_done'],
            terminal_status: 'missing_required_tool',
          },
          provider_lane: {
            resolved: false,
            status: 'error',
            resolved_lane: 'inline',
            missing_required_tools: ['keeper_task_done'],
          },
          provider_attempt: {
            started_count: 1,
            finished_count: 1,
            terminal_status: 'timeout',
          },
        },
        swimlanes: {
          provider: {
            lane: 'provider',
            label: 'Provider',
            event_count: 2,
            terminal_status: 'timeout',
            gap_codes: [],
            events: [{ event: 'provider_attempt_finished', count: 1 }],
          },
          tool_runtime: {
            lane: 'tool_runtime',
            label: 'Tool Runtime',
            event_count: 1,
            terminal_status: 'missing_required_tool',
            gap_codes: ['required_tool_not_materialized'],
          },
        },
        gaps: [
          {
            code: 'required_tool_not_materialized',
            severity: 'bad',
            lane: 'tool_runtime',
            detail: 'missing required tools: keeper_task_done',
          },
        ],
      },
      health: 'partial',
    })

    expect(result.runtime_lens.turn_clock.trace_id).toBe('trace-lens')
    expect(result.runtime_lens.turn_clock.terminal_event_present).toBe(false)
    expect(result.runtime_lens.axes.tool_surface.requested_tools).toEqual(['read_file'])
    expect(result.runtime_lens.axes.tool_surface.visible_tool_count).toBeNull()
    expect(result.runtime_lens.axes.provider_lane.resolved).toBe(false)
    expect(result.runtime_lens.axes.provider_attempt.terminal_status).toBe('timeout')
    expect(result.runtime_lens.swimlanes.provider.terminal_status).toBe('timeout')
    expect(result.runtime_lens.swimlanes.memory_context.terminal_status).toBe('unknown')
    expect(result.runtime_lens.gaps.map(gap => gap.code)).toEqual(['required_tool_not_materialized'])
  })

  it('fetches runtime trace evidence with query params', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        keeper: 'keeper sangsu',
        trace_id: 'trace 1',
        turn_id: 7,
        manifest_path: '/tmp/runtime-manifest.jsonl',
        manifest_path_present: true,
        manifest_total_rows: 2,
        manifest_returned_rows: 2,
        receipt_returned_rows: 1,
	        turn_identity: {
          requested_keeper_turn_id: 7,
          manifest_keeper_turn_ids: [7],
          max_oas_turn_count: 4,
          provider_lane_resolved_count: 1,
          provider_attempt_started_count: 1,
          provider_attempt_finished_count: 1,
          event_bus_correlated_count: 1,
          memory_injected_count: 1,
          memory_flushed_count: 1,
          receipt_appended_count: 1,
          turn_finished_count: 1,
	        },
	        provider_attempts: {
	          started_count: 1,
	          finished_count: 1,
	          terminal_status: 'provider_returned',
	          attempts: [],
	        },
	        event_bus: {
          event_bus_correlated_count: 1,
          context_compact_started_count: 0,
          context_compacted_count: 0,
        },
        memory: {
          memory_injected_count: 1,
          memory_flushed_count: 1,
        },
        health: 'ok',
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperRuntimeTrace('keeper sangsu', {
      traceId: 'trace 1',
      turnId: 7,
      limit: 50,
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]! as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper%20sangsu/runtime-trace?trace_id=trace+1&turn_id=7&limit=50')
    expect(init.method).toBeUndefined()
	    expect(result.turn_identity.max_oas_turn_count).toBe(4)
	    expect(result.provider_attempts.terminal_status).toBe('provider_returned')
	    expect(result.memory.memory_injected_count).toBe(1)
    expect(result.runtime_lens.turn_clock.trace_id).toBe('trace 1')
  })
})

describe('keeper lifecycle', () => {
  it('treats unauthorized shutdown responses as failures', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: 'Token required' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await shutdownKeeper('keeper-test')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Token required')
  })

  it('falls back to the HTTP status when boot failure payload is not json', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('auth gateway failed', {
        status: 502,
        headers: { 'Content-Type': 'text/plain' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await bootKeeper('keeper-test')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Failed to boot keeper-test (HTTP 502): auth gateway failed')
  })

  it('falls back to the HTTP status when boot failure payload is not JSON', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('null', {
        status: 502,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await bootKeeper('keeper-test')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Failed to boot keeper-test (HTTP 502)')
  })

  it('posts keeper clear payload and returns structured detail', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        action: 'clear',
        name: 'keeper-test',
        detail: {
          cleared_message_count: 12,
          continuity_cleared: true,
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await clearKeeper('keeper-test', {
      reason: 'reset stale continuity',
      preserve_system_prompt: true,
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]! as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper-test/clear')
    expect(JSON.parse(String(init.body))).toEqual({
      reason: 'reset stale continuity',
      preserve_system_prompt: true,
    })
    expect(result.ok).toBe(true)
    expect(result.action).toBe('clear')
    expect(result.detail).toEqual({
      cleared_message_count: 12,
      continuity_cleared: true,
    })
  })

  it('fetches keeper checkpoint inventory from the admin route', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        keeper: 'keeper-test',
        trace_id: 'trace-keeper-test',
        session_dir: '/tmp/trace-keeper-test',
        current: null,
        history: [],
        legacy_shadow_count: 0,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchKeeperCheckpoints('keeper-test')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/keepers/keeper-test/checkpoints',
      expect.objectContaining({
        method: 'GET',
      }),
    )
    expect(result.trace_id).toBe('trace-keeper-test')
    expect(result.history).toEqual([])
  })

  it('posts selected OAS history snapshot ids for deletion', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        action: 'delete_history',
        keeper: 'keeper-test',
        deleted_snapshot_ids: ['oas-snapshot-1.json'],
        missing_snapshot_ids: [],
        inventory: {
          keeper: 'keeper-test',
          trace_id: 'trace-keeper-test',
          session_dir: '/tmp/trace-keeper-test',
          current: null,
          history: [],
          legacy_shadow_count: 0,
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await deleteKeeperHistorySnapshots('keeper-test', ['oas-snapshot-1.json'])

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]! as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper-test/checkpoints')
    expect(JSON.parse(String(init.body))).toEqual({
      action: 'delete_history',
      snapshot_ids: ['oas-snapshot-1.json'],
    })
    expect(result.deleted_snapshot_ids).toEqual(['oas-snapshot-1.json'])
  })

  it('sends POST with action=pause via directive endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true, action: 'pause', name: 'janitor' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await pauseKeeper('janitor')

    expect(result.ok).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/janitor/directive')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body)).toEqual({ action: 'pause' })
  })

  it('sends POST with action=resume via directive endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true, action: 'resume', name: 'janitor' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await resumeKeeper('janitor')

    expect(result.ok).toBe(true)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/janitor/directive')
    expect(JSON.parse(init.body)).toEqual({ action: 'resume' })
  })

  it('sends POST with action=wakeup via directive endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true, action: 'wakeup', name: 'sangsu' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await wakeKeeper('sangsu')

    expect(result.ok).toBe(true)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/sangsu/directive')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body)).toEqual({ action: 'wakeup' })
  })

  it('returns error when wakeup directive fails', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: false, error: 'Keeper not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await wakeKeeper('nonexistent')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Keeper not found')
  })

  it('returns error when pause directive fails', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: false, error: 'Keeper not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await pauseKeeper('nonexistent')

    expect(result.ok).toBe(false)
    expect(result.error).toBe('Keeper not found')
  })
})
