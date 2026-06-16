import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { IdeMemoryPanel } from './ide-memory-panel'

describe('IdeMemoryPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({
        entries: [{
          id: 'mem-1',
          kind: 'Comment',
          content: 'remember this',
          file_path: 'lib/runtime.ml',
          line_start: 12,
          line_end: 12,
          keeper_id: 'sangsu',
          created_at_ms: Date.now(),
          goal_id: 'goal-runtime',
          task_id: null,
        }],
        total: 1,
        limit: 50,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }),
    ))
  })

  afterEach(() => {
    render(null, container)
    vi.unstubAllGlobals()
  })

  it('renders v2 IDE marker classes for the panel, rows, and action button', async () => {
    render(h(IdeMemoryPanel, { keeperName: 'sangsu' }), container)

    await waitFor(() => {
      expect(container.querySelector('.ide-memory-panel.v2-ide-panel')).not.toBeNull()
      expect(container.querySelector('.ide-memory-panel__entry.v2-ide-row')).not.toBeNull()
    })
    expect(container.querySelector('.ide-memory-panel__refresh.v2-ide-action')).not.toBeNull()
  })
})
