import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  buildDashboardSseUrl,
  connectSSE,
  connected,
  disconnectSSE,
  flushPendingSseEvents,
  journal,
  normalizeSSEDispatchType,
} from './sse'
import { clearStoredToken, setStoredToken } from './api/core'

class MockEventSource {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSED = 2

  static instances: MockEventSource[] = []

  onopen: ((event: Event) => void) | null = null
  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: ((event: Event) => void) | null = null
  readyState = MockEventSource.CONNECTING
  readonly url: string
  close = vi.fn(() => {
    this.readyState = MockEventSource.CLOSED
  })

  constructor(url: string) {
    this.url = url
    MockEventSource.instances.push(this)
  }

  simulateOpen(): void {
    this.readyState = MockEventSource.OPEN
    this.onopen?.(new Event('open'))
  }

  simulateMessage(data: string): void {
    this.onmessage?.(new MessageEvent('message', { data }))
  }

  static reset(): void {
    MockEventSource.instances = []
  }
}

async function importSseConnect(): Promise<typeof import('./sse')> {
  return import('./sse')
}

describe('buildDashboardSseUrl', () => {
  afterEach(() => {
    clearStoredToken()
  })

  it('keeps the stored bearer out of the URL while preserving agent scope', () => {
    setStoredToken('secret')
    expect(
      buildDashboardSseUrl('dash_test', '?agent=keeper-a'),
    ).toBe('/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer')
  })

  it('never projects blank raw stored tokens into the URL', () => {
    sessionStorage.setItem('masc_bearer_token', '   ')

    expect(buildDashboardSseUrl('dash_test', '?agent=keeper-a')).toBe(
      '/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer',
    )
  })

  it('omits token when sessionStorage is empty', () => {
    expect(buildDashboardSseUrl('dash_test', '?agent=keeper-a')).toBe(
      '/mcp?agent=keeper-a&session_id=dash_test&sse_kind=observer',
    )
  })

  it('omits optional params when they are absent', () => {
    expect(buildDashboardSseUrl('dash_test', '')).toBe(
      '/mcp?session_id=dash_test&sse_kind=observer',
    )
  })
})

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

describe('dashboard SSE credential lifecycle', () => {
  beforeEach(() => {
    disconnectSSE()
    clearStoredToken()
    MockEventSource.reset()
    vi.stubGlobal('EventSource', MockEventSource)
    sessionStorage.removeItem('masc_dashboard_sse_session_id')
  })

  afterEach(() => {
    disconnectSSE()
    clearStoredToken()
    vi.unstubAllGlobals()
  })

  it('aborts stale fetch streams on token rotation and token clear', async () => {
    const fetchSignals: AbortSignal[] = []
    const fetchMock = vi.fn((_url: string, init?: RequestInit) => {
      if (init?.signal instanceof AbortSignal) fetchSignals.push(init.signal)
      return Promise.resolve(
        new Response(new ReadableStream<Uint8Array>(), {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        }),
      )
    })
    vi.stubGlobal('fetch', fetchMock)
    setStoredToken('token-a')

    connectSSE()
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    expect(fetchMock.mock.calls[0]?.[1]).toEqual(
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: 'Bearer token-a' }),
      }),
    )

    setStoredToken('token-b')
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    expect(fetchSignals[0]?.aborted).toBe(true)
    expect(fetchMock.mock.calls[1]?.[1]).toEqual(
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: 'Bearer token-b' }),
      }),
    )

    clearStoredToken()
    await vi.waitFor(() => expect(MockEventSource.instances).toHaveLength(1))
    expect(fetchSignals[1]?.aborted).toBe(true)

    disconnectSSE()
    expect(MockEventSource.instances[0]?.close).toHaveBeenCalledTimes(1)
    setStoredToken('token-c')
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(MockEventSource.instances).toHaveLength(1)
  })
})

describe('SSE OAS typed-payload handlers', () => {
  beforeEach(() => {
    MockEventSource.reset()
    vi.stubGlobal('EventSource', MockEventSource)
    disconnectSSE()
    journal.value = []
    connected.value = false
    sessionStorage.removeItem('masc_dashboard_sse_session_id')
  })

  afterEach(() => {
    disconnectSSE()
    vi.unstubAllGlobals()
  })

  function emitEvent(payload: Record<string, unknown>): void {
    const es = MockEventSource.instances[0]
    if (!es) throw new Error('MockEventSource not created')
    es.simulateMessage(JSON.stringify(payload))
    flushPendingSseEvents()
  }

  function lastJournalEntry() {
    // journal.value is newest-first (RingBuffer.toArray ordering)
    return journal.value[0]
  }

  it('creates a journal entry from a typed oas:agent_started payload', async () => {
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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

  it('creates a journal entry from a typed oas:agent_completed payload', async () => {
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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

  it('creates a journal entry from a typed oas:agent_failed payload with all error fields', async () => {
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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

  it('drops a malformed oas:agent_started payload and logs a warning', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const beforeCount = journal.value.length
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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

  it('creates a journal entry from a typed oas:tool_called payload', async () => {
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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

  it('creates a journal entry from a typed oas:turn_completed payload', async () => {
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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

  it('creates a journal entry from a typed oas:handoff_requested payload', async () => {
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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

  it('creates a journal entry and compaction record from a typed oas:context_compacted payload', async () => {
    const { connectSSE } = await importSseConnect()
    connectSSE()
    MockEventSource.instances[0]!.simulateOpen()
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
