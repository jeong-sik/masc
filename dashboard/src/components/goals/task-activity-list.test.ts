import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import type { UnifiedTraceEvent } from '../session-trace/session-trace-state'
import { activeFilter } from './task-detail-state'

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

import { TaskActivityList } from './task-activity-list'

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
  })

  afterEach(() => {
    cleanup()
    activeFilter.value = 'all'
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
    expect(screen.getByTestId('json-viewer-card')).toHaveAttribute('data-title', 'Result')
    const text = screen.getByTestId('json-viewer-card').textContent ?? ''
    expect(text).toContain('"ok":true')
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
})
