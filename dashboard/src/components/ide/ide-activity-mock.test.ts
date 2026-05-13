import { afterEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { IdeActivityMock } from './ide-activity-mock'
import { activeIdeFile, ideContextFocus } from './ide-state'

afterEach(() => {
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
            pr_number: 15000,
          },
          tags: ['task:task-runtime', 'board:post-1', 'git:main', 'log:turn-1'],
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
    })

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
})
