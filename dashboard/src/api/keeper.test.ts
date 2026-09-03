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
  bulkKeeperDirective,
  clearKeeper,
  deleteKeeperHistorySnapshots,
  fetchKeeperChatOperation,
  fetchKeeperChatHistory,
  fetchKeeperCheckpoints,
  fetchKeeperRuntimeTrace,
  KeeperEventQueueOperationError,
  operateKeeperEventQueue,
  pauseKeeper,
  parseKeeperRuntimeTrace,
  parseKeeperEventQueueSourceAddress,
  resumeKeeper,
  resetKeeper,
  shutdownKeeper,
  streamKeeperMessage,
  wakeKeeper,
} from './keeper'
import {
  applyKeeperCheckpointPurge as applyKeeperCheckpointPurgeFromLifecycle,
  bootKeeper as bootKeeperFromLifecycle,
  bulkKeeperDirective as bulkKeeperDirectiveFromLifecycle,
  clearKeeper as clearKeeperFromLifecycle,
  deleteKeeperHistorySnapshots as deleteKeeperHistorySnapshotsFromLifecycle,
  fetchKeeperCheckpoints as fetchKeeperCheckpointsFromLifecycle,
  pauseKeeper as pauseKeeperFromLifecycle,
  previewKeeperCheckpointPurge as previewKeeperCheckpointPurgeFromLifecycle,
  purgeKeeper as purgeKeeperFromLifecycle,
  resetKeeper as resetKeeperFromLifecycle,
  resumeKeeper as resumeKeeperFromLifecycle,
  shutdownKeeper as shutdownKeeperFromLifecycle,
  wakeKeeper as wakeKeeperFromLifecycle,
} from './keeper-lifecycle'
import {
  fetchKeeperRuntimeTrace as fetchKeeperRuntimeTraceFromRuntimeTrace,
  parseKeeperRuntimeTrace as parseKeeperRuntimeTraceFromRuntimeTrace,
} from './keeper-runtime-trace'
import { resetDevTokenBootstrap } from './dev-token'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'

afterEach(() => {
  vi.useRealTimers()
  vi.clearAllMocks()
  vi.unstubAllGlobals()
  try {
    window.localStorage?.removeItem?.('masc_dashboard_agent_name')
  } catch {
    // Ignore storage cleanup failures in the test environment.
  }
  try {
    window.sessionStorage?.clear?.()
  } catch {
    // Ignore storage cleanup failures in the test environment.
  }
  resetDevTokenBootstrap()
})

describe('keeper API module split compatibility', () => {
  it('keeps runtime-trace helpers re-exported from the keeper barrel', () => {
    expect(parseKeeperRuntimeTrace).toBe(parseKeeperRuntimeTraceFromRuntimeTrace)
    expect(fetchKeeperRuntimeTrace).toBe(fetchKeeperRuntimeTraceFromRuntimeTrace)
  })

  it('keeps lifecycle helpers re-exported from the keeper barrel', () => {
    expect(bootKeeper).toBe(bootKeeperFromLifecycle)
    expect(shutdownKeeper).toBe(shutdownKeeperFromLifecycle)
    expect(resetKeeper).toBe(resetKeeperFromLifecycle)
    expect(clearKeeper).toBe(clearKeeperFromLifecycle)
    expect(pauseKeeper).toBe(pauseKeeperFromLifecycle)
    expect(resumeKeeper).toBe(resumeKeeperFromLifecycle)
    expect(wakeKeeper).toBe(wakeKeeperFromLifecycle)
    expect(fetchKeeperCheckpoints).toBe(fetchKeeperCheckpointsFromLifecycle)
    expect(deleteKeeperHistorySnapshots).toBe(deleteKeeperHistorySnapshotsFromLifecycle)
    expect(bulkKeeperDirective).toBe(bulkKeeperDirectiveFromLifecycle)
  })
})

describe('Keeper Event Queue API', () => {
  it('reads the exact-entry address a waiting-inventory row carries', () => {
    const address = parseKeeperEventQueueSourceAddress({
      queue_index: 0,
      post_id: 'workspace-message:wmsg-1',
      source_ref: 'a'.repeat(64),
      source_incarnation: '17',
      urgency: 'normal',
      arrived_at_unix: 42,
      payload_kind: 'workspace_message',
    })
    expect(address).toEqual({ sourceRef: 'a'.repeat(64), sourceIncarnation: '17' })
  })

  // The address is the operator route's CAS key; a row that lacks either half,
  // or carries it in another shape, must not produce a mutation request.
  it('rejects a row detail without a usable address', () => {
    expect(parseKeeperEventQueueSourceAddress(null)).toBeNull()
    expect(parseKeeperEventQueueSourceAddress({ queue_index: 0 })).toBeNull()
    expect(parseKeeperEventQueueSourceAddress({
      source_ref: 'A'.repeat(64),
      source_incarnation: '17',
    })).toBeNull()
    expect(parseKeeperEventQueueSourceAddress({
      source_ref: 'a'.repeat(63),
      source_incarnation: '17',
    })).toBeNull()
    expect(parseKeeperEventQueueSourceAddress({
      source_ref: 'a'.repeat(64),
      source_incarnation: '-1',
    })).toBeNull()
  })

  it('sends a metadata-only event ref with its durable revision', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        schema: 'keeper_event_queue.operator.result.v1',
        ok: true,
        keeper_name: 'sangsu',
        result: { status: 'applied', revision: '8' },
        audit: { recorded: true },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await operateKeeperEventQueue('sangsu', {
      action: 'reprioritize',
      sourceIncarnation: '7',
      sourceRef: 'd'.repeat(64),
      urgency: 'immediate',
    })

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/keepers/sangsu/events/operator',
      expect.objectContaining({
        body: JSON.stringify({
          schema: 'keeper_event_queue.operator.request.v2',
          action: 'reprioritize',
          source_incarnation: '7',
          source_ref: 'd'.repeat(64),
          urgency: 'immediate',
        }),
      }),
    )
  })

  it('surfaces a committed event mutation follow-up failure with durable identity', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        schema: 'keeper_event_queue.operator.result.v1',
        ok: true,
        keeper_name: 'sangsu',
        result: {
          status: 'committed_followup_failed',
          transition_id: 'transition-9',
          stage: 'target_projection',
          detail: 'target queue unavailable',
        },
        audit: { recorded: true },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    let observed: unknown
    try {
      await operateKeeperEventQueue('sangsu', {
        action: 'cancel',
        operationId: 'operation-9',
        reason: 'operator cancellation',
        sourceIncarnation: '8',
        sourceRef: 'e'.repeat(64),
      })
    } catch (cause) {
      observed = cause
    }

    expect(observed).toBeInstanceOf(KeeperEventQueueOperationError)
    expect(observed).toMatchObject({
      commitState: 'committed',
      operation: {
        action: 'cancel',
        operationId: 'operation-9',
        reason: 'operator cancellation',
        sourceIncarnation: '8',
        sourceRef: 'e'.repeat(64),
      },
    })
    expect((observed as Error).message).toContain(
      'Event queue mutation committed, but target_projection follow-up failed (transition-9)',
    )
  })

  it('retains the generated event operation identity when the POST result is unknown', async () => {
    vi.stubGlobal('crypto', {
      randomUUID: vi.fn(() => '00000000-0000-4000-8000-000000000099'),
    })
    const fetchMock = vi.fn().mockRejectedValue(
      new TypeError('connection reset after possible commit'),
    )
    vi.stubGlobal('fetch', fetchMock)

    let observed: unknown
    try {
      await operateKeeperEventQueue('sangsu', {
        action: 'transfer',
        sourceIncarnation: '9',
        sourceRef: 'f'.repeat(64),
        targetKeeper: 'rondo',
      })
    } catch (cause) {
      observed = cause
    }

    expect(observed).toBeInstanceOf(KeeperEventQueueOperationError)
    expect(observed).toMatchObject({
      commitState: 'unknown',
      operation: {
        action: 'transfer',
        operationId: '00000000-0000-4000-8000-000000000099',
        sourceIncarnation: '9',
        sourceRef: 'f'.repeat(64),
        targetKeeper: 'rondo',
      },
    })
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/keepers/sangsu/events/operator',
      expect.objectContaining({
        body: JSON.stringify({
          schema: 'keeper_event_queue.operator.request.v2',
          action: 'transfer',
          source_incarnation: '9',
          source_ref: 'f'.repeat(64),
          operator_operation_id: '00000000-0000-4000-8000-000000000099',
          target_keeper: 'rondo',
        }),
      }),
    )
  })

  it('bounds chat history response-body consumption after headers arrive', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      statusText: 'OK',
      json: vi.fn(() => new Promise<never>(() => undefined)),
    } satisfies Partial<Response>)
    vi.stubGlobal('fetch', fetchMock)

    const historyPromise = fetchKeeperChatHistory('echo')
    const rejection = expect(historyPromise).rejects.toMatchObject({ timeout: true })
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    await rejection

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[1]).toEqual(expect.objectContaining({
      signal: expect.any(AbortSignal),
    }))
  })
})

describe('streamKeeperMessage', () => {
  const devTokenResponse = () => new Response(
    JSON.stringify({ token: 'test-dev-token', actor: 'dashboard', role: 'admin' }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  )

  it('posts direct reply mode to the keeper chat stream endpoint', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-eager-manta%E3%85%8A')

    const fetchMock = vi.fn((url: string) => url === '/api/v1/dashboard/dev-token'
      ? Promise.resolve(devTokenResponse())
      : Promise.resolve(new Response('data: {"type":"RUN_FINISHED"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })))
    vi.stubGlobal('fetch', fetchMock)

    const events: string[] = []
    await streamKeeperMessage('sangsu', 'ping', {
      operationId: 'kmsg-stream-direct',
      onEvent: event => {
        events.push(event.type)
      },
    })

    expect(fetchMock).toHaveBeenCalledTimes(2)
    const [, init] = fetchMock.mock.calls[1] as unknown as [string, RequestInit]
    const headers = init.headers as Record<string, string>
    expect(JSON.parse(String(init.body))).toEqual({
      request_id: 'kmsg-stream-direct',
      name: 'sangsu',
      message: 'ping',
    })
    const actorHeader = headers['X-MASC-Agent'] ?? headers['x-masc-agent']
    expect(actorHeader).toBe('dashboard')
    expect(actorHeader).not.toContain('%')
    expect(events).toEqual(['RUN_FINISHED'])
  })

  it('forwards copilot context fields to the stream endpoint', async () => {
    const fetchMock = vi.fn((url: string) => url === '/api/v1/dashboard/dev-token'
      ? Promise.resolve(devTokenResponse())
      : Promise.resolve(new Response('data: {"type":"RUN_FINISHED"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })))
    vi.stubGlobal('fetch', fetchMock)

    const events: string[] = []
    await streamKeeperMessage('sangsu', 'ping', {
      operationId: 'kmsg-stream-copilot',
      onEvent: event => {
        events.push(event.type)
      },
      channel: 'copilot',
      channelWorkspaceId: 'session-7',
      turnInstructions: 'focus on overview',
      surfaceContext: {
        label: 'Overview',
        route: '/overview',
        scene: 'fleet view',
        fields: [{ k: 'run', v: '2/5' }],
      },
    })

    expect(fetchMock).toHaveBeenCalledTimes(2)
    const [, init] = fetchMock.mock.calls[1] as unknown as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toEqual({
      request_id: 'kmsg-stream-copilot',
      name: 'sangsu',
      message: 'ping',
      channel: 'copilot',
      channel_workspace_id: 'session-7',
      turn_instructions: 'focus on overview',
      surface_context: {
        label: 'Overview',
        route: '/overview',
        scene: 'fleet view',
        fields: [{ k: 'run', v: '2/5' }],
      },
    })
    expect(events).toEqual(['RUN_FINISHED'])
  })

  it('forwards semantic user blocks separately from attachment payloads', async () => {
    const fetchMock = vi.fn((url: string) => url === '/api/v1/dashboard/dev-token'
      ? Promise.resolve(devTokenResponse())
      : Promise.resolve(new Response('data: {"type":"RUN_FINISHED"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })))
    vi.stubGlobal('fetch', fetchMock)

    await streamKeeperMessage('sangsu', 'describe this', {
      operationId: 'kmsg-stream-blocks',
      onEvent: () => {},
      attachments: [
        {
          id: 'att-img',
          type: 'image',
          name: 'screen.png',
          size: 1024,
          mimeType: 'image/png',
          data: 'data:image/png;base64,abc123',
        },
      ],
      userBlocks: [
        {
          type: 'image',
          attachmentId: 'att-img',
          name: 'screen.png',
          mimeType: 'image/png',
          size: 1024,
        },
        { type: 'text', text: 'describe this' },
      ],
    })

    const [, init] = fetchMock.mock.calls[1] as unknown as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toMatchObject({
      name: 'sangsu',
      message: 'describe this',
      attachments: [
        {
          id: 'att-img',
          type: 'image',
          name: 'screen.png',
          size: 1024,
          mime_type: 'image/png',
          data: 'data:image/png;base64,abc123',
        },
      ],
      user_blocks: [
        {
          type: 'image',
          attachment_id: 'att-img',
          name: 'screen.png',
          mime_type: 'image/png',
          size: 1024,
        },
        { type: 'text', text: 'describe this' },
      ],
    })
  })

  const stubStaleToken = () => {
    window.sessionStorage.setItem('masc_bearer_token', 'stale-token')
    window.sessionStorage.setItem(
      'masc_bearer_token_meta',
      JSON.stringify({ source: 'dev', actor: 'dashboard', role: 'worker' }),
    )
  }

  const stubStreamRetryFetch = (first401Body: unknown) => {
    let chatAttempts = 0
    const fetchMock = vi.fn((url: string, _init?: RequestInit) => {
      if (url === '/api/v1/keepers/chat/stream') {
        chatAttempts += 1
        if (chatAttempts === 1) {
          return Promise.resolve(new Response(
            JSON.stringify(first401Body),
            { status: 401, headers: { 'Content-Type': 'application/json' } },
          ))
        }
        return Promise.resolve(new Response('data: {"type":"RUN_FINISHED"}\n\n', {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        }))
      }
      if (url === '/api/v1/dashboard/dev-token') {
        return Promise.resolve(new Response(
          JSON.stringify({ token: 'fresh-token', actor: 'dashboard', role: 'admin' }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        ))
      }
      return Promise.reject(new Error(`unexpected fetch ${url}`))
    })
    vi.stubGlobal('fetch', fetchMock)
    return fetchMock
  }

  it('refreshes a stale loopback dev token once and retries on typed invalid_token code', async () => {
    stubStaleToken()
    // The message is generic; the typed auth_error_code drives the retry.
    const fetchMock = stubStreamRetryFetch({
      error: 'authentication failed',
      auth_error_code: 'invalid_token',
    })

    const events: string[] = []
    await streamKeeperMessage('sangsu', 'ping', {
      operationId: 'kmsg-stream-retry-invalid-token',
      onEvent: event => {
        events.push(event.type)
      },
    })

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      '/api/v1/keepers/chat/stream',
      '/api/v1/dashboard/dev-token',
      '/api/v1/keepers/chat/stream',
    ])
    const firstHeaders = fetchMock.mock.calls[0]?.[1]?.headers as Record<string, string>
    const retryHeaders = fetchMock.mock.calls[2]?.[1]?.headers as Record<string, string>
    expect(firstHeaders.Authorization).toBe('Bearer stale-token')
    expect(retryHeaders.Authorization).toBe('Bearer fresh-token')
    expect(events).toEqual(['RUN_FINISHED'])
  })

  it('retries on actor_mismatch typed code', async () => {
    stubStaleToken()
    const fetchMock = stubStreamRetryFetch({
      error: 'Agent name required',
      auth_error_code: 'actor_mismatch',
    })

    await streamKeeperMessage('sangsu', 'ping', {
      operationId: 'kmsg-stream-retry-actor',
      onEvent: () => {},
    })

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      '/api/v1/keepers/chat/stream',
      '/api/v1/dashboard/dev-token',
      '/api/v1/keepers/chat/stream',
    ])
  })

  it('does NOT retry when the typed code is not a stale-token case', async () => {
    stubStaleToken()
    const fetchMock = vi.fn((url: string) => {
      if (url === '/api/v1/keepers/chat/stream') {
        return Promise.resolve(new Response(
          JSON.stringify({
            error: '[AuthError] Forbidden: browser cannot cross-origin HTTP mutation',
            auth_error_code: 'same_origin_blocked',
          }),
          { status: 401, headers: { 'Content-Type': 'application/json' } },
        ))
      }
      return Promise.reject(new Error(`unexpected fetch ${url}`))
    })
    vi.stubGlobal('fetch', fetchMock)

    await expect(
      streamKeeperMessage('sangsu', 'ping', {
        operationId: 'kmsg-stream-no-retry-origin',
        onEvent: () => {},
      }),
    ).rejects.toMatchObject({
      name: 'ApiRequestError',
      authErrorCode: 'same_origin_blocked',
      detail: '[AuthError] Forbidden: browser cannot cross-origin HTTP mutation',
    })

    // Only the single chat POST — no dev-token refresh, no retry.
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      '/api/v1/keepers/chat/stream',
    ])
  })

  it('does NOT retry servers without typed auth_error_code', async () => {
    stubStaleToken()
    const fetchMock = stubStreamRetryFetch({
      error: '[AuthError] Invalid token: Token mismatch',
    })

    await expect(
      streamKeeperMessage('sangsu', 'ping', {
        operationId: 'kmsg-stream-no-retry-untyped',
        onEvent: () => {},
      }),
    ).rejects.toThrow()

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      '/api/v1/keepers/chat/stream',
    ])
  })
})

describe('fetchKeeperChatOperation', () => {
  it('parses restart interruption as a terminal failed operation', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        schema: 'masc.keeper_chat_operation.v1',
        operation_id: 'kmsg-restart-1',
        sequence: '7',
        created_at: 42,
        source: {},
        input: null,
        state: 'Failed',
        completed_at: 43,
        failure_kind: 'Interrupted_by_restart',
        failure_detail: 'runtime restarted while operation was Running',
        outcome_ref: null,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const operation = await fetchKeeperChatOperation('sangsu', 'kmsg-restart-1')

    expect(operation.state).toEqual({
      kind: 'failed',
      completedAt: 43,
      failureKind: 'Interrupted_by_restart',
      detail: 'runtime restarted while operation was Running',
      outcomeRef: null,
    })
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/keepers/sangsu/chat/operations/kmsg-restart-1',
      expect.any(Object),
    )
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
      manifest_scan_diagnostics: {
        schema: 'keeper.runtime_manifest_scan_diagnostics.v1',
        unsupported_event_count: 1,
        unsupported_event_counts: [{ event: 'future_event', count: 1 }],
        unsupported_event_unattributed_count: 0,
        invalid_manifest_row_count: 1,
        invalid_json_row_count: 1,
        samples: [
          { kind: 'unsupported_event', event: 'future_event' },
        ],
      },
      turn_identity: {
        requested_keeper_turn_id: 7,
        manifest_keeper_turn_ids: [7],
        receipt_turn_counts: [7],
        max_agent_core_turn_count: 3,
        runtime_completed_count: 1,
        runtime_failed_count: 0,
        event_bus_correlated_count: 1,
        memory_injected_count: 1,
        memory_flushed_count: 1,
        receipt_appended_count: 1,
        turn_finished_count: 1,
	      },
	      event_bus: {
        event_bus_correlated_count: 1,
        correlation_ids: ['corr-1'],
        run_ids: ['run-1'],
      },
      memory: {
        memory_injected_count: 1,
        memory_flush_success_count: 1,
        episodes_flushed: 2,
      },
      linked_artifacts: {
        receipts: [
          {
            kind: 'execution_receipt',
            path: '/tmp/receipt.jsonl',
            present: true,
            file_stat: { size: 120 },
          },
        ],
        checkpoints: [
          {
            kind: 'agent_core_checkpoint',
            path: '/tmp/checkpoint.json',
            present: false,
            file_stat: null,
          },
        ],
        tool_call_logs: [],
      },
      manifest_rows: [{ event: 'Turn_started', trace_id: 'trace-1' }],
      receipts: [{ terminal_reason_code: 'completed' }],
      health: 'ok',
      stale_reason: null,
    })

    expect(result.keeper).toBe('sangsu')
	    expect(result.turn_identity.provider_lane_resolved_count).toBe(0)
	    expect(result.turn_identity.runtime_completed_count).toBe(1)
	    expect(result.turn_identity.runtime_failed_count).toBe(0)
	    expect(result.event_bus.correlation_ids).toEqual(['corr-1'])
    expect(result.memory.memory_flushed_count).toBe(0)
    expect(result.memory.episodes_flushed).toBe(2)
    expect(result.manifest_scan_diagnostics.state).toBe('available')
    if (result.manifest_scan_diagnostics.state !== 'available') {
      throw new Error(result.manifest_scan_diagnostics.error)
    }
    expect(result.manifest_scan_diagnostics.unsupported_event_counts).toEqual([
      { event: 'future_event', count: 1 },
    ])
    expect(result.manifest_scan_diagnostics.samples[0]?.detail).toBeNull()
    expect(result.linked_artifacts.receipts[0]?.path).toBe('/tmp/receipt.jsonl')
    expect(result.linked_artifacts.checkpoints[0]?.present).toBe(false)
    expect(result.manifest_rows[0]?.event).toBe('Turn_started')
    expect(result.receipts[0]?.terminal_reason_code).toBe('completed')
    expect(result.health).toBe('ok')
  })

  it('does not report clean diagnostics when an older runtime omits them', () => {
    const result = parseKeeperRuntimeTrace({ keeper: 'sangsu', trace_id: 'trace-old' })

    expect(result.manifest_scan_diagnostics).toEqual({
      state: 'unavailable',
      schema: null,
      error: 'runtime did not report manifest scan diagnostics',
    })
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
      event_bus: {},
      memory: {},
      runtime_lens: {
        axes: {
          provider_lane: {
            resolved: false,
            status: 'error',
            resolved_lane: 'inline',
          },
        },
        swimlanes: {
          provider: {
            lane: 'provider',
            label: 'Provider',
            event_count: 2,
            terminal_status: 'timeout',
            completeness: 'complete',
            gap_codes: [],
            events: [{ event: 'runtime_completed', count: 1 }],
          },
          tool_runtime: {
            lane: 'tool_runtime',
            label: 'Tool Runtime',
            event_count: 0,
            terminal_status: 'not_observed',
            completeness: 'complete',
            gap_codes: [],
          },
        },
        clock_edges: [
          {
            edge_id: 'edge-runtime-routed',
            lane: 'masc_policy_runtime',
            event: 'runtime_routed',
            status: 'attempt',
            observed_at: '2026-05-13T00:00:03Z',
            source_clock: 'wall',
            started_at: '2026-05-13T00:00:03Z',
            trace_id: 'trace-lens',
            keeper_turn_id: 9,
            event_bus_correlation_id: 'corr-1',
            event_bus_event_count: 2,
            event_bus_payload_kinds: ['tool_called', 'tool_completed'],
            links: {
              tool_call_log_path: '/tmp/tool-calls.jsonl',
            },
          },
        ],
        clock_groups: [
          {
            group_type: 'turn',
            group_id: 'trace-lens:keeper-9',
            edge_count: 2,
            edge_ids: ['edge-runtime-routed', 'edge-runtime-completed'],
            lanes: ['masc_policy_runtime'],
            events: ['runtime_routed', 'runtime_completed'],
            statuses: ['attempt', 'completed'],
            first_observed_at: '2026-05-13T00:00:03Z',
            last_observed_at: '2026-05-13T00:00:08Z',
            closed: true,
            terminal_events: ['runtime_completed'],
            parent_event_ids: [],
            caused_by: [],
            event_bus_event_count: 0,
            event_bus_payload_kinds: [],
          },
        ],
        gaps: [
          {
            code: 'clock_context_injection_missing',
            severity: 'warn',
            lane: 'memory_context',
            detail: 'turn finished without a context_injected clock edge',
          },
        ],
      },
      health: 'partial',
    })

    expect(result.runtime_lens.turn_clock.trace_id).toBe('trace-lens')
    expect(result.runtime_lens.turn_clock.terminal_event_present).toBe(false)
    expect(result.runtime_lens.axes.provider_lane.resolved).toBe(false)
    expect(result.runtime_lens.swimlanes.memory_context.terminal_status).toBe('unknown')
    expect(result.runtime_lens.clock_edges[0]?.edge_id).toBe('edge-runtime-routed')
    expect(result.runtime_lens.swimlanes.tool_runtime.completeness).toBe('complete')
    expect(result.runtime_lens.clock_edges[0]?.event).toBe('runtime_routed')
    expect(result.runtime_lens.clock_edges[0]?.event_bus_event_count).toBe(2)
    expect(result.runtime_lens.clock_edges[0]?.event_bus_payload_kinds).toEqual(['tool_called', 'tool_completed'])
    expect(result.runtime_lens.clock_edges[0]?.links.tool_call_log_path).toBe('/tmp/tool-calls.jsonl')
    expect(result.runtime_lens.clock_groups[0]?.group_type).toBe('turn')
    expect(result.runtime_lens.clock_groups[0]?.closed).toBe(true)
    expect(result.runtime_lens.clock_groups[0]?.terminal_events).toEqual(['runtime_completed'])
    expect(result.runtime_lens.gaps.map(gap => gap.code)).toEqual([
      'clock_context_injection_missing',
    ])
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
          max_agent_core_turn_count: 4,
          provider_lane_resolved_count: 1,
          runtime_completed_count: 1,
          runtime_failed_count: 0,
          event_bus_correlated_count: 1,
          memory_injected_count: 1,
          memory_flushed_count: 1,
          receipt_appended_count: 1,
          turn_finished_count: 1,
	        },
	        event_bus: {
          event_bus_correlated_count: 1,
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
	    expect(result.turn_identity.max_agent_core_turn_count).toBe(4)
	    expect(result.turn_identity.runtime_completed_count).toBe(1)
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
        current_status: 'missing',
        current_error: null,
        history: [],
        history_errors: [],
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
    expect(result.current_status).toBe('missing')
    expect(result.history).toEqual([])
    expect(result.history_errors).toEqual([])
  })

  it('posts selected Agent Core history snapshot ids for deletion', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        ok: true,
        action: 'delete_history',
        keeper: 'keeper-test',
        deleted_snapshot_ids: ['agent-core-snapshot-1.json'],
        missing_snapshot_ids: [],
        inventory: {
          keeper: 'keeper-test',
          trace_id: 'trace-keeper-test',
          session_dir: '/tmp/trace-keeper-test',
          current: null,
          current_status: 'missing',
          current_error: null,
          history: [],
          history_errors: [],
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await deleteKeeperHistorySnapshots('keeper-test', ['agent-core-snapshot-1.json'])

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]! as [string, RequestInit]
    expect(url).toBe('/api/v1/keepers/keeper-test/checkpoints')
    expect(JSON.parse(String(init.body))).toEqual({
      action: 'delete_history',
      snapshot_ids: ['agent-core-snapshot-1.json'],
    })
    expect(result.deleted_snapshot_ids).toEqual(['agent-core-snapshot-1.json'])
  })

  it('previews and applies current checkpoint purge through the same admin route', async () => {
    const responseFor = (action: 'preview_purge' | 'apply_purge') => ({
      schema: 'masc.keeper_checkpoint_purge.v1',
      ok: true,
      action,
      keeper: 'keeper-test',
      trace_id: 'trace-keeper-test',
      apply_allowed: true,
      applied: action === 'apply_purge',
      backup_path: action === 'apply_purge' ? '/tmp/backup.json' : null,
      report: {
        messages_before: 10,
        messages_after: 8,
        bytes_before: 2048,
        bytes_after: 1024,
        bytes_removed: 1024,
        duplicates_dropped: 2,
        reasoning_blocks_stripped: 1,
        reasoning_messages_dropped: 0,
        tool_results_cleared: 3,
      },
      warnings: [],
      inventory: {
        keeper: 'keeper-test',
        trace_id: 'trace-keeper-test',
        session_dir: '/tmp/trace-keeper-test',
        current: null,
        current_status: 'missing',
        current_error: null,
        history: [],
        history_errors: [],
      },
    })
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(responseFor('preview_purge')), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify(responseFor('apply_purge')), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)

    const preview = await previewKeeperCheckpointPurgeFromLifecycle('keeper-test')
    const applied = await applyKeeperCheckpointPurgeFromLifecycle('keeper-test')

    expect(preview.applied).toBe(false)
    expect(applied.applied).toBe(true)
    expect(applied.backup_path).toBe('/tmp/backup.json')
    expect(fetchMock).toHaveBeenCalledTimes(2)
    for (const [index, action] of ['preview_purge', 'apply_purge'].entries()) {
      const [url, init] = fetchMock.mock.calls[index]! as [string, RequestInit]
      expect(url).toBe('/api/v1/keepers/keeper-test/checkpoints')
      expect(init.method).toBe('POST')
      expect(JSON.parse(String(init.body))).toEqual({ action })
    }
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

    const result = await resumeKeeper('janitor', {
      operatorOperationId: 'dashboard-resume-test-1',
    })

    expect(result.ok).toBe(true)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe('/api/v1/keepers/janitor/directive')
    expect(JSON.parse(init.body)).toEqual({
      action: 'resume',
      operator_operation_id: 'dashboard-resume-test-1',
    })
  })

  it('boots after a durable resume commit cannot project the offline lane', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(
        new Response(JSON.stringify({
          ok: false,
          action: 'resume',
          name: 'offline-janitor',
          committed: true,
          projection: 'committed_followup_failed',
        }), {
          status: 202,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, action: 'boot', name: 'offline-janitor' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
    vi.stubGlobal('fetch', fetchMock)

    const result = await resumeKeeper('offline-janitor', {
      operatorOperationId: 'dashboard-resume-offline-1',
    })

    expect(result).toMatchObject({ ok: true, action: 'boot', committed: true })
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(fetchMock.mock.calls[0]![0]).toBe('/api/v1/keepers/offline-janitor/directive')
    expect(fetchMock.mock.calls[1]![0]).toBe('/api/v1/keepers/offline-janitor/boot')
  })

  it('reuses the same resume operation ID after an ambiguous failed response', async () => {
    vi.stubGlobal('crypto', { randomUUID: vi.fn(() => 'stable-resume-uuid') })
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new Error('connection reset'))
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, action: 'resume', name: 'janitor' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
    vi.stubGlobal('fetch', fetchMock)

    expect((await resumeKeeper('janitor')).ok).toBe(false)
    expect((await resumeKeeper('janitor')).ok).toBe(true)

    const firstInit = fetchMock.mock.calls[0]![1] as RequestInit
    const secondInit = fetchMock.mock.calls[1]![1] as RequestInit
    const first = JSON.parse(String(firstInit.body))
    const second = JSON.parse(String(secondInit.body))
    expect(first.operator_operation_id).toBe('dashboard-resume-stable-resume-uuid')
    expect(second.operator_operation_id).toBe(first.operator_operation_id)
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

describe('purgeKeeper', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('posts the keeper name to the dashboard purge route and returns the accepted operation', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          accepted: true,
          target_kind: 'keeper',
          agent_name: 'keeper-canary-10t-agy3-agent',
          keeper_name: 'canary-10t-agy3',
          operation_id: 'op-1',
        }),
        { status: 202, headers: { 'Content-Type': 'application/json' } },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await purgeKeeperFromLifecycle('canary-10t-agy3')

    expect(result.accepted).toBe(true)
    expect(result.keeper_name).toBe('canary-10t-agy3')
    expect(result.operation_id).toBe('op-1')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]! as [string, RequestInit]
    expect(url).toBe('/api/v1/dashboard/agents/purge')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({ agent_name: 'canary-10t-agy3' })
  })

  it('surfaces the server error text instead of a bare status code', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: 'keeper metadata unreadable' }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(purgeKeeperFromLifecycle('canary-10t-agy3')).rejects.toThrow(
      'keeper metadata unreadable',
    )
  })

  it('falls back to a named error when the server body carries no error text', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('', { status: 500 }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(purgeKeeperFromLifecycle('canary-10t-agy3')).rejects.toThrow(
      'canary-10t-agy3 제거 실패 (HTTP 500)',
    )
  })
})
