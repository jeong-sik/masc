import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { deriveIdeContextLens, IdeContextLens } from './ide-context-lens'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import type { AnchoredThread } from './anchored-thread-rail-store'
import type { KeeperCursorOverlay } from './keeper-cursor-overlay'
import type { RunActivityEvent } from './run-activity-store'

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
    expect(model.activeLineCount).toBe(2)
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
    expect(counts.get('git')).toBeGreaterThan(0)
    expect(counts.get('pr')).toBeGreaterThan(0)
    expect(counts.get('log')).toBeGreaterThan(0)
    expect(model.anchors[0]).toMatchObject({
      surface: 'PR',
      line: 27,
      keeper_id: 'sangsu',
    })
    expect(model.anchors[0]?.meta).toContain('goal goal-ide')
  })
})
