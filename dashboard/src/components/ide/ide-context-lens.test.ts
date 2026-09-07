import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { deriveIdeContextLens, IdeContextLens, routeLinksForContext } from './ide-context-lens'
import type { UnifiedDiffRow } from '../../api/workspace'
import type { AnchoredThread } from './anchored-thread-rail-store'
import type { RunActivityEvent } from './run-activity-store'
import { ideContextFocus } from './ide-state'

const diffRows: ReadonlyArray<UnifiedDiffRow> = [
  { kind: 'add', oldLine: null, newLine: 12, text: '+let progress = ...' },
  { kind: 'delete', oldLine: 13, newLine: null, text: '-let old = ...' },
]

const events: ReadonlyArray<RunActivityEvent> = [
  {
    id: 'evt-1',
    run_id: 'run-default',
    keeper_id: 'sangsu',
    verb: 'commented on',
    target: 'board:post-1',
    detail: 'reviewed git diff and task status',
    kind: 'board.comment.created',
    tags: ['pr:15000', 'goal:goal-ide'],
    timestamp_ms: 100,
    // Structured surface classification (#20513 replaced regex/tag/text
    // parsing with event.context for surface counts). Drives goal/task/
    // board/pr/git surfaces; comment comes from anchored threads.
    context: {
      goal_id: 'goal-ide',
      task_id: 'task-42',
      board_post_id: 'post-1',
      pr_id: '15000',
      git_ref: 'abc123',
    },
  },
]

const thread: AnchoredThread = {
  id: 'thread-1',
  kind: 'question',
  author_keeper_id: 'scholar',
  anchor: {
    file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
    line_start: 19,
    line_end: 19,
    symbol_hint: 'fn:wireContext',
  },
  body: 'Should this board comment appear next to the code line?',
  created_ms: 300,
  resolved: false,
  reply_count: 2,
}

describe('IdeContextLens', () => {
  it('derives linked surfaces from threads, diff rows, and activity', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows,
      events,
      threads: [thread],
    })

    const linked = new Set(
      model.surfaces
        .filter(surface => surface.status === 'linked')
        .map(surface => surface.id),
    )

    expect(linked).toEqual(new Set([
      'line',
      'keeper',
      'goal',
      'task',
      'board',
      'git',
      'pr',
      'comment',
      'log',
      'telemetry',
    ]))
    expect(model.activeLineCount).toBe(2)
    expect(model.changedLineCount).toBe(2)
    expect(model.anchorTotalCount).toBe(3)
    expect(model.anchors.map(anchor => anchor.surface)).toContain('Git')
    expect(model.surfaces.find(surface => surface.id === 'line')?.routeLink).toMatchObject({
      label: 'Code',
      params: { file: 'lib/keeper/keeper_tool_ide_runtime.ml', line: '19' },
    })
    expect(model.surfaces.find(surface => surface.id === 'pr')?.routeLink).toMatchObject({
      label: 'PR',
      params: { section: 'repositories', pr: '15000' },
    })
    expect(model.surfaces.find(surface => surface.id === 'telemetry')?.routeLink).toMatchObject({
      label: 'Telemetry',
      params: { section: 'fleet-health', view: 'event-log' },
    })
    expect(model.surfaces.find(surface => surface.id === 'comment')?.routeLink).toMatchObject({
      label: 'Board',
    })
    expect(model.surfaces.find(surface => surface.id === 'comment')?.focusAnchor).toMatchObject({
      id: 'thread-thread-1',
      surface: 'QUESTION',
    })
  })

  it('does not claim telemetry links from local-only code evidence', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows,
      events: [],
    })

    const counts = new Map(model.surfaces.map(surface => [surface.id, surface.count]))
    expect(counts.get('lsp')).toBe(0)
    expect(counts.get('git')).toBe(2)
    expect(counts.get('log')).toBe(0)
    expect(counts.get('telemetry')).toBe(0)
  })

  it('renders a compact context lens panel', () => {
    const activated: unknown[] = []
    const container = document.createElement('div')
    ideContextFocus.value = null

    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
        diffRows,
        events,
        threads: [thread],
        onRouteLinkActivate: link => activated.push(link),
      }),
      container,
    )

    expect(container.querySelector('[data-testid="ide-context-lens"]')).not.toBeNull()
    expect(container.textContent).toContain('CONTEXT LENS')
    expect(container.textContent).toContain('10/12 linked')
    expect(container.textContent).toContain('keeper_tool_ide_runtime.ml')
    expect(container.textContent).toContain('3 anchors')
    expect(container.textContent).toContain('goal goal-ide')

    const surfaceButtons = [...container.querySelectorAll<HTMLButtonElement>('.ide-context-surface-action')]
    expect(surfaceButtons.map(button => button.textContent)).toEqual([
      'Line2',
      'Keeper2',
      'Goal1',
      'Task1',
      'Board2',
      'Git3',
      'PR1',
      'Comment1',
      'Log1',
      'Telemetry1',
    ])

    fireEvent.click(surfaceButtons.find(button => button.textContent === 'PR1')!)
    expect(activated[0]).toMatchObject({
      label: 'PR',
      params: { section: 'repositories', pr: '15000' },
    })

    fireEvent.click(surfaceButtons.find(button => button.textContent === 'Comment1')!)
    expect(activated[1]).toMatchObject({
      label: 'Board',
      params: { post: 'thread-1' },
    })
  })

  it('reports when the compact anchor list is truncated', () => {
    const container = document.createElement('div')
    const extraEvents = [
      events[0]!,
      { ...events[0]!, id: 'evt-2' },
      { ...events[0]!, id: 'evt-3' },
    ]
    const secondThread: AnchoredThread = {
      ...thread,
      id: 'thread-2',
      body: 'Second anchored thread',
      anchor: { ...thread.anchor, line_start: 20, line_end: 20 },
    }
    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
        diagnostics: [
          {
            file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
            line: 21,
            severity: 1,
            source: 'ocamllsp',
            message: 'First diagnostic',
          },
          {
            file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
            line: 22,
            severity: 2,
            source: 'ocamllsp',
            message: 'Second diagnostic',
          },
        ],
        diffRows,
        events: extraEvents,
        threads: [thread, secondThread],
      }),
      container,
    )

    const panel = container.querySelector('[data-testid="ide-context-lens"]')
    expect(panel?.getAttribute('data-visible-anchors')).toBe('6')
    expect(panel?.getAttribute('data-total-anchors')).toBe('8')
    expect(container.textContent).toContain('6/8 anchors')
  })

  it('keeps operational PR, Git, and planning anchors visible when the current file is busy', () => {
    const richEvent: RunActivityEvent = {
      id: 'evt-rich',
      run_id: 'run-default',
      keeper_id: 'sangsu',
      verb: 'noted',
      target: 'PR #15000',
      timestamp_ms: 400,
      context: {
        file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
        line: 27,
        goal_id: 'goal-ide',
        task_id: 'task-42',
        pr_id: '15000',
        board_post_id: 'post-1',
        comment_id: 'comment-1',
        git_ref: 'abc123',
        log_id: 'turn-9',
      },
    }
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diagnostics: [
        {
          file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
          line: 21,
          severity: 1,
          source: 'ocamllsp',
          code: 'type',
          message: 'First diagnostic',
        },
        {
          file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
          line: 22,
          severity: 2,
          source: 'ocamllsp',
          message: 'Second diagnostic',
        },
      ],
      diffRows,
      events: [
        richEvent,
        { ...richEvent, id: 'evt-rich-2', context: { ...richEvent.context, line: 28 } },
        { ...richEvent, id: 'evt-rich-3', context: { ...richEvent.context, line: 29 } },
      ],
      threads: [thread],
    })

    expect(model.anchorTotalCount).toBeGreaterThan(6)
    expect(model.anchors).toHaveLength(6)
    const visible = model.anchors.map(anchor => anchor.id)
    expect(visible[0]).toBe('diagnostic-21-ocamllsp-type-0')
    expect(visible).toContain('event-evt-rich')
    expect(visible).toContain('git-diff-summary')
    expect(visible).toContain('thread-thread-1')
    const richAnchor = model.anchors.find(anchor => anchor.id === 'event-evt-rich')
    expect(richAnchor?.route_links?.map(link => link.label)).toContain('PR')
    expect(model.anchors.find(anchor => anchor.id === 'git-diff-summary')?.surface).toBe('Git')
  })

  it('publishes focused file and line when an anchor is clicked', () => {
    const container = document.createElement('div')
    ideContextFocus.value = null

    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
        diffRows: [],
        events: [],
        threads: [thread],
      }),
      container,
    )

    const button = container.querySelector<HTMLButtonElement>('.ide-context-anchor-action')
    expect(button).not.toBeNull()
    fireEvent.click(button!)

    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
      line: 19,
      surface: 'QUESTION',
      source_id: 'thread-thread-1',
      keeper_id: 'scholar',
    })
  })

  it('links LSP diagnostics into file line anchors', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diagnostics: [{
        file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
        line: 22,
        severity: 2,
        source: 'ocamllsp',
        code: 'type',
        message: 'This expression has type string but an int was expected.',
      }],
      diffRows: [],
      events: [],
    })

    const counts = new Map(model.surfaces.map(surface => [surface.id, surface.count]))
    expect(counts.get('lsp')).toBe(1)
    expect(counts.get('line')).toBe(1)
    expect(model.anchors[0]).toMatchObject({
      surface: 'LSP',
      line: 22,
      meta: 'warning / ocamllsp / code type',
    })
    expect(model.anchors[0]?.route_links?.map(link => link.label)).toEqual(['Code', 'Telemetry'])
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Code')).toMatchObject({
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/keeper/keeper_tool_ide_runtime.ml',
        line: '22',
        surface: 'LSP',
        label: 'This expression has type string but an int was …',
        source_id: 'diagnostic-22-ocamllsp-type-0',
      },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Telemetry')).toMatchObject({
      tab: 'monitoring',
      params: {
        section: 'fleet-health',
        view: 'event-log',
        q: 'ocamllsp type',
      },
      evidence: 'Fleet telemetry event log · query ocamllsp type',
    })
  })

  it('keeps diagnostic telemetry routes quiet without source metadata', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diagnostics: [{
        file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
        line: 22,
        severity: 1,
        message: 'Missing semicolon.',
      }],
      diffRows: [],
      events: [],
    })

    expect(model.anchors[0]?.route_links?.map(link => link.label)).toEqual(['Code'])
  })

  it('renders operational route links for linked goal, task, and keeper context', () => {
    const activated: unknown[] = []
    const container = document.createElement('div')

    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
        diffRows: [],
        events: [{
          id: 'evt-planning',
          run_id: 'run-default',
          keeper_id: 'sangsu',
          verb: 'edited',
          target: 'lib/keeper/keeper_tool_ide_runtime.ml',
          timestamp_ms: 100,
          context: {
            file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
            line: 12,
            goal_id: 'goal-ide',
            task_id: 'task-42',
          },
        }],
        onRouteLinkActivate: link => activated.push(link),
      }),
      container,
    )

    const links = [...container.querySelectorAll<HTMLButtonElement>('.ide-context-route-link')]
    expect(container.querySelector('.ide-context-route-count')?.textContent).toBe('CTX 5')
    expect(links.map(link => link.textContent)).toEqual(['Code', 'Goal', 'Task', 'Telemetry', 'Keeper'])

    fireEvent.click(links.find(link => link.textContent === 'Goal')!)
    expect(activated[0]).toMatchObject({
      id: 'goal:goal-ide',
      tab: 'workspace',
      params: { section: 'planning', goal: 'goal-ide' },
    })
  })

  it('routes file and line context back into the Code IDE shell', () => {
    const links = routeLinksForContext({
      filePath: ' lib\\runtime.ml ',
      line: 42,
      surface: 'Task',
      label: 'Runtime task',
      sourceId: 'task:runtime',
      keeperId: 'sangsu',
    })

    expect(links[0]).toMatchObject({
      id: 'code:lib/runtime.ml:42',
      label: 'Code',
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/runtime.ml',
        line: '42',
        surface: 'Task',
        label: 'Runtime task',
        source_id: 'task:runtime',
        keeper: 'sangsu',
      },
      evidence: 'Code lib/runtime.ml:42',
    })
  })

  it('does not build Code routes for unsafe file paths', () => {
    expect(routeLinksForContext({
      filePath: '/tmp/runtime.ml',
      line: 42,
      goalId: 'goal-ide',
    }).map(link => link.label)).toEqual(['Goal'])
  })

  it('links conversation threads into board, comment, keeper, and line context', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [],
      threads: [thread],
    })

    const counts = new Map(model.surfaces.map(surface => [surface.id, surface.count]))
    expect(counts.get('board')).toBeGreaterThan(0)
    expect(counts.get('comment')).toBeGreaterThan(0)
    expect(counts.get('keeper')).toBe(1)
    expect(model.activeLineCount).toBe(1)
    expect(model.anchors[0]).toMatchObject({
      surface: 'QUESTION',
      line: 19,
      keeper_id: 'scholar',
    })
  })

  it('uses structured activity context as file, line, PR, task, goal, log, and git evidence', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-context',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        context: {
          file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
          line: 27,
          goal_id: 'goal-ide',
          task_id: 'task-42',
          pr_id: '15000',
          board_post_id: 'post-1',
          comment_id: 'comment-1',
          git_ref: 'abc123',
          log_id: 'turn-9',
          session_id: 'sess-9',
          operation_id: 'op-9',
          worker_run_id: 'wr-9',
        },
      }],
    })

    const counts = new Map(model.surfaces.map(surface => [surface.id, surface.count]))
    expect(counts.get('line')).toBe(1)
    expect(counts.get('goal')).toBeGreaterThan(0)
    expect(counts.get('task')).toBeGreaterThan(0)
    expect(counts.get('board')).toBeGreaterThan(0)
    expect(counts.get('comment')).toBeGreaterThan(0)
    expect(counts.get('git')).toBeGreaterThan(0)
    expect(counts.get('pr')).toBeGreaterThan(0)
    expect(counts.get('log')).toBe(1)
    expect(counts.get('runtime')).toBe(1)
    expect(counts.get('telemetry')).toBe(1)
    expect(model.anchors[0]).toMatchObject({
      surface: 'Comment',
      line: 27,
      keeper_id: 'sangsu',
    })
    expect(model.anchors[0]?.meta).toContain('goal goal-ide')
    expect(model.anchors[0]?.route_links?.map(link => link.label)).toEqual([
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
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Comment')).toMatchObject({
      tab: 'board',
      params: { post: 'post-1', comment: 'comment-1' },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Code')).toMatchObject({
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/keeper/keeper_tool_ide_runtime.ml',
        line: '27',
        surface: 'Comment',
        source_id: 'event-evt-context',
        keeper: 'sangsu',
      },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Log')).toMatchObject({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'audit', log_id: 'turn-9' },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Telemetry')).toMatchObject({
      tab: 'monitoring',
      params: {
        section: 'fleet-health',
        view: 'event-log',
        session_id: 'sess-9',
        operation_id: 'op-9',
        worker_run_id: 'wr-9',
        q: 'turn-9',
      },
      evidence: 'Fleet telemetry event log · session sess-9 · operation op-9 · worker wr-9 · query turn-9',
    })
    expect(model.surfaces.find(surface => surface.id === 'runtime')).toMatchObject({
      label: 'Runtime',
      count: 1,
      routeLink: expect.objectContaining({
        label: 'Telemetry',
        params: {
          section: 'fleet-health',
          view: 'event-log',
          session_id: 'sess-9',
          operation_id: 'op-9',
          worker_run_id: 'wr-9',
          q: 'turn-9',
        },
      }),
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Keeper')).toMatchObject({
      tab: 'monitoring',
      params: { section: 'agents', view: 'keepers', keeper: 'sangsu' },
    })
  })

  it('promotes tagged activity references into routeable IDE context links', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-tagged-context',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'PR #15000',
        timestamp_ms: 400,
        detail: [
          'goal:goal-ide',
          'task:task-42',
          'board:post-1',
          'comment:comment-1',
          'git:abc123',
          'log:turn-9',
          'session:sess-9',
          'op:op-9',
          'wr:wr-9',
          'line:27',
        ].join(' '),
        tags: ['pr:15000'],
        // Surface classification/count reads event.context (#20513); the
        // detail text still feeds route-link refs (eventRouteRefs retained).
        // pr_id selects the PR surface; session/op/wr light the runtime
        // surface. line stays in detail (context.line without file_path is
        // filtered out by deriveIdeContextLens).
        context: {
          pr_id: '15000',
          session_id: 'sess-9',
          operation_id: 'op-9',
          worker_run_id: 'wr-9',
        },
      }],
    })

    expect(model.activeLineCount).toBe(1)
    expect(model.surfaces.find(surface => surface.id === 'runtime')).toMatchObject({
      status: 'linked',
      count: 1,
    })
    expect(model.anchors[0]).toMatchObject({
      surface: 'PR',
      line: 27,
      keeper_id: 'sangsu',
    })
    expect(model.anchors[0]?.meta).toContain('goal goal-ide')
    expect(model.anchors[0]?.route_links?.map(link => link.label)).toEqual([
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
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Code')).toMatchObject({
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/keeper/keeper_tool_ide_runtime.ml',
        line: '27',
        surface: 'PR',
      },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Telemetry')).toMatchObject({
      tab: 'monitoring',
      params: {
        section: 'fleet-health',
        view: 'event-log',
        session_id: 'sess-9',
        operation_id: 'op-9',
        worker_run_id: 'wr-9',
        q: 'turn-9',
      },
    })
  })

  it('promotes tagged runtime references into runtime anchors', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-tagged-runtime',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'runtime scope',
        timestamp_ms: 400,
        detail: 'session:sess-9 op:op-9 wr:wr-9 line:27',
        // Runtime surface classification reads event.context (#20513).
        // line stays in detail (refs.line); context.line without file_path
        // would be filtered out by deriveIdeContextLens.
        context: {
          session_id: 'sess-9',
          operation_id: 'op-9',
          worker_run_id: 'wr-9',
        },
      }],
    })

    expect(model.surfaces.find(surface => surface.id === 'runtime')).toMatchObject({
      status: 'linked',
      count: 1,
      routeLink: expect.objectContaining({
        label: 'Telemetry',
        params: {
          section: 'fleet-health',
          view: 'event-log',
          session_id: 'sess-9',
          operation_id: 'op-9',
          worker_run_id: 'wr-9',
        },
      }),
    })
    expect(model.anchors[0]).toMatchObject({
      surface: 'Runtime',
      line: 27,
      keeper_id: 'sangsu',
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Code')).toMatchObject({
      tab: 'code',
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/keeper/keeper_tool_ide_runtime.ml',
        line: '27',
        surface: 'Runtime',
      },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Telemetry')).toMatchObject({
      tab: 'monitoring',
      params: {
        section: 'fleet-health',
        view: 'event-log',
        session_id: 'sess-9',
        operation_id: 'op-9',
        worker_run_id: 'wr-9',
      },
    })
  })

  it('prefers structured activity context over tagged fallback references', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-structured-wins',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'PR #99999',
        timestamp_ms: 400,
        detail: 'pr:99999 log:turn-999',
        context: {
          file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
          pr_id: '15000',
          log_id: 'turn-9',
        },
      }],
    })

    expect(model.anchors[0]?.route_links?.find(link => link.label === 'PR')).toMatchObject({
      id: 'pr:15000',
      evidence: 'PR 15000',
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Log')).toMatchObject({
      id: 'log:turn-9',
      evidence: 'Log turn-9',
    })
  })

  it('keeps other-file activity out of the current-file lens', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-other-file',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        detail: 'goal:goal-other task:task-other pr:15001 log:turn-10',
        context: {
          file_path: 'lib/runtime.ml',
          line: 99,
          goal_id: 'goal-other',
          task_id: 'task-other',
          pr_id: '15001',
          board_post_id: 'post-other',
          git_ref: 'def456',
          log_id: 'turn-10',
        },
      }],
    })

    expect(model.linkedCount).toBe(0)
    expect(model.activeLineCount).toBe(0)
    expect(model.anchors).toEqual([])
  })

  it('normalizes file paths before matching current-file lens inputs', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-backslash',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        context: {
          file_path: 'lib\\keeper\\keeper_tool_ide_runtime.ml',
          line: 27,
          log_id: 'turn-9',
        },
      }],
      threads: [{
        ...thread,
        id: 'thread-backslash',
        anchor: {
          ...thread.anchor,
          file_path: 'lib\\keeper\\keeper_tool_ide_runtime.ml',
        },
      }],
    })

    const counts = new Map(model.surfaces.map(surface => [surface.id, surface.count]))
    expect(counts.get('lsp')).toBe(0)
    expect(counts.get('keeper')).toBe(2)
    expect(counts.get('log')).toBe(1)
    expect(model.activeLineCount).toBe(2)
    expect(model.anchors.map(anchor => anchor.id)).toEqual([
      'thread-thread-backslash',
      'event-evt-backslash',
    ])
  })

  it('does not turn unscoped event lines into current-file anchors', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-line-only',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        context: {
          line: 27,
          goal_id: 'goal-ide',
          log_id: 'turn-9',
        },
      }],
    })

    const lineSurface = model.surfaces.find(surface => surface.id === 'line')
    expect(lineSurface?.count).toBe(0)
    expect(model.linkedCount).toBe(0)
    expect(model.anchors).toEqual([])
  })

  it('does not advertise delete-only diff rows as editor-focusable lines', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [{ kind: 'delete', oldLine: 13, newLine: null, text: '-let old = ...' }],
      events: [],
    })

    expect(model.changedLineCount).toBe(1)
    expect(model.activeLineCount).toBe(0)
    expect(model.anchors[0]).toMatchObject({
      id: 'git-diff-summary',
      surface: 'Git',
    })
    expect(model.anchors[0]?.line).toBeUndefined()
  })

  it('routes log context into the runtime audit focus', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-log',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        context: {
          file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
          line: 27,
          log_id: 'turn-9',
        },
      }],
    })

    const logRoute = model.anchors[0]?.route_links?.find(link => link.label === 'Log')
    expect(logRoute?.params).toEqual({ section: 'runtime', view: 'audit', log_id: 'turn-9' })
  })

  it('routes telemetry-only context into event-log query focus', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_tool_ide_runtime.ml',
      diffRows: [],
      events: [{
        id: 'evt-telemetry',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        context: {
          file_path: 'lib/keeper/keeper_tool_ide_runtime.ml',
          line: 27,
          log_id: 'turn-9',
        },
      }],
    })

    const telemetryRoute = model.anchors[0]?.route_links?.find(link => link.label === 'Telemetry')
    expect(telemetryRoute).toMatchObject({
      id: 'telemetry:turn-9',
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'event-log', q: 'turn-9' },
      evidence: 'Fleet telemetry event log · query turn-9',
    })
  })
})
