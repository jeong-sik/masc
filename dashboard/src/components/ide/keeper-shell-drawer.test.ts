import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { tasks } from '../../store'
import { cursorOverlaySignal } from './keeper-cursor-overlay'
import {
  KeeperShellDrawer,
  keeperShellRouteLinks,
  linesFromShellEvent,
  summarizeShellLines,
} from './keeper-shell-drawer'

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

describe('KeeperShellDrawer event mapping', () => {
  it('maps stdout and stderr chunks to terminal lines', () => {
    const lines = linesFromShellEvent({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'one\ntwo\n',
      stderr_since: 'warn\n',
      closed: false,
    })

    expect(lines.map(line => line.text)).toEqual(['one', 'two', 'warn'])
    expect(lines.map(line => line.stream)).toEqual(['stdout', 'stdout', 'stderr'])
  })

  it('surfaces dropped byte evidence as a meta line', () => {
    const lines = linesFromShellEvent({
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
    const summary = summarizeShellLines([
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

  it('builds operational routes from shell task, goal, git branch, cursor, and keeper', () => {
    const links = keeperShellRouteLinks({
      keeperName: 'sangsu',
      taskId: 'task-123',
      taskList: [{
        id: 'task-123',
        title: 'Runtime task',
        goal_id: 'goal-ide',
        worktree: {
          branch: 'feat/runtime',
          path: '/tmp/runtime',
          git_root: '/tmp/runtime',
          repo_name: 'masc-mcp',
        },
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
      'Goal',
      'Task',
      'Git',
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
        label: 'keeper shell task-123',
        source_id: 'keeper-shell:sangsu:task-123',
        keeper: 'sangsu',
      },
      evidence: 'Code lib/runtime.ml:42',
    })
    expect(links.find(link => link.label === 'Telemetry')).toMatchObject({
      params: { section: 'fleet-health', view: 'event-log', q: 'task-123' },
      evidence: 'Fleet telemetry event log · query task-123',
    })
  })

  it('renders shell output through the shared terminal molecule', async () => {
    mounted = document.createElement('div')
    render(h(KeeperShellDrawer, { keeperName: '' }), mounted)

    await waitFor(() => expect(mounted?.textContent).toContain('no keeper selected'))
    const terminal = mounted.querySelector('[data-terminal][data-testid="keeper-shell-terminal"]')
    expect(terminal?.getAttribute('aria-label')).toBe('Keeper shell terminal')
    expect(terminal?.querySelector('.term-line.is-meta')?.textContent).toContain('no keeper selected')
    expect(mounted.querySelector('[data-testid="keeper-shell-summary"]')?.textContent).toContain('1 line')
    expect(mounted.querySelector('[data-status-chip-tone="neutral"]')?.textContent).toContain('idle')
  })

  it('renders streaming summary chips for stdout, stderr, and dropped bytes', async () => {
    let resolveFetch: (value: Response) => void = () => undefined
    const fetchPromise = new Promise<Response>(resolve => {
      resolveFetch = resolve
    })
    const fetchMock = vi.fn().mockReturnValue(fetchPromise)
    vi.stubGlobal('fetch', fetchMock)

    mounted = document.createElement('div')
    render(h(KeeperShellDrawer, { keeperName: 'sangsu' }), mounted)

    resolveFetch(new Response(
      'event: shell\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-123","stdout_since":"one\\ntwo\\n","stderr_since":"warn\\n","bytes_dropped_stdout":12,"bytes_dropped_stderr":3,"closed":false}\n\n',
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ))

    await waitFor(() => expect(mounted?.textContent).toContain('task-123'))
    const summary = mounted.querySelector('[data-testid="keeper-shell-summary"]')
    expect(summary?.getAttribute('role')).toBeNull()
    expect(summary?.getAttribute('aria-label')).toContain('4 lines, 2 stdout, 1 stderr, 1 meta')
    expect(summary?.getAttribute('aria-label')).toContain('15 dropped bytes')
    expect(summary?.textContent).toContain('stdout 2')
    expect(summary?.textContent).toContain('stderr 1')
    expect(summary?.textContent).toContain('dropped 15B')
    expect(mounted.querySelector('[data-status-chip-tone="info"]')?.textContent).toContain('streaming')
    expect(mounted.querySelector('[data-status-chip-tone="bad"]')?.textContent).toContain('stderr 1')
  })

  it('renders shell context links and routes back into code and task context', async () => {
    tasks.value = [{
      id: 'task-123',
      title: 'Runtime task',
      goal_id: 'goal-ide',
      status: 'in_progress',
      worktree: {
        branch: 'feat/runtime',
        path: '/tmp/runtime',
        git_root: '/tmp/runtime',
        repo_name: 'masc-mcp',
      },
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
    render(h(KeeperShellDrawer, { keeperName: 'sangsu' }), mounted)

    resolveFetch(new Response(
      'event: shell\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"task-123","stdout_since":"one\\n","stderr_since":"","closed":false}\n\n',
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ))

    await waitFor(() => expect(mounted?.textContent).toContain('task-123'))
    const routeLinks = [...mounted.querySelectorAll<HTMLButtonElement>('.keeper-shell-context-links button')]
    expect(routeLinks.map(link => link.textContent)).toEqual([
      'Code',
      'Goal',
      'Task',
      'Git',
      'Telemetry',
      'Keeper',
    ])

    fireEvent.click(routeLinks.find(link => link.textContent === 'Code')!)
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=42&surface=Terminal&label=keeper+shell+task-123&source_id=keeper-shell%3Asangsu%3Atask-123&keeper=sangsu')

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
    render(h(KeeperShellDrawer, { keeperName: 'sangsu' }), mounted)
    const log = mounted.querySelector('[role="log"]') as HTMLDivElement
    log.scrollTop = 17

    resolveFetch(new Response(
      'event: shell\ndata: {"type":"snapshot","keeper":"sangsu","stdout_since":"fresh\\n","stderr_since":"","closed":false}\n\n',
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ))

    await waitFor(() => expect(mounted?.textContent).toContain('fresh'))
    expect(log.scrollTop).toBe(17)
  })
})
