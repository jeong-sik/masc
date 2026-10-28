import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { tasks } from '../../store'
import {
  ExecuteOutputDrawer,
  executeOutputRouteLinks,
  linesFromExecuteOutputEvent,
  summarizeOutputLines,
} from './execute-output-drawer'

let mounted: HTMLDivElement | null = null

afterEach(() => {
  if (mounted) render(null, mounted)
  mounted = null
  tasks.value = []
  window.location.hash = ''
  vi.unstubAllGlobals()
})

/** An event-stream body that delivers [text] and then stays open. */
function openStream(text: string): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      if (text !== '') controller.enqueue(new TextEncoder().encode(text))
    },
  })
}

describe('ExecuteOutputDrawer event mapping', () => {
  it('maps stdout and stderr chunks to terminal lines', () => {
    const lines = linesFromExecuteOutputEvent({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'one\ntwo\n',
      stderr_since: 'warn\n',
      closed: false,
    })

    expect(lines.map(line => line.text)).toEqual(['one', 'two', 'warn'])
    expect(lines.map(line => line.stream)).toEqual(['stdout', 'stdout', 'stderr'])
  })

  it('prefers structured snapshot lines over byte chunks', () => {
    const lines = linesFromExecuteOutputEvent({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'duplicate\n',
      lines: [
        { ts_ms: 1000, stream: 'stdout', text: 'one', ansi: false },
        { ts_ms: 1001, stream: 'stderr', text: 'warn', ansi: false },
        { ts_ms: 1002, stream: 'system', text: 'closed', ansi: false },
      ],
      closed: false,
    })

    expect(lines).toEqual([
      { text: 'one', stream: 'stdout' },
      { text: 'warn', stream: 'stderr' },
      { text: 'closed', stream: 'meta' },
    ])
  })

  it('maps live line and task close events', () => {
    expect(linesFromExecuteOutputEvent({
      type: 'line',
      keeper: 'sangsu',
      line: { ts_ms: 1000, stream: 'stdout', text: 'fresh', ansi: false },
      closed: false,
    })).toEqual([{ text: 'fresh', stream: 'stdout' }])

    expect(linesFromExecuteOutputEvent({
      type: 'task_closed',
      keeper: 'sangsu',
      closed: true,
    })).toEqual([{ text: 'Execute output task closed', stream: 'meta' }])
  })

  it('labels retained and active commands as summaries without duplicating them', () => {
    const lines = linesFromExecuteOutputEvent({
      type: 'snapshot', keeper: 'sangsu', closed: false,
      lines: [{ stream: 'cmd', stream_id: 1, text: 'first command' }],
      active_streams: [
        { stream_id: 1, task_id: 'a', command: 'first command', started_at: 1 },
        { stream_id: 2, task_id: 'b', command: 'second command', started_at: 2 },
      ],
    })
    expect(lines.map(line => line.text)).toEqual([
      'command summary: first command', 'command summary: second command',
    ])
  })

  it('shows a pre-dispatch transport failure and a boxed observation separately', () => {
    expect(linesFromExecuteOutputEvent({
      type: 'task_closed', keeper: 'sangsu', stream_id: 2, task_id: 'task-a',
      closed: true, status: { outcome: 'request_not_sent' },
    }).map(line => line.text)).toEqual(['Execute request not sent (stream 2, task task-a)'])
    expect(linesFromExecuteOutputEvent({
      type: 'task_closed', keeper: 'sangsu', closed: true,
      status: { phase: 'gate_observation', outcome: 'observation_ended' },
    }).map(line => line.text)).toEqual(['Gate observation ended'])
  })

  it('says how many log entries a gap event missed', () => {
    expect(linesFromExecuteOutputEvent({
      type: 'gap',
      keeper: 'sangsu',
      missing_from_seq: 1,
      missing_to_seq: 10,
      missing_count: 10,
    })).toEqual([
      { text: 'missed 10 output entries the server no longer keeps (seq 1-10)', stream: 'meta' },
    ])
  })

  it('surfaces dropped byte evidence as a meta line', () => {
    const lines = linesFromExecuteOutputEvent({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'tail\n',
      stderr_since: '',
      bytes_dropped_stdout: 12,
      bytes_dropped_stderr: 3,
    })

    expect(lines[0]).toEqual({ text: 'dropped 15 older bytes', stream: 'meta' })
  })

  it('summarizes terminal streams and dropped byte evidence', () => {
    const summary = summarizeOutputLines([
      { text: 'dropped 15 older bytes', stream: 'meta' },
      { text: 'one', stream: 'stdout' },
      { text: 'two', stream: 'stdout' },
      { text: 'warn', stream: 'stderr' },
    ])

    expect(summary).toEqual({
      total: 4,
      stdout: 2,
      stderr: 1,
      meta: 1,
      droppedBytes: 15,
      lastStream: 'stderr',
    })
  })

  it('builds operational routes from Execute output task, goal, and keeper', () => {
    const links = executeOutputRouteLinks({
      keeperName: 'sangsu',
      taskId: 'task-123',
      taskList: [{
        id: 'task-123',
        title: 'Runtime task',
        goal_id: 'goal-ide',
      }],
    })

    expect(links.map(link => link.label)).toEqual([
      'Goal',
      'Task',
      'Telemetry',
      'Keeper',
    ])
    expect(links.find(link => link.label === 'Telemetry')).toMatchObject({
      params: { section: 'fleet-health', view: 'event-log', q: 'task-123' },
      evidence: 'Fleet telemetry event log · query task-123',
    })
  })

  it('renders Execute output through the shared terminal molecule', async () => {
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: '' }), mounted)

    await waitFor(() => expect(mounted?.textContent).toContain('no keeper selected'))
    const terminal = mounted.querySelector('[data-terminal][data-testid="execute-output-terminal"]')
    expect(terminal?.getAttribute('aria-label')).toBe('Execute output terminal')
    expect(terminal?.querySelector('.term-line.is-meta')?.textContent).toContain('no keeper selected')
    expect(mounted.querySelector('[data-testid="execute-output-summary"]')?.textContent).toContain('1 line')
    expect(mounted.querySelector('[data-status-chip-tone="neutral"]')?.textContent).toContain('idle')
  })

  it('collapses and restores the compact execution drawer without starting a stream', async () => {
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, {
      keeperName: 'sangsu',
      streamEnabled: false,
      compact: true,
    }), mounted)

    await waitFor(() => expect(mounted?.textContent).toContain('waiting for an active Execute output task'))
    const toggle = mounted.querySelector<HTMLButtonElement>('.execute-output-drawer-toggle')
    expect(toggle?.getAttribute('aria-expanded')).toBe('true')
    expect(mounted.querySelector('[data-testid="execute-output-terminal"]')).not.toBeNull()

    fireEvent.click(toggle!)
    expect(toggle?.getAttribute('aria-expanded')).toBe('false')
    expect(mounted.querySelector('[data-testid="execute-output-terminal"]')).toBeNull()

    fireEvent.click(toggle!)
    expect(toggle?.getAttribute('aria-expanded')).toBe('true')
    expect(mounted.querySelector('[data-testid="execute-output-terminal"]')).not.toBeNull()
  })

  it('renders streaming summary chips for stdout, stderr, and dropped bytes', async () => {
    let resolveFetch: (value: Response) => void = () => undefined
    const fetchPromise = new Promise<Response>(resolve => {
      resolveFetch = resolve
    })
    const fetchMock = vi.fn().mockReturnValue(fetchPromise)
    vi.stubGlobal('fetch', fetchMock)

    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    // The stream stays open: a live task keeps its connection.
    resolveFetch(new Response(
      openStream('event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-123","stdout_since":"one\\ntwo\\n","stderr_since":"warn\\n","bytes_dropped_stdout":12,"bytes_dropped_stderr":3,"closed":false}\n\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ))

    await waitFor(() => expect(mounted?.textContent).toContain('task-123'))
    const summary = mounted.querySelector('[data-testid="execute-output-summary"]')
    expect(summary?.getAttribute('role')).toBeNull()
    expect(summary?.getAttribute('aria-label')).toContain('4 lines, 2 stdout, 1 stderr, 1 meta')
    expect(summary?.getAttribute('aria-label')).toContain('15 dropped bytes')
    expect(summary?.textContent).toContain('stdout 2')
    expect(summary?.textContent).toContain('stderr 1')
    expect(summary?.textContent).toContain('dropped 15B')
    expect(mounted.querySelector('[data-status-chip-tone="info"]')?.textContent).toContain('streaming')
    expect(mounted.querySelector('[data-status-chip-tone="bad"]')?.textContent).toContain('stderr 1')
  })

  // A body that ends while the task is still running used to leave the chip
  // on "streaming" for good. It now says the output ended early.
  it('marks a stream that ends without the task closing as ended', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-9","stdout_since":"one\\n","closed":false}\n\n',
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))

    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => {
      expect(mounted?.querySelector('[data-status-chip-tone="warn"]')?.textContent).toContain('ended')
    })
    expect(mounted.textContent).toContain('output stream ended before the task closed')
  })

  it('keeps closed for a stream whose task said it closed', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-9","stdout_since":"one\\n","closed":true}\n\n',
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))

    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => {
      expect(mounted?.querySelector('[data-status-chip-tone="neutral"]')?.textContent).toContain('closed')
    })
    expect(mounted.textContent).not.toContain('output stream ended before the task closed')
  })

  it('shows an unknown outcome from a closed snapshot even when output exists', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-a","closed":true,"active_count":0,"active_streams":[],"status":{"outcome":"unknown"},"lines":[{"stream":"stdout","text":"partial output"}]}\n\n',
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => expect(mounted?.querySelector('[data-status-chip-tone="warn"]')?.textContent).toBe('unknown'))
    expect(mounted.textContent).toContain('partial output')
    expect(mounted.textContent).toContain('Execute result unknown (task task-a)')
    expect(mounted.textContent).not.toContain('output stream ended before the task closed')
  })

  it('preserves an unknown outcome from the final live close after the body ends', async () => {
    const events = [
      { type: 'snapshot', keeper: 'sangsu', closed: false, active_count: 1, lines: [],
        active_streams: [{ stream_id: 1, task_id: 'task-a', command: 'a', started_at: 1 }] },
      { type: 'task_closed', keeper: 'sangsu', stream_id: 1, task_id: 'task-a',
        closed: true, active_count: 0, status: { outcome: 'unknown' } },
    ].map(event => `event: output\ndata: ${JSON.stringify(event)}\n\n`).join('')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(events, {
      status: 200, headers: { 'Content-Type': 'text/event-stream' },
    })))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => expect(mounted?.querySelector('[data-status-chip-tone="warn"]')?.textContent).toBe('unknown'))
    expect(mounted.textContent).toContain('Execute result unknown (stream 1, task task-a)')
    expect(mounted.textContent).not.toContain('output stream ended before the task closed')
  })

  it('keeps an unknown close visible while another execution continues and after it closes', async () => {
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined
    const body = new ReadableStream<Uint8Array>({ start(value) { controller = value } })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, {
      status: 200, headers: { 'Content-Type': 'text/event-stream' },
    })))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)
    const emit = (event: object) => controller!.enqueue(new TextEncoder().encode(
      `event: output\ndata: ${JSON.stringify(event)}\n\n`,
    ))
    const header = () => mounted?.querySelector('.execute-output-drawer-header')?.textContent ?? ''
    emit({ type: 'snapshot', keeper: 'sangsu', closed: false, active_count: 2, lines: [],
      active_streams: [
        { stream_id: 1, task_id: 'task-a', command: 'a', started_at: 1 },
        { stream_id: 2, task_id: 'task-b', command: 'b', started_at: 2 },
      ] })
    emit({ type: 'task_closed', keeper: 'sangsu', stream_id: 1, task_id: 'task-a',
      closed: false, active_count: 1, status: { outcome: 'unknown' } })
    await waitFor(() => expect(header()).toContain('unconfirmed result'))
    expect(header()).toContain('streaming')
    expect(header()).toContain('task-b')
    expect(mounted.textContent).toContain('Execute result unknown (stream 1, task task-a)')

    emit({ type: 'task_closed', keeper: 'sangsu', stream_id: 2, task_id: 'task-b',
      closed: true, active_count: 0, status: { kind: 'exit', code: 0 } })
    await waitFor(() => expect(header()).toContain('unknown'))
    expect(header()).not.toContain('closed')
    expect(header()).not.toContain('task-b')
    expect(mounted.textContent).toContain('Execute exited with code 0 (stream 2, task task-b)')
    expect(mounted.textContent).toContain('Execute result unknown (stream 1, task task-a)')
  })

  it('keeps a gap unconfirmed even after a later execution closes', async () => {
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined
    const body = new ReadableStream<Uint8Array>({ start(value) { controller = value } })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, {
      status: 200, headers: { 'Content-Type': 'text/event-stream' },
    })))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)
    const emit = (event: object) => controller!.enqueue(new TextEncoder().encode(
      `event: output\ndata: ${JSON.stringify(event)}\n\n`,
    ))
    const header = () => mounted?.querySelector('.execute-output-drawer-header')?.textContent ?? ''
    emit({ type: 'snapshot', keeper: 'sangsu', closed: false, active_count: 1, lines: [],
      active_streams: [{ stream_id: 1, task_id: 'task-a', command: 'a', started_at: 1 }] })
    emit({ type: 'gap', keeper: 'sangsu', missing_from_seq: 2, missing_to_seq: 4, missing_count: 3 })
    emit({ type: 'line', keeper: 'sangsu', stream_id: 1, task_id: 'task-a', closed: false,
      line: { stream: 'stdout', text: 'later output' } })
    await waitFor(() => expect(header()).toContain('history incomplete'))
    expect(header()).toContain('streaming')
    emit({ type: 'task_closed', keeper: 'sangsu', stream_id: 1, task_id: 'task-a',
      closed: true, active_count: 0, status: { kind: 'exit', code: 0 } })
    await waitFor(() => expect(header()).toContain('unknown'))
    expect(header()).not.toContain('closed')
    expect(header()).not.toContain('task-a')
    expect(mounted.textContent).toContain('missed 3 output entries')
    expect(mounted.textContent).toContain('Execute exited with code 0 (stream 1, task task-a)')
  })

  it('restores retained per-execution outcomes from a reconnect snapshot', async () => {
    const event = { type: 'snapshot', keeper: 'sangsu', task_id: 'task-b', closed: true,
      active_count: 0, active_streams: [], status: { kind: 'exit', code: 0 }, lines: [
        { stream: 'status', stream_id: 1, task_id: 'task-a', text: '{"outcome":"unknown"}' },
        { stream: 'status', stream_id: 2, task_id: 'task-b', text: '{"kind":"exit","code":0}' },
      ] }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      `event: output\ndata: ${JSON.stringify(event)}\n\n`,
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => expect(mounted?.querySelector('[data-status-chip-tone="warn"]')?.textContent).toBe('unknown'))
    const header = mounted.querySelector('.execute-output-drawer-header')?.textContent ?? ''
    expect(header).not.toContain('task-b')
    const terminal = mounted.querySelector('[data-terminal]')?.textContent ?? ''
    expect(terminal).toContain('Execute result unknown (stream 1, task task-a)')
    expect(terminal.match(/Execute exited with code 0 \(stream 2, task task-b\)/g)).toHaveLength(1)
  })

  it('restores an unknown prior result while a different execution is active', async () => {
    const event = { type: 'snapshot', keeper: 'sangsu', task_id: 'task-b', closed: false,
      active_count: 1, active_streams: [{ stream_id: 2, task_id: 'task-b', command: 'b', started_at: 2 }],
      lines: [{ stream: 'status', stream_id: 1, task_id: 'task-a', text: '{"outcome":"unknown"}' }] }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      openStream(`event: output\ndata: ${JSON.stringify(event)}\n\n`),
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => expect(mounted?.textContent).toContain('unconfirmed result'))
    const header = mounted.querySelector('.execute-output-drawer-header')?.textContent ?? ''
    expect(header).toContain('streaming')
    expect(header).toContain('task-b')
    expect(mounted.textContent).toContain('Execute result unknown (stream 1, task task-a)')
  })

  it('says history is incomplete when the snapshot omits retained lines', async () => {
    const event = { type: 'snapshot', keeper: 'sangsu', task_id: 'task-b', closed: true,
      active_count: 0, active_streams: [], lines_omitted: 3, status: { kind: 'exit', code: 0 },
      lines: [{ stream: 'status', stream_id: 2, task_id: 'task-b', text: '{"kind":"exit","code":0}' }] }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      `event: output\ndata: ${JSON.stringify(event)}\n\n`,
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => expect(mounted?.textContent).toContain('history incomplete'))
    expect(mounted.textContent).toContain('3 earlier output lines omitted from this view')
    expect(mounted.textContent).toContain('Execute exited with code 0 (stream 2, task task-b)')
    expect(mounted.textContent).not.toContain('Execute result unknown')
  })

  it('says history is incomplete when the server has evicted earlier events', async () => {
    const event = { type: 'snapshot', keeper: 'sangsu', task_id: 'task-b', closed: true,
      active_count: 0, active_streams: [], first_retained_seq: 9, status: { kind: 'exit', code: 0 },
      lines: [{ stream: 'status', stream_id: 2, task_id: 'task-b', text: '{"kind":"exit","code":0}' }] }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      `event: output\ndata: ${JSON.stringify(event)}\n\n`,
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    await waitFor(() => expect(mounted?.textContent).toContain('history incomplete'))
    expect(mounted.textContent).toContain('earlier output events are no longer retained (before seq 9)')
    expect(mounted.textContent).not.toContain('Execute result unknown')
  })

  it('reports an interrupted new execution after an earlier one closed', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","closed":true,"lines":[]}\n\n' +
      'event: output\ndata: {"type":"task_opened","keeper":"sangsu","stream_id":7,"closed":false}\n\n',
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    )))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)
    await waitFor(() => expect(mounted?.textContent).toContain('output stream ended before the task closed'))
  })

  it('offers Stop only while live output is on', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(openStream(''), {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    })))
    const onStop = vi.fn()

    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu', onStop }), mounted)
    fireEvent.click(mounted.querySelector<HTMLButtonElement>('[data-testid="execute-output-stop"]')!)
    expect(onStop).toHaveBeenCalledTimes(1)

    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu', onStop, streamEnabled: false }), mounted)
    expect(mounted.querySelector('[data-testid="execute-output-stop"]')).toBeNull()
  })

  it('marks a gap and does not guess which task is active across missing events', async () => {
    let resolveFetch: (value: Response) => void = () => undefined
    const fetchPromise = new Promise<Response>(resolve => {
      resolveFetch = resolve
    })
    vi.stubGlobal('fetch', vi.fn().mockReturnValue(fetchPromise))

    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    resolveFetch(new Response(
      openStream([
        'event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-123","lines":[{"seq":1,"ts_ms":1000,"stream":"stdout","text":"first","ansi":false}],"last_seq":1,"closed":true}\n\n',
        'event: output\ndata: {"type":"line","keeper":"sangsu","seq":2,"task_id":"task-123","line":{"seq":2,"ts_ms":1001,"stream":"stdout","text":"second","ansi":false},"closed":false}\n\n',
        'event: output\ndata: {"type":"gap","keeper":"sangsu","missing_from_seq":3,"missing_to_seq":9,"missing_count":7}\n\n',
      ].join('')),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ))

    await waitFor(() =>
      expect(mounted?.textContent).toContain('missed 7 output entries the server no longer keeps (seq 3-9)'))
    const terminalLines = [...mounted.querySelectorAll('[data-testid="execute-output-terminal"] .term-line')]
      .map(line => line.textContent?.trim())
    expect(terminalLines).toEqual([
      'first',
      'second',
      'missed 7 output entries the server no longer keeps (seq 3-9)',
    ])
    expect(mounted.querySelector('.execute-output-drawer-header')?.textContent).not.toContain('task-123')
    expect(mounted.querySelector('[data-status-chip-tone="warn"]')?.textContent).toContain('unknown')
  })

  it('keeps the remaining task after another concurrent execution closes', async () => {
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined
    const body = new ReadableStream<Uint8Array>({ start(value) { controller = value } })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, {
      status: 200, headers: { 'Content-Type': 'text/event-stream' },
    })))
    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)
    const emit = (event: object) => controller!.enqueue(new TextEncoder().encode(
      `event: output\ndata: ${JSON.stringify(event)}\n\n`,
    ))
    const header = () => mounted?.querySelector('.execute-output-drawer-header')?.textContent ?? ''
    emit({ type: 'snapshot', keeper: 'sangsu', closed: false, active_count: 2,
      task_id: 'task-b', lines: [], active_streams: [
        { stream_id: 1, task_id: 'task-a', command: 'a', started_at: 1 },
        { stream_id: 2, task_id: 'task-b', command: 'b', started_at: 2 },
      ] })
    await waitFor(() => expect(header()).not.toContain('task-b'))
    emit({ type: 'line', keeper: 'sangsu', stream_id: 1, task_id: 'task-a', closed: false,
      line: { stream: 'stdout', text: 'from a' } })
    await waitFor(() => expect(mounted?.textContent).toContain('from a'))
    expect(header()).not.toContain('task-a')
    emit({ type: 'task_closed', keeper: 'sangsu', stream_id: 1, task_id: 'task-a',
      closed: false, active_count: 1, status: { code: 0 } })
    await waitFor(() => expect(header()).toContain('task-b'))
    expect(header()).not.toContain('task-a')
    emit({ type: 'line', keeper: 'sangsu', stream_id: 2, task_id: 'task-b', closed: false,
      line: { stream: 'stdout', text: 'from b' } })
    await waitFor(() => expect(mounted?.textContent).toContain('from b'))
    expect(header()).toContain('task-b')
  })

  it('renders Execute output context links and routes back into task context', async () => {
    tasks.value = [{
      id: 'task-123',
      title: 'Runtime task',
      goal_id: 'goal-ide',
      status: 'in_progress',
    }]
    let resolveFetch: (value: Response) => void = () => undefined
    const fetchPromise = new Promise<Response>(resolve => {
      resolveFetch = resolve
    })
    vi.stubGlobal('fetch', vi.fn().mockReturnValue(fetchPromise))

    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)

    resolveFetch(new Response(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-123","stdout_since":"one\\n","stderr_since":"","closed":false}\n\n',
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ))

    await waitFor(() => expect(mounted?.textContent).toContain('task-123'))
    const routeLinks = [...mounted.querySelectorAll<HTMLButtonElement>('.execute-output-context-links button')]
    expect(routeLinks.map(link => link.textContent)).toEqual([
      'Goal',
      'Task',
      'Telemetry',
      'Keeper',
    ])
    const badge = mounted.querySelector<HTMLElement>('.execute-output-context-badge')
    expect(badge?.textContent?.trim()).toBe('CTX 4')
    expect(badge?.getAttribute('data-context-route-count')).toBe('4')
    expect(badge?.getAttribute('title')).toBe('Linked context: Goal, Task, Telemetry, Keeper')
    expect(badge?.getAttribute('aria-label'))
      .toBe('Execute output has 4 linked context routes: Goal, Task, Telemetry, Keeper')

    fireEvent.click(routeLinks.find(link => link.textContent === 'Task')!)
    expect(window.location.hash).toBe('#workspace?section=planning&view=default&task=task-123')
  })

  it('does not auto-scroll when reduced motion is preferred', async () => {
    let resolveFetch: (value: Response) => void = () => undefined
    const fetchPromise = new Promise<Response>(resolve => {
      resolveFetch = resolve
    })
    const fetchMock = vi.fn().mockReturnValue(fetchPromise)
    vi.stubGlobal('fetch', fetchMock)
    vi.stubGlobal('matchMedia', vi.fn().mockReturnValue({
      matches: true,
      media: '(prefers-reduced-motion: reduce)',
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }))

    mounted = document.createElement('div')
    render(h(ExecuteOutputDrawer, { keeperName: 'sangsu' }), mounted)
    const log = mounted.querySelector('[role="log"]') as HTMLDivElement
    log.scrollTop = 17

    resolveFetch(new Response(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","stdout_since":"fresh\\n","stderr_since":"","closed":false}\n\n',
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ))

    await waitFor(() => expect(mounted?.textContent).toContain('fresh'))
    expect(log.scrollTop).toBe(17)
  })
})
