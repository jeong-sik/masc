import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import type { UnifiedTraceEvent } from '../session-trace/session-trace-state'
import { activeFilter, activityListSearchQuery } from './task-detail-state'

vi.mock('../common/json-viewer', async importOriginal => {
  const actual = await importOriginal<typeof import('../common/json-viewer')>()
  return {
    ...actual,
    JsonViewerCard: ({ data, title }: { data: unknown; title?: string }) =>
      h('div', { 'data-testid': 'json-viewer-card', 'data-title': title ?? '' }, typeof data === 'string' ? data : JSON.stringify(data)),
  }
})
vi.mock('../common/time-ago', () => ({
  TimeAgo: ({ timestamp }: { timestamp: string }) => h('span', {}, timestamp),
}))

import { TaskActivityList, filterActivityEvents } from './task-activity-list'

function sampleToolCallEvent(overrides: Partial<UnifiedTraceEvent> = {}): UnifiedTraceEvent {
  return {
    id: 'evt-1',
    ts: 1,
    ts_iso: '2026-04-03T00:00:00Z',
    kind: 'tool_call',
    sourceLane: 'masc',
    summary: 'tool summary',
    detail: {},
    toolArgs: '*literal* `ticks`',
    toolResult: null,
    ...overrides,
  }
}

describe('TaskActivityList', () => {
  beforeEach(() => {
    activeFilter.value = 'all'
    activityListSearchQuery.value = ''
  })

  afterEach(() => {
    cleanup()
    activeFilter.value = 'all'
    activityListSearchQuery.value = ''
    vi.clearAllMocks()
  })

  it('renders the structured viewer lazily and preserves raw string payloads', async () => {
    const { container } = render(h(TaskActivityList, {
      events: [sampleToolCallEvent()],
      loading: false,
      error: null,
      showToolCalls: true,
    }))

    expect(screen.queryByTestId('json-viewer-card')).not.toBeInTheDocument()

    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event('toggle', { bubbles: true }))

    await waitFor(() => {
      expect(screen.getAllByTestId('json-viewer-card')).toHaveLength(1)
    })
    const blocks = screen.getAllByTestId('json-viewer-card')
    expect(blocks).toHaveLength(1)
    const firstBlock = blocks[0]
    expect(firstBlock).toBeDefined()
    if (!firstBlock) return
    const text = firstBlock.textContent ?? ''
    expect(text).toContain('*literal* `ticks`')
    expect(firstBlock).toHaveAttribute('data-title', 'Args')
  })

  it('passes object args into the structured viewer when expanded', async () => {
    const { container } = render(h(TaskActivityList, {
      events: [sampleToolCallEvent({ toolArgs: { ok: true } })],
      loading: false,
      error: null,
      showToolCalls: true,
    }))

    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event('toggle', { bubbles: true }))

    await waitFor(() => {
      expect(screen.getByTestId('json-viewer-card')).toBeInTheDocument()
    })
    const text = screen.getByTestId('json-viewer-card').textContent ?? ''
    expect(text).toContain('"ok":true')
  })

  it('parses JSON string payloads before passing them to the structured viewer', async () => {
    const { container } = render(h(TaskActivityList, {
      events: [sampleToolCallEvent({ toolArgs: undefined, toolResult: '{"ok":true}' })],
      loading: false,
      error: null,
      showToolCalls: true,
    }))

    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event('toggle', { bubbles: true }))

    await waitFor(() => {
      expect(screen.getByTestId('json-viewer-card')).toBeInTheDocument()
    })
    expect(screen.getByTestId('json-viewer-card')).toHaveAttribute('data-title', '결과')
    const text = screen.getByTestId('json-viewer-card').textContent ?? ''
    expect(text).toContain('"ok":true')
  })

  it('renders event.detail when expanded for lifecycle events without toolArgs/toolResult', async () => {
    const { container } = render(h(TaskActivityList, {
      events: [sampleToolCallEvent({
        kind: 'lifecycle',
        toolArgs: undefined,
        toolResult: null,
        detail: { agent: 'keeper-sojin-agent', event: 'turn_completed', turn: 42 },
      })],
      loading: false,
      error: null,
      showToolCalls: true,
    }))

    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event('toggle', { bubbles: true }))

    await waitFor(() => {
      expect(screen.getByTestId('json-viewer-card')).toBeInTheDocument()
    })
    const card = screen.getByTestId('json-viewer-card')
    expect(card).toHaveAttribute('data-title', '세부')
    const text = card.textContent ?? ''
    expect(text).toContain('keeper-sojin-agent')
    expect(text).toContain('turn_completed')
  })

  it('marks decorative icons as hidden from assistive tech', () => {
    const { container } = render(h(TaskActivityList, {
      events: [sampleToolCallEvent({ toolArgs: undefined, toolResult: null })],
      loading: false,
      error: null,
      showToolCalls: true,
    }))

    const icon = container.querySelector('[data-icon="Settings"]')
    expect(icon).not.toBeNull()
    expect(icon).toHaveAttribute('aria-hidden', 'true')
    expect(icon).toHaveAttribute('focusable', 'false')
  })

  it('narrows events when search query is entered', () => {
    const events = [
      sampleToolCallEvent({ id: 'e1', summary: 'fetch_keeper_trajectory' }),
      sampleToolCallEvent({ id: 'e2', summary: 'broadcast message', kind: 'broadcast', toolArgs: undefined, toolResult: null }),
    ]
    render(h(TaskActivityList, { events, loading: false, error: null, showToolCalls: true }))

    // Initially both rows visible
    expect(screen.getByText('fetch_keeper_trajectory')).toBeInTheDocument()
    expect(screen.getByText('broadcast message')).toBeInTheDocument()

    const input = screen.getByLabelText('활동 검색') as HTMLInputElement
    fireEvent.input(input, { target: { value: 'broadcast' } })

    expect(screen.queryByText('fetch_keeper_trajectory')).not.toBeInTheDocument()
    expect(screen.getByText('broadcast message')).toBeInTheDocument()
  })
})

describe('filterActivityEvents', () => {
  const base: UnifiedTraceEvent = {
    id: 'x',
    ts: 0,
    ts_iso: '2026-04-03T00:00:00Z',
    kind: 'tool_call',
    sourceLane: 'masc',
    summary: 's',
    detail: {},
  }

  it('returns all events when filter=all and query is empty', () => {
    const evs = [{ ...base, id: 'a' }, { ...base, id: 'b', kind: 'broadcast' as const }]
    expect(filterActivityEvents(evs, 'all', '')).toHaveLength(2)
  })

  it('filters by categorical kind', () => {
    const evs = [
      { ...base, id: 'a', kind: 'tool_call' as const },
      { ...base, id: 'b', kind: 'broadcast' as const },
      { ...base, id: 'c', kind: 'task' as const },
    ]
    const out = filterActivityEvents(evs, 'broadcast', '')
    expect(out).toHaveLength(1)
    expect(out[0]?.id).toBe('b')
  })

  it('matches free-text query against summary (case-insensitive)', () => {
    const evs = [
      { ...base, id: 'a', summary: 'Fetch Trajectory' },
      { ...base, id: 'b', summary: 'broadcast' },
    ]
    const out = filterActivityEvents(evs, 'all', 'TRAJECTORY')
    expect(out.map(e => e.id)).toEqual(['a'])
  })

  it('matches query against toolName, error, toolArgs (object), toolResult', () => {
    const evs: UnifiedTraceEvent[] = [
      { ...base, id: 'tool', toolName: 'masc_claim' },
      { ...base, id: 'err', summary: 'x', error: 'permission denied' },
      { ...base, id: 'args', summary: 'x', toolArgs: { room: 'alpha' } },
      { ...base, id: 'res', summary: 'x', toolResult: '{"ok":true}' },
      { ...base, id: 'none', summary: 'unrelated' },
    ]
    expect(filterActivityEvents(evs, 'all', 'masc_claim').map(e => e.id)).toEqual(['tool'])
    expect(filterActivityEvents(evs, 'all', 'denied').map(e => e.id)).toEqual(['err'])
    expect(filterActivityEvents(evs, 'all', 'alpha').map(e => e.id)).toEqual(['args'])
    expect(filterActivityEvents(evs, 'all', '"ok":true').map(e => e.id)).toEqual(['res'])
  })

  it('ignores whitespace-only query', () => {
    const evs = [{ ...base, id: 'a' }, { ...base, id: 'b' }]
    expect(filterActivityEvents(evs, 'all', '   ')).toHaveLength(2)
  })

  it('combines kind filter and text query (AND semantics)', () => {
    const evs: UnifiedTraceEvent[] = [
      { ...base, id: 'a', kind: 'tool_call', summary: 'alpha call' },
      { ...base, id: 'b', kind: 'broadcast', summary: 'alpha message' },
    ]
    const out = filterActivityEvents(evs, 'tool_call', 'alpha')
    expect(out.map(e => e.id)).toEqual(['a'])
  })
})
