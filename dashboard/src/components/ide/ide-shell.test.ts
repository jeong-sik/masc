import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'

vi.mock('../../api/repositories', () => ({
  discoverRepositories: vi.fn(() => Promise.resolve([])),
  fetchRepositoriesList: vi.fn(() => Promise.resolve([{
    id: 'masc',
    name: 'masc',
    url: '',
    local_path: '/workspace/masc',
    default_branch: 'main',
    status: 'active',
    auto_sync: false,
    sync_interval: 300,
    created_at: null,
    updated_at: null,
    git_status: {
      state: 'available',
      source: 'git-status-porcelain-v1',
      dirty: true,
      changed_files: 2,
      staged_files: 1,
      unstaged_files: 0,
      untracked_files: 1,
      conflicted_files: 0,
    },
  }])),
}))

vi.mock('./ide-conversation-rail', () => ({
  IdeConversationRail: () => null,
}))

import {
  deriveIdeStatusbarModel,
  IDE_TREE_WIDTH_DEFAULT,
  IDE_TREE_WIDTH_MAX,
  IDE_TREE_WIDTH_MIN,
  IDE_TREE_WIDTH_STORAGE_KEY,
  IdeShell,
  normalizeIdeTreeWidth,
} from './ide-shell'
import { navigate, route } from '../../router'
import { clearTraces, pushTrace } from './keeper-trace-store'
import { activeIdeFile, ideContextFocus } from './ide-state'
import { resetIdeDataWorkspaceStoreForTest } from './ide-workspace-singleton'
import { cursorOverlaySignal } from './keeper-cursor-overlay'
import { EMPTY_LSP_STATUS_SNAPSHOT, lspStatusSnapshot } from './ide-lsp-client'

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

function clearLocalStorage(): void {
  try {
    window.localStorage.clear()
  } catch {
    // localStorage can be disabled in some test runtimes.
  }
}

function setLocalStorageItem(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value)
  } catch {
    // Tests that assert storage hydrate will fail through the rendered state.
  }
}

function getLocalStorageItem(key: string): string | null {
  try {
    return window.localStorage.getItem(key)
  } catch {
    return null
  }
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

const dashboardFetchHandlers: ReadonlyArray<[
  RegExp,
  () => Response,
]> = [
  [/\/api\/v1\/workspace\/tree/, () => jsonResponse([])],
  [/\/api\/v1\/workspace\/file/, () => jsonResponse({ ok: true, content: '{}', language: 'json' })],
  [/\/api\/v1\/git\/blame/, () => jsonResponse([])],
  [/\/api\/v1\/git\/diff/, () => jsonResponse({ unified: [] })],
  [/\/api\/v1\/ide\/regions/, () => jsonResponse({ ok: true, data: [] })],
  [/\/api\/v1\/ide\/annotations/, () => jsonResponse({ ok: true, data: [] })],
  [/\/state-diagram/, () => jsonResponse({
    keeper: 'sangsu',
    current_phase: 'observe',
    memory_kind_usage: [],
  })],
]

function dashboardFetchMock(input: RequestInfo | URL): Promise<Response> {
  const url = String(input)
  const handler = dashboardFetchHandlers.find(([pattern]) => pattern.test(url))
  if (!handler) throw new Error(`Unmocked fetch URL: ${url}`)
  return Promise.resolve(handler[1]())
}

function dashboardFetchMockWithFailure(
  pattern: RegExp,
  error: Error,
): (input: RequestInfo | URL) => Promise<Response> {
  return (input: RequestInfo | URL): Promise<Response> => {
    const url = String(input)
    if (pattern.test(url)) return Promise.reject(error)
    return dashboardFetchMock(input)
  }
}

function dashboardFetchMockWithResponse(
  pattern: RegExp,
  response: Response,
): (input: RequestInfo | URL) => Promise<Response> {
  return (input: RequestInfo | URL): Promise<Response> => {
    const url = String(input)
    if (pattern.test(url)) return Promise.resolve(response)
    return dashboardFetchMock(input)
  }
}

describe('IdeShell', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    clearLocalStorage()
    vi.stubGlobal('fetch', vi.fn(dashboardFetchMock))
  })

  afterEach(() => {
    render(null, container)
    // IdeShell now shares an app-lifetime workspace-store singleton; dispose it
    // between tests (after unmount) so each test starts from a fresh store
    // instead of inheriting the previous test's tree/repo/diff state.
    resetIdeDataWorkspaceStoreForTest()
    vi.unstubAllGlobals()
    window.location.hash = ''
    route.value = { tab: 'overview', params: {}, postId: null }
    activeIdeFile.value = 'package.json'
    ideContextFocus.value = null
    cursorOverlaySignal.value = { cursors: new Map(), heatmap: new Map(), collisions: [], active_file: null }
    lspStatusSnapshot.value = EMPTY_LSP_STATUS_SNAPSHOT
    clearTraces()
    clearLocalStorage()
  })

  it('fails fast for unmocked dashboard fetch URLs', () => {
    expect(() => dashboardFetchMock('/api/v1/dashboard/unexpected')).toThrow(
      'Unmocked fetch URL: /api/v1/dashboard/unexpected',
    )
  })

  it('hydrates layer buttons from the route layers param', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', layers: 'time,approve' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(container.querySelector('.v2-ide-surface')).not.toBeNull()
    expect(container.querySelectorAll('.v2-ide-panel').length).toBeGreaterThanOrEqual(3)
    expect(container.querySelector('.v2-ide-toolbar')).not.toBeNull()
    expect(container.querySelector('[data-testid="ide-readiness-notice"]')?.textContent)
      .toBe('experimental')
    expect(buttonByText(container, 'Time').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Approve').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Tools').getAttribute('aria-pressed')).toBe('false')
    expect(container.textContent).toContain('PERSISTENCE MAP')
    expect(container.textContent).toContain('Active overlays')
    expect(container.textContent).toContain('Time')
    expect(container.textContent).toContain('Approve')
  })

  it('renders repository git status without the dirty-count stub', async () => {
    render(h(IdeShell, {}), container)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="ide-repo-origin"]')?.textContent)
        .toContain('2개 변경')
    })
    expect(container.querySelector('[data-stub="repo-dirty-count"]')).toBeNull()
    expect(container.querySelector('[data-state="dirty"]')?.getAttribute('title'))
      .toContain('untracked 1')
  })

  it('hydrates current file and line focus from IDE route params', async () => {
    route.value = {
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib\\runtime.ml',
        line: '42',
        surface: 'Task',
        label: 'Runtime task',
        source_id: 'task:runtime',
        keeper: 'sangsu',
      },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    await waitFor(() => expect(activeIdeFile.value).toBe('lib/runtime.ml'))
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 42,
      surface: 'Task',
      label: 'Runtime task',
      source_id: 'task:runtime',
      keeper_id: 'sangsu',
    })
  })

  it('hydrates operational route links from IDE route params', async () => {
    route.value = {
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/runtime.ml',
        line: '42',
        surface: 'PR',
        label: 'Runtime review',
        source_id: 'trace:evt-42',
        keeper: 'sangsu',
        goal: 'goal-runtime',
        task: 'task-runtime',
        post: 'post-runtime',
        comment: 'comment-runtime',
        pr: '15035',
        ref: 'main',
        log_id: 'turn-42',
        session_id: 'sess-runtime',
        operation_id: 'op-runtime',
        worker_run_id: 'wr-runtime',
      },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    await waitFor(() => expect(ideContextFocus.value?.route_links?.map(link => link.label)).toEqual([
      'Code',
      'Goal',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ]))

    const toolbarFocus = container.querySelector('[data-testid="ide-toolbar-context-focus"]')
    expect(toolbarFocus?.getAttribute('aria-label')).toBe(
      'Current IDE context: PR line 42, Runtime review, keeper sangsu, 10 route links',
    )

    const routeButtons = [...container.querySelectorAll<HTMLButtonElement>('.ide-toolbar-context-links button')]
    expect(routeButtons.map(button => button.getAttribute('aria-label'))).toEqual([
      'Open Code lib/runtime.ml:42',
      'Open Goal goal-runtime',
      'Open Task task-runtime',
      'Open Board post post-runtime',
      'Open Comment comment-runtime',
      'Open PR 15035',
      'Open Git main',
      'Open Log turn-42',
      'Open Fleet telemetry event log · session sess-runtime · operation op-runtime · worker wr-runtime · query turn-42',
      'Open Keeper sangsu',
    ])

    fireEvent.click(routeButtons[8]!)
    expect(window.location.hash).toBe(
      '#monitoring?section=fleet-health&view=event-log&session_id=sess-runtime&operation_id=op-runtime&worker_run_id=wr-runtime&q=turn-42',
    )
  })

  it('derives compact operational statusbar chips from IDE route context', () => {
    const model = deriveIdeStatusbarModel({
      activeView: 'split-diff',
      activeLayers: new Set(['keeper-trace', 'approve']),
      activeFilePath: 'dashboard/src/components/ide/ide-shell.ts',
      findOpen: true,
      terminalOpen: true,
      railsCollapsed: true,
      reviewFocusActive: false,
      routeParams: {
        surface: 'PR',
        label: 'Runtime review',
        line: '42',
        goal: 'goal-runtime',
        task: 'task-runtime',
        post: 'post-runtime',
        comment: 'comment-runtime',
        pr: '15035',
        ref: 'main',
        log_id: 'turn-42',
        session_id: 'sess-runtime',
        keeper: 'sangsu',
      },
      repositories: [{
        id: 'masc',
        name: 'masc',
        url: '',
        local_path: '/workspace/masc',
        default_branch: 'main',
        status: 'active',
        auto_sync: false,
        sync_interval: 300,
        created_at: null,
        updated_at: null,
      }],
      activeRepositoryId: 'masc',
      workspaceSource: { kind: 'repository', repoId: 'masc' },
      dashboardConnected: true,
    })

    expect(model.workspaceLabel).toBe('masc')
    expect(model.connectionLabel).toBe('dashboard · live')
    expect(model.connectionTone).toBe('ok')
    expect(model.chips.map(chip => chip.label)).toEqual([
      'SPLIT DIFF',
      'ide/ide-shell.ts',
      'Trace +1',
      'terminal',
      'find',
      'rails hidden',
      'PR L42 Runtime review',
      'Goal goal-runtime',
      'Task task-runtime',
      'Board post-runtime',
      'Comment comment-runtime',
      'PR #15035',
      'Git main',
      'Log turn-42',
      'Telemetry sess-runtime',
      'Keeper sangsu',
    ])
  })

  it('derives operational statusbar chips from the active IDE context focus', () => {
    const model = deriveIdeStatusbarModel({
      activeView: 'source',
      activeLayers: new Set<string>(),
      activeFilePath: 'lib/runtime.ml',
      contextFocus: {
        file_path: 'lib/runtime.ml',
        line: 42,
        surface: 'Task',
        label: 'task task-runtime',
        source_id: 'event-1',
        keeper_id: 'sangsu',
        activated_at_ms: Date.now(),
        route_links: [
          {
            id: 'goal:goal-runtime',
            label: 'Goal',
            tab: 'workspace',
            params: { section: 'planning', goal: 'goal-runtime' },
            evidence: 'Goal goal-runtime',
          },
          {
            id: 'task:task-runtime',
            label: 'Task',
            tab: 'workspace',
            params: { section: 'planning', view: 'default', task: 'task-runtime' },
            evidence: 'Task task-runtime',
          },
          {
            id: 'pr:15035',
            label: 'PR',
            tab: 'workspace',
            params: { section: 'repositories', pr: '15035' },
            evidence: 'PR 15035',
          },
          {
            id: 'git:main',
            label: 'Git',
            tab: 'workspace',
            params: { section: 'repositories', ref: 'main' },
            evidence: 'Git main',
          },
          {
            id: 'log:turn-42',
            label: 'Log',
            tab: 'monitoring',
            params: { section: 'runtime', view: 'audit', log_id: 'turn-42' },
            evidence: 'Log turn-42',
          },
          {
            id: 'telemetry:sess-runtime',
            label: 'Telemetry',
            tab: 'monitoring',
            params: {
              section: 'fleet-health',
              view: 'event-log',
              session_id: 'sess-runtime',
              operation_id: 'op-runtime',
              worker_run_id: 'wr-runtime',
              q: 'turn-42',
            },
            evidence: 'Fleet telemetry event log · session sess-runtime · operation op-runtime · worker wr-runtime · query turn-42',
          },
          {
            id: 'keeper:sangsu',
            label: 'Keeper',
            tab: 'monitoring',
            params: { section: 'agents', view: 'keepers', keeper: 'sangsu' },
            evidence: 'Keeper sangsu',
          },
        ],
      },
      findOpen: false,
      terminalOpen: false,
      railsCollapsed: false,
      reviewFocusActive: false,
      routeParams: {},
      dashboardConnected: true,
    })

    expect(model.chips.map(chip => chip.label)).toEqual([
      'SOURCE',
      'lib/runtime.ml',
      'Task L42 task task-runtime',
      'Goal goal-runtime',
      'Task task-runtime',
      'PR #15035',
      'Git main',
      'Log turn-42',
      'Telemetry sess-runtime',
      'Keeper sangsu',
    ])
  })

  it('renders statusbar operational chips for the focused PR/task/log route', async () => {
    route.value = {
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/runtime.ml',
        line: '42',
        surface: 'PR',
        label: 'Runtime review',
        source_id: 'trace:evt-42',
        keeper: 'sangsu',
        task: 'task-runtime',
        pr: '15035',
        log_id: 'turn-42',
      },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    await waitFor(() => expect(activeIdeFile.value).toBe('lib/runtime.ml'))
    await waitFor(() => expect(container.querySelector('[data-testid="ide-statusbar-workspace"]')?.textContent).toBe('masc'))

    const statusbar = container.querySelector('[data-testid="ide-statusbar"]')
    expect(statusbar?.getAttribute('aria-label')).toBe('IDE operational status')
    expect(statusbar?.textContent).not.toContain('LIVE WORKSPACE')
    const chipLabels = [
      ...container.querySelectorAll<HTMLElement>('[data-testid^="ide-statusbar-chip-"]'),
    ].map(chip => chip.textContent)
    expect(chipLabels).toEqual([
      'SOURCE',
      'lib/runtime.ml',
      'terminal',
      'PR L42 Runtime review',
      'Task task-runtime',
      'PR #15035',
      'Log turn-42',
      'Telemetry turn-42',
      'Keeper sangsu',
    ])
  })

  it('surfaces workspace fetch failures in the IDE statusbar', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(dashboardFetchMockWithFailure(
        /\/api\/v1\/git\/diff/,
        new Error('diff endpoint unavailable'),
      )),
    )
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'unified', file: 'lib/runtime.ml' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const chip = await waitFor(() => {
      const found = container.querySelector('[data-testid="ide-statusbar-chip-workspace-fetch"]')
      expect(found).not.toBeNull()
      return found!
    })
    expect(chip.textContent).toBe('IDE fetch degraded diff')
    expect(chip.getAttribute('title')).toContain('diff endpoint unavailable')
  })

  it('surfaces malformed annotation responses in the IDE statusbar', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(dashboardFetchMockWithResponse(
        /\/api\/v1\/ide\/annotations/,
        jsonResponse({ ok: true, data: [null] }),
      )),
    )
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', file: 'lib/runtime.ml' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const chip = await waitFor(() => {
      const found = container.querySelector('[data-testid="ide-statusbar-chip-workspace-fetch"]')
      expect(found).not.toBeNull()
      return found!
    })
    expect(chip.textContent).toBe('IDE fetch degraded annotations')
    expect(chip.getAttribute('title')).toContain(
      'fetchIdeAnnotations returned malformed row at index 0',
    )
  })

  it('surfaces overlay-only LSP languages in the IDE statusbar', async () => {
    lspStatusSnapshot.value = {
      langs: [
        {
          lang: 'ocaml',
          connected: false,
          overlay_only: true,
          command: 'ocamllsp',
          last_error: 'ocamllsp unavailable',
        },
        {
          lang: 'typescript',
          connected: true,
          overlay_only: false,
          command: 'typescript-language-server',
          last_error: null,
        },
      ],
    }
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', file: 'lib/runtime.ml' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const chip = await waitFor(() => {
      const found = container.querySelector('[data-testid="ide-statusbar-chip-lsp-status"]')
      expect(found).not.toBeNull()
      return found!
    })
    expect(chip.textContent).toBe('LSP overlay-only 1')
    expect(chip.getAttribute('title')).toContain('ocaml: ocamllsp unavailable')
    expect(chip.getAttribute('title')).not.toContain('typescript')
  })

  it('focuses active keeper breadcrumb chips into routeable code and keeper context', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }
    activeIdeFile.value = 'lib/runtime.ml'
    cursorOverlaySignal.value = {
      cursors: new Map([[
        'sangsu',
        {
          keeper_id: 'sangsu',
          file_path: 'lib/runtime.ml',
          line: 42,
          column: 7,
          focus_mode: 'editing',
          last_update: Date.parse('2026-05-06T00:00:00Z'),
          tool_name: 'ocamllsp',
          turn: 9,
        },
      ]]),
      heatmap: new Map(),
      collisions: [],
      active_file: 'lib/runtime.ml',
    }

    render(h(IdeShell, {}), container)

    const keeperButton = await waitFor(() => {
      const button = container.querySelector<HTMLButtonElement>('.ide-breadcrumb-keeper')
      expect(button?.getAttribute('aria-label')).toBe('Focus sangsu keeper context at line 42')
      return button!
    })

    fireEvent.click(keeperButton)

    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 42,
      surface: 'Keeper',
      label: 'ocamllsp',
      source_id: 'breadcrumb:sangsu:42',
      keeper_id: 'sangsu',
    })
    expect(ideContextFocus.value?.route_links?.map(link => link.label)).toEqual(['Code', 'Keeper'])
    await waitFor(() => expect(container.querySelector('[data-testid="ide-toolbar-context-focus"]')?.textContent)
      .toContain('ocamllsp'))
    const routeGroups = [...container.querySelectorAll<HTMLButtonElement>('.ide-toolbar-context-route-group-action')]
    expect(routeGroups.map(button => button.textContent)).toEqual(['Code1', 'Runtime1'])
    await waitFor(() => {
      const chipLabels = [
        ...container.querySelectorAll<HTMLElement>('[data-testid^="ide-statusbar-chip-"]'),
      ].map(chip => chip.textContent)
      expect(chipLabels).toEqual([
        'SOURCE',
        'lib/runtime.ml',
        'Keeper L42 ocamllsp',
        'Keeper sangsu',
      ])
    })
    fireEvent.click(routeGroups[1]!)
    expect(window.location.hash).toBe('#monitoring?section=agents&view=keepers&keeper=sangsu')
  })

  it('rejects unsafe IDE route file focus params', async () => {
    route.value = {
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: '/workspace/lib/runtime.ml',
        line: '42',
      },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    await new Promise(resolve => setTimeout(resolve, 0))
    expect(activeIdeFile.value).toBe('package.json')
    expect(ideContextFocus.value).toBeNull()
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
    expect(buttonByText(container, 'Runtime').getAttribute('aria-pressed')).toBe('false')
  })

  it('lets explicit review-focus layers override the default review bundle', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'unified', focus: 'review', layers: 'runtime' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(container.querySelector('[data-testid="ide-review-focus"]')).not.toBeNull()
    expect(buttonByText(container, 'Runtime').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Trace').getAttribute('aria-pressed')).toBe('false')
    expect(buttonByText(container, 'Approve').getAttribute('aria-pressed')).toBe('false')
    expect(buttonByText(container, 'Notes').getAttribute('aria-pressed')).toBe('false')
  })

  it('persists an explicit empty review-focus layer override', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'unified', focus: 'review' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    fireEvent.click(buttonByText(container, 'Trace'))
    fireEvent.click(buttonByText(container, 'Approve'))
    fireEvent.click(buttonByText(container, 'Notes'))

    expect(route.value.params.layers).toBe('none')
    expect(container.querySelector('[data-testid="ide-review-focus"]')).not.toBeNull()
    expect(buttonByText(container, 'Trace').getAttribute('aria-pressed')).toBe('false')
    expect(buttonByText(container, 'Approve').getAttribute('aria-pressed')).toBe('false')
    expect(buttonByText(container, 'Notes').getAttribute('aria-pressed')).toBe('false')
  })

  it('does not activate review focus outside the unified view', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', focus: 'review' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(container.querySelector('[data-testid="ide-review-focus"]')).toBeNull()
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
      params: { section: 'ide-shell', view: 'unified', focus: ' Review ' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    fireEvent.click(buttonByText(container, 'SOURCE'))

    expect(route.value.params.view).toBe('source')
    expect(route.value.params.focus).toBeUndefined()
    expect(route.value.params.layers).toBeUndefined()
  })

  it('runs layer commands from the IDE command bar', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    const input = ideCommandInput(container)
    input.value = 'runtime'
    fireEvent.input(input)
    await waitFor(() => expect(container.querySelector('[role="listbox"]')).not.toBeNull())
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(route.value.params.layers).toBe('runtime')
  })

  it('runs the rails command from the IDE command bar', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    const input = ideCommandInput(container)
    input.value = 'rails'
    fireEvent.input(input)
    await waitFor(() => expect(container.querySelector('[role="listbox"]')).not.toBeNull())
    fireEvent.keyDown(input, { key: 'Enter' })

    expect(route.value.params.rails).toBe('hidden')
    expect(buttonByText(container, 'Rails').getAttribute('aria-pressed')).toBe('true')
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

  it('renders the Runtime layer button and toggles it via URL', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const btn = buttonByText(container, 'Runtime')
    expect(btn.getAttribute('aria-pressed')).toBe('false')

    fireEvent.click(btn)
    expect(route.value.params.layers).toBe('runtime')
    expect(btn.getAttribute('aria-pressed')).toBe('true')

    fireEvent.click(btn)
    expect(route.value.params.layers).toBeUndefined()
    expect(btn.getAttribute('aria-pressed')).toBe('false')
  })

  it('keeps default right rail context diagnostics bounded above the primary conversation rail', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const rail = container.querySelector('[data-testid="ide-right-rail"]')
    const contextStack = container.querySelector('[data-testid="ide-right-context-stack"]')
    const primaryRail = container.querySelector('[data-testid="ide-primary-conversation-rail"]')
    expect(rail).not.toBeNull()
    expect(contextStack).not.toBeNull()
    expect(primaryRail).not.toBeNull()
    expect(rail?.classList.contains('ide-v2-rail')).toBe(true)
    expect(buttonByText(container, 'Work Context').getAttribute('aria-selected')).toBe('true')
    expect(buttonByText(container, 'Run Activity').getAttribute('title'))
      .toBe('Workspace and keeper activity linked to the active file and repository')
    expect(buttonByText(container, 'Keeper Cursors').getAttribute('title'))
      .toBe('Live keeper file focus and cursor stream status')
    expect(container.querySelector('[data-testid="ide-dashboard-connection"]')?.getAttribute('title'))
      .toContain('Dashboard event transport')
    expect(container.querySelector('.ide-plane-activity')).toBeNull()
    expect(container.querySelector('[data-testid="ide-cursor-rail"]')).toBeNull()
  })

  it('switches the IDE right rail tabs and renders cursor stream focus', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }
    class MockEventSource {
      onopen: ((event: Event) => void) | null = null
      onmessage: ((event: MessageEvent) => void) | null = null
      onerror: ((event: Event) => void) | null = null

      constructor(_url: string) {}

      close = vi.fn()
    }
    vi.stubGlobal('EventSource', MockEventSource)
    cursorOverlaySignal.value = {
      cursors: new Map([[
        'sangsu',
        {
          keeper_id: 'sangsu',
          file_path: 'lib/scheduler/round.ml',
          line: 94,
          column: 4,
          selection_end: { line: 96, column: 0 },
          focus_mode: 'editing',
          last_update: Date.now(),
          tool_name: 'str_replace',
          turn: 12,
        },
      ]]),
      heatmap: new Map([[94, 1]]),
      collisions: [{ line: 94, keeper_ids: ['sangsu', 'nick0cave'], risk_level: 'medium' }],
      active_file: 'lib/scheduler/round.ml',
    }

    render(h(IdeShell, {}), container)
    await waitFor(() => expect(cursorOverlaySignal.value.stream?.status).toBe('connecting'))
    cursorOverlaySignal.value = {
      ...cursorOverlaySignal.value,
      stream: {
        status: 'degraded',
        failedCount: 2,
        lastErrorMs: Date.UTC(2026, 6, 4, 1, 2, 3),
        error: 'SSE transport error',
      },
    }

    fireEvent.click(buttonByText(container, 'Run Activity'))
    expect(buttonByText(container, 'Run Activity').getAttribute('aria-selected')).toBe('true')
    expect(container.querySelector('.ide-plane-activity')).not.toBeNull()
    expect(container.querySelector('[data-testid="ide-right-context-stack"]')).toBeNull()

    fireEvent.click(buttonByText(container, 'Keeper Cursors'))
    expect(buttonByText(container, 'Keeper Cursors').getAttribute('aria-selected')).toBe('true')
    expect(container.querySelector('.ide-plane-activity')).toBeNull()
    expect(container.querySelector('[data-testid="ide-right-context-stack"]')).toBeNull()
    const cursorRail = container.querySelector('[data-testid="ide-cursor-rail"]')
    expect(cursorRail).not.toBeNull()
    expect(cursorRail?.textContent).toContain('KEEPER CURSORS')
    expect(cursorRail?.textContent).toContain('sangsu')
    expect(cursorRail?.textContent).toContain('editing')
    expect(cursorRail?.textContent).toContain('str_replace')
    expect(cursorRail?.textContent).toContain('round.ml:94-96')
    expect(cursorRail?.textContent).toContain('L94')
    expect(container.querySelector('[data-testid="ide-cursor-stream-status"]')?.textContent)
      .toBe('stream degraded 2 failed')
    expect(container.querySelector('[data-testid="ide-cursor-stream-status"]')?.getAttribute('data-state'))
      .toBe('degraded')

    fireEvent.click(buttonByText(container, 'Focus'))
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/scheduler/round.ml',
      line: 94,
      surface: 'Keeper',
      label: 'str_replace',
      keeper_id: 'sangsu',
    })
  })

  it('hydrates collapsed IDE rails from the route', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'split-diff', rails: 'hidden' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(container.querySelector('.ide-plane-shell')?.getAttribute('data-rails-collapsed')).toBe('true')
    expect(container.querySelector('.ide-plane-conversation')).toBeNull()
    expect(container.querySelector('.ide-plane-activity')).toBeNull()
    expect(buttonByText(container, 'Rails').getAttribute('aria-pressed')).toBe('true')
  })

  it('toggles IDE rails through the toolbar and persists the route param', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const railsButton = buttonByText(container, 'Rails')
    expect(railsButton.getAttribute('aria-pressed')).toBe('false')
    fireEvent.click(railsButton)
    expect(route.value.params.rails).toBe('hidden')
    expect(container.querySelector('.ide-plane-shell')?.getAttribute('data-rails-collapsed')).toBe('true')
    fireEvent.click(buttonByText(container, 'Rails'))
    expect(route.value.params.rails).toBeUndefined()
  })

  it('normalizes persisted IDE tree widths to the supported range', () => {
    expect(normalizeIdeTreeWidth(120)).toBe(IDE_TREE_WIDTH_MIN)
    expect(normalizeIdeTreeWidth(241.6)).toBe(242)
    expect(normalizeIdeTreeWidth(800)).toBe(IDE_TREE_WIDTH_MAX)
    expect(normalizeIdeTreeWidth('bad')).toBe(IDE_TREE_WIDTH_DEFAULT)
  })

  it('hydrates the persisted IDE tree width into the grid and resize handle', () => {
    setLocalStorageItem(IDE_TREE_WIDTH_STORAGE_KEY, JSON.stringify(315))
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const shell = container.querySelector<HTMLElement>('.ide-plane-shell')
    const grid = container.querySelector<HTMLElement>('.ide-v2-body')
    const handle = container.querySelector<HTMLElement>('[data-testid="ide-tree-resize"]')
    expect(shell?.getAttribute('data-tree-width')).toBe('315')
    expect(grid?.getAttribute('style')).toContain('--ide-tree-width: 315px')
    expect(handle?.getAttribute('aria-valuenow')).toBe('315')
  })

  it('resizes the IDE file tree with pointer drag and keyboard controls', async () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const shell = container.querySelector<HTMLElement>('.ide-plane-shell')
    const handle = container.querySelector<HTMLElement>('[data-testid="ide-tree-resize"]') as HTMLButtonElement
    expect(shell?.getAttribute('data-tree-width')).toBe(String(IDE_TREE_WIDTH_DEFAULT))
    expect(handle.getAttribute('aria-valuenow')).toBe(String(IDE_TREE_WIDTH_DEFAULT))

    fireEvent.pointerDown(handle, { button: 0, clientX: 230 })
    fireEvent.pointerMove(window, { clientX: 285 })
    await waitFor(() => expect(shell?.getAttribute('data-tree-width')).toBe('285'))
    expect(handle.getAttribute('aria-valuenow')).toBe('285')
    expect(getLocalStorageItem(IDE_TREE_WIDTH_STORAGE_KEY)).toBe('285')

    fireEvent.pointerMove(window, { clientX: 620 })
    await waitFor(() => expect(shell?.getAttribute('data-tree-width')).toBe(String(IDE_TREE_WIDTH_MAX)))
    fireEvent.pointerUp(window)

    fireEvent.keyDown(handle, { key: 'Home' })
    await waitFor(() => expect(shell?.getAttribute('data-tree-width')).toBe(String(IDE_TREE_WIDTH_MIN)))
    expect(getLocalStorageItem(IDE_TREE_WIDTH_STORAGE_KEY)).toBe(String(IDE_TREE_WIDTH_MIN))

    fireEvent.keyDown(handle, { key: 'End' })
    await waitFor(() => expect(shell?.getAttribute('data-tree-width')).toBe(String(IDE_TREE_WIDTH_MAX)))
    expect(getLocalStorageItem(IDE_TREE_WIDTH_STORAGE_KEY)).toBe(String(IDE_TREE_WIDTH_MAX))
  })

  it('hydrates runtime layer button from the ?layers=runtime URL param', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', layers: 'runtime' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(buttonByText(container, 'Runtime').getAttribute('aria-pressed')).toBe('true')
    expect(container.textContent).toContain('Active overlays')
    expect(container.textContent).toContain('Runtime')
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

  it('opens the Execute output drawer from the terminal route param', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        'event: output\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"bgt-1","stdout_since":"hello\\\\n","stderr_since":"","closed":true}\n\n',
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
    expect(container.querySelector('[data-testid="execute-output-drawer"]')).not.toBeNull()
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/dashboard/execute-output/sangsu',
      expect.objectContaining({
        headers: expect.objectContaining({ Accept: 'text/event-stream' }),
      }),
    )
  })
})
