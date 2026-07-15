import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { tasks } from '../../store'
import { cursorOverlaySignal } from './keeper-cursor-overlay'
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
  cursorOverlaySignal.value = {
    cursors: new Map(),
    heatmap: new Map(),
    collisions: [],
    active_file: null,
  }
  window.location.hash = ''
  vi.unstubAllGlobals()
})

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

  it('builds operational routes from Execute output task, cursor, and keeper', () => {
    const links = executeOutputRouteLinks({
      keeperName: 'sangsu',
      taskId: 'task-123',
      taskList: [{
        id: 'task-123',
        title: 'Runtime task',

      }],
      cursor: {
        keeper_id: 'sangsu',
        file_path: 'lib/runtime.ml',
        line: 42,
        column: 3,
        focus_mode: 'editing',
        last_update: Date.now(),
        tool_name: 'ocamllsp',
      },
    })

    expect(links.map(link => link.label)).toEqual([
      'Code',
      'Task',
      'Telemetry',
      'Keeper',
    ])
    expect(links.find(link => link.label === 'Code')).toMatchObject({
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/runtime.ml',
        line: '42',
        surface: 'Terminal',
        label: 'Execute output task-123',
        source_id: 'execute-output:sangsu:task-123',
        keeper: 'sangsu',
      },
      evidence: 'Code lib/runtime.ml:42',
    })
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

    resolveFetch(new Response(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-123","stdout_since":"one\\ntwo\\n","stderr_since":"warn\\n","bytes_dropped_stdout":12,"bytes_dropped_stderr":3,"closed":false}\n\n',
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

  it('renders Execute output context links and routes back into code and task context', async () => {
    tasks.value = [{
      id: 'task-123',
      title: 'Runtime task',

      status: 'in_progress',
    }]
    cursorOverlaySignal.value = {
      cursors: new Map([['sangsu', {
        keeper_id: 'sangsu',
        file_path: 'lib/runtime.ml',
        line: 42,
        column: 3,
        focus_mode: 'editing',
        last_update: Date.now(),
        tool_name: 'ocamllsp',
      }]]),
      heatmap: new Map(),
      collisions: [],
      active_file: 'lib/runtime.ml',
    }
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
      'Code',
      'Task',
      'Telemetry',
      'Keeper',
    ])
    const badge = mounted.querySelector<HTMLElement>('.execute-output-context-badge')
    expect(badge?.textContent?.trim()).toBe('CTX 4')
    expect(badge?.getAttribute('data-context-route-count')).toBe('4')
    expect(badge?.getAttribute('title')).toBe('Linked context: Code, Task, Telemetry, Keeper')
    expect(badge?.getAttribute('aria-label'))
      .toBe('Execute output has 4 linked context routes: Code, Task, Telemetry, Keeper')

    fireEvent.click(routeLinks.find(link => link.textContent === 'Code')!)
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=42&surface=Terminal&label=Execute+output+task-123&source_id=execute-output%3Asangsu%3Atask-123&keeper=sangsu')

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
