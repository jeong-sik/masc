import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'

vi.mock('../../api/git-graph', () => ({
  fetchGitGraph: vi.fn(() => Promise.resolve({
    generated_at: '2026-05-06T00:00:00Z',
    repos: [{
      id: 'masc-mcp',
      root: '/workspace/masc-mcp',
      label: 'masc-mcp',
      current_branch: 'main',
      head: 'abc123',
      dirty: false,
      conflict_count: 0,
      branch_count: 2,
      commit_count: 8,
      worktree_count: 1,
    }],
    agents: [],
    nodes: [],
    edges: [],
    stats: {
      repo_count: 1,
      agent_count: 0,
      branch_count: 2,
      commit_count: 8,
      conflict_count: 0,
      dirty_count: 0,
    },
    warnings: [],
  })),
}))

vi.mock('../../api/repositories', () => ({
  discoverRepositories: vi.fn(() => Promise.resolve([])),
  fetchRepositoriesList: vi.fn(() => Promise.resolve([{
    id: 'masc-mcp',
    name: 'masc-mcp',
    local_path: '/workspace/masc-mcp',
  }])),
}))

vi.mock('./ide-conversation-rail-mock', () => ({
  IdeConversationRailMock: () => null,
}))

import { IdeShell } from './ide-shell'
import { navigate, route } from '../../router'
import { clearTraces, pushTrace } from './keeper-trace-store'

function buttonByText(container: HTMLElement, text: string): HTMLButtonElement {
  const button = Array.from(container.querySelectorAll('button'))
    .find(candidate => candidate.textContent === text)
  if (!(button instanceof HTMLButtonElement)) {
    throw new Error(`missing button: ${text}`)
  }
  return button
}

function ideCommandInput(container: HTMLElement): HTMLInputElement {
  const input = container.querySelector('[data-testid="ide-command-bar"] input')
  if (!(input instanceof HTMLInputElement)) {
    throw new Error('missing IDE command bar input')
  }
  return input
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

function dashboardFetchMock(input: RequestInfo | URL): Promise<Response> {
  const url = String(input)
  if (url.includes('/api/v1/workspace/tree')) return Promise.resolve(jsonResponse([]))
  if (url.includes('/api/v1/workspace/file')) return Promise.resolve(jsonResponse({ ok: false, content: '' }))
  if (url.includes('/api/v1/git/blame')) return Promise.resolve(jsonResponse([]))
  if (url.includes('/api/v1/git/diff')) return Promise.resolve(jsonResponse({ unified: [] }))
  if (url.includes('/state-diagram')) {
    return Promise.resolve(jsonResponse({
      keeper: 'sangsu',
      current_phase: 'observe',
      memory_kind_usage: [],
    }))
  }
  if (url.includes('/bdi-snapshot')) {
    return Promise.resolve(jsonResponse({
      keeper: 'sangsu',
      generated_at: '2026-05-06T00:00:00Z',
      poll_interval_ms: 5000,
      recent_token_spend: [],
      source: 'test',
    }))
  }
  return Promise.resolve(jsonResponse({}))
}

describe('IdeShell', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    vi.stubGlobal('fetch', vi.fn(dashboardFetchMock))
  })

  afterEach(() => {
    render(null, container)
    vi.unstubAllGlobals()
    window.location.hash = ''
    route.value = { tab: 'overview', params: {}, postId: null }
    clearTraces()
  })

  it('hydrates layer buttons from the route layers param', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', layers: 'time,approve' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(buttonByText(container, 'Time').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Approve').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Tools').getAttribute('aria-pressed')).toBe('false')
    expect(container.textContent).toContain('PERSISTENCE MAP')
    expect(container.textContent).toContain('Active overlays')
    expect(container.textContent).toContain('Time')
    expect(container.textContent).toContain('Approve')
  })

  it('renders toolbar lanes that can collapse independently on narrow screens', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const toolbar = container.querySelector('[data-testid="ide-toolbar"]')
    const tabs = container.querySelector('[data-testid="ide-toolbar-tabs"]')
    const layers = container.querySelector('[data-testid="ide-toolbar-layers"]')

    expect(toolbar?.classList.contains('ide-toolbar')).toBe(true)
    expect(toolbar?.getAttribute('role')).toBe('toolbar')
    expect(tabs?.classList.contains('ide-toolbar-tabs')).toBe(true)
    expect(tabs?.getAttribute('role')).toBe('tablist')
    expect(layers?.classList.contains('ide-toolbar-layers')).toBe(true)
    expect(layers?.getAttribute('aria-label')).toBe('Layers (multi-select)')
    expect(tabs).not.toBe(layers)
    expect(container.querySelector('.ide-toolbar-spacer')).toBeNull()
  })

  it('persists layer toggles back to the route', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'split-diff', layers: 'time,approve' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    expect(container.querySelector('[aria-label="Split diff preview"]')).not.toBeNull()
    fireEvent.click(buttonByText(container, 'Tools'))

    expect(route.value.params.view).toBe('split-diff')
    expect(route.value.params.layers).toBe('approve,time,tools')

    fireEvent.click(buttonByText(container, 'EXPLODE'))
    expect(route.value.params.layers).toBe('explode')
  })

  it('turns focus=review into a unified review workspace with review layers', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'unified', focus: 'review' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(container.querySelector('[data-testid="ide-review-focus"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Unified diff preview"]')).not.toBeNull()
    expect(buttonByText(container, 'Trace').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Approve').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Notes').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Cascade').getAttribute('aria-pressed')).toBe('false')
  })

  it('lets explicit review-focus layers override the default review bundle', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'unified', focus: 'review', layers: 'cascade' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(container.querySelector('[data-testid="ide-review-focus"]')).not.toBeNull()
    expect(buttonByText(container, 'Cascade').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Trace').getAttribute('aria-pressed')).toBe('false')
    expect(buttonByText(container, 'Approve').getAttribute('aria-pressed')).toBe('false')
    expect(buttonByText(container, 'Notes').getAttribute('aria-pressed')).toBe('false')
  })

  it('runs view commands from the IDE command bar', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    const input = ideCommandInput(container)
    input.value = 'unified'
    fireEvent.input(input)
    await waitFor(() => expect(container.querySelector('[role="listbox"]')).not.toBeNull())
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(route.value.params.view).toBe('unified')
  })

  it('clears review focus when switching away from unified review mode', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'unified', focus: 'review' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    fireEvent.click(buttonByText(container, 'SOURCE'))

    expect(route.value.params.view).toBe('source')
    expect(route.value.params.focus).toBeUndefined()
  })

  it('runs layer commands from the IDE command bar', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    const input = ideCommandInput(container)
    input.value = 'cascade'
    fireEvent.input(input)
    await waitFor(() => expect(container.querySelector('[role="listbox"]')).not.toBeNull())
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(route.value.params.layers).toBe('cascade')
  })

  it('opens the terminal route from the IDE command bar', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    const input = ideCommandInput(container)
    input.value = 'terminal'
    fireEvent.input(input)
    await waitFor(() => expect(container.querySelector('[role="listbox"]')).not.toBeNull())
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(route.value.params.terminal).toBe('open')
  })

  it('opens the current-file find panel from the IDE command bar', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    const input = ideCommandInput(container)
    input.value = 'find'
    fireEvent.input(input)
    await waitFor(() => expect(container.querySelector('[role="listbox"]')).not.toBeNull())
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(route.value.params.find).toBe('open')
    expect(container.querySelector('[data-testid="ide-find-panel"]')).not.toBeNull()
  })

  it('renders the Cascade layer button and toggles it via URL', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const btn = buttonByText(container, 'Cascade')
    expect(btn.getAttribute('aria-pressed')).toBe('false')

    fireEvent.click(btn)
    expect(route.value.params.layers).toBe('cascade')
    expect(btn.getAttribute('aria-pressed')).toBe('true')

    fireEvent.click(btn)
    expect(route.value.params.layers).toBeUndefined()
    expect(btn.getAttribute('aria-pressed')).toBe('false')
  })

  it('renders IDE branch graph context in the review rail', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(container.textContent).toContain('BRANCH GRAPH')
    await waitFor(() => expect(container.textContent).toContain('masc-mcp'))
    expect(container.textContent).toContain('main')
  })

  it('hydrates cascade layer button from the ?layers=cascade URL param', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', layers: 'cascade' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(buttonByText(container, 'Cascade').getAttribute('aria-pressed')).toBe('true')
    expect(container.textContent).toContain('Active overlays')
    expect(container.textContent).toContain('Cascade')
  })

  it('mounts the OverlayKeeperTrace overlay when the keeper-trace layer is toggled on', () => {
    pushTrace({
      id: 'shell-mount-evt-1',
      tsMs: Date.parse('2026-05-06T01:00:00Z'),
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'shell-mount-evt-1',
      line: null,
    })
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', layers: 'keeper-trace' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const overlay = container.querySelector('[data-overlay="keeper-trace"]')
    expect(overlay).not.toBeNull()
  })

  it('does not render the OverlayKeeperTrace overlay when the keeper-trace layer is off', () => {
    pushTrace({
      id: 'shell-mount-evt-2',
      tsMs: Date.parse('2026-05-06T01:00:00Z'),
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'shell-mount-evt-2',
      line: null,
    })
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const overlay = container.querySelector('[data-overlay="keeper-trace"]')
    expect(overlay).toBeNull()
  })

  it('opens the keeper shell drawer from the terminal route param', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        'event: shell\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"bgt-1","stdout_since":"hello\\\\n","stderr_since":"","closed":true}\n\n',
        {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)
    navigate('code', {
      section: 'ide-shell',
      view: 'source',
      terminal: 'open',
      keeper: 'sangsu',
    })

    render(h(IdeShell, {}), container)

    await waitFor(() => expect(container.textContent).toContain('hello'))
    expect(container.querySelector('[data-testid="keeper-shell-drawer"]')).not.toBeNull()
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/dashboard/keeper-shell/sangsu',
      expect.objectContaining({
        headers: expect.objectContaining({ Accept: 'text/event-stream' }),
      }),
    )
  })
})
