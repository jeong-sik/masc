import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import {
  conversationContextSummary,
  IdeConversationRail,
  postsToAnchoredThreads,
  replayRailItems,
} from './ide-conversation-rail'
import { activeIdeFile, ideContextFocus } from './ide-state'
import { clearTraces, keeperTraceState } from './keeper-trace-store'
import { ideReplayUntilMs, setIdeReplayUntilMs } from './ide-replay-state'
import { cursorOverlaySignal } from './keeper-cursor-overlay'

function stubEmptyConversationFetch(): void {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    if (url.startsWith('/api/v1/board')) {
      return new Response(JSON.stringify([]), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    if (url.startsWith('/api/v1/dashboard/keeper-decisions')) {
      return new Response(JSON.stringify({ events: [], limit: 200, generated_at: null }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    if (url.startsWith('/api/v1/cascade/strategy_trace')) {
      return new Response(JSON.stringify({ updated_at: null, total_events: 0, events: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    return new Response('{}', { status: 404 })
  }))
}

beforeEach(() => {
  stubEmptyConversationFetch()
})

afterEach(() => {
  vi.unstubAllGlobals()
  activeIdeFile.value = 'package.json'
  ideContextFocus.value = null
  setIdeReplayUntilMs(null)
  cursorOverlaySignal.value = {
    cursors: new Map(),
    heatmap: new Map(),
    collisions: [],
    active_file: null,
  }
  window.location.hash = ''
  clearTraces()
})

describe('IdeConversationRail', () => {
  it('renders the conversation rail with empty state when no API data', () => {
    const container = document.createElement('div')
    render(h(IdeConversationRail, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('REACTION THREAD')
    expect(region?.classList.contains('ide-conversation-panel')).toBe(true)
    expect(container.querySelector('.ide-rail-scope')?.getAttribute('aria-label')).toBe('Keeper workspace scope')
    expect(container.querySelector('.ide-rail-list')).not.toBeNull()
    expect(container.textContent).toContain('REACTION THREAD')
    expect(container.textContent).toContain('0')
    expect(container.textContent).toContain('no conversation activity')
  })

  it('normalizes explicit board post file references into anchored threads', () => {
    const threads = postsToAnchoredThreads([
      {
        id: 'thread-line',
        author: 'scholar',
        title: 'Review lib/runtime.ml:42',
        body: 'question fn:run about this line',
        content: 'question fn:run about this line',
        tags: [],
        author_identity: { kind: 'keeper', id: 'scholar', key: 'scholar', display_name: 'scholar', raw: 'scholar' },
        votes: 0,
        comment_count: 2,
        created_at: '2026-05-05T10:00:00Z',
        updated_at: '2026-05-05T10:00:00Z',
      },
      {
        id: 'thread-file',
        author: 'sangsu',
        title: 'File-level note',
        body: 'looks good',
        content: 'looks good',
        tags: [],
        author_identity: { kind: 'keeper', id: 'sangsu', key: 'sangsu', display_name: 'sangsu', raw: 'sangsu' },
        votes: 1,
        comment_count: 0,
        created_at: '2026-05-05T10:01:00Z',
        updated_at: '2026-05-05T10:01:00Z',
      },
      {
        id: 'thread-windows-path',
        author: 'scholar',
        title: 'Review ./lib\\runtime.ml:43',
        body: 'question about normalized file path',
        content: 'question about normalized file path',
        tags: [],
        author_identity: { kind: 'keeper', id: 'scholar', key: 'scholar', display_name: 'scholar', raw: 'scholar' },
        votes: 0,
        comment_count: 1,
        created_at: '2026-05-05T10:02:00Z',
        updated_at: '2026-05-05T10:02:00Z',
      },
      {
        id: 'thread-absolute-path',
        author: 'scholar',
        title: 'Review /workspace/lib/runtime.ml:44',
        body: 'should not anchor unsafe absolute paths',
        content: 'should not anchor unsafe absolute paths',
        tags: [],
        author_identity: { kind: 'keeper', id: 'scholar', key: 'scholar', display_name: 'scholar', raw: 'scholar' },
        votes: 0,
        comment_count: 1,
        created_at: '2026-05-05T10:03:00Z',
        updated_at: '2026-05-05T10:03:00Z',
      },
    ])

    expect(threads).toHaveLength(2)
    expect(threads[0]).toMatchObject({
      id: 'thread-line',
      anchor: {
        file_path: 'lib/runtime.ml',
        line_start: 42,
        line_end: 42,
        symbol_hint: 'fn:run',
      },
      reply_count: 2,
    })
    expect(threads[1]).toMatchObject({
      id: 'thread-windows-path',
      anchor: {
        file_path: 'lib/runtime.ml',
        line_start: 43,
        line_end: 43,
      },
      reply_count: 1,
    })
  })

  it('does not reanchor generic board posts when the active file changes', () => {
    const posts = [{
      id: 'thread-generic',
      author: 'sangsu',
      title: 'File-level note',
      body: 'looks good',
      content: 'looks good',
      tags: [],
      author_identity: { kind: 'keeper', id: 'sangsu', key: 'sangsu', display_name: 'sangsu', raw: 'sangsu' },
      votes: 1,
      comment_count: 0,
      created_at: '2026-05-05T10:01:00Z',
      updated_at: '2026-05-05T10:01:00Z',
    }]

    expect(postsToAnchoredThreads(posts)).toEqual([])
    activeIdeFile.value = 'lib/runtime.ml'
    expect(postsToAnchoredThreads(posts)).toEqual([])
  })

  it('orders thread, decision, and cascade replay items on one timeline', () => {
    const items = replayRailItems(
      [{
        id: 'thread-old',
        author: 'sangsu',
        title: 'old thread',
        body: 'thread body',
        content: 'thread body',
        tags: [],
        author_identity: { kind: 'keeper', id: 'sangsu', key: 'sangsu', display_name: 'sangsu', raw: 'sangsu' },
        votes: 0,
        comment_count: 0,
        created_at: '2026-05-05T10:00:00Z',
        updated_at: '2026-05-05T10:00:00Z',
      }],
      [{
        ts_unix: Date.UTC(2026, 4, 5, 10, 1, 0) / 1000,
        keeper_name: 'scholar',
        event_type: 'turn',
        outcome: 'success',
        choice: null,
        reason: null,
        context: null,
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
        cascade_name: 'primary',
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
            author: 'sangsu',
            title: 'old thread',
            body: 'old thread body',
            content: 'old thread body',
            tags: [],
            author_identity: { kind: 'keeper', id: 'sangsu', key: 'sangsu', display_name: 'sangsu', raw: 'sangsu' },
            votes: 0,
            comment_count: 0,
            created_at: '2026-05-05T10:00:00Z',
            updated_at: '2026-05-05T10:00:00Z',
          },
          {
            id: 'thread-new',
            author: 'scholar',
            title: 'new thread',
            body: 'new thread body',
            content: 'new thread body',
            tags: [],
            author_identity: { kind: 'keeper', id: 'scholar', key: 'scholar', display_name: 'scholar', raw: 'scholar' },
            votes: 0,
            comment_count: 0,
            created_at: '2026-05-05T10:03:00Z',
            updated_at: '2026-05-05T10:03:00Z',
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
            model_used: null,
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
            cascade_name: 'primary',
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
    render(h(IdeConversationRail, {}), container)

    await waitFor(() => {
      expect(container.textContent).toContain('new thread body')
      expect(container.textContent).toContain('turn_completed')
      expect(container.textContent).toContain('primary')
    })

    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }))

    await waitFor(() => {
      expect(ideReplayUntilMs.value).toBe(Date.UTC(2026, 4, 5, 10, 0, 0))
      expect(container.textContent).toContain('old thread body')
      expect(container.textContent).toContain('1/2 threads')
      expect(container.textContent).toContain('0/1 decisions')
      expect(container.textContent).toContain('0/1 cascade')
    })
    expect(container.textContent).not.toContain('new thread body')
    expect(container.textContent).not.toContain('turn_completed')
    expect(container.textContent).not.toContain('primary')

    render(null, container)
  })

  it('renders route links for keeper decision and cascade replay entries', async () => {
    const decisionTs = Date.UTC(2026, 4, 5, 10, 1, 0) / 1000
    const cascadeTs = Date.UTC(2026, 4, 5, 10, 2, 0) / 1000
    cursorOverlaySignal.value = {
      cursors: new Map([[
        'scholar',
        {
          keeper_id: 'scholar',
          file_path: 'lib/runtime.ml',
          line: 42,
          column: 3,
          focus_mode: 'reviewing',
          last_update: Date.UTC(2026, 4, 5, 10, 1, 30),
        },
      ]]),
      heatmap: new Map(),
      collisions: [],
      active_file: 'lib/runtime.ml',
    }
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
      if (url.startsWith('/api/v1/board')) {
        return new Response(JSON.stringify([]), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.startsWith('/api/v1/dashboard/keeper-decisions')) {
        return new Response(JSON.stringify({
          events: [{
            ts_unix: decisionTs,
            keeper_name: 'scholar',
            event_type: 'turn_completed',
            outcome: 'success',
            model_used: 'glm:auto',
            latency_ms: null,
            cost_usd: null,
            input_tokens: null,
            output_tokens: null,
            stop_reason: null,
            error_category: null,
            tool: 'apply_patch',
            duration_ms: null,
            match_count: null,
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
            ts: cascadeTs,
            cascade_name: 'primary',
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
    }))

    const container = document.createElement('div')
    render(h(IdeConversationRail, {}), container)

    await waitFor(() => {
      expect(container.textContent).toContain('turn_completed')
      expect(container.textContent).toContain('primary')
    })

    const decisionCard = container.querySelector<HTMLElement>('[data-replay-source="decision"]')
    expect(decisionCard).not.toBeNull()
    expect(decisionCard?.querySelector('.ide-conversation-context-badge')?.textContent).toBe('CTX 3')
    expect(decisionCard?.querySelector('.ide-conversation-context-badge')?.getAttribute('title'))
      .toBe('Linked context: Code, Telemetry, Keeper')
    const decisionLinks = [...decisionCard!.querySelectorAll<HTMLButtonElement>('.ide-conversation-route-link')]
    expect(decisionLinks.map(link => link.textContent)).toEqual(['Code', 'Telemetry', 'Keeper'])

    fireEvent.click(decisionLinks.find(link => link.textContent === 'Code')!)
    expect(window.location.hash.startsWith('#code?')).toBe(true)
    expect(routeHashParams().get('file')).toBe('lib/runtime.ml')
    expect(routeHashParams().get('line')).toBe('42')

    fireEvent.click(decisionLinks.find(link => link.textContent === 'Telemetry')!)
    expect(routeHashParams().get('q')).toBe(
      `decision keeper:scholar event:turn_completed outcome:success tool:apply_patch ts:${decisionTs}`,
    )

    fireEvent.click(decisionLinks.find(link => link.textContent === 'Keeper')!)
    expect(window.location.hash).toBe('#monitoring?section=agents&view=keepers&keeper=scholar')

    const cascadeCard = container.querySelector<HTMLElement>('[data-replay-source="cascade"]')
    expect(cascadeCard).not.toBeNull()
    expect(cascadeCard?.querySelector('.ide-conversation-context-badge')?.textContent).toBe('CTX 1')
    expect(cascadeCard?.querySelector('.ide-conversation-context-badge')?.getAttribute('title'))
      .toBe('Linked context: Telemetry')
    const cascadeLinks = [...cascadeCard!.querySelectorAll<HTMLButtonElement>('.ide-conversation-route-link')]
    expect(cascadeLinks.map(link => link.textContent)).toEqual(['Telemetry'])

    fireEvent.click(cascadeLinks[0]!)
    expect(routeHashParams().get('q')).toBe(
      `cascade primary strategy:ranked cycle:1 kind:ordered ts:${cascadeTs}`,
    )

    render(null, container)
  })

  it('focuses the editor line when a line-anchored board thread is clicked', async () => {
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
      if (url.startsWith('/api/v1/board')) {
        return new Response(JSON.stringify([{
          id: 'thread-line',
          author: 'scholar',
          title: 'Review lib/runtime.ml:42',
          body: 'question fn:run about this line',
          content: 'question fn:run about this line',
          tags: [],
          author_identity: { kind: 'keeper', id: 'scholar', key: 'scholar', display_name: 'scholar', raw: 'scholar' },
          votes: 0,
          comment_count: 2,
          created_at: '2026-05-05T10:00:00Z',
          updated_at: '2026-05-05T10:00:00Z',
        }]), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.startsWith('/api/v1/dashboard/keeper-decisions')) {
        return new Response(JSON.stringify({ events: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.startsWith('/api/v1/cascade/strategy_trace')) {
        return new Response(JSON.stringify({ events: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response('{}', { status: 404 })
    }))

    const container = document.createElement('div')
    render(h(IdeConversationRail, {}), container)

    await waitFor(() => {
      expect(container.textContent).toContain('question fn:run about this line')
    })
    await waitFor(() => {
      const trace = keeperTraceState.value.events.find(event => event.id === 'thread-line')
      expect(trace).toMatchObject({
        source: 'anchored-thread',
        filePath: 'lib/runtime.ml',
        line: 42,
      })
    })

    const card = container.querySelector<HTMLButtonElement>('.ide-conversation-card')
    expect(card).not.toBeNull()
    fireEvent.click(card!)

    expect(activeIdeFile.value).toBe('lib/runtime.ml')
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 42,
      surface: 'QUESTION',
      source_id: 'thread-thread-line',
      keeper_id: 'scholar',
    })

    render(null, container)
  })

  it('renders route links for board thread code, planning, review, and keeper context', async () => {
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
      if (url.startsWith('/api/v1/board')) {
        return new Response(JSON.stringify([{
          id: 'thread-line',
          author: 'scholar',
          title: 'Review lib/runtime.ml:42',
          body: 'question fn:run comment:comment-1 PR 15035 task:task-runtime goal:goal-runtime branch:feat/ide-routes log:turn-7',
          content: 'question fn:run comment:comment-1 PR 15035 task:task-runtime goal:goal-runtime branch:feat/ide-routes log:turn-7',
          tags: [],
          author_identity: { kind: 'keeper', id: 'scholar', key: 'scholar', display_name: 'scholar', raw: 'scholar' },
          votes: 0,
          comment_count: 2,
          created_at: '2026-05-05T10:00:00Z',
          updated_at: '2026-05-05T10:00:00Z',
        }]), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.startsWith('/api/v1/dashboard/keeper-decisions')) {
        return new Response(JSON.stringify({ events: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      if (url.startsWith('/api/v1/cascade/strategy_trace')) {
        return new Response(JSON.stringify({ events: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response('{}', { status: 404 })
    }))

    const container = document.createElement('div')
    render(h(IdeConversationRail, {}), container)

    await waitFor(() => {
      expect(container.textContent).toContain('comment:comment-1')
    })

    const badge = container.querySelector('.ide-conversation-context-badge')
    expect(badge?.textContent).toBe('CTX 10')
    expect(badge?.getAttribute('title'))
      .toBe('Linked context: Code, Goal, Task, Board, Comment, PR, Git, Log, Telemetry, Keeper')

    const links = [...container.querySelectorAll<HTMLButtonElement>('.ide-conversation-route-link')]
    expect(links.map(link => link.textContent)).toEqual([
      'Code',
      'Goal',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ])
    expect(links.map(link => link.getAttribute('aria-label'))).toContain('Open Comment comment-1')

    fireEvent.click(links.find(link => link.textContent === 'Board')!)
    expect(window.location.hash).toBe('#workspace?section=board&post=thread-line')

    fireEvent.click(links.find(link => link.textContent === 'Comment')!)
    expect(window.location.hash).toBe('#workspace?section=board&post=thread-line&comment=comment-1')

    fireEvent.click(links.find(link => link.textContent === 'PR')!)
    expect(window.location.hash).toBe('#workspace?section=repositories&view=graph&pr=15035')

    fireEvent.click(links.find(link => link.textContent === 'Keeper')!)
    expect(window.location.hash).toBe('#monitoring?section=agents&view=keepers&keeper=scholar')

    render(null, container)
  })

  it('summarizes conversation route link coverage for card chrome', () => {
    expect(conversationContextSummary([
      { id: 'code:a', label: 'Code', tab: 'code', params: {}, evidence: 'Code a' },
      { id: 'task:t-1', label: 'Task', tab: 'workspace', params: {}, evidence: 'Task t-1' },
    ])).toEqual({
      label: 'CTX 2',
      title: 'Linked context: Code, Task',
    })

    expect(conversationContextSummary([])).toBeNull()
  })
})

function routeHashParams(): URLSearchParams {
  return new URLSearchParams(window.location.hash.split('?')[1] ?? '')
}
