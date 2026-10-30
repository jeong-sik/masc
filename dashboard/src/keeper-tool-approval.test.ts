import { afterEach, describe, expect, it, vi } from 'vitest'
import { keeperToolApprovals, upsertKeeperToolApproval } from './keeper-state'
import { answerHeldKeeperToolApproval, hydrateKeeperToolApprovals } from './keeper-actions'

// task-343: the answer path for a held tool call. Before this surface the
// dashboard decoded KEEPER_TOOL_APPROVAL_REQUESTED and drew nothing; the
// operator's decision never reached the server, and the wait retired itself
// after 180s as a denial nobody chose. These tests fix that the POST goes to
// the wait that owns the call and that the row it leaves behind is honest
// about what happened.

function pendingRow(toolCallId: string): void {
  upsertKeeperToolApproval('sangsu', {
    toolCallId,
    toolName: 'Execute',
    args: '{"argv":["ls"]}',
    question: 'Execute ls 를 실행할까요?',
    because: 'process execution requires approval',
    askedAtMs: Date.now(),
    timeoutSec: 180,
    answering: false,
    answeredDecision: null,
    answeredOutcome: null,
    settled: false,
  })
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

afterEach(() => {
  vi.unstubAllGlobals()
  keeperToolApprovals.value = {}
})

describe('answerHeldKeeperToolApproval', () => {
  it('POSTs the decision to the wait that owns the call and retires the row', async () => {
    pendingRow('call-1')
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse(200, { settled: true, decision: 'approve' }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const settled = await answerHeldKeeperToolApproval('sangsu', 'call-1', 'approve')

    expect(settled).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/keepers/tool-approval')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({
      name: 'sangsu',
      tool_call_id: 'call-1',
      decision: 'approve',
    })
    // The row retires so the card cannot be answered twice.
    expect(keeperToolApprovals.value.sangsu?.['call-1']?.settled).toBe(true)
  })

  it('retires the row on a late answer (settled: false) instead of promising a dead wait', async () => {
    pendingRow('call-late')
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(jsonResponse(200, { settled: false, decision: 'deny' })),
    )

    const settled = await answerHeldKeeperToolApproval('sangsu', 'call-late', 'deny')

    // settled=false is not a thrown error: the call is gone either way.
    expect(settled).toBe(false)
    expect(keeperToolApprovals.value.sangsu?.['call-late']?.settled).toBe(true)
  })

  it('re-arms the card when the POST fails so the operator can retry', async () => {
    pendingRow('call-fail')
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(jsonResponse(500, { error: 'boom' })),
    )

    await expect(answerHeldKeeperToolApproval('sangsu', 'call-fail', 'approve')).resolves.toBe(false)

    const row = keeperToolApprovals.value.sangsu?.['call-fail']
    expect(row?.settled).toBe(false)
    expect(row?.answering).toBe(false)
    expect(row?.answeredDecision).toBeNull()
  })

  it('ignores a second answer for a call already being answered', async () => {
    pendingRow('call-double')
    let releaseFetch: (() => void) | undefined
    const gate = new Promise<void>(resolve => {
      releaseFetch = resolve
    })
    const fetchMock = vi.fn().mockImplementation(async () => {
      await gate
      return jsonResponse(200, { settled: true, decision: 'approve' })
    })
    vi.stubGlobal('fetch', fetchMock)

    const first = answerHeldKeeperToolApproval('sangsu', 'call-double', 'approve')
    // Second click while the first POST is in flight: no duplicate answer.
    await expect(answerHeldKeeperToolApproval('sangsu', 'call-double', 'deny')).resolves.toBe(false)
    releaseFetch?.()
    await expect(first).resolves.toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe('hydrateKeeperToolApprovals', () => {
  it('fills gaps from the public listing without overwriting rows the stream already drew', async () => {
    pendingRow('call-known')
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse(200, {
        pending: [
          {
            keeper: 'sangsu',
            tool_call_id: 'call-known',
            tool: 'StaleOverwrite',
            args: '{}',
            question: 'stale?',
            because: 'stale reason',
            asked_at: 1,
            timeout_sec: 180,
          },
          {
            keeper: 'sangsu',
            tool_call_id: 'call-hydrated',
            tool: 'Execute',
            args: '{}',
            question: '보고서를 날릴까요?',
            because: 'external side effect',
            asked_at: 1787636000,
            timeout_sec: 180,
          },
        ],
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await hydrateKeeperToolApprovals()

    // Known row untouched (hydrated askedAt would clobber stream askedAt).
    expect(keeperToolApprovals.value.sangsu?.['call-known']?.toolName).toBe('Execute')
    // Gap filled: a wait this view never saw still gets a card.
    const hydrated = keeperToolApprovals.value.sangsu?.['call-hydrated']
    expect(hydrated?.toolName).toBe('Execute')
    expect(hydrated?.question).toBe('보고서를 날릴까요?')
    expect(hydrated?.because).toBe('external side effect')
    expect(hydrated?.askedAtMs).toBe(1787636000 * 1000)
  })

  it('stays silent when the listing fails — hydration is best-effort', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(503, { error: 'unavailable' })))
    await expect(hydrateKeeperToolApprovals()).resolves.toBeUndefined()
    expect(keeperToolApprovals.value.sangsu).toBeUndefined()
  })
})
