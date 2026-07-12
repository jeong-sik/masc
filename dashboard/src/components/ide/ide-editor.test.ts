import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { annotationRouteLinks, currentFileFindMatches, IdeEditor } from './ide-editor'
import { createCodeDocumentStore } from './code-document-store'
import { createKeeperLineOwnershipStore } from './keeper-line-ownership-store'
import { focusIdeContextAnchor, focusIdeFile, ideContextFocus } from './ide-state'
import { ideConversationThreadSnapshot } from './ide-context-bridge'
import { lspDiagnosticSnapshot } from './ide-lsp-client'
import { cursorOverlaySignal } from './keeper-cursor-overlay'
import { clearTraces, pushTrace } from './keeper-trace-store'
import { ideReplayUntilMs, setIdeReplayUntilMs } from './ide-replay-state'

describe('IdeEditor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    focusIdeFile({
      path: 'package.json',
      origin: 'operator',
      workspace_identity: { kind: 'project' },
      availability: 'available',
    })
    ideContextFocus.value = null
    setIdeReplayUntilMs(null)
    clearTraces()
  })

  afterEach(() => {
    render(null, container)
    ideContextFocus.value = null
    setIdeReplayUntilMs(null)
    clearTraces()
    lspDiagnosticSnapshot.value = new Map()
    ideConversationThreadSnapshot.value = { filePath: '', threads: [] }
    cursorOverlaySignal.value = {
      cursors: new Map(),
      heatmap: new Map(),
      collisions: [],
      active_file: null,
    }
    window.location.hash = ''
  })

  it('syncs CodeMirror when file content loads after initial mount', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'package.json',
      language: 'json',
      content: '',
    })
    const ownershipStore = createKeeperLineOwnershipStore('package.json')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
      }),
      container,
    )

    await waitFor(() => {
      expect(container.querySelector('.cm-content')).not.toBeNull()
    })
    expect(container.querySelector('.cm-lineNumbers')).not.toBeNull()
    expect(container.querySelector('.cm-content')?.textContent).toBe('')

    documentStore.load({
      file_path: 'package.json',
      language: 'json',
      content: '{\n  "name": "masc"\n}\n',
    })

    await waitFor(() => {
      expect(container.textContent).toContain('3 lines')
      expect(container.querySelector('.cm-content')?.textContent).toContain('masc')
    })
  })

  it('shows observed keeper ownership in Source view, not only Blame view', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')
    ownershipStore.ingest({
      file_path: 'runtime.ts',
      line_start: 1,
      line_end: 1,
      keeper_id: 'sangsu',
      timestamp_ms: 1,
      kind: 'observed',
    })

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
      }),
      container,
    )

    await waitFor(() => {
      expect(container.querySelector('.cm-blame-gutter')).not.toBeNull()
      expect(container.querySelector('[data-testid="ide-observation-summary"]')?.textContent)
        .toContain('metadata pending')
    })
    expect(container.querySelector('.ide-codemirror-shell')?.getAttribute('data-view'))
      .toBe('source-ownership')
  })

  it('finds current-file matches with case and whole-word options', () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst RuntimeValue = runtime + 1\n',
    })

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'runtime',
        { caseSensitive: false, wholeWord: false },
      ).map(match => match.line),
    ).toEqual([1, 2])

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'runtime',
        { caseSensitive: true, wholeWord: false },
      ).map(match => match.line),
    ).toEqual([1, 2])

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'Runtime',
        { caseSensitive: true, wholeWord: false },
      ).map(match => match.line),
    ).toEqual([2])

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'runtime',
        { caseSensitive: false, wholeWord: true },
      ).map(match => match.line),
    ).toEqual([1, 2])
  })

  it('renders the current-file find panel and cycles matches', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst other = 2\nreturn runtime\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        findOpen: true,
      }),
      container,
    )

    const input = container.querySelector<HTMLInputElement>('[aria-label="Find query"]')
    expect(input).not.toBeNull()
    fireEvent.input(input!, { target: { value: 'runtime' } })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="ide-find-status"]')?.textContent)
        .toContain('1 of 2 matches')
    })
    expect(container.querySelector('[data-testid="ide-find-results"]')?.textContent)
      .toContain('return runtime')

    const next = container.querySelector<HTMLButtonElement>('[aria-label="Next match"]')
    expect(next).not.toBeNull()
    fireEvent.click(next!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="ide-find-status"]')?.textContent)
        .toContain('2 of 2 matches')
    })
  })

  it('includes keeper trace in active layer summary and count', () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        activeLayers: new Set(['time', 'keeper-trace']),
      }),
      container,
    )

    expect(container.textContent).toContain('2 layers')
    expect(container.querySelector('[aria-label="Active IDE overlays"]')?.textContent)
      .toContain('Trace')
  })

  it('renders keeper trace line dots only for the active file when the trace layer is on', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst task = runtime + 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    pushTrace({
      id: 'thread-runtime',
      tsMs: 2000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'thread-runtime',
      filePath: 'runtime.ts',
      line: 2,
    })
    pushTrace({
      id: 'thread-other',
      tsMs: 3000,
      keeperName: 'moth',
      source: 'anchored-thread',
      threadId: 'thread-other',
      filePath: 'other.ts',
      line: 1,
    })

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        activeLayers: new Set(['keeper-trace']),
      }),
      container,
    )

    await waitFor(() => {
      expect(container.querySelector('.cm-trace-gutter')).not.toBeNull()
      expect(container.querySelector('.cm-trace-dot')?.getAttribute('aria-label'))
        .toBe('thread scholar')
      expect(container.querySelector('.cm-masc-trace-chip')?.textContent)
        .toBe('Trace · Thread · thread thread-runtime · keeper scholar')
    })
    expect(container.querySelectorAll('.cm-trace-dot')).toHaveLength(1)
  })

  it('filters keeper trace gutter dots through the shared replay cursor', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const oldTrace = 1\nconst replayTrace = oldTrace + 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')
    pushTrace({
      id: 'thread-old',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'anchored-thread',
      threadId: 'thread-old',
      filePath: 'runtime.ts',
      line: 2,
    })
    pushTrace({
      id: 'thread-future',
      tsMs: 3000,
      keeperName: 'moth',
      source: 'anchored-thread',
      threadId: 'thread-future',
      filePath: 'runtime.ts',
      line: 1,
    })
    setIdeReplayUntilMs(1500)

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        activeLayers: new Set(['keeper-trace']),
      }),
      container,
    )

    await waitFor(() => {
      expect(container.querySelector('button.cm-trace-stack[data-line="2"]')).not.toBeNull()
    })
    expect(container.querySelector('button.cm-trace-stack[data-line="1"]')).toBeNull()
    expect(container.querySelectorAll('.cm-trace-dot')).toHaveLength(1)
  })

  it('summarizes current-file operational signals in the editor header', () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst other = 2\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')
    lspDiagnosticSnapshot.value = new Map([[
      'runtime.ts',
      [{
        file_path: 'runtime.ts',
        line: 1,
        severity: 2,
        source: 'tsserver',
        message: 'runtime is never reassigned',
      }],
    ]])
    ideConversationThreadSnapshot.value = {
      filePath: 'runtime.ts',
      threads: [{
        id: 'thread-1',
        kind: 'question',
        author_keeper_id: 'sangsu',
        anchor: {
          file_path: 'runtime.ts',
          line_start: 2,
          line_end: 2,
          symbol_hint: 'runtime',
        },
        body: 'Is this task still tied to the active goal?',
        created_ms: 1,
        resolved: false,
        reply_count: 1,
      }],
    }
    cursorOverlaySignal.value = {
      cursors: new Map([[
        'sangsu',
        {
          keeper_id: 'sangsu',
          file_path: 'runtime.ts',
          line: 2,
          column: 1,
          focus_mode: 'editing',
          last_update: Date.now(),
        },
      ]]),
      heatmap: new Map(),
      collisions: [],
      active_file: 'runtime.ts',
    }
    pushTrace({
      id: 'activity-runtime',
      tsMs: 3000,
      keeperName: 'sangsu',
      source: 'activity-event',
      eventId: 'evt-1',
      filePath: 'runtime.ts',
      line: 1,
      surface: 'PR',
    })
    pushTrace({
      id: 'thread-runtime',
      tsMs: 2000,
      keeperName: 'sangsu',
      source: 'anchored-thread',
      threadId: 'thread-1',
      filePath: 'runtime.ts',
      line: 2,
    })
    pushTrace({
      id: 'activity-other',
      tsMs: 4000,
      keeperName: 'moth',
      source: 'activity-event',
      eventId: 'evt-other',
      filePath: 'other.ts',
      line: 1,
      surface: 'Task',
    })

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [
          { kind: 'add', oldLine: null, newLine: 1, text: '+const runtime = 1' },
          { kind: 'delete', oldLine: 2, newLine: null, text: '-const old = 1' },
        ] as const,
        annotations: [{
          id: 'ann-1',
          file_path: 'runtime.ts',
          line_start: 1,
          line_end: 1,
          keeper_id: 'sangsu',
          kind: 'Comment',
          content: 'Keep this task linked to the line',
          goal_id: 'goal-1',
          task_id: 'task-1',
          created_at_ms: 1,
          updated_at_ms: 1,
        }],
      }),
      container,
    )

    const signals = [...container.querySelectorAll<HTMLLIElement>('.ide-editor-file-signals > li')]
    expect(signals.map(item => item.textContent)).toEqual([
      'LSP1',
      'Notes1',
      'Threads1',
      'Trace2',
      'Ops1',
      'Diff2',
      'Keepers1',
    ])
    expect(signals.every(item => item.getAttribute('data-active') === 'true')).toBe(true)
    expect(signals.map(item => item.title)).toEqual([
      '1 current-file diagnostic',
      '1 current-file annotation',
      '1 current-file anchored thread',
      '2 current-file trace events',
      '1 current-file operational surface link',
      '2 current-file changed rows',
      '1 keeper active in this file',
    ])
  })

  it('counts loaded annotations in the notes overlay summary', () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        activeLayers: new Set(['notes']),
        annotations: [{
          id: 'ann-1',
          file_path: 'runtime.ts',
          line_start: 1,
          line_end: 1,
          keeper_id: 'sangsu',
          kind: 'Comment',
          content: 'Keep this task linked to the line',
          goal_id: 'goal-1',
          task_id: 'task-1',
          created_at_ms: 1,
          updated_at_ms: 1,
        }],
      }),
      container,
    )

    expect(container.querySelector('[aria-label="Active IDE overlays"]')?.textContent)
      .toContain('1 note')
  })

  it('renders loaded annotations as compact context chips on code lines', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst other = 2\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        annotations: [
          {
            id: 'ann-1',
            file_path: 'runtime.ts',
            line_start: 1,
            line_end: 1,
            keeper_id: 'sangsu',
            kind: 'Comment',
            content: 'Keep this task linked to the line',
            goal_id: 'goal-1',
            task_id: 'task-1',
            created_at_ms: 1,
            updated_at_ms: 1,
          },
          {
            id: 'ann-2',
            file_path: 'runtime.ts',
            line_start: 1,
            line_end: 1,
            keeper_id: 'reviewer',
            kind: 'Question',
            content: 'Is this still the active goal?',
            goal_id: null,
            task_id: null,
            created_at_ms: 2,
            updated_at_ms: 2,
          },
          {
            id: 'ann-other-file',
            file_path: 'other.ts',
            line_start: 1,
            line_end: 1,
            keeper_id: 'other',
            kind: 'Comment',
            content: 'Not this file',
            goal_id: null,
            task_id: null,
            created_at_ms: 3,
            updated_at_ms: 3,
          },
        ],
      }),
      container,
    )

    await waitFor(() => {
      const chip = container.querySelector('.cm-masc-annotation-chip')
      expect(chip?.textContent)
        .toBe('Comment · goal goal-1 · task task-1 · keeper sangsu · +1')
    })
    expect(container.querySelectorAll('.cm-masc-annotation-chip')).toHaveLength(1)
    expect(container.querySelector('.cm-masc-annotation-chip')?.getAttribute('aria-label'))
      .toBe('Line 1 annotation context: Comment · goal goal-1 · task task-1 · keeper sangsu · +1')
  })

  it('maps annotation detail context into operational route links', () => {
    const links = annotationRouteLinks({
      id: 'ann-1',
      file_path: 'runtime.ts',
      line_start: 7,
      line_end: 7,
      keeper_id: 'sangsu',
      kind: 'Comment',
      content: 'Keep this task linked to the active goal',
      goal_id: 'goal-runtime',
      task_id: 'task-runtime',
    })

    expect(links.map(link => link.label)).toEqual(['Code', 'Goal', 'Task', 'Keeper'])
    expect(links.find(link => link.label === 'Code')).toMatchObject({
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'runtime.ts',
        line: '7',
        surface: 'Comment',
        source_id: 'annotation-ann-1',
        keeper: 'sangsu',
      },
    })
    expect(links.find(link => link.label === 'Goal')?.params).toMatchObject({
      section: 'planning',
      goal: 'goal-runtime',
    })
    expect(links.find(link => link.label === 'Task')?.params).toMatchObject({
      section: 'planning',
      task: 'task-runtime',
    })
    expect(links.find(link => link.label === 'Keeper')?.params).toMatchObject({
      section: 'agents',
      keeper: 'sangsu',
    })
  })

  it('focuses operational route context when a keeper trace gutter stack is clicked', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst task = runtime + 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    pushTrace({
      id: 'activity-runtime',
      tsMs: 3000,
      keeperName: 'sangsu',
      source: 'activity-event',
      eventId: 'evt-1',
      filePath: 'runtime.ts',
      line: 2,
      surface: 'PR',
      goalId: 'goal-runtime',
      taskId: 'task-runtime',
      boardPostId: 'post-runtime',
      commentId: 'comment-runtime',
      prId: '15035',
      gitRef: 'refs/heads/review-response',
      logId: 'turn-2',
      sessionId: 'sess-runtime',
      operationId: 'op-runtime',
      workerRunId: 'worker-runtime',
    })

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        activeLayers: new Set(['keeper-trace']),
      }),
      container,
    )

    await waitFor(() => {
      expect(container.querySelector('button.cm-trace-stack')).not.toBeNull()
    })
    fireEvent.click(container.querySelector<HTMLButtonElement>('button.cm-trace-stack')!)

    expect(ideReplayUntilMs.value).toBe(3000)
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'runtime.ts',
      line: 2,
      surface: 'PR',
      label: 'PR activity evt-1',
      source_id: 'trace:activity-runtime',
      keeper_id: 'sangsu',
    })
    expect(ideContextFocus.value?.route_links?.map(link => link.label)).toEqual([
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
    ])
    expect(ideContextFocus.value?.route_links?.find(link => link.label === 'Telemetry')?.params)
      .toMatchObject({
        section: 'fleet-health',
        view: 'event-log',
        session_id: 'sess-runtime',
        operation_id: 'op-runtime',
        worker_run_id: 'worker-runtime',
        q: 'turn-2',
      })
    await waitFor(() => {
      expect(container.querySelector('[data-testid="ide-context-focus-status"]')?.textContent)
        .toContain('Focused L2')
      expect(container.querySelectorAll('.ide-editor-context-route-link')).toHaveLength(10)
    })
  })

  it('shows and highlights the focused context line from the shared IDE signal', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst task = runtime + 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
      }),
      container,
    )

    await waitFor(() => {
      expect(container.querySelector('.cm-content')).not.toBeNull()
    })

    focusIdeContextAnchor({
      file_path: 'runtime.ts',
      line: 2,
      surface: 'Task',
      label: 'task task-runtime',
      source_id: 'event-1',
      keeper_id: 'sangsu',
      route_links: [
        {
          id: 'task:task-runtime',
          label: 'Task',
          tab: 'workspace',
          params: { section: 'planning', view: 'default', task: 'task-runtime' },
          evidence: 'Task task-runtime',
        },
        {
          id: 'telemetry:turn-9',
          label: 'Telemetry',
          tab: 'monitoring',
          params: { section: 'fleet-health', view: 'event-log', q: 'turn-9' },
          evidence: 'Fleet telemetry event log · query turn-9',
        },
      ],
    }, 'operator')

    await waitFor(() => {
      expect(container.querySelector('[data-testid="ide-context-focus-status"]')?.textContent)
        .toContain('Focused L2')
      expect(container.querySelector('.cm-masc-context-focus')).not.toBeNull()
      expect(container.querySelector('.cm-masc-context-focus-chip')?.textContent)
        .toContain('Task · task task-runtime · keeper sangsu · 2 links')
    })
    expect(container.querySelector('.cm-masc-context-focus-chip')?.getAttribute('aria-label'))
      .toBe('Focused context on line 2: Task, task task-runtime, keeper sangsu, 2 links')
    const focusMeta = [...container.querySelectorAll('.ide-editor-context-focus-meta > span')]
      .map(node => node.textContent)
    expect(focusMeta).toEqual(['Task', 'keeper sangsu', 'source event-1', '2 links'])
    expect(container.querySelector('.ide-editor-context-route-count')?.textContent).toBe('CTX 2')
    const routeLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-editor-context-route-link')]
    expect(routeLinks.map(link => link.textContent)).toEqual(['Task', 'Telemetry'])
    fireEvent.click(routeLinks.find(link => link.textContent === 'Telemetry')!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=turn-9')
  })
})
