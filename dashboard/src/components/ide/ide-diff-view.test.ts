// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { fireEvent } from '@testing-library/preact'
import { render } from 'preact'
import type { UnifiedDiffRow } from '../../api/workspace'
import {
  buildSplitDiff,
  diffContextFocusForRows,
  formatDiffLineRange,
  formatDiffSummaryAria,
  SplitDiffView,
  summarizeDiffRows,
  UnifiedDiffView,
} from './ide-diff-view'

const row = (
  kind: 'context' | 'add' | 'delete',
  oldLine: number | null,
  newLine: number | null,
  text: string,
): UnifiedDiffRow => ({ kind, oldLine, newLine, text })

describe('buildSplitDiff', () => {
  it('maps context rows to both sides', () => {
    const result = buildSplitDiff([
      row('context', 1, 1, 'unchanged'),
    ])
    expect(result).toHaveLength(1)
    expect(result[0]!.before?.kind).toBe('context')
    expect(result[0]!.after?.kind).toBe('context')
    expect(result[0]!.before?.text).toBe('unchanged')
  })

  it('pairs deletes with adds', () => {
    const result = buildSplitDiff([
      row('delete', 1, null, 'old line'),
      row('add', null, 1, 'new line'),
    ])
    expect(result).toHaveLength(1)
    expect(result[0]!.before?.kind).toBe('delete')
    expect(result[0]!.before?.text).toBe('old line')
    expect(result[0]!.after?.kind).toBe('add')
    expect(result[0]!.after?.text).toBe('new line')
  })

  it('handles unequal delete/add counts', () => {
    const result = buildSplitDiff([
      row('delete', 1, null, 'a'),
      row('delete', 2, null, 'b'),
      row('add', null, 1, 'c'),
    ])
    expect(result).toHaveLength(2)
    expect(result[0]!.before?.text).toBe('a')
    expect(result[0]!.after?.text).toBe('c')
    expect(result[1]!.before?.text).toBe('b')
    expect(result[1]!.after).toBeNull()
  })

  it('handles mixed context and changes', () => {
    const result = buildSplitDiff([
      row('context', 1, 1, 'keep'),
      row('delete', 2, null, 'gone'),
      row('add', null, 2, 'here'),
      row('context', 3, 3, 'keep2'),
    ])
    expect(result).toHaveLength(3)
    expect(result[0]!.before?.text).toBe('keep')
    expect(result[1]!.before?.text).toBe('gone')
    expect(result[1]!.after?.text).toBe('here')
    expect(result[2]!.before?.text).toBe('keep2')
  })

  it('returns empty for no rows', () => {
    expect(buildSplitDiff([])).toEqual([])
  })

  it('handles only adds', () => {
    const result = buildSplitDiff([
      row('add', null, 1, 'added'),
      row('add', null, 2, 'more'),
    ])
    expect(result).toHaveLength(2)
    expect(result[0]!.before).toBeNull()
    expect(result[0]!.after?.text).toBe('added')
    expect(result[1]!.before).toBeNull()
    expect(result[1]!.after?.text).toBe('more')
  })
})

describe('summarizeDiffRows', () => {
  it('counts diff tones and derives visible old/new line windows', () => {
    const summary = summarizeDiffRows([
      row('context', 10, 10, 'keep'),
      row('delete', 11, null, 'remove'),
      row('add', null, 11, 'add'),
      row('add', null, 12, 'also add'),
      row('context', 12, 13, 'keep again'),
    ])
    expect(summary).toEqual({
      total: 5,
      additions: 2,
      deletions: 1,
      context: 2,
      changed: 3,
      oldRange: { start: 10, end: 12 },
      newRange: { start: 10, end: 13 },
    })
  })

  it('returns empty ranges for empty rows', () => {
    const summary = summarizeDiffRows([])
    expect(summary.total).toBe(0)
    expect(summary.changed).toBe(0)
    expect(formatDiffLineRange(summary.oldRange)).toBe('n/a')
    expect(formatDiffLineRange(summary.newRange)).toBe('n/a')
  })

  it('matches current context focus against old or new diff lines', () => {
    const rows = [
      row('delete', 4, null, 'old'),
      row('add', null, 5, 'new'),
    ]
    expect(diffContextFocusForRows(rows, {
      file_path: 'lib/runtime.ml',
      line: 5,
      surface: 'Task',
      label: 'task task-runtime',
      source_id: 'event-1',
      activated_at_ms: Date.now(),
    })?.line).toBe(5)
    expect(diffContextFocusForRows(rows, {
      file_path: 'lib/runtime.ml',
      line: 9,
      surface: 'Task',
      label: 'task task-runtime',
      source_id: 'event-1',
      activated_at_ms: Date.now(),
    })).toBeNull()
  })
})

describe('formatDiffSummaryAria', () => {
  it('produces a screen-reader summary with pluralized counts', () => {
    const summary = summarizeDiffRows([
      row('delete', 4, null, 'old'),
      row('add', null, 4, 'new'),
      row('context', 5, 5, 'same'),
    ])
    expect(formatDiffSummaryAria(summary, 'Unified')).toBe(
      'Unified diff summary: 1 addition, 1 deletion, 1 context row, old lines 4-5, new lines 4-5',
    )
  })
})

describe('diff preview chrome', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    window.location.hash = ''
  })

  it('renders unified summary chips before diff rows', () => {
    render(UnifiedDiffView([
      row('delete', 4, null, 'old value'),
      row('add', null, 4, 'new value'),
      row('context', 5, 5, 'same value'),
    ]), container)

    expect(container.querySelector('[role="status"]')?.getAttribute('aria-label')).toContain('Unified diff summary')
    expect(container.querySelector('[data-status-chip-tone="ok"]')?.textContent).toBe('+1')
    expect(container.querySelector('[data-status-chip-tone="bad"]')?.textContent).toBe('-1')
    expect(container.querySelector('[data-status-chip-tone="info"]')?.textContent).toBe('old 4-5 -> new 4-5')
    expect(container.querySelector('[aria-label="Unified diff rows"]')?.textContent).toContain('new value')
  })

  it('renders focused diff context and routes through its links', () => {
    render(UnifiedDiffView([
      row('delete', 4, null, 'old value'),
      row('add', null, 4, 'new value'),
      row('context', 5, 5, 'same value'),
    ], {
      file_path: 'lib/runtime.ml',
      line: 4,
      surface: 'Task',
      label: 'task task-runtime',
      source_id: 'event-1',
      activated_at_ms: Date.now(),
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
    }), container)

    const focus = container.querySelector('[data-testid="ide-diff-context-focus"]')
    expect(focus?.getAttribute('aria-label'))
      .toBe('Diff context: Task line 4, task task-runtime, 2 route links')
    expect(focus?.textContent).toContain('Task')
    expect(focus?.textContent).toContain('L4')
    expect(container.querySelectorAll('[data-context-focus="true"]')).toHaveLength(2)

    const telemetry = [...container.querySelectorAll<HTMLButtonElement>('.ide-diff-context-links button')]
      .find(button => button.textContent === 'Telemetry')
    fireEvent.click(telemetry!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=turn-9')
  })

  it('renders split empty state instead of a blank pane', () => {
    render(SplitDiffView([]), container)
    expect(container.querySelector('[role="status"]')?.getAttribute('aria-label')).toContain('Split diff summary')
    expect(container.querySelector('[role="note"]')?.textContent).toContain('No split diff rows')
  })
})
