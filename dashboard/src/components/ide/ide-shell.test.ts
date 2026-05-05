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

import { IdeShell } from './ide-shell'
import { navigate, route } from '../../router'

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

describe('IdeShell', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
  })

  afterEach(() => {
    render(null, container)
    vi.unstubAllGlobals()
    window.location.hash = ''
    route.value = { tab: 'overview', params: {}, postId: null }
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
