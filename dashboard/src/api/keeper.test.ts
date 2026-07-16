import { afterEach, describe, expect, it, vi } from 'vitest'
import type * as CoreApi from './core'

const { runOperatorAction, currentDashboardActor } = vi.hoisted(() => ({
  runOperatorAction: vi.fn(),
  currentDashboardActor: vi.fn(() => 'dashboard'),
}))

vi.mock('./core', async (importOriginal) => {
  const actual = await importOriginal<typeof CoreApi>()
  return {
    ...actual,
    currentDashboardActor,
    runOperatorAction,
  }
})

import {
  bootKeeper,
  bulkKeeperDirective,
  cancelQueuedKeeperMessage,
  clearKeeper,
  deleteKeeperHistorySnapshots,
  fetchKeeperChatHistory,
  fetchKeeperChatReceipt,
  fetchKeeperCheckpoints,
  fetchQueuedKeeperMessageResult,
  fetchKeeperRuntimeTrace,
  isTerminalQueuedKeeperMessage,
  pauseKeeper,
  parseKeeperRuntimeTrace,
  parseKeeperChatReceipt,
  resolveKeeperChatRecovery,
  queuedKeeperMessageError,
  queuedKeeperMessageToReply,
  resumeKeeper,
  resetKeeper,
  sendKeeperMessageDetailed,
  shutdownKeeper,
  streamKeeperMessage,
  submitQueuedKeeperMessage,
  wakeKeeper,
} from './keeper'
import {
  bootKeeper as bootKeeperFromLifecycle,
  bulkKeeperDirective as bulkKeeperDirectiveFromLifecycle,
  clearKeeper as clearKeeperFromLifecycle,
  deleteKeeperHistorySnapshots as deleteKeeperHistorySnapshotsFromLifecycle,
  fetchKeeperCheckpoints as fetchKeeperCheckpointsFromLifecycle,
  pauseKeeper as pauseKeeperFromLifecycle,
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
import { keeperRunRefToWire, parseKeeperRunRef } from '../lib/keeper-run-ref'

function keeperRunRef(runId: string) {
  return parseKeeperRunRef({
    run_id: runId,
    target: { kind: 'keeper', name: 'sangsu' },
    capability: 'invoke_turn',
  })
}

function keeperRunWire(runId: string) {
  return keeperRunRefToWire(keeperRunRef(runId))
}

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

describe('Keeper chat durable receipt API', () => {
  it('parses exact non-dispatchable recovery evidence', () => {
    expect(parseKeeperChatReceipt({
      schema: 'keeper_chat_queue.receipt.v2',
      keeper_name: 'echo',
      receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '8',
      state: {
        kind: 'recovery_required',
        lease_id: 'lease_00000000-0000-4000-8000-000000000002',
        started_at: 42,
        dispatchable: false,
      },
    })).toEqual({
      keeperName: 'echo',
      receiptId: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '8',
      state: {
        kind: 'recovery_required',
        leaseId: 'lease_00000000-0000-4000-8000-000000000002',
        startedAt: 42,
        dispatchable: false,
      },
    })
  })

  it('rejects recovery evidence that claims automatic dispatchability', () => {
    expect(() => parseKeeperChatReceipt({
      schema: 'keeper_chat_queue.receipt.v2',
      keeper_name: 'echo',
      receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '8',
      state: {
        kind: 'recovery_required',
        lease_id: 'lease_00000000-0000-4000-8000-000000000002',
        started_at: 42,
        dispatchable: true,
      },
    })).toThrow('invalid recovery evidence')
  })

  it('parses the closed terminal failure state', () => {
    expect(parseKeeperChatReceipt({
      schema: 'keeper_chat_queue.receipt.v2',
      keeper_name: 'echo',
      receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '7',
      state: {
        kind: 'failed',
        failure_kind: 'delivery_failed',
        detail: 'Slack API rejected the message',
        completed_at: 42,
        outcome_ref: null,
      },
    })).toEqual({
      keeperName: 'echo',
      receiptId: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '7',
      state: {
        kind: 'failed',
        failureKind: 'delivery_failed',
        detail: 'Slack API rejected the message',
        completedAt: 42,
        outcomeRef: null,
      },
    })
  })

  it.each(['recovery_interrupted'] as const)(
    'parses the canonical %s terminal failure kind',
    (failureKind) => {
      expect(parseKeeperChatReceipt({
        schema: 'keeper_chat_queue.receipt.v2',
        keeper_name: 'echo',
        receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
        revision: '7',
        state: {
          kind: 'failed',
          failure_kind: failureKind,
          detail: 'startup recovery could not prove terminal connector delivery',
          completed_at: 42,
          outcome_ref: null,
        },
      }).state).toMatchObject({ kind: 'failed', failureKind })
    },
  )

  it('rejects an unknown receipt lifecycle instead of guessing', () => {
    expect(() => parseKeeperChatReceipt({
      schema: 'keeper_chat_queue.receipt.v2',
      keeper_name: 'echo',
      receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '1',
      state: { kind: 'lost_somewhere' },
    })).toThrow('unknown state')
  })

  it('rejects a non-canonical receipt identity', () => {
    expect(() => parseKeeperChatReceipt({
      schema: 'keeper_chat_queue.receipt.v2',
      keeper_name: 'echo',
      receipt_id: 'receipt-echo-1',
      revision: '1',
      state: { kind: 'pending' },
    })).toThrow('missing identity')
  })

  it('rejects malformed nullable outcome refs instead of coercing schema drift', () => {
    expect(() => parseKeeperChatReceipt({
      schema: 'keeper_chat_queue.receipt.v2',
      keeper_name: 'echo',
      receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '2',
      state: { kind: 'delivered', completed_at: 42, outcome_ref: 7 },
    })).toThrow('outcome_ref must be a string or null')
  })

  it('rejects whitespace-only failure detail', () => {
    expect(() => parseKeeperChatReceipt({
      schema: 'keeper_chat_queue.receipt.v2',
      keeper_name: 'echo',
      receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
      revision: '2',
      state: {
        kind: 'failed',
        failure_kind: 'delivery_failed',
        detail: '   ',
        completed_at: 42,
        outcome_ref: null,
      },
    })).toThrow('invalid failure metadata')
  })

  it('fetches the exact encoded Keeper receipt route', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        schema: 'keeper_chat_queue.receipt.v2',
        keeper_name: 'keeper sangsu',
        receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
        revision: '2',
        state: { kind: 'pending' },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchKeeperChatReceipt(
      'keeper sangsu',
      'chatq_00000000-0000-4000-8000-000000000001',
    )

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/keepers/keeper%20sangsu/chat/receipts/chatq_00000000-0000-4000-8000-000000000001',
      expect.objectContaining({ headers: expect.any(Object) }),
    )
  })

  it('resolves one exact recovery receipt with string revision and lease evidence', async () => {
    const receiptId = 'chatq_00000000-0000-4000-8000-000000000001'
    const leaseId = 'lease_00000000-0000-4000-8000-000000000002'
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        schema: 'keeper_chat_queue.recovery.result.v1',
        ok: true,
        decision: 'requeue_unconfirmed',
        receipt: {
          schema: 'keeper_chat_queue.receipt.v2',
          keeper_name: 'keeper sangsu',
          receipt_id: receiptId,
          revision: '9223372036854775806',
          state: { kind: 'pending' },
        },
        audit: { recorded: true },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await resolveKeeperChatRecovery(
      'keeper sangsu',
      receiptId,
      '9223372036854775805',
      leaseId,
      { kind: 'requeue_unconfirmed' },
    )

    expect(result.receipt.revision).toBe('9223372036854775806')
    expect(fetchMock).toHaveBeenCalledWith(
      `/api/v1/keepers/keeper%20sangsu/chat/receipts/${receiptId}/recovery`,
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          schema: 'keeper_chat_queue.recovery.request.v1',
          expected_revision: '9223372036854775805',
          lease_id: leaseId,
          decision: { kind: 'requeue_unconfirmed' },
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

describe('submitQueuedKeeperMessage', () => {
  it('submits direct keeper input through the async queue', async () => {
    runOperatorAction.mockResolvedValueOnce({
      result: {
        tool_name: 'masc_keeper_msg',
        result: {
          run_ref: keeperRunWire('kmsg_sangsu_1'),
          result_contract: 'awaiting_execution',
        },
      },
    })

    const submitted = await submitQueuedKeeperMessage('sangsu', 'ping')

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
    expect(submitted).toEqual({
      runRef: keeperRunRef('kmsg_sangsu_1'),
      resultContract: 'awaiting_execution',
      message: undefined,
      reason: undefined,
    })
  })
})

describe('fetchQueuedKeeperMessageResult', () => {
  it('polls the keeper chat request HTTP wrapper instead of MCP session state', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        run_ref: keeperRunWire('kmsg_sangsu_1'),
        result_contract: 'completed',
        result: { reply: 'pong' },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchQueuedKeeperMessageResult(keeperRunRef('kmsg_sangsu_1'))

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/gate/message/status')
    expect(init.method).toBe('POST')
    expect(init.headers).toMatchObject({ 'Content-Type': 'application/json' })
    expect(JSON.parse(String(init.body))).toEqual({
      run_ref: keeperRunWire('kmsg_sangsu_1'),
    })
    expect(result.resultContract).toBe('completed')
    expect(result.result).toEqual({ reply: 'pong' })
  })

  it('normalizes cancelled queued results as cancellation text', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        run_ref: keeperRunWire('kmsg_sangsu_2'),
        result_contract: 'cancelled',
        result: {
          cancelled: true,
          reason: 'keeper_msg request was cancelled by operator',
          cancelled_by: 'operator',
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchQueuedKeeperMessageResult(keeperRunRef('kmsg_sangsu_2'))

    expect(result.resultContract).toBe('cancelled')
    expect(queuedKeeperMessageError(result)).toBe('요청이 취소되었습니다.')
    expect(queuedKeeperMessageToReply(result).text).toBe('요청이 취소되었습니다.')
  })

  it('keeps cancelling as a typed non-terminal lifecycle state', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        run_ref: keeperRunWire('kmsg_sangsu_cancelling'),
        result_contract: 'cancellation_requested',
        result: {
          cancellation_requested: true,
          cancelled_by: 'operator',
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const result = await fetchQueuedKeeperMessageResult(
      keeperRunRef('kmsg_sangsu_cancelling'),
    )

    expect(result.resultContract).toBe('cancellation_requested')
    expect(isTerminalQueuedKeeperMessage(result)).toBe(false)
  })

  it('rejects the removed raw request response instead of adapting it', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        request_id: 'kmsg_sangsu_future',
        status: 'done',
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(fetchQueuedKeeperMessageResult(keeperRunRef('kmsg_sangsu_future')))
      .rejects.toThrow('run_ref must be an object')
  })

  it('preserves typed persistence failure detail as a terminal result', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        run_ref: keeperRunWire('kmsg_sangsu_persist_failure'),
        result_contract: 'failed',
        result: {
          error: 'request_persistence_failed',
          attempted_status: 'cancelled',
          reason: 'terminal callback failed',
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const result = await fetchQueuedKeeperMessageResult(
      keeperRunRef('kmsg_sangsu_persist_failure'),
    )

    expect(result.resultContract).toBe('failed')
    expect(isTerminalQueuedKeeperMessage(result)).toBe(true)
    expect(result.result).toEqual(expect.objectContaining({
      attempted_status: 'cancelled',
      reason: 'terminal callback failed',
    }))
  })

  it('suppresses queued continuation checkpoints as non-visible replies', () => {
    const result = {
      runRef: keeperRunRef('kmsg_sangsu_3'),
      resultContract: 'yielded' as const,
      result: {
        reply: 'Continuation checkpoint saved; keeper remains scheduled for the next cycle.',
        turn_outcome: 'continuation_checkpoint',
      },
    }

    const reply = queuedKeeperMessageToReply(result)

    expect(reply.text).toBe('')
    expect(reply.details?.turnOutcome).toBe('continuation_checkpoint')
    expect(reply.details?.replyText).toBe(
      'Continuation checkpoint saved; keeper remains scheduled for the next cycle.',
    )
  })

  it('suppresses queued no-visible replies as non-visible replies', () => {
    const result = {
      runRef: keeperRunRef('kmsg_sangsu_4'),
      resultContract: 'completed' as const,
      result: {
        reply: '',
        turn_outcome: 'no_visible_reply',
      },
    }

    const reply = queuedKeeperMessageToReply(result)

    expect(reply.text).toBe('')
    expect(reply.details?.turnOutcome).toBe('no_visible_reply')
    expect(reply.details?.replyText).toBeNull()
  })
})

describe('cancelQueuedKeeperMessage', () => {
  it('accepts a durable cancelling acknowledgement without claiming terminal cancellation', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        run_ref: keeperRunWire('kmsg_sangsu_cancel'),
        result_contract: 'cancellation_requested',
        durability: 'durable',
      }), {
        status: 202,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await cancelQueuedKeeperMessage(keeperRunRef('kmsg_sangsu_cancel'))

    expect(result).toEqual({
      runRef: keeperRunRef('kmsg_sangsu_cancel'),
      resultContract: 'cancellation_requested',
      durability: 'durable',
      warning: undefined,
    })
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/gate/message/cancel')
    expect(JSON.parse(String(init.body))).toEqual({
      run_ref: keeperRunWire('kmsg_sangsu_cancel'),
    })
    expect(init.signal).toBeUndefined()
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

  it('forwards copilot context fields to the stream endpoint', async () => {
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

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toEqual({
      name: 'sangsu',
      message: 'ping',
      direct_reply: true,
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
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('data: {"type":"RUN_FINISHED"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await streamKeeperMessage('sangsu', 'describe this', {
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

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toMatchObject({
      name: 'sangsu',
      message: 'describe this',
      direct_reply: true,
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
      JSON.stringify({ source: 'dev', actor: 'dashboard', scope: 'worker' }),
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
          JSON.stringify({ token: 'fresh-token', actor: 'dashboard', scope: 'worker' }),
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

    await streamKeeperMessage('sangsu', 'ping', { onEvent: () => {} })

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
      streamKeeperMessage('sangsu', 'ping', { onEvent: () => {} }),
    ).rejects.toThrow()

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
      streamKeeperMessage('sangsu', 'ping', { onEvent: () => {} }),
    ).rejects.toThrow()

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      '/api/v1/keepers/chat/stream',
    ])
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
        retired_event_count: 2,
        retired_event_counts: [
          { event: 'state_snapshot_sidecar_saved', count: 1 },
          { event: 'working_state_sidecar_saved', count: 1 },
        ],
        unsupported_event_count: 1,
        unsupported_event_counts: [{ event: 'future_event', count: 1 }],
        unsupported_event_unattributed_count: 0,
        invalid_manifest_row_count: 1,
        invalid_json_row_count: 1,
        samples: [
          { kind: 'retired_event', event: 'state_snapshot_sidecar_saved' },
          { kind: 'unsupported_event', event: 'future_event' },
        ],
      },
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
	            runtime_id: 'glm-coding-with-spark',
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
            kind: 'oas_checkpoint',
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
	    expect(result.turn_identity.provider_attempt_started_count).toBe(1)
	    expect(result.provider_attempts.terminal_status).toBe('timeout')
	    expect(result.provider_attempts.attempts[0]?.exception_kind).toBe('outer_oas_timeout')
	    expect(result.event_bus.correlation_ids).toEqual(['corr-1'])
    expect(result.memory.memory_flushed_count).toBe(0)
    expect(result.memory.episodes_flushed).toBe(2)
    expect(result.manifest_scan_diagnostics.state).toBe('available')
    if (result.manifest_scan_diagnostics.state !== 'available') {
      throw new Error(result.manifest_scan_diagnostics.error)
    }
    expect(result.manifest_scan_diagnostics.retired_event_count).toBe(2)
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
      provider_attempts: {},
      event_bus: {},
      memory: {},
      runtime_lens: {
        axes: {
          provider_lane: {
            resolved: false,
            status: 'error',
            resolved_lane: 'inline',
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
            completeness: 'complete',
            gap_codes: [],
            events: [{ event: 'provider_attempt_finished', count: 1 }],
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
            edge_id: 'edge-provider-start',
            lane: 'provider',
            event: 'provider_attempt_started',
            status: 'started',
            observed_at: '2026-05-13T00:00:03Z',
            source_clock: 'wall',
            started_at: '2026-05-13T00:00:03Z',
            trace_id: 'trace-lens',
            keeper_turn_id: 9,
            provider_attempt_id: 'trace-lens:keeper-9:provider-attempt-1',
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
            group_type: 'provider_attempt',
            group_id: 'trace-lens:keeper-9:provider-attempt-1',
            edge_count: 2,
            edge_ids: ['edge-provider-start', 'edge-provider-finish'],
            lanes: ['provider'],
            events: ['provider_attempt_started', 'provider_attempt_finished'],
            statuses: ['started', 'provider_returned'],
            first_observed_at: '2026-05-13T00:00:03Z',
            last_observed_at: '2026-05-13T00:00:08Z',
            closed: true,
            terminal_events: ['provider_attempt_finished'],
            parent_event_ids: [],
            caused_by: [],
            event_bus_event_count: 0,
            event_bus_payload_kinds: [],
          },
        ],
        gaps: [
          {
            code: 'clock_provider_attempt_unfinished',
            severity: 'warn',
            lane: 'provider',
            detail: 'provider attempts started=1 finished=0',
          },
        ],
      },
      health: 'partial',
    })

    expect(result.runtime_lens.turn_clock.trace_id).toBe('trace-lens')
    expect(result.runtime_lens.turn_clock.terminal_event_present).toBe(false)
    expect(result.runtime_lens.axes.provider_lane.resolved).toBe(false)
    expect(result.runtime_lens.axes.provider_attempt.terminal_status).toBe('timeout')
    expect(result.runtime_lens.swimlanes.provider.terminal_status).toBe('timeout')
    expect(result.runtime_lens.swimlanes.memory_context.terminal_status).toBe('unknown')
    expect(result.runtime_lens.clock_edges[0]?.edge_id).toBe('edge-provider-start')
    expect(result.runtime_lens.swimlanes.tool_runtime.completeness).toBe('complete')
    expect(result.runtime_lens.clock_edges[0]?.provider_attempt_id).toBe('trace-lens:keeper-9:provider-attempt-1')
    expect(result.runtime_lens.clock_edges[0]?.event_bus_event_count).toBe(2)
    expect(result.runtime_lens.clock_edges[0]?.event_bus_payload_kinds).toEqual(['tool_called', 'tool_completed'])
    expect(result.runtime_lens.clock_edges[0]?.links.tool_call_log_path).toBe('/tmp/tool-calls.jsonl')
    expect(result.runtime_lens.clock_groups[0]?.group_type).toBe('provider_attempt')
    expect(result.runtime_lens.clock_groups[0]?.closed).toBe(true)
    expect(result.runtime_lens.clock_groups[0]?.terminal_events).toEqual(['provider_attempt_finished'])
    expect(result.runtime_lens.gaps.map(gap => gap.code)).toEqual([
      'clock_provider_attempt_unfinished',
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
