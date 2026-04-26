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
    sourceLane: 'masc',
    summary: 'tool summary',
    detail: {},
    toolName: 'demo_tool',
    toolArgs: '{"arg":true}',
    toolResult: '{"ok":true,"detail":"completed"}',
    ...overrides,
  }
}

function sampleThinkingEvent(overrides: Partial<UnifiedTraceEvent> = {}): UnifiedTraceEvent {
  return {
    id: 'thinking-1',
    ts: 2,
    ts_iso: '2026-04-03T00:01:00Z',
    kind: 'thinking',
    sourceLane: 'masc',
    summary: 'thinking block (120 chars)',
    detail: {},
    thinkingContent: 'The user wants to refactor the module. I should check the dependency graph first.',
    thinkingRedacted: false,
    ...overrides,
  }
}

describe('SessionTraceEntry', () => {
  it('renders tool args through JsonViewerCard and result through ResultViewer', () => {
    const { container } = render(h(SessionTraceEntry, { event: sampleToolCallEvent() }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    // Args still uses JsonViewerCard
    const cards = screen.getAllByTestId('json-viewer-card')
    expect(cards.length).toBeGreaterThanOrEqual(1)
    expect(cards[0]?.textContent ?? '').toContain('"arg":true')

    // Result is rendered by ResultViewer (may be pre or JsonViewerCard depending on content type)
    const resultText = container.textContent ?? ''
    expect(resultText).toContain('"ok":true')
  })

  it('labels error payloads as Error when expanded', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleToolCallEvent({ toolResult: null, error: 'plain error' }),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    // Args card is always rendered via JsonViewerCard
    const cards = screen.getAllByTestId('json-viewer-card')
    expect(cards).toHaveLength(1)
    expect(cards[0]?.getAttribute('data-title')).toBe('인자')

    // Plain-text errors render through ResultViewer <pre>, not JsonViewerCard
    const errorPre = container.querySelector('pre')
    expect(errorPre?.textContent ?? '').toContain('plain error')

    // ResultViewer should display the "Error" title label
    expect(screen.getByText('Error')).toBeTruthy()
  })

  it('renders ThinkingDetail with markdown content when expanded', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleThinkingEvent(),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    const mdBlocks = screen.getAllByTestId('markdown')
    expect(mdBlocks.length).toBeGreaterThanOrEqual(1)
    const thinkingMd = mdBlocks.find(el =>
      (el.textContent ?? '').includes('refactor the module'),
    )
    expect(thinkingMd).toBeDefined()
  })

  it('renders redacted ThinkingDetail with placeholder text', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleThinkingEvent({
        thinkingRedacted: true,
        thinkingContent: undefined,
      }),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    // The redacted placeholder should be visible (Korean text)
    expect(container.textContent).toContain('비공개 처리')
  })
})
