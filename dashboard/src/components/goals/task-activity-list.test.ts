import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import type { UnifiedTraceEvent } from '../session-trace/session-trace-state'
import { activeFilter } from './task-detail-state'

vi.mock('../common/markdown', () => ({
  Markdown: ({ text }: { text: string }) => h('div', { 'data-testid': 'markdown' }, text),
}))

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

  it('renders markdown lazily and preserves raw string payloads inside code fences', async () => {
    const { container } = render(h(TaskActivityList, {
      events: [sampleToolCallEvent()],
      loading: false,
      error: null,
      showToolCalls: true,
    }))

    expect(screen.queryByTestId('markdown')).not.toBeInTheDocument()

    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event('toggle', { bubbles: true }))

    await waitFor(() => {
      expect(screen.getAllByTestId('markdown')).toHaveLength(1)
    })
    const blocks = screen.getAllByTestId('markdown')
    expect(blocks).toHaveLength(1)
    const text = blocks[0].textContent ?? ''
    expect(text.startsWith('```')).toBe(true)
    expect(text).toContain('*literal* `ticks`')
    expect(text.endsWith('```')).toBe(true)
  })

  it('formats object args as fenced json when expanded', async () => {
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
      expect(screen.getByTestId('markdown')).toBeInTheDocument()
    })
    const text = screen.getByTestId('markdown').textContent ?? ''
    expect(text.startsWith('```json')).toBe(true)
    expect(text).toContain('"ok": true')
    expect(text.endsWith('```')).toBe(true)
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
