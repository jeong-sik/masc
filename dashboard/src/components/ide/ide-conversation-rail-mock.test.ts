import { afterEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { IdeConversationRailMock, replayRailItems } from './ide-conversation-rail-mock'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('IdeConversationRailMock', () => {
  it('renders the conversation rail with empty state when no API data', () => {
    const container = document.createElement('div')
    render(h(IdeConversationRailMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('REACTION THREAD')
    expect(container.textContent).toContain('REACTION THREAD')
    expect(container.textContent).toContain('0')
  })

  it('orders thread, decision, and cascade replay items on one timeline', () => {
    const items = replayRailItems(
      [{
        id: 'thread-old',
        title: 'old thread',
        body: 'thread body',
        author_identity: 'sangsu',
        votes: 0,
        comment_count: 0,
        created_at_iso: '2026-05-05T10:00:00Z',
      }],
      [{
        ts_unix: Date.UTC(2026, 4, 5, 10, 1, 0) / 1000,
        keeper_name: 'scholar',
        event_type: 'turn',
        outcome: 'success',
        model_used: 'glm:auto',
        latency_ms: null,
        cost_usd: null,
        input_tokens: null,
        output_tokens: null,
        stop_reason: null,
        error_category: null,
        tool: null,
        duration_ms: null,
        match_count: null,
      }],
      [{
        ts: Date.UTC(2026, 4, 5, 10, 2, 0) / 1000,
        cascade_name: 'big_three',
        strategy: 'ranked',
        cycle: 1,
        candidates_in: 3,
        candidates_out: 2,
        backoff_ms: 0,
        kind: 'ordered',
      }],
    )

    expect(items.map(item => item.source)).toEqual(['cascade', 'decision', 'thread'])
  })

  it('uses one replay cursor for thread, decision, and cascade rail items', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (url.startsWith('/api/v1/board')) {
        return new Response(JSON.stringify([
          {
            id: 'thread-old',
            title: 'old thread',
            body: 'old thread body',
            author_identity: 'sangsu',
            votes: 0,
            comment_count: 0,
            created_at_iso: '2026-05-05T10:00:00Z',
          },
          {
            id: 'thread-new',
            title: 'new thread',
            body: 'new thread body',
            author_identity: 'scholar',
            votes: 0,
            comment_count: 0,
            created_at_iso: '2026-05-05T10:03:00Z',
          },
        ]), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.startsWith('/api/v1/dashboard/keeper-decisions')) {
        return new Response(JSON.stringify({
          events: [{
            ts_unix: Date.UTC(2026, 4, 5, 10, 1, 0) / 1000,
            keeper_name: 'scholar',
            event_type: 'turn_completed',
            outcome: 'success',
            model_used: 'glm:auto',
          }],
          limit: 200,
          generated_at: null,
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.startsWith('/api/v1/cascade/strategy_trace')) {
        return new Response(JSON.stringify({
          updated_at: '2026-05-05T10:04:00Z',
          total_events: 1,
          events: [{
            ts: Date.UTC(2026, 4, 5, 10, 2, 0) / 1000,
            cascade_name: 'big_three',
            strategy: 'ranked',
            cycle: 1,
            candidates_in: 3,
            candidates_out: 2,
            backoff_ms: 0,
            kind: 'ordered',
          }],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response('{}', { status: 404 })
    })
    vi.stubGlobal('fetch', fetchMock)

    const container = document.createElement('div')
    render(h(IdeConversationRailMock, {}), container)

    await waitFor(() => {
      expect(container.textContent).toContain('new thread body')
      expect(container.textContent).toContain('turn_completed')
      expect(container.textContent).toContain('big_three')
    })

    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }))

    await waitFor(() => {
      expect(container.textContent).toContain('old thread body')
      expect(container.textContent).toContain('1/2 threads')
      expect(container.textContent).toContain('0/1 decisions')
      expect(container.textContent).toContain('0/1 cascade')
    })
    expect(container.textContent).not.toContain('new thread body')
    expect(container.textContent).not.toContain('turn_completed')
    expect(container.textContent).not.toContain('big_three')

    render(null, container)
  })
})
