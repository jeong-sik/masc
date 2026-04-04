import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import type { UnifiedTraceEvent } from '../session-trace/session-trace-state'
import { activeFilter } from './task-detail-state'

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

  it('renders string args lazily and preserves the raw payload text', async () => {
    const { container } = render(h(TaskActivityList, {
      events: [sampleToolCallEvent()],
      loading: false,
      error: null,
      showToolCalls: true,
    }))

    expect(screen.queryByText('Args')).not.toBeInTheDocument()
    expect(screen.queryByText('"*literal* `ticks`"')).not.toBeInTheDocument()

    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    if (!details) return

    details.open = true
    fireEvent(details, new Event('toggle', { bubbles: true }))

    await waitFor(() => {
      expect(screen.getByText('Args')).toBeInTheDocument()
    })
    expect(screen.getByText('"*literal* `ticks`"')).toBeInTheDocument()
  })

  it('renders object args in the JsonViewer when expanded', async () => {
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
      expect(screen.getByRole('button', { name: 'Collapse JSON object' })).toBeInTheDocument()
    })
    expect(screen.getByText('Args')).toBeInTheDocument()
    expect(screen.getByText('ok:')).toBeInTheDocument()
    expect(screen.getByText('true')).toBeInTheDocument()
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
