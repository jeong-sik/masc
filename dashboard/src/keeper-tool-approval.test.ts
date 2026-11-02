import { afterEach, describe, expect, it, vi } from 'vitest'
import { keeperToolApprovals, keeperActionErrors, upsertKeeperToolApproval, dropKeeperToolApproval } from './keeper-state'
import { answerHeldKeeperToolApproval, hydrateKeeperToolApprovals } from './keeper-actions'
import { answerKeeperToolApproval, fetchKeeperToolApprovals } from './api/keeper'

// task-343: the answer path for a held tool call. Before this surface the
// dashboard decoded KEEPER_TOOL_APPROVAL_REQUESTED and drew nothing; the
// operator's decision never reached the server, and the wait retired itself
// after 180s as a denial nobody chose. These tests fix that the POST goes to
// the wait that owns the call and that the row it leaves behind is honest
// about what happened.

function pendingRow(toolCallId: string, approvalId = `approval-${toolCallId}`, keeperName = 'sangsu'): void {
  upsertKeeperToolApproval(keeperName, {
    approvalId,
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
  keeperActionErrors.value = {}
})

describe('answerHeldKeeperToolApproval', () => {
  it('POSTs the decision to the wait that owns the call and retires the row', async () => {
    pendingRow('call-1')
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse(200, { settled: true, remembered: false, decision: 'approve' }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const settled = await answerHeldKeeperToolApproval('sangsu', 'call-1', 'approval-call-1', 'approve')

    expect(settled).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/keepers/tool-approval')
    expect(init.method).toBe('POST')
    expect(JSON.parse(String(init.body))).toEqual({
      name: 'sangsu',
      tool_call_id: 'call-1',
      approval_id: 'approval-call-1',
      decision: 'approve',
    })
    // The row retires so the card cannot be answered twice.
    expect(keeperToolApprovals.value.sangsu?.['call-1']?.settled).toBe(true)
  })

  it('retires only the exact ask when the server remembers a late answer', async () => {
    pendingRow('call-late')
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(jsonResponse(200, { settled: false, remembered: true, decision: 'deny' })),
    )

    const settled = await answerHeldKeeperToolApproval('sangsu', 'call-late', 'approval-call-late', 'deny')

    expect(settled).toBe(true)
    expect(keeperToolApprovals.value.sangsu?.['call-late']?.settled).toBe(true)
  })

  it('re-arms the card when the POST fails so the operator can retry', async () => {
    pendingRow('call-fail')
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(jsonResponse(500, { error: 'boom' })),
    )

    await expect(answerHeldKeeperToolApproval('sangsu', 'call-fail', 'approval-call-fail', 'approve')).resolves.toBe(false)

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
      return jsonResponse(200, { settled: true, remembered: false, decision: 'approve' })
    })
    vi.stubGlobal('fetch', fetchMock)

    const first = answerHeldKeeperToolApproval('sangsu', 'call-double', 'approval-call-double', 'approve')
    // Second click while the first POST is in flight: no duplicate answer.
    await expect(answerHeldKeeperToolApproval('sangsu', 'call-double', 'approval-call-double', 'deny')).resolves.toBe(false)
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
            approval_id: 'approval-call-known',
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
            approval_id: 'approval-call-hydrated',
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

describe('approval instance ownership', () => {
  it('keeps the ask pending when neither settlement nor late recording was accepted', async () => {
    pendingRow('call-1')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      jsonResponse(200, { settled: false, remembered: false, decision: 'approve' }),
    ))
    await expect(answerHeldKeeperToolApproval('sangsu', 'call-1', 'approval-call-1', 'approve')).resolves.toBe(false)
    expect(keeperToolApprovals.value.sangsu?.['call-1']).toMatchObject({
      approvalId: 'approval-call-1', settled: false, answering: false, answeredDecision: null,
    })
  })

  it('does not answer replacement B from the callback for displayed A', async () => {
    pendingRow('call-1', 'approval-b')
    const replacement = keeperToolApprovals.value.sangsu?.['call-1']
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    await expect(answerHeldKeeperToolApproval('sangsu', 'call-1', 'approval-a', 'approve')).resolves.toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
    expect(keeperToolApprovals.value.sangsu?.['call-1']).toBe(replacement)
  })

  it.each([200, 500])('does not mutate replacement B when A POST completes with HTTP %s', async status => {
    pendingRow('call-1', 'approval-a')
    pendingRow('other-call', 'other-ask')
    pendingRow('call-1', 'other-keeper-ask', 'other-keeper')
    let release: (() => void) | undefined
    const gate = new Promise<void>(resolve => { release = resolve })
    vi.stubGlobal('fetch', vi.fn(async () => {
      await gate
      return jsonResponse(status, { settled: true, remembered: false, decision: 'approve' })
    }))
    const first = answerHeldKeeperToolApproval('sangsu', 'call-1', 'approval-a', 'approve')
    pendingRow('call-1', 'approval-b')
    const replacement = keeperToolApprovals.value.sangsu?.['call-1']
    const otherCall = keeperToolApprovals.value.sangsu?.['other-call']
    const otherKeeper = keeperToolApprovals.value['other-keeper']
    keeperActionErrors.value = { sangsu: 'owned by B' }
    release?.()
    await expect(first).resolves.toBe(false)
    expect(keeperToolApprovals.value.sangsu?.['call-1']).toBe(replacement)
    expect(keeperToolApprovals.value.sangsu?.['other-call']).toBe(otherCall)
    expect(keeperToolApprovals.value['other-keeper']).toBe(otherKeeper)
    expect(keeperActionErrors.value.sangsu).toBe('owned by B')
  })

  it('does not unlock an in-flight ask when its request is replayed', async () => {
    pendingRow('call-1')
    let release: (() => void) | undefined
    const gate = new Promise<void>(resolve => { release = resolve })
    const fetchMock = vi.fn(async () => {
      await gate
      return jsonResponse(200, { settled: true, remembered: false, decision: 'approve' })
    })
    vi.stubGlobal('fetch', fetchMock)
    const first = answerHeldKeeperToolApproval('sangsu', 'call-1', 'approval-call-1', 'approve')
    pendingRow('call-1')
    await expect(answerHeldKeeperToolApproval('sangsu', 'call-1', 'approval-call-1', 'deny')).resolves.toBe(false)
    release?.()
    await expect(first).resolves.toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it.each([{}, { settled: true }, { settled: true, remembered: 'false', decision: 'approve' }])(
    'keeps pending on a malformed answer receipt', async receipt => {
      pendingRow('call-1')
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, receipt)))
      await expect(answerHeldKeeperToolApproval('sangsu', 'call-1', 'approval-call-1', 'approve')).resolves.toBe(false)
      expect(keeperToolApprovals.value.sangsu?.['call-1']).toMatchObject({ settled: false, answering: false })
    },
  )

  it('sends the exact opaque approval ID without normalizing it', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse(200, { settled: true, remembered: false, decision: 'approve' }),
    )
    vi.stubGlobal('fetch', fetchMock)
    await answerKeeperToolApproval('sangsu', 'call-1', ' opaque-approval ', 'approve')
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body)).approval_id).toBe(' opaque-approval ')
  })

  it('rejects a missing or blank identity before making a POST', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    await expect(answerKeeperToolApproval('sangsu', 'call-1', '', 'approve')).rejects.toThrow()
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

describe('approval hydration ownership', () => {
  const row = (approvalId: unknown) => ({ keeper: 'sangsu', tool_call_id: 'call-1', approval_id: approvalId,
    tool: 'Execute', args: '{}', question: 'run?', because: '', asked_at: 1, timeout_sec: 180 })

  it('hydrates every pending call for the same Keeper from one listing', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, {
      pending: [row('approval-a'), { ...row('approval-b'), tool_call_id: 'call-2' }],
    })))

    await hydrateKeeperToolApprovals()

    expect(keeperToolApprovals.value.sangsu?.['call-1']?.approvalId).toBe('approval-a')
    expect(keeperToolApprovals.value.sangsu?.['call-2']?.approvalId).toBe('approval-b')
  })

  it('replaces unchanged A with authoritative pending B', async () => {
    pendingRow('call-1', 'approval-a')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, { pending: [row('approval-b')] })))
    await hydrateKeeperToolApprovals()
    expect(keeperToolApprovals.value.sangsu?.['call-1']?.approvalId).toBe('approval-b')
  })

  it('cannot overwrite a concurrent stream replacement B with an older listing A', async () => {
    pendingRow('call-1', 'approval-a')
    let release: (() => void) | undefined
    const gate = new Promise<void>(resolve => { release = resolve })
    vi.stubGlobal('fetch', vi.fn(async () => { await gate; return jsonResponse(200, { pending: [row('approval-a')] }) }))
    const hydration = hydrateKeeperToolApprovals()
    pendingRow('call-1', 'approval-b')
    const replacement = keeperToolApprovals.value.sangsu?.['call-1']
    release?.()
    await hydration
    expect(keeperToolApprovals.value.sangsu?.['call-1']).toBe(replacement)
  })

  it('does not resurrect A when its request and settlement both arrived during the listing read', async () => {
    let release: (() => void) | undefined
    const gate = new Promise<void>(resolve => { release = resolve })
    vi.stubGlobal('fetch', vi.fn(async () => { await gate; return jsonResponse(200, { pending: [row('approval-a')] }) }))
    const hydration = hydrateKeeperToolApprovals()
    pendingRow('call-1', 'approval-a')
    dropKeeperToolApproval('sangsu', 'call-1', 'approval-a')
    release?.()
    await hydration
    expect(keeperToolApprovals.value.sangsu?.['call-1']).toBeUndefined()
  })

  it('refuses a listing without the required pending array', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, {})))
    await expect(fetchKeeperToolApprovals()).rejects.toThrow()
  })

  it.each([undefined, null, 1, '', ' '])('rejects malformed listing identity %s without changing pending asks', async approvalId => {
    pendingRow('call-1', 'approval-a')
    const existing = keeperToolApprovals.value.sangsu?.['call-1']
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, { pending: [row(approvalId)] })))
    await expect(fetchKeeperToolApprovals()).rejects.toThrow()
    await hydrateKeeperToolApprovals()
    expect(keeperToolApprovals.value.sangsu?.['call-1']).toBe(existing)
  })
})
