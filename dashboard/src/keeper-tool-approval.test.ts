import { v7 as uuidv7 } from 'uuid'
import { fetchKeeperToolApprovals } from './api/keeper'
import { applyKeeperStreamEvent } from './keeper-stream'
import { clearStoredToken, setStoredToken } from './api/core'
import { effect } from '@preact/signals'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { keeperActionErrors, keeperThreads, appendThreadEntry, keeperToolApprovals, upsertKeeperToolApproval } from './keeper-state'
import { answerHeldKeeperToolApproval, hydrateKeeperToolApprovals } from './keeper-actions'

// task-343: the answer path for a held tool call. Before this surface the
// dashboard decoded KEEPER_TOOL_APPROVAL_REQUESTED and drew nothing; the
// operator's decision never reached the server, and the wait retired itself
// after 180s as a denial nobody chose. These tests fix that the POST goes to
// the wait that owns the call and that the row it leaves behind is honest
// about what happened.

const approvalIds = new Map<string, string>()
function idFor(call: string): string {
  const existing = approvalIds.get(call)
  if (existing) return existing
  const id = uuidv7()
  approvalIds.set(call, id)
  return id
}

function pendingRow(toolCallId: string): void {
  upsertKeeperToolApproval('sangsu', {
    approvalId: idFor(toolCallId),
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
  clearStoredToken()
  keeperToolApprovals.value = {}
  keeperActionErrors.value = {}
  keeperThreads.value = {}
})

describe('answerHeldKeeperToolApproval', () => {
  it('POSTs the decision to the wait that owns the call and retires the row', async () => {
    pendingRow('call-1')
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse(200, { settled: true, decision: 'approve' }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const settled = await answerHeldKeeperToolApproval('sangsu', idFor('call-1'), 'approve')

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
    expect(keeperToolApprovals.value.sangsu?.[idFor('call-1')]?.settled).toBe(true)
  })

  it('retires the row on a late answer (settled: false) instead of promising a dead wait', async () => {
    pendingRow('call-late')
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(jsonResponse(200, { settled: false, decision: 'deny' })),
    )

    const settled = await answerHeldKeeperToolApproval('sangsu', idFor('call-late'), 'deny')

    // settled=false is not a thrown error: the call is gone either way.
    expect(settled).toBe(false)
    expect(keeperToolApprovals.value.sangsu?.[idFor('call-late')]?.settled).toBe(true)
  })

  it('re-arms the card when the POST fails so the operator can retry', async () => {
    pendingRow('call-fail')
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(jsonResponse(500, { error: 'boom' })),
    )

    await expect(answerHeldKeeperToolApproval('sangsu', idFor('call-fail'), 'approve')).resolves.toBe(false)

    const row = keeperToolApprovals.value.sangsu?.[idFor('call-fail')]
    expect(row?.settled).toBe(false)
    expect(row?.answering).toBe(false)
    expect(row?.answeredDecision).toBeNull()
  })

  it('keeps two admissions distinct while an older answer is in flight', async () => {
    pendingRow('shared-provider')
    const firstId = idFor('shared-provider')
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const answered = answerHeldKeeperToolApproval('sangsu', firstId, 'approve')
    await vi.waitFor(() => expect(resolveFetch).toBeDefined())
    const secondId = uuidv7()
    const first = keeperToolApprovals.value.sangsu![firstId]!
    upsertKeeperToolApproval('sangsu', {
      ...first, approvalId: secondId, answering: false,
      answeredDecision: null, answeredOutcome: null, settled: false,
    })
    const second = keeperToolApprovals.value.sangsu![secondId]
    expect(keeperToolApprovals.value.sangsu![firstId]?.answering).toBe(true)
    resolveFetch(jsonResponse(200, { settled: true, decision: 'approve' }))
    await expect(answered).resolves.toBe(true)
    expect(keeperToolApprovals.value.sangsu![firstId]?.settled).toBe(true)
    expect(keeperToolApprovals.value.sangsu![secondId]).toBe(second)
    expect(second?.settled).toBe(false)
  })

  it('does not settle a replacement wait with the same provider call ID', async () => {
    pendingRow('call-reused')
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const first = answerHeldKeeperToolApproval('sangsu', idFor('call-reused'), 'approve')
    await vi.waitFor(() => expect(resolveFetch).toBeDefined())
    pendingRow('call-reused')
    const replacement = keeperToolApprovals.value.sangsu![idFor('call-reused')]
    resolveFetch(jsonResponse(200, { settled: true, decision: 'approve' }))
    await expect(first).resolves.toBe(true)
    expect(keeperToolApprovals.value.sangsu![idFor('call-reused')]).toBe(replacement)
    expect(replacement?.settled).toBe(false)
  })

  it('does not publish an old failure into a replacement wait', async () => {
    pendingRow('call-failure-reused')
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const first = answerHeldKeeperToolApproval('sangsu', idFor('call-failure-reused'), 'approve')
    await vi.waitFor(() => expect(resolveFetch).toBeDefined())
    pendingRow('call-failure-reused')
    const replacement = keeperToolApprovals.value.sangsu![idFor('call-failure-reused')]
    keeperActionErrors.value = { sangsu: 'new request error' }
    resolveFetch(jsonResponse(500, { error: 'old request failure' }))
    await expect(first).resolves.toBe(false)
    expect(keeperToolApprovals.value.sangsu![idFor('call-failure-reused')]).toBe(replacement)
    expect(keeperActionErrors.value.sangsu).toBe('new request error')
  })

  it('does not dispatch after an answering observer replaces the wait', async () => {
    pendingRow('call-observer')
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    let replaced = false
    const dispose = effect(() => {
      const row = keeperToolApprovals.value.sangsu?.[idFor('call-observer')]
      if (row?.answering && !replaced) {
        replaced = true
        pendingRow('call-observer')
      }
    })
    try {
      await expect(answerHeldKeeperToolApproval('sangsu', idFor('call-observer'), 'approve')).resolves.toBe(false)
      expect(replaced).toBe(true)
      expect(fetchMock).not.toHaveBeenCalled()
      expect(keeperToolApprovals.value.sangsu?.[idFor('call-observer')]?.answering).toBe(false)
    } finally { dispose() }
  })

  it('does not answer an approval retained from a previous authentication', async () => {
    setStoredToken('synthetic-approval-old-account')
    pendingRow('old-account-call')
    setStoredToken('synthetic-approval-new-account')
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    await expect(answerHeldKeeperToolApproval('sangsu', idFor('old-account-call'), 'approve')).resolves.toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it.each([
    {},
    { settled: 'false', decision: 'approve' },
    { settled: true },
    { settled: true, decision: 'unknown' },
    null,
  ])('preserves the pending approval when the answer receipt is malformed', async body => {
    pendingRow('malformed-receipt-call')
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(200, body))
    vi.stubGlobal('fetch', fetchMock)
    await expect(answerHeldKeeperToolApproval('sangsu', idFor('malformed-receipt-call'), 'approve')).resolves.toBe(false)
    expect(keeperToolApprovals.value.sangsu?.[idFor('malformed-receipt-call')]?.settled).toBe(false)
    expect(fetchMock).toHaveBeenCalledTimes(1)
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

    const first = answerHeldKeeperToolApproval('sangsu', idFor('call-double'), 'approve')
    // Second click while the first POST is in flight: no duplicate answer.
    await expect(answerHeldKeeperToolApproval('sangsu', idFor('call-double'), 'deny')).resolves.toBe(false)
    releaseFetch?.()
    await expect(first).resolves.toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe('approval inventory protocol', () => {
  it.each([
    {},
    { pending: {} },
    { pending: [{ approval_id: idFor('call-malformed'), keeper: 'sangsu', tool_call_id: 'call-malformed' }] },
    { pending: [null] },
  ])('rejects malformed inventory rather than inventing an empty list or prompt', async body => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, body)))
    await expect(fetchKeeperToolApprovals()).rejects.toThrow()
  })
})

describe('hydrateKeeperToolApprovals', () => {
  it('fills gaps from the public listing without overwriting rows the stream already drew', async () => {
    pendingRow('call-known')
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse(200, {
        pending: [
          {
            approval_id: idFor('call-known'),
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
            approval_id: idFor('call-hydrated'),
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
    expect(keeperToolApprovals.value.sangsu?.[idFor('call-known')]?.toolName).toBe('Execute')
    // Gap filled: a wait this view never saw still gets a card.
    const hydrated = keeperToolApprovals.value.sangsu?.[idFor('call-hydrated')]
    expect(hydrated?.toolName).toBe('Execute')
    expect(hydrated?.question).toBe('보고서를 날릴까요?')
    expect(hydrated?.because).toBe('external side effect')
    expect(hydrated?.askedAtMs).toBe(1787636000 * 1000)
  })

  it('hydrates another admission even when its provider call ID is already known', async () => {
    pendingRow('shared-inventory-provider')
    const firstId = idFor('shared-inventory-provider')
    const secondId = uuidv7()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, { pending: [{
      approval_id: secondId, keeper: 'sangsu', tool_call_id: 'shared-inventory-provider',
      tool: 'Execute', args: '{}', question: 'Second ask?', because: 'policy',
      asked_at: 1, timeout_sec: 180,
    }] })))
    await hydrateKeeperToolApprovals()
    expect(keeperToolApprovals.value.sangsu![firstId]?.question).toBe('Execute ls 를 실행할까요?')
    expect(keeperToolApprovals.value.sangsu![secondId]?.question).toBe('Second ask?')
    expect(keeperToolApprovals.value.sangsu![secondId]?.toolCallId).toBe('shared-inventory-provider')
  })

  it.each([undefined, 'provider-call', 42, '12de81b6-4388-4aa5-b4b0-678d3cabeeff'])(
    'rejects inventory without a canonical server admission ID', async approval_id => {
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, { pending: [{
        approval_id, keeper: 'sangsu', tool_call_id: 'inventory-call', tool: 'Execute',
        args: '{}', question: 'Run?', because: 'policy', asked_at: 1, timeout_sec: 180,
      }] })))
      await expect(fetchKeeperToolApprovals()).rejects.toThrow('approval_id')
    },
  )

  it('discards a listing completed after authentication changes', async () => {
    setStoredToken('synthetic-approval-account-a')
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const pending = hydrateKeeperToolApprovals()
    await vi.waitFor(() => expect(resolveFetch).toBeDefined())
    setStoredToken('synthetic-approval-account-b')
    resolveFetch(jsonResponse(200, { pending: [{
      approval_id: idFor('foreign-wait'), keeper: 'sangsu', tool_call_id: 'foreign-wait', tool: 'Execute', args: '{}',
      question: 'approval', because: 'effect', asked_at: 1, timeout_sec: 180,
    }] }))
    await pending
    expect(keeperToolApprovals.value.sangsu?.[idFor('foreign-wait')]).toBeUndefined()
  })

  it('stops publishing remaining rows when an observer changes authentication', async () => {
    setStoredToken('synthetic-hydration-account-a')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, { pending:
      ['first-wait', 'second-wait'].map(tool_call_id => ({
        approval_id: idFor(tool_call_id), keeper: 'sangsu', tool_call_id, tool: 'Execute', args: '{}',
        question: 'approval', because: 'effect', asked_at: 1, timeout_sec: 180,
      })),
    })))
    let switched = false
    const dispose = effect(() => {
      if (keeperToolApprovals.value.sangsu?.[idFor('first-wait')] && !switched) {
        switched = true
        setStoredToken('synthetic-hydration-account-b')
        keeperToolApprovals.value = {}
      }
    })
    try {
      await hydrateKeeperToolApprovals()
      expect(switched).toBe(true)
      expect(keeperToolApprovals.value.sangsu?.[idFor('second-wait')]).toBeUndefined()
    } finally { dispose() }
  })

  it('does not resurrect a wait from an older overlapping listing', async () => {
    const resolvers: Array<(response: Response) => void> = []
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolvers.push(resolve) })))
    const older = hydrateKeeperToolApprovals()
    await vi.waitFor(() => expect(resolvers).toHaveLength(1))
    const newer = hydrateKeeperToolApprovals()
    await vi.waitFor(() => expect(resolvers).toHaveLength(2))
    resolvers[1]!(jsonResponse(200, { pending: [] }))
    await newer
    resolvers[0]!(jsonResponse(200, { pending: [{
      approval_id: idFor('finished-wait'), keeper: 'sangsu', tool_call_id: 'finished-wait', tool: 'Execute', args: '{}',
      question: 'approval', because: 'effect', asked_at: 1, timeout_sec: 180,
    }] }))
    await older
    expect(keeperToolApprovals.value.sangsu?.[idFor('finished-wait')]).toBeUndefined()
  })

  it('does not resurrect a known wait settled while its listing was pending', async () => {
    pendingRow('stream-finished-wait')
    appendThreadEntry('sangsu', {
      id: 'approval-reply', role: 'assistant', source: 'direct_assistant', label: 'sangsu',
      text: '', rawText: '', timestamp: new Date().toISOString(),
      delivery: 'sending', streamState: 'opening', details: null,
    })
    let resolveFetch!: (response: Response) => void
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(resolve => { resolveFetch = resolve })))
    const listing = hydrateKeeperToolApprovals()
    await vi.waitFor(() => expect(resolveFetch).toBeDefined())
    expect(applyKeeperStreamEvent('sangsu', 'approval-reply', {
      type: 'CUSTOM', name: 'KEEPER_TOOL_APPROVAL_SETTLED',
      value: { approval_id: idFor('stream-finished-wait'), tool_call_id: 'stream-finished-wait', outcome: 'approve' },
    })).toBeNull()
    resolveFetch(jsonResponse(200, { pending: [{
      approval_id: idFor('stream-finished-wait'), keeper: 'sangsu', tool_call_id: 'stream-finished-wait', tool: 'Execute', args: '{}',
      question: 'approval', because: 'effect', asked_at: 1, timeout_sec: 180,
    }] }))
    await listing
    expect(keeperToolApprovals.value.sangsu?.[idFor('stream-finished-wait')]?.settled).toBe(true)
  })

  it('does not publish an infinite millisecond timestamp from finite server seconds', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(200, { pending: [{
      approval_id: idFor('overflow-clock'), keeper: 'sangsu', tool_call_id: 'overflow-clock', tool: 'Execute', args: '{}',
      question: 'approval', because: 'effect', asked_at: Number.MAX_VALUE, timeout_sec: 180,
    }] })))
    await hydrateKeeperToolApprovals()
    expect(keeperToolApprovals.value.sangsu?.[idFor('overflow-clock')]).toBeUndefined()
  })

  it('stays silent when the listing fails — hydration is best-effort', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(503, { error: 'unavailable' })))
    await expect(hydrateKeeperToolApprovals()).resolves.toBeUndefined()
    expect(keeperToolApprovals.value.sangsu).toBeUndefined()
  })
})
