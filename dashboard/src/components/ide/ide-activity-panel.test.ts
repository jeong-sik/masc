import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render as preactRender } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { deriveIdeRunProgressSummary, IdeActivityPanel } from './ide-activity-panel'
import { focusIdeFile, ideContextFocus } from './ide-state'
import { lspDiagnosticSnapshot } from './ide-lsp-client'
import { clearTraces, keeperTraceState } from './keeper-trace-store'
import { goals, tasks } from '../../store'

const renderedContainers = new Set<Parameters<typeof preactRender>[1]>()

const render = (...args: Parameters<typeof preactRender>): ReturnType<typeof preactRender> => {
  renderedContainers.add(args[1])
  return preactRender(...args)
}

function stubEmptyActivityFetch(): void {
  vi.stubGlobal('fetch', vi.fn(async () =>
    new Response(JSON.stringify({ events: [] }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  ))
}

beforeEach(() => {
  stubEmptyActivityFetch()
  clearTraces()
})

afterEach(() => {
  for (const container of renderedContainers) preactRender(null, container)
  renderedContainers.clear()
  vi.useRealTimers()
  vi.unstubAllGlobals()
  ideContextFocus.value = null
  lspDiagnosticSnapshot.value = new Map()
  focusIdeFile({
    path: 'package.json',
    origin: 'operator',
    workspace_identity: { kind: 'project' },
    availability: 'available',
  })
  goals.value = []
  tasks.value = []
  window.location.hash = ''
  clearTraces()
})

describe('IdeActivityPanel', () => {
  it.each([false, true])('shows persisted workspace totals separately from the loaded window (compact=%s)', async compact => {
    const events = Array.from({ length: 50 }, (_, index) => ({
      seq: index + 1923, ts_ms: Date.now(), workspace_id: 'workspace', kind: 'task.created',
    }))
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ events, total_matching_events: 1972 }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })))
    const container = document.createElement('div')
    render(h(IdeActivityPanel, { compact }), container)
    await waitFor(() => expect(container.querySelector('[data-testid="ide-workspace-history-window"]')?.textContent)
      .toContain('Workspace history: 50 of 1972 loaded'))
    expect(container.textContent).toContain('older events are not loaded')
  })

  it.each([undefined, -1, true, '1972'])('does not invent a total from invalid or missing metadata (%s)', async total => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ events: [], total_matching_events: total }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })))
    const container = document.createElement('div')
    render(h(IdeActivityPanel, {}), container)
    await waitFor(() => expect(container.textContent).toContain('Workspace history: 0 loaded · total unavailable'))
  })

  it('keeps global history and planning links while file anchors follow the real scoped IDE response', async () => {
    const requests: string[] = []
    vi.stubGlobal('fetch', vi.fn(async input => {
      const url = new URL(String(input), 'http://localhost')
      let payload: unknown
      if (url.pathname === '/api/v1/ide/events') {
        const scope = url.searchParams.get('codebase')!
        requests.push(scope)
        payload = { ok: true, data: { events: [{
          type: 'tool', keeper_id: 'scoped-keeper', turn_id: `turn-${scope}`,
          timestamp_ms: 2, tool_name: 'read_file', outcome: 'success', typed_outcome: 'progress',
          latency_ms: 1, summary: `observed ${scope}`, file_path: 'src/shared.ml',
        }] } }
      } else {
        payload = { events: [{
          seq: 1, ts_ms: 1, ts_iso: '2026-05-05T10:00:00Z', kind: 'task.noted',
          actor: { kind: 'keeper', id: 'global-keeper' }, subject: { kind: 'task', id: 'global-task' },
          payload: { file_path: 'src/shared.ml', line: 99, codebase: 'github.com_owner_a',
            summary: 'global same filename', goal_id: 'global-goal', task_id: 'global-task' }, tags: [],
        }] }
      }
      return new Response(JSON.stringify(payload), { status: 200, headers: { 'Content-Type': 'application/json' } })
    }))
    const container = document.createElement('div')
    const show = (codebase: string) => render(h(IdeActivityPanel, { codebase, activeFile: 'src/shared.ml' }), container)
    show('github.com_owner_a')
    await waitFor(() => expect(container.querySelector('[data-total-anchors]')?.getAttribute('data-total-anchors')).toBe('1'))
    expect(container.textContent).toContain('2 events')
    expect(container.querySelector('.ide-context-anchor-action')?.textContent).toContain('turn-github.com_owner_a')
    const globalRow = [...container.querySelectorAll('.ide-activity-row')].find(row => row.textContent?.includes('global same filename'))!
    expect(globalRow.querySelector('.ide-activity-context-jump')).toBeNull()
    expect([...globalRow.querySelectorAll('.ide-activity-route-link')].map(link => link.textContent)).toEqual(['Goal', 'Task', 'Telemetry', 'Keeper'])
    fireEvent.click(globalRow.querySelector<HTMLButtonElement>('[aria-label="Open Task global-task"]')!)
    expect(window.location.hash).toBe('#workspace?section=planning&view=default&task=global-task')
    const scopedJump = container.querySelector<HTMLButtonElement>('.ide-activity-context-jump')!
    fireEvent.click(scopedJump)
    expect(ideContextFocus.value).toMatchObject({ file_path: 'src/shared.ml' })
    expect(ideContextFocus.value?.line).toBeUndefined()
    show('github.com_owner_b')
    expect(container.querySelector('.ide-context-anchor-action')).toBeNull()
    await waitFor(() => expect(container.querySelector('.ide-context-anchor-action')?.textContent).toContain('turn-github.com_owner_b'))
    expect(container.querySelector('[data-total-anchors]')?.getAttribute('data-total-anchors')).toBe('1')
    expect(container.textContent).not.toContain('observed github.com_owner_a')
    expect(container.textContent).toContain('global same filename')
    expect(requests).toEqual(['github.com_owner_a', 'github.com_owner_b'])
  })

  it('renders the activity pane with empty state when no API data', () => {
    const container = document.createElement('div')
    render(h(IdeActivityPanel, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('EVENT TIMELINE')
    expect(container.textContent).toContain('0 events · 0 keepers')
    expect(container.querySelector('[data-testid="ide-context-lens"]')).not.toBeNull()
    expect(container.textContent).toContain('RUN PROGRESS')
    expect(container.textContent).toContain('0/0 linked')
    expect(container.querySelector('[role="progressbar"]')?.getAttribute('aria-valuenow')).toBe('0')
    expect(container.textContent).toContain('no keeper activity')
  })

  it('shows a no-scope message instead of "no recent activity" when codebase is absent', async () => {
    const container = document.createElement('div')
    render(h(IdeActivityPanel, {}), container)

    await waitFor(() => {
      const notice = container.querySelector('[data-testid="ide-activity-no-scope"]')
      expect(notice?.textContent).toBe('관측 스코프(저장소/keeper)가 선택되지 않았습니다')
    })
    expect(container.textContent).not.toContain('no recent activity')
  })

  it('shows "no recent activity" (not the no-scope message) when a scoped fetch genuinely finds nothing', async () => {
    vi.stubGlobal('fetch', vi.fn(async input => {
      const url = String(input)
      if (url.includes('/api/v1/ide/events')) {
        return new Response(JSON.stringify({ ok: true, data: { events: [] } }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ events: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { codebase: 'github.com_x_masc' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('no recent activity')
    })
    expect(container.querySelector('[data-testid="ide-activity-no-scope"]')).toBeNull()
  })

  it('hides the previous repository snapshot immediately when scope is cleared', async () => {
    let activityCalls = 0
    let resolveUnscopedGraph: ((response: Response) => void) | null = null
    vi.stubGlobal('fetch', vi.fn(async input => {
      const url = String(input)
      if (url.includes('/api/v1/ide/events')) {
        return new Response(JSON.stringify({
          ok: true,
          data: {
            events: [{
              type: 'turn',
              keeper_id: 'repo-a-keeper',
              turn_id: 'turn-repo-a',
              phase: 'completed',
              timestamp_ms: 100,
            }],
          },
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      activityCalls += 1
      if (activityCalls === 1) {
        return new Response(JSON.stringify({ events: [] }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Promise<Response>(resolve => {
        resolveUnscopedGraph = resolve
      })
    }))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { codebase: 'github.com_x_repo-a' }), container)
    await waitFor(() => expect(container.querySelector('[aria-label="Open Log turn-repo-a"]')).not.toBeNull())

    render(h(IdeActivityPanel, {}), container)
    expect(container.querySelector('[aria-label="Open Log turn-repo-a"]')).toBeNull()
    expect(container.querySelector('[data-testid="ide-activity-no-scope"]')).not.toBeNull()

    await waitFor(() => expect(resolveUnscopedGraph).not.toBeNull())
    resolveUnscopedGraph!(new Response(JSON.stringify({ events: [] }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }))
    await waitFor(() => {
      expect(container.querySelector('.ide-activity-refresh-status')?.textContent).toBe('loaded')
    })
  })

  it('does not expose repository A events while repository B is loading', async () => {
    let resolveRepoB: ((response: Response) => void) | null = null
    vi.stubGlobal('fetch', vi.fn(async input => {
      const url = String(input)
      if (url.includes('/api/v1/activity/events')) {
        return new Response(JSON.stringify({ events: [] }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.includes('codebase=github.com_x_repo-a')) {
        return new Response(JSON.stringify({
          ok: true,
          data: {
            events: [{
              type: 'turn',
              keeper_id: 'repo-a-keeper',
              turn_id: 'turn-repo-a',
              phase: 'completed',
              timestamp_ms: 100,
            }],
          },
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.includes('codebase=github.com_x_repo-b')) {
        return new Promise<Response>(resolve => {
          resolveRepoB = resolve
        })
      }
      throw new Error(`unexpected fetch ${url}`)
    }))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { codebase: 'github.com_x_repo-a' }), container)
    await waitFor(() => expect(container.querySelector('[aria-label="Open Log turn-repo-a"]')).not.toBeNull())

    render(h(IdeActivityPanel, { codebase: 'github.com_x_repo-b' }), container)
    expect(container.querySelector('[aria-label="Open Log turn-repo-a"]')).toBeNull()
    await waitFor(() => expect(resolveRepoB).not.toBeNull())

    resolveRepoB!(new Response(JSON.stringify({
      ok: true,
      data: {
        events: [{
          type: 'turn',
          keeper_id: 'repo-b-keeper',
          turn_id: 'turn-repo-b',
          phase: 'completed',
          timestamp_ms: 200,
        }],
      },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))

    await waitFor(() => expect(container.querySelector('[aria-label="Open Log turn-repo-b"]')).not.toBeNull())
    expect(container.querySelector('[aria-label="Open Log turn-repo-a"]')).toBeNull()
  })

  it('treats a null active file as no active file', () => {
    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: null }), container)

    expect(container.querySelector('[role="region"]')?.getAttribute('aria-label')).toBe('EVENT TIMELINE')
    expect(container.textContent).toContain('0 events · 0 keepers')
  })

  it('renders file context from diff props', () => {
    const container = document.createElement('div')
    render(h(IdeActivityPanel, {
      activeFile: 'lib/runtime.ml',
      diffRows: [{ kind: 'add', oldLine: null, newLine: 4, text: '+let x = 1' }],
    }), container)

    expect(container.textContent).toContain('CONTEXT LENS')
    expect(container.textContent).toContain('runtime.ml')
    expect(container.textContent).toContain('1 changed rows')
  })

  it('renders current-file LSP diagnostics in the context lens', () => {
    lspDiagnosticSnapshot.value = new Map([[
      'lib/runtime.ml',
      [{
        file_path: 'lib/runtime.ml',
        line: 6,
        severity: 1,
        source: 'ocamllsp',
        code: 'type',
        message: 'Type mismatch in keeper progress projection',
      }],
    ]])
    const container = document.createElement('div')

    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    expect(container.textContent).toContain('Type mismatch in keeper progress projection')
    expect(container.textContent).toContain('1 line anchors')
    const button = container.querySelector<HTMLButtonElement>('.ide-context-anchor-action')
    fireEvent.click(button!)
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 6,
      surface: 'LSP',
    })
  })

  it('keeps global activity operational links without claiming file context', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'log', id: 'turn-1' },
          payload: {
            file_path: 'lib/runtime.ml',
            line: 4,
            goal_id: 'goal-runtime',
            comment_id: 'comment-1',
            pr_number: 15000,
            session_id: 'sess-runtime',
            operation_id: 'op-runtime',
          },
          tags: ['task:task-runtime', 'board:post-1', 'comment:comment-1', 'git:main', 'log:turn-1', 'worker:wr-runtime'],
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('0 line anchors')
      expect(container.textContent).toContain('1/1 linked')
    })
    expect(container.querySelector('[role="progressbar"]')?.getAttribute('aria-valuenow')).toBe('100')

    const surfaces = [...container.querySelectorAll('.ide-run-progress-surfaces > span')]
      .map(node => node.textContent)
    expect(surfaces).toEqual([
      'Goal1',
      'Task1',
      'Board1',
      'Comment1',
      'PR1',
      'Git1',
      'Log1',
      'Session1',
      'Operation1',
      'Run1',
      'Telemetry1',
    ])

    const surfaceLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-run-progress-surface-link')]
    expect(surfaceLinks.every(link => link.classList.contains('v2-ide-action'))).toBe(true)
    expect(surfaceLinks.map(link => link.textContent)).toEqual([
      'Goal1',
      'Task1',
      'Board1',
      'Comment1',
      'PR1',
      'Git1',
      'Log1',
      'Session1',
      'Operation1',
      'Run1',
      'Telemetry1',
    ])
    fireEvent.click(surfaceLinks.find(link => link.textContent === 'PR1')!)
    expect(window.location.hash).toBe('#workspace?section=repositories&pr=15000')
    fireEvent.click(surfaceLinks.find(link => link.textContent === 'Session1')!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&session_id=sess-runtime&operation_id=op-runtime&worker_run_id=wr-runtime&q=turn-1')
    fireEvent.click(surfaceLinks.find(link => link.textContent === 'Telemetry1')!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&session_id=sess-runtime&operation_id=op-runtime&worker_run_id=wr-runtime&q=turn-1')

    const keeperLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-run-progress-keeper-link')]
    expect(keeperLinks.every(link => link.classList.contains('v2-ide-action'))).toBe(true)
    expect(keeperLinks.map(link => link.getAttribute('aria-label'))).toEqual(['Open Keeper sangsu'])
    fireEvent.click(keeperLinks[0]!)
    expect(window.location.hash).toBe('#monitoring?section=agents&view=keepers&keeper=sangsu')

    const activityRows = [...container.querySelectorAll<HTMLLIElement>('.ide-activity-row')]
    expect(activityRows.every(row => row.classList.contains('v2-ide-row'))).toBe(true)

    const contextJump = container.querySelector<HTMLButtonElement>('.ide-activity-context-jump')
    expect(contextJump).toBeNull()

    const activityRouteLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-activity-route-link')]
    expect(activityRouteLinks.every(link => link.classList.contains('v2-ide-action'))).toBe(true)
    expect(container.querySelector('.ide-activity-route-count')?.textContent).toBe('CTX 9')
    expect(activityRouteLinks.map(link => link.textContent)).toEqual([
      'Goal',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ])
    fireEvent.click(activityRouteLinks.find(link => link.textContent === 'Telemetry')!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&session_id=sess-runtime&operation_id=op-runtime&worker_run_id=wr-runtime&q=turn-1')

    expect(keeperTraceState.value.events).toEqual([])
  })

  it('merges IDE bridge events into the activity timeline', async () => {
    vi.stubGlobal('fetch', vi.fn(async input => {
      const url = String(input)
      if (url.includes('/api/v1/ide/events')) {
        return new Response(JSON.stringify({
          ok: true,
          data: {
            events: [{
              type: 'tool',
              tool_name: 'execute',
              keeper_id: 'sangsu',
              turn_id: 'turn-bridge',
              outcome: 'success',
              typed_outcome: 'progress',
              latency_ms: 50,
              summary: 'updated runtime',
              file_path: 'lib/runtime.ml',
              timestamp_ms: 500,
            }],
          },
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response(JSON.stringify({ events: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))

    const container = document.createElement('div')
    // Bridge events are fetched only under an explicit scope: without a
    // repo or keeper lane the server rejects unscoped /api/v1/ide/events.
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml', codebase: 'github.com_x_masc' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('tool:execute')
      expect(container.textContent).toContain('progress: updated runtime')
      expect(container.textContent).toContain('1/1 linked')
    })

    const jump = container.querySelector<HTMLButtonElement>('.ide-activity-context-jump')
    expect(jump?.textContent).toContain('runtime.ml')
    fireEvent.click(jump!)
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/runtime.ml',
      surface: 'Log',
      keeper_id: 'sangsu',
      source_id: 'ide-tool-turn-bridge-500-0',
    })
  })

  it('scopes IDE bridge activity events to the active repository', async () => {
    const ideEventUrls: string[] = []
    vi.stubGlobal('fetch', vi.fn(async input => {
      const url = String(input)
      if (url.includes('/api/v1/ide/events')) {
        ideEventUrls.push(url)
        return new Response(JSON.stringify({ ok: true, data: { events: [] } }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ events: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml', codebase: 'github.com_x_masc' }), container)

    await waitFor(() => expect(ideEventUrls).toHaveLength(1))
    const url = new URL(ideEventUrls[0]!, 'http://localhost')
    expect(url.pathname).toBe('/api/v1/ide/events')
    expect(url.searchParams.get('codebase')).toBe('github.com_x_masc')
    expect(url.searchParams.get('limit')).toBe('50')
  })

  it('shows linked context coverage for mixed activity events', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [
          {
            seq: 1,
            ts_ms: 100,
            ts_iso: '2026-05-05T10:00:00Z',
            workspace_id: 'run-default',
            kind: 'telemetry.turn',
            actor: { kind: 'keeper', id: 'sangsu' },
            subject: { kind: 'log', id: 'turn-1' },
            payload: {
              log_id: 'turn-1',
            },
            tags: [],
          },
          {
            seq: 2,
            ts_ms: 200,
            ts_iso: '2026-05-05T10:00:01Z',
            workspace_id: 'run-default',
            kind: 'keeper.note',
            actor: { kind: 'keeper', id: 'analyst' },
            subject: { kind: 'note', id: 'note-1' },
            payload: {
              summary: 'unlinked note',
            },
            tags: [],
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('1/2 linked')
      expect(container.textContent).toContain('50%')
    })
    const coverage = container.querySelector('[role="progressbar"]')
    expect(coverage?.getAttribute('aria-label')).toBe('Linked context coverage 1 of 2 events')
    expect(coverage?.getAttribute('aria-valuenow')).toBe('50')
  })

  it('maps nested activity context and evidence refs into IDE route links', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'log', id: 'turn-8' },
          payload: {
            context: {
              goal_id: 'goal-runtime',
              task_id: 'task-runtime',
              board_post_id: 'post-1',
              comment_id: 'comment-1',
            },
            failure_envelope: {
              evidence_ref: {
                file_path: 'lib/runtime.ml',
                line_start: 8,
                pr_number: 15008,
                branch: 'feat/runtime',
                log_id: 'turn-8',
                session_id: 'sess-nested',
                operation_id: 'op-nested',
                worker_run_id: 'wr-nested',
              },
            },
          },
          tags: [],
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.querySelectorAll('.ide-activity-row')).toHaveLength(1)
      expect(container.textContent).toContain('0 line anchors')
    })

    const activityRouteLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-activity-route-link')]
    expect(container.querySelector('.ide-activity-route-count')?.textContent).toBe('CTX 9')
    expect(activityRouteLinks.map(link => link.textContent)).toEqual([
      'Goal',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ])

    fireEvent.click(activityRouteLinks.find(link => link.textContent === 'Telemetry')!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&session_id=sess-nested&operation_id=op-nested&worker_run_id=wr-nested&q=turn-8')
  })

  it('refreshes activity events when polling is enabled', async () => {
    vi.useFakeTimers()
    const activityResponses = [
      {
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'log', id: 'turn-1' },
          payload: {
            file_path: 'lib/runtime.ml',
            line: 4,
            log_id: 'turn-1',
          },
          tags: [],
        }],
      },
      {
        events: [{
          seq: 2,
          ts_ms: 200,
          ts_iso: '2026-05-05T10:00:10Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'analyst' },
          subject: { kind: 'log', id: 'turn-2' },
          payload: {
            file_path: 'lib/runtime.ml',
            line: 8,
            goal_id: 'goal-refresh',
            log_id: 'turn-2',
          },
          tags: [],
        }],
      },
    ]
    let activityIndex = 0
    const fetchMock = vi.fn(async input => {
      const url = String(input)
      if (url.includes('/api/v1/ide/events')) {
        return new Response(JSON.stringify({ ok: true, data: { events: [] } }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      const body = activityResponses[Math.min(activityIndex, activityResponses.length - 1)]
      activityIndex += 1
      return new Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    })
    vi.stubGlobal('fetch', fetchMock)

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml', pollMs: 1_000 }), container)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('turn-1')
    })
    // Without a repo or keeper-lane scope there is no bridge fetch: the
    // server rejects unscoped /api/v1/ide/events, so only the activity
    // graph is polled (one call per load).
    expect(fetchMock).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(1_000)
    await vi.waitFor(() => {
      expect(container.querySelector('[aria-label="Open Goal goal-refresh"]')).not.toBeNull()
    })
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(container.textContent).toContain('turn-2')
    expect(container.textContent).not.toContain('turn-1')

    render(null, container)
  })

  it('keeps the last activity snapshot when a refresh fails', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-05-05T10:00:00Z'))
    let activityCalls = 0
    const fetchMock = vi.fn(async input => {
      const url = String(input)
      if (url.includes('/api/v1/ide/events')) {
        return new Response(JSON.stringify({ ok: true, data: { events: [] } }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      activityCalls += 1
      if (activityCalls === 1) {
        return new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'log', id: 'turn-stable' },
          payload: {
            file_path: 'lib/runtime.ml',
            line: 4,
            log_id: 'turn-stable',
          },
          tags: [],
        }],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response('unavailable', { status: 503 })
    })
    vi.stubGlobal('fetch', fetchMock)

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml', pollMs: 1_000 }), container)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('turn-stable')
    })
    expect(container.querySelector('.ide-activity-refresh-status')?.textContent).toBe('live')

    vi.setSystemTime(new Date('2026-05-05T10:00:10Z'))
    await vi.advanceTimersByTimeAsync(1_000)
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalledTimes(2)
    })

    expect(container.textContent).toContain('turn-stable')
    expect(container.textContent).toContain('1 events · 1 keepers')
    expect(container.querySelector('.ide-activity-refresh-status')?.textContent).toBe('stale 1 failed')

    render(null, container)
  })

  it('surfaces offline refresh state when the activity API is unavailable before any snapshot', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('unavailable', { status: 503 })))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.querySelector('.ide-activity-refresh-status')?.textContent).toBe('offline 1 failed')
    })
    // No codebase was passed: the empty list explains the missing
    // scope rather than claiming "no recent activity" (which would imply
    // a real, merely-empty fetch happened).
    expect(container.querySelector('[data-testid="ide-activity-no-scope"]')).not.toBeNull()
  })

  it('renders active run goal progress from activity goal and task links', async () => {
    goals.value = [{
      id: 'goal-runtime',
      title: 'Runtime goal',
      metric: 'green CI',
      target_value: 'merged',
      priority: 1,
      phase: 'executing',
      created_at: '2026-05-05T09:00:00Z',
      updated_at: '2026-05-05T09:30:00Z',
    }]
    tasks.value = [
      { id: 'task-runtime-a', title: 'Done runtime task', goal_id: 'goal-runtime', status: 'done' },
      { id: 'task-runtime-b', title: 'Open runtime task', goal_id: 'goal-runtime', status: 'in_progress' },
    ]
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'task', id: 'task-runtime-b' },
          payload: {
            goal_id: 'goal-runtime',
            task_id: 'task-runtime-b',
            log_id: 'turn-1',
          },
          tags: [],
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('GOAL TRACK')
      expect(container.textContent).toContain('Runtime goal')
      expect(container.textContent).toContain('1/2 tasks')
      expect(container.textContent).not.toContain('50%')
    })

    const goalLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-run-progress-goal-links button')]
    expect(goalLinks.every(link => link.classList.contains('v2-ide-action'))).toBe(true)
    expect(goalLinks.map(link => link.textContent)).toEqual(['Goal', 'Task'])

    fireEvent.click(goalLinks[0]!)
    expect(window.location.hash).toBe('#workspace?section=planning&goal=goal-runtime')

    fireEvent.click(goalLinks[1]!)
    expect(window.location.hash).toBe('#workspace?section=planning&view=default&task=task-runtime-b')
  })

  it('ignores non-positive numeric payload ids when deriving context links', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'log', id: 'turn-1' },
          payload: {
            file_path: 'lib/runtime.ml',
            line: 4,
            comment_number: 0,
            pr_number: 0,
            log_id: 'turn-1',
          },
          tags: [],
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      const surfaces = [...container.querySelectorAll('.ide-run-progress-surfaces > span')]
        .map(node => node.textContent)
      expect(surfaces).toEqual([
        'Goal0',
        'Task0',
        'Board0',
        'Comment0',
        'PR0',
        'Git0',
        'Log1',
        'Session0',
        'Operation0',
        'Run0',
        'Telemetry1',
      ])
    })
  })

  it('does not focus the active file for unscoped activity lines', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          workspace_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'log', id: 'turn-1' },
          payload: {
            line: 42,
            log_id: 'turn-1',
          },
          tags: [],
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('telemetry.turn')
    })
    expect(container.querySelector('.ide-activity-context-jump')).toBeNull()
    expect(container.querySelector('.ide-activity-route-count')?.textContent).toBe('CTX 3')
    expect([...container.querySelectorAll<HTMLButtonElement>('.ide-activity-route-link')]
      .map(link => link.textContent)).toEqual(['Log', 'Telemetry', 'Keeper'])
    fireEvent.click(container.querySelectorAll<HTMLButtonElement>('.ide-activity-route-link')[1]!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=turn-1')
  })

  it('does not infer codebase authority from global activity paths or tags', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [
          {
            seq: 1,
            ts_ms: 100,
            ts_iso: '2026-05-05T10:00:00Z',
            workspace_id: 'run-default',
            kind: 'telemetry.turn',
            actor: { kind: 'keeper', id: 'sangsu' },
            subject: { kind: 'log', id: 'turn-1' },
            payload: {
              file_path: ' lib\\runtime.ml ',
              line: 4,
              log_id: 'turn-1',
            },
            tags: [],
          },
          {
            seq: 2,
            ts_ms: 90,
            ts_iso: '2026-05-05T10:00:01Z',
            workspace_id: 'run-default',
            kind: 'telemetry.turn',
            actor: { kind: 'keeper', id: 'sangsu' },
            subject: { kind: 'log', id: 'turn-2' },
            payload: {
              line: 7,
              log_id: 'turn-2',
            },
            tags: ['file:lib\\runtime.ml:7'],
          },
          {
            seq: 3,
            ts_ms: 80,
            ts_iso: '2026-05-05T10:00:02Z',
            workspace_id: 'run-default',
            kind: 'telemetry.turn',
            actor: { kind: 'keeper', id: 'sangsu' },
            subject: { kind: 'log', id: 'turn-3' },
            payload: {
              file_path: '/workspace/lib/runtime.ml',
              line: 9,
              log_id: 'turn-3',
            },
            tags: [],
          },
          {
            seq: 4,
            ts_ms: 70,
            ts_iso: '2026-05-05T10:00:03Z',
            workspace_id: 'run-default',
            kind: 'telemetry.turn',
            actor: { kind: 'keeper', id: 'sangsu' },
            subject: { kind: 'log', id: 'turn-4' },
            payload: {
              file_path: 'lib/payload.ml',
              line: 4,
              log_id: 'turn-4',
            },
            tags: ['file:/workspace/lib/other.ml:99'],
          },
        ],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityPanel, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('4 events')
    })

    expect(container.querySelectorAll('.ide-activity-context-jump')).toHaveLength(0)
    expect(container.querySelectorAll('[aria-label^="Open Code "]')).toHaveLength(0)
    expect(container.querySelectorAll('.ide-activity-row')).toHaveLength(4)
  })

  it('derives a compact run progress summary from activity events', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-05-05T10:01:30Z'))

    const events = [
      {
        id: 'evt-1',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted' as const,
        target: 'telemetry',
        timestamp_ms: Date.parse('2026-05-05T10:01:00Z'),
        context: {
          file_path: 'lib/runtime.ml',
          line: 4,
          goal_id: 'goal-runtime',
          task_id: 'task-runtime',
          log_id: 'turn-1',
        },
      },
      {
        id: 'evt-2',
        run_id: 'run-default',
        keeper_id: 'analyst',
        verb: 'committed' as const,
        target: 'git:main',
        timestamp_ms: Date.parse('2026-05-05T10:00:00Z'),
        context: {
          git_ref: 'main',
          pr_id: '15000',
        },
      },
      {
        id: 'evt-3',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'commented on' as const,
        target: 'board:post-1',
        timestamp_ms: Date.parse('2026-05-05T09:59:00Z'),
        context: {
          board_post_id: 'post-1',
          comment_id: 'comment-1',
        },
      },
    ]
    const summary = deriveIdeRunProgressSummary(
      events,
      'lib/runtime.ml',
      [{
        id: 'goal-runtime',
        title: 'Runtime goal',
        priority: 1,
        phase: 'executing',
        created_at: '2026-05-05T09:00:00Z',
        updated_at: '2026-05-05T09:30:00Z',
      }],
      [
        { id: 'task-runtime', title: 'Runtime task', goal_id: 'goal-runtime', status: 'done' },
        { id: 'task-followup', title: 'Runtime follow-up', goal_id: 'goal-runtime', status: 'todo' },
      ],
    )

    expect(summary).toMatchObject({
      totalEvents: 3,
      currentFileEvents: 0,
      linkedEvents: 3,
      linkedCoveragePercent: 100,
      linkedCoverageLabel: '100%',
      keeperTotalCount: 2,
      latestAgeLabel: '30s ago',
      activeGoal: {
        goalId: 'goal-runtime',
        taskId: 'task-runtime',
        title: 'Runtime goal',
        progress: { done: 1, total: 2, ratio: 0.5 },
        progressLabel: '1/2 tasks',
      },
    })
    expect(summary.surfaceCounts.map(surface => [surface.label, surface.count])).toEqual([
      ['Goal', 1],
      ['Task', 1],
      ['Board', 1],
      ['Comment', 1],
      ['PR', 1],
      ['Git', 1],
      ['Log', 1],
      ['Session', 0],
      ['Operation', 0],
      ['Run', 0],
      ['Telemetry', 3],
    ])
    expect(summary.surfaceCounts.find(surface => surface.label === 'PR')?.routeLink).toMatchObject({
      label: 'PR',
      params: { section: 'repositories', pr: '15000' },
    })
    expect(summary.surfaceCounts.find(surface => surface.label === 'Telemetry')?.routeLink).toMatchObject({
      label: 'Telemetry',
      params: { section: 'fleet-health', view: 'event-log', q: 'turn-1' },
    })
    expect(summary.keeperCounts.map(entry => ({
      keeper_id: entry.keeper_id,
      count: entry.count,
      routeLink: entry.routeLink && {
        label: entry.routeLink.label,
        params: entry.routeLink.params,
      },
    }))).toEqual([
      {
        keeper_id: 'sangsu',
        count: 2,
        routeLink: { label: 'Keeper', params: { section: 'agents', view: 'keepers', keeper: 'sangsu' } },
      },
      {
        keeper_id: 'analyst',
        count: 1,
        routeLink: { label: 'Keeper', params: { section: 'agents', view: 'keepers', keeper: 'analyst' } },
      },
    ])
  })

  it('routes run progress surface chips to the latest matching event context', () => {
    const summary = deriveIdeRunProgressSummary([
      {
        id: 'evt-old',
        run_id: 'run-default',
        keeper_id: 'analyst',
        verb: 'noted' as const,
        target: 'pr',
        timestamp_ms: 100,
        context: {
          pr_id: '14999',
          log_id: 'turn-old',
        },
      },
      {
        id: 'evt-latest',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted' as const,
        target: 'pr',
        timestamp_ms: 200,
        context: {
          pr_id: '15000',
          log_id: 'turn-latest',
          session_id: 'sess-latest',
          operation_id: 'op-latest',
          worker_run_id: 'wr-latest',
        },
      },
    ], 'lib/runtime.ml')

    expect(summary.surfaceCounts.find(surface => surface.label === 'PR')?.routeLink).toMatchObject({
      label: 'PR',
      params: { section: 'repositories', pr: '15000' },
    })
    expect(summary.surfaceCounts.find(surface => surface.label === 'Telemetry')?.routeLink).toMatchObject({
      label: 'Telemetry',
      params: {
        section: 'fleet-health',
        view: 'event-log',
        session_id: 'sess-latest',
        operation_id: 'op-latest',
        worker_run_id: 'wr-latest',
        q: 'turn-latest',
      },
    })
    expect(summary.surfaceCounts.find(surface => surface.label === 'Session')?.routeLink).toMatchObject({
      label: 'Telemetry',
      params: {
        section: 'fleet-health',
        view: 'event-log',
        session_id: 'sess-latest',
        operation_id: 'op-latest',
        worker_run_id: 'wr-latest',
        q: 'turn-latest',
      },
    })
  })

  it('keeps the run progress keeper total separate from the top keeper list', () => {
    const events = ['delta', 'bravo', 'charlie', 'alpha'].map((keeper_id, index) => ({
      id: `evt-${keeper_id}`,
      run_id: 'run-default',
      keeper_id,
      verb: 'noted' as const,
      target: 'telemetry',
      timestamp_ms: 100 - index,
    }))

    const summary = deriveIdeRunProgressSummary(events, 'lib/runtime.ml')

    expect(summary.keeperTotalCount).toBe(4)
    expect(summary.keeperCounts).toHaveLength(3)
    expect(summary.keeperCounts.map(entry => entry.keeper_id)).toEqual(['alpha', 'bravo', 'charlie'])
    expect(summary.keeperCounts.map(entry => entry.routeLink?.label)).toEqual(['Keeper', 'Keeper', 'Keeper'])
  })
})
