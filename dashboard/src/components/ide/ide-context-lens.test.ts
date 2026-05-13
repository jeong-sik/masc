import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { deriveIdeContextLens, IdeContextLens } from './ide-context-lens'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import type { AnchoredThread } from './anchored-thread-rail-store'
import type { KeeperCursorOverlay } from './keeper-cursor-overlay'
import type { RunActivityEvent } from './run-activity-store'
import { ideContextFocus } from './ide-state'

const annotation: IdeAnnotation = {
  id: 'ann-1',
  file_path: 'lib/keeper/keeper_exec_ide.ml',
  line_start: 12,
  line_end: 14,
  keeper_id: 'sangsu',
  kind: 'Comment',
  content: 'Wire goal and task progress into the code line.',
  goal_id: 'goal-ide',
  task_id: 'task-42',
  created_at_ms: 1,
  updated_at_ms: 2,
}

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
  },
]

const overlay: KeeperCursorOverlay = {
  cursors: new Map([[
    'sangsu',
    {
      keeper_id: 'sangsu',
      file_path: 'lib/keeper/keeper_exec_ide.ml',
      line: 12,
      column: 4,
      focus_mode: 'editing',
      last_update: 100,
      tool_name: 'keeper_exec_ide',
      turn: 7,
    },
  ]]),
  heatmap: new Map(),
  collisions: [],
  active_file: 'lib/keeper/keeper_exec_ide.ml',
}

const thread: AnchoredThread = {
  id: 'thread-1',
  kind: 'question',
  author_keeper_id: 'scholar',
  anchor: {
    file_path: 'lib/keeper/keeper_exec_ide.ml',
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
  it('derives linked surfaces from annotations, diff rows, activity, and cursors', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [annotation],
      diffRows,
      events,
      overlay,
    })

    const linked = new Set(
      model.surfaces
        .filter(surface => surface.status === 'linked')
        .map(surface => surface.id),
    )

    expect(linked).toEqual(new Set([
      'lsp',
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
    expect(model.activeLineCount).toBe(1)
    expect(model.changedLineCount).toBe(2)
    expect(model.anchors.map(anchor => anchor.surface)).toContain('Git')
  })

  it('renders a compact context lens panel', () => {
    const container = document.createElement('div')

    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_exec_ide.ml',
        annotations: [annotation],
        diffRows,
        events,
        overlay,
      }),
      container,
    )

    expect(container.querySelector('[data-testid="ide-context-lens"]')).not.toBeNull()
    expect(container.textContent).toContain('CONTEXT LENS')
    expect(container.textContent).toContain('11/11 linked')
    expect(container.textContent).toContain('keeper_exec_ide.ml')
    expect(container.textContent).toContain('goal goal-ide')
  })

  it('publishes focused file and line when an anchor is clicked', () => {
    const container = document.createElement('div')
    ideContextFocus.value = null

    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_exec_ide.ml',
        annotations: [annotation],
        diffRows: [],
        events: [],
        overlay: { ...overlay, cursors: new Map() },
      }),
      container,
    )

    const button = container.querySelector<HTMLButtonElement>('.ide-context-anchor-action')
    expect(button).not.toBeNull()
    fireEvent.click(button!)

    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/keeper/keeper_exec_ide.ml',
      line: 12,
      surface: 'Comment',
      source_id: 'annotation-ann-1',
      keeper_id: 'sangsu',
    })
  })

  it('omits invalid annotation lines from anchors and focus state', () => {
    const invalidLineAnnotation: IdeAnnotation = {
      ...annotation,
      id: 'ann-line-zero',
      line_start: 0,
      line_end: 0,
    }
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [invalidLineAnnotation],
      diffRows: [],
      events: [],
      overlay: { ...overlay, cursors: new Map() },
    })

    expect(model.activeLineCount).toBe(0)
    expect(model.anchors[0]).toMatchObject({
      id: 'annotation-ann-line-zero',
      surface: 'Comment',
    })
    expect(model.anchors[0]?.line).toBeUndefined()

    const container = document.createElement('div')
    ideContextFocus.value = null
    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_exec_ide.ml',
        annotations: [invalidLineAnnotation],
        diffRows: [],
        events: [],
        overlay: { ...overlay, cursors: new Map() },
      }),
      container,
    )
    const button = container.querySelector<HTMLButtonElement>('.ide-context-anchor-action')
    fireEvent.click(button!)

    const focus = ideContextFocus.value as { readonly line?: number } | null
    expect(focus?.line).toBeUndefined()
  })

  it('renders operational route links for linked goal, task, and keeper context', () => {
    const activated: unknown[] = []
    const container = document.createElement('div')

    render(
      h(IdeContextLens, {
        filePath: 'lib/keeper/keeper_exec_ide.ml',
        annotations: [annotation],
        diffRows: [],
        events: [],
        overlay: { ...overlay, cursors: new Map() },
        onRouteLinkActivate: link => activated.push(link),
      }),
      container,
    )

    const links = [...container.querySelectorAll<HTMLButtonElement>('.ide-context-route-link')]
    expect(links.map(link => link.textContent)).toEqual(['Goal', 'Task', 'Keeper'])

    fireEvent.click(links[0]!)
    expect(activated[0]).toMatchObject({
      id: 'goal:goal-ide',
      tab: 'workspace',
      params: { section: 'planning', goal: 'goal-ide' },
    })
  })

  it('links conversation threads into board, comment, keeper, and line context', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [],
      diffRows: [],
      events: [],
      threads: [thread],
      overlay: { ...overlay, cursors: new Map() },
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
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [],
      diffRows: [],
      events: [{
        id: 'evt-context',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        context: {
          file_path: 'lib/keeper/keeper_exec_ide.ml',
          line: 27,
          goal_id: 'goal-ide',
          task_id: 'task-42',
          pr_id: '15000',
          board_post_id: 'post-1',
          comment_id: 'comment-1',
          git_ref: 'abc123',
          log_id: 'turn-9',
        },
      }],
      overlay: { ...overlay, cursors: new Map() },
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
    expect(model.anchors[0]).toMatchObject({
      surface: 'Comment',
      line: 27,
      keeper_id: 'sangsu',
    })
    expect(model.anchors[0]?.meta).toContain('goal goal-ide')
    expect(model.anchors[0]?.route_links?.map(link => link.label)).toEqual([
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
      tab: 'workspace',
      params: { section: 'board', post: 'post-1', comment: 'comment-1' },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Log')).toMatchObject({
      tab: 'monitoring',
      params: { section: 'runtime', view: 'audit' },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Telemetry')).toMatchObject({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'event-log' },
    })
    expect(model.anchors[0]?.route_links?.find(link => link.label === 'Keeper')).toMatchObject({
      tab: 'monitoring',
      params: { section: 'agents', view: 'keepers', keeper: 'sangsu' },
    })
  })

  it('keeps other-file activity out of the current-file lens', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [],
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
      overlay: { ...overlay, cursors: new Map() },
    })

    expect(model.linkedCount).toBe(0)
    expect(model.activeLineCount).toBe(0)
    expect(model.anchors).toEqual([])
  })

  it('does not turn unscoped event lines into current-file anchors', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [],
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
      overlay: { ...overlay, cursors: new Map() },
    })

    const lineSurface = model.surfaces.find(surface => surface.id === 'line')
    expect(lineSurface?.count).toBe(0)
    expect(model.linkedCount).toBe(0)
    expect(model.anchors).toEqual([])
  })

  it('does not advertise delete-only diff rows as editor-focusable lines', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [],
      diffRows: [{ kind: 'delete', oldLine: 13, newLine: null, text: '-let old = ...' }],
      events: [],
      overlay: { ...overlay, cursors: new Map() },
    })

    expect(model.changedLineCount).toBe(1)
    expect(model.activeLineCount).toBe(0)
    expect(model.anchors[0]).toMatchObject({
      id: 'git-diff-summary',
      surface: 'Git',
    })
    expect(model.anchors[0]?.line).toBeUndefined()
  })

  it('does not advertise an unsupported log focus route param', () => {
    const model = deriveIdeContextLens({
      filePath: 'lib/keeper/keeper_exec_ide.ml',
      annotations: [],
      diffRows: [],
      events: [{
        id: 'evt-log',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
        target: 'telemetry',
        timestamp_ms: 400,
        context: {
          file_path: 'lib/keeper/keeper_exec_ide.ml',
          line: 27,
          log_id: 'turn-9',
        },
      }],
      overlay: { ...overlay, cursors: new Map() },
    })

    const logRoute = model.anchors[0]?.route_links?.find(link => link.label === 'Log')
    expect(logRoute?.params).toEqual({ section: 'runtime', view: 'audit' })
  })
})
