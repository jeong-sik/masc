import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, bumpSessionEpoch, resetAuthStateForTests, setSingleUserToken } from '../../core/auth'
import { resetShellStateForTests } from '../../shell/shell-state'
import {
  KeeperSandboxTerminal,
  MAX_TERMINAL_LINES,
  createInitialTerminalState,
  reduceTerminalEvent,
} from './keeper-sandbox-terminal'

function sseStreamResponse(frames: readonly string[]): {
  readonly response: Response
  readonly aborted: () => boolean
} {
  let wasAborted = false
  const encoder = new TextEncoder()
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const frame of frames) {
        controller.enqueue(encoder.encode(frame))
      }
    },
    cancel() {
      wasAborted = true
    },
  })
  return {
    response: new Response(body, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    }),
    aborted: () => wasAborted,
  }
}

describe('KeeperSandboxTerminal', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetShellStateForTests()
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: true },
      workspaceId: 'default',
    }
    setSingleUserToken('secret-tok-123')
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    resetAuthStateForTests()
    resetShellStateForTests()
  })

  it('connects with Bearer auth header, renders SSE events + ANSI text safely, and aborts on unmount', async () => {
    const sse = sseStreamResponse([
      `data: ${JSON.stringify({
        type: 'task_opened',
        seq: 1,
        stream_id: 10,
        command: 'dune runtest',
        cwd: '/workspace/masc',
        sandbox_profile: 'docker',
      })}\n\n`,
      `data: ${JSON.stringify({
        type: 'line',
        line: { seq: 2, stream: 'stdout', text: '\x1b[32mPASS\x1b[0m <img src=x onerror=alert(1)>' },
      })}\n\n`,
      `data: ${JSON.stringify({
        type: 'line',
        line: { seq: 3, stream: 'stderr', text: 'warn: flaky timing' },
      })}\n\n`,
      `data: ${JSON.stringify({
        type: 'gap',
        missing_from_seq: 4,
        missing_to_seq: 6,
        missing_count: 3,
        bytes_dropped_stdout: 512,
      })}\n\n`,
      `data: ${JSON.stringify({
        type: 'task_closed',
        seq: 7,
        stream_id: 10,
        status: { exited: 0 },
      })}\n\n`,
    ])

    let capturedHeaders: HeadersInit | undefined
    let capturedSignal: AbortSignal | undefined
    let capturedUrl = ''
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      capturedUrl = String(input)
      capturedHeaders = init?.headers
      capturedSignal = init?.signal ?? undefined
      return sse.response
    }))

    const view = render(html`<${KeeperSandboxTerminal} keeperName="alpha/bot" />`)

    await waitFor(() => {
      expect(view.getByTestId('kst-viewport').textContent).toContain('exit 0')
    })

    expect(capturedUrl).toContain('/api/v1/dashboard/execute-output/alpha%2Fbot')
    expect((capturedHeaders as Record<string, string>).Authorization).toBe('Bearer secret-tok-123')
    expect((capturedHeaders as Record<string, string>).Accept).toBe('text/event-stream')
    // XSS safety: literal HTML is rendered as text, never an <img> element
    expect(view.container.querySelector('img')).toBeNull()
    expect(view.getByTestId('kst-viewport').textContent).toContain('<img src=x onerror=alert(1)>')
    expect(view.getByTestId('kst-backend-badge').textContent).toBe('sandbox: docker')
    expect(view.getByTestId('kst-gap-banner').textContent).toContain('누락 이벤트 3건')
    expect(view.getByTestId('kst-gap-banner').textContent).toContain('512B 드롭')

    // Stream filter: stderr only
    fireEvent.click(view.getByTestId('kst-filter-stderr'))
    expect(view.getByTestId('kst-viewport').textContent).toContain('warn: flaky timing')
    expect(view.getByTestId('kst-viewport').textContent).not.toContain('PASS')

    // Stream filter back to all + text filter
    fireEvent.click(view.getByTestId('kst-filter-all'))
    fireEvent.input(view.getByTestId('kst-text-filter'), { target: { value: 'PASS' } })
    expect(view.getByTestId('kst-viewport').textContent).toContain('PASS')
    expect(view.getByTestId('kst-viewport').textContent).not.toContain('warn: flaky timing')

    // Clear buffer
    fireEvent.click(view.getByTestId('kst-clear-btn'))
    expect(view.getByTestId('kst-empty-state')).toBeTruthy()

    // Unmount aborts SSE fetch
    expect(capturedSignal?.aborted).toBe(false)
    view.unmount()
    expect(capturedSignal?.aborted).toBe(true)
  })

  it('aborts active SSE stream on sessionEpoch change and shows honest no_task guidance', async () => {
    const sse = sseStreamResponse([
      `data: ${JSON.stringify({ type: 'no_task', keeper: 'idle-keeper' })}\n\n`,
    ])
    let capturedSignal: AbortSignal | undefined
    vi.stubGlobal('fetch', vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      capturedSignal = init?.signal ?? undefined
      return sse.response
    }))

    const view = render(html`<${KeeperSandboxTerminal} keeperName="idle-keeper" />`)
    await waitFor(() => {
      expect(view.getByTestId('kst-empty-state').textContent).toContain('서버 시작 이후')
    })
    expect(view.getByTestId('kst-empty-state').textContent).toContain('Tool Calls')

    const firstSignal = capturedSignal
    bumpSessionEpoch()
    expect(firstSignal?.aborted).toBe(true)
  })

  it('fetches host container / VM logs only when disclosure is expanded', async () => {
    const calls: string[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      calls.push(url)
      if (url.includes('/execute-output/')) {
        return sseStreamResponse([`data: ${JSON.stringify({ type: 'no_task', keeper: 'vm-k' })}\n\n`]).response
      }
      if (url.includes('/api/v1/gate/keeper-sandbox-logs')) {
        return Response.json({
          keeper: 'vm-k',
          backend: 'docker',
          state: 'available',
          reason: null,
          reason_code: null,
          tail: 200,
          instances: [
            {
              instance_id: 'cid-1',
              instance_name: 'masc-vm-k',
              running: true,
              stdout: 'container booted ok\n',
              stderr: 'minor stderr note\n',
              error: null,
            },
          ],
        })
      }
      return Response.json({}, { status: 404 })
    }))

    const view = render(html`<${KeeperSandboxTerminal} keeperName="vm-k" />`)
    await waitFor(() => expect(calls.some((u) => u.includes('/execute-output/'))).toBe(true))
    expect(calls.some((u) => u.includes('/keeper-sandbox-logs'))).toBe(false)

    const disclosure = view.getByTestId('kst-host-logs-disclosure') as HTMLDetailsElement
    disclosure.open = true
    fireEvent(disclosure, new Event('toggle'))

    await waitFor(() => {
      expect(view.getByTestId('kst-host-log-instance').textContent).toContain('container booted ok')
    })
    expect(view.getByTestId('kst-host-log-instance').textContent).toContain('minor stderr note')
    expect(calls.some((u) => u.includes('/api/v1/gate/keeper-sandbox-logs?name=vm-k&tail=200'))).toBe(true)
  })

  it('caps retained DOM lines at MAX_TERMINAL_LINES and tracks head-dropped count', () => {
    let state = createInitialTerminalState()
    const total = MAX_TERMINAL_LINES + 15
    const lines = Array.from({ length: total }, (_, idx) => ({
      seq: idx + 1,
      stream: 'stdout',
      text: `line-${idx + 1}`,
    }))
    state = reduceTerminalEvent(state, { type: 'snapshot', lines, last_seq: total })
    expect(state.lines).toHaveLength(MAX_TERMINAL_LINES)
    expect(state.headDroppedCount).toBe(15)
    expect(state.lines[0]!.text).toBe('line-16')
  })

  it('counts the rows the server left out of the snapshot as head-dropped', () => {
    const lines = Array.from({ length: 3 }, (_, idx) => ({
      seq: 3001 + idx,
      stream: 'stdout',
      text: `line-${3001 + idx}`,
    }))
    const state = reduceTerminalEvent(createInitialTerminalState(), {
      type: 'snapshot',
      lines,
      lines_omitted: 3000,
      first_retained_seq: 1,
      last_seq: 3003,
    })
    expect(state.lines).toHaveLength(3)
    expect(state.headDroppedCount).toBe(3000)
    expect(state.gap.firstRetainedSeq).toBe(1)
  })
})
