import { h } from 'preact'
import { fireEvent, render, screen } from '@testing-library/preact'
import { describe, expect, it, vi } from 'vitest'
import type { UnifiedTraceEvent } from './session-trace-state'
import { SessionTraceEntry } from './session-trace-entry'

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

vi.mock('../common/markdown', () => ({
  Markdown: ({ text }: { text: string }) => h('div', { 'data-testid': 'markdown' }, text),
}))

function sampleToolCallEvent(overrides: Partial<UnifiedTraceEvent> = {}): UnifiedTraceEvent {
  return {
    id: 'trace-1',
    ts: 1,
    ts_iso: '2026-04-03T00:00:00Z',
    kind: 'tool_call',
    summary: 'tool summary',
    detail: {},
    toolName: 'demo_tool',
    toolArgs: '{"arg":true}',
    toolResult: '{"ok":true,"detail":"completed"}',
    ...overrides,
  }
}

describe('SessionTraceEntry', () => {
  it('renders tool results through JsonViewerCard and parses JSON-string payloads', () => {
    const { container } = render(h(SessionTraceEntry, { event: sampleToolCallEvent() }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    const cards = screen.getAllByTestId('json-viewer-card')
    expect(cards).toHaveLength(2)
    expect(cards[0]?.getAttribute('data-title')).toBe('Args')
    expect(cards[0]?.textContent ?? '').toContain('"arg":true')
    expect(cards[1]?.getAttribute('data-title')).toBe('Result')
    expect(cards[1]?.textContent ?? '').toContain('"ok":true')
    expect(cards[1]?.textContent ?? '').toContain('"detail":"completed"')
  })

  it('labels error payloads as Error when expanded', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleToolCallEvent({ toolResult: null, error: 'plain error' }),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    // Args card is always rendered via JsonViewerCard
    const cards = screen.getAllByTestId('json-viewer-card')
    expect(cards).toHaveLength(1)
    expect(cards[0]?.getAttribute('data-title')).toBe('Args')

    // Plain-text errors render through ResultViewer <pre>, not JsonViewerCard
    // (detectContentHint returns 'plain' for non-JSON strings)
    const errorPre = container.querySelector('pre')
    expect(errorPre?.textContent ?? '').toContain('plain error')
  })
})
