import { h } from 'preact'
import { fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { UnifiedTraceEvent } from './session-trace-state'
import { SessionTraceEntry, traceRouteLinks } from './session-trace-entry'

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

afterEach(() => {
  window.location.hash = ''
})

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

  it('applies v2 monitoring marker classes to trace row and detail', () => {
    const { container } = render(h(SessionTraceEntry, { event: sampleToolCallEvent() }))
    expect(container.querySelector('.v2-monitoring-trace-row')).not.toBeNull()
    expect(container.querySelector('.v2-monitoring-trace-detail')).not.toBeNull()
  })

  it('links safe tool-call file args back to the Code IDE route', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleToolCallEvent({
        agentName: 'sangsu',
        toolArgs: { file_path: 'lib/runtime.ml', line: 12 },
      }),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)
    const codeLink = screen.getByTestId('session-trace-code-link')
    expect(codeLink.textContent).toBe('Code')
    expect(codeLink.getAttribute('title')).toBe('Code lib/runtime.ml:12')

    fireEvent.click(codeLink)
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=12&surface=Tool&label=demo_tool&source_id=trace-1&keeper=sangsu')
  })

  it('renders tool-call operational context links from trace detail and top-level ids', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleToolCallEvent({
        id: 'trace-context-1',
        agentName: 'sangsu',
        sessionId: 'sess-9',
        operationId: 'op-9',
        workerRunId: 'wr-9',
        toolArgs: { file_path: 'lib/runtime.ml', line: 12 },
        detail: {
          task_id: 'task-runtime',
          pr_id: '15035',
          git_ref: 'abc123',
          log_id: 'turn-9',
        },
      }),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    const contextLinks = screen.getAllByTestId('session-trace-context-link')
    expect(contextLinks.map(link => link.textContent)).toEqual([
      'Tasktask-runtime',
      'PR15035',
      'Gitabc123',
      'Logturn-9',
      'Telemetrysession sess-9 · operation op-9 · worker wr-9 · query turn-9',
      'Keepersangsu',
    ])

    fireEvent.click(contextLinks.find(link => link.textContent?.startsWith('Telemetry'))!)
    expect(window.location.hash).toBe(
      '#monitoring?section=fleet-health&view=event-log&session_id=sess-9&operation_id=op-9&worker_run_id=wr-9&q=turn-9',
    )
  })

  it('expands lifecycle trace rows when nested evidence carries IDE context', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: {
        id: 'lifecycle-context-1',
        ts: 3,
        ts_iso: '2026-04-03T00:02:00Z',
        kind: 'lifecycle',
        sourceLane: 'masc',
        summary: 'checkpoint saved',
        detail: {
          evidence_ref: {
            file_path: 'lib/keeper.ml',
            line: 7,

            operation_id: 'op-runtime',
          },
        },
        agentName: 'sangsu',
      },
    }))

    const summary = container.querySelector('summary')
    expect(summary).not.toBeNull()
    fireEvent.click(summary as HTMLElement)

    const contextLinks = screen.getAllByTestId('session-trace-context-link')
    expect(contextLinks.map(link => link.getAttribute('aria-label'))).toEqual([
      'Open Code lib/keeper.ml:7',
      'Open Fleet telemetry event log · operation op-runtime · query lifecycle-context-1',
      'Open Keeper sangsu',
    ])

    fireEvent.click(contextLinks[0]!)
    expect(window.location.hash).toBe(
      '#code?section=ide-shell&view=source&file=lib%2Fkeeper.ml&line=7&surface=%EC%83%9D%EB%AA%85%EC%A3%BC%EA%B8%B0&label=checkpoint+saved&source_id=lifecycle-context-1&keeper=sangsu',
    )
  })

  it('derives trace route links from nested detail records without rendering', () => {
    const links = traceRouteLinks(sampleToolCallEvent({
      agentName: 'keeper-alpha',
      detail: {
        context: {
          board_post_id: 'post-1',
          comment_id: 'comment-1',
        },
      },
    }))

    expect(links.map(link => link.label)).toEqual(['Board', 'Comment', 'Keeper'])
  })

  it('shows tok/sec for durable LLM response lifecycle details', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: {
        id: 'llm-response-1',
        ts: 4,
        ts_iso: '2026-04-03T00:03:00Z',
        kind: 'lifecycle',
        sourceLane: 'oas',
        summary: 'LLM response',
        detail: {
          durable_kind: 'llm_response',
          output_tokens: 80,
          duration_ms: 2000,
          stop_reason: 'stop',
        },
      },
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    expect(container.textContent ?? '').toContain('40.0 tok/s')
  })

  it('does not render Code links for unsafe absolute tool-call file args', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleToolCallEvent({
        toolArgs: { file_path: '/tmp/runtime.ml', line: 12 },
      }),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)
    expect(screen.queryByTestId('session-trace-code-link')).toBeNull()
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

  it('surfaces redacted tool I/O preview state when full details are withheld', () => {
    const { container } = render(h(SessionTraceEntry, {
      event: sampleToolCallEvent({
        toolArgs: undefined,
        toolResult: null,
        detail: { tool_io_redacted: true },
      }),
    }))

    fireEvent.click(container.querySelector('summary') as HTMLElement)

    expect(screen.getByText('Tool I/O preview redacted')).toBeTruthy()
    expect(container.textContent ?? '').not.toContain('세부 정보가 기록되지 않았습니다.')
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
