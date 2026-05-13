import { afterEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { deriveIdeRunProgressSummary, IdeActivityMock } from './ide-activity-mock'
import { activeIdeFile, ideContextFocus } from './ide-state'

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  ideContextFocus.value = null
  activeIdeFile.value = 'package.json'
})

describe('IdeActivityMock', () => {
  it('renders the activity pane with empty state when no API data', () => {
    const container = document.createElement('div')
    render(h(IdeActivityMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('EVENT TIMELINE')
    expect(container.textContent).toContain('0 events · 0 keepers')
    expect(container.querySelector('[data-testid="ide-context-lens"]')).not.toBeNull()
    expect(container.textContent).toContain('RUN PROGRESS')
    expect(container.textContent).toContain('0/0 linked')
    expect(container.textContent).toContain('no keeper activity')
  })

  it('renders file context from annotation and diff props', () => {
    const container = document.createElement('div')
    render(h(IdeActivityMock, {
      activeFile: 'lib/runtime.ml',
      annotations: [{
        id: 'ann-1',
        file_path: 'lib/runtime.ml',
        line_start: 4,
        line_end: 4,
        keeper_id: 'sangsu',
        kind: 'Comment',
        content: 'Task status belongs next to this line',
        goal_id: 'goal-runtime',
        task_id: 'task-runtime',
        created_at_ms: 1,
        updated_at_ms: 1,
      }],
      diffRows: [{ kind: 'add', oldLine: null, newLine: 4, text: '+let x = 1' }],
    }), container)

    expect(container.textContent).toContain('CONTEXT LENS')
    expect(container.textContent).toContain('runtime.ml')
    expect(container.textContent).toContain('goal goal-runtime')
    expect(container.textContent).toContain('1 changed rows')
  })

  it('maps activity payload and tags into structured context lens links', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          room_id: 'run-default',
          kind: 'telemetry.turn',
          actor: { kind: 'keeper', id: 'sangsu' },
          subject: { kind: 'log', id: 'turn-1' },
          payload: {
            file_path: 'lib/runtime.ml',
            line: 4,
            goal_id: 'goal-runtime',
            comment_id: 'comment-1',
            pr_number: 15000,
          },
          tags: ['task:task-runtime', 'board:post-1', 'comment:comment-1', 'git:main', 'log:turn-1'],
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))

    const container = document.createElement('div')
    render(h(IdeActivityMock, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      expect(container.textContent).toContain('goal goal-runtime')
      expect(container.textContent).toContain('task task-runtime')
      expect(container.textContent).toContain('PR 15000')
      expect(container.textContent).toContain('1 line anchors')
      expect(container.textContent).toContain('1/1 linked')
    })

    const surfaces = [...container.querySelectorAll('.ide-run-progress-surfaces > span')]
      .map(node => node.textContent)
    expect(surfaces).toEqual(['Goal1', 'Task1', 'Board1', 'Comment1', 'PR1', 'Git1', 'Log1', 'Telemetry1'])

    const jump = container.querySelector<HTMLButtonElement>('.ide-activity-context-jump')
    expect(jump?.textContent).toContain('runtime.ml:4')
    fireEvent.click(jump!)

    expect(activeIdeFile.value).toBe('lib/runtime.ml')
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 4,
      surface: 'PR',
      keeper_id: 'sangsu',
      source_id: 'evt-1',
    })
  })

  it('ignores non-positive numeric payload ids when deriving context links', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        events: [{
          seq: 1,
          ts_ms: 100,
          ts_iso: '2026-05-05T10:00:00Z',
          room_id: 'run-default',
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
    render(h(IdeActivityMock, { activeFile: 'lib/runtime.ml' }), container)

    await waitFor(() => {
      const surfaces = [...container.querySelectorAll('.ide-run-progress-surfaces > span')]
        .map(node => node.textContent)
      expect(surfaces).toEqual(['Goal0', 'Task0', 'Board0', 'Comment0', 'PR0', 'Git0', 'Log1', 'Telemetry1'])
    })
  })

  it('derives a compact run progress summary from activity events', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-05-05T10:01:30Z'))

    const summary = deriveIdeRunProgressSummary([
      {
        id: 'evt-1',
        run_id: 'run-default',
        keeper_id: 'sangsu',
        verb: 'noted',
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
        verb: 'committed',
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
        verb: 'commented on',
        target: 'board:post-1',
        timestamp_ms: Date.parse('2026-05-05T09:59:00Z'),
        context: {
          board_post_id: 'post-1',
          comment_id: 'comment-1',
        },
      },
    ], 'lib/runtime.ml')

    expect(summary).toMatchObject({
      totalEvents: 3,
      currentFileEvents: 1,
      linkedEvents: 3,
      keeperTotalCount: 2,
      latestAgeLabel: '30s ago',
    })
    expect(summary.surfaceCounts.map(surface => [surface.label, surface.count])).toEqual([
      ['Goal', 1],
      ['Task', 1],
      ['Board', 1],
      ['Comment', 1],
      ['PR', 1],
      ['Git', 1],
      ['Log', 1],
      ['Telemetry', 3],
    ])
    expect(summary.keeperCounts).toEqual([
      { keeper_id: 'sangsu', count: 2 },
      { keeper_id: 'analyst', count: 1 },
    ])
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
  })
})
