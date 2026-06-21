import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardPost } from '../../types'
import { route } from '../../router'
import { boardLoading, boardPosts, fusionRunsLoading, refreshBoard, refreshFusionRuns } from '../../store'
import { FusionSurface } from './fusion-surface'

// Mock only the refresh side effects; keep the real signals (boardLoading /
// fusionRunsLoading) via ...actual so the component reads live state. The manual
// Refresh button must fan out to BOTH refreshers — the run-status panel is a
// second data source the board refresh cannot reach (RFC-0266 Phase 4).
vi.mock('../../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../store')>()
  return { ...actual, refreshBoard: vi.fn(), refreshFusionRuns: vi.fn() }
})

function boardPost(overrides: Partial<BoardPost> & { id: string; meta: BoardPost['meta'] }): BoardPost {
  const { id, meta, ...rest } = overrides
  return {
    id,
    author: 'fusion-keeper',
    author_identity: {
      kind: 'keeper',
      id: 'fusion-keeper',
      key: 'keeper:fusion-keeper',
      display_name: 'Fusion Keeper',
      raw: 'fusion-keeper',
    },
    post_kind: 'automation',
    pinned: false,
    title: 'Fusion deliberation',
    body: 'Fusion body',
    content: 'Fusion content',
    meta,
    tags: [],
    votes: null,
    comment_count: 0,
    created_at: '2026-06-19T01:00:00Z',
    updated_at: '2026-06-19T01:02:00Z',
    ...rest,
  }
}

describe('FusionSurface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = '#fusion'
    route.value = { tab: 'fusion', params: {}, postId: null }
    boardLoading.value = false
    boardPosts.value = []
    fusionRunsLoading.value = false
    vi.mocked(refreshBoard).mockClear()
    vi.mocked(refreshFusionRuns).mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    boardLoading.value = false
    boardPosts.value = []
    fusionRunsLoading.value = false
    route.value = { tab: 'overview', params: {}, postId: null }
    window.location.hash = '#overview'
  })

  it('renders live top-level fusion board metadata', () => {
    boardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        title: 'Fusion deliberation (run fus-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-1',
          question: 'Which deploy path should we take?',
          panel: [
            {
              model: 'gpt-5',
              status: 'answered',
              answer: 'Use the canary path.',
              input_tokens: 1200,
              output_tokens: 340,
            },
            {
              model: 'claude-sonnet-4',
              status: 'failed',
              reason: 'timeout',
            },
          ],
          judge: {
            status: 'synthesized',
            decision: 'answer',
            synthesis: 'Canary has the best rollback evidence.',
            resolved_answer: 'Ship canary first, then expand.',
          },
          observed_usage: {
            input_tokens: 1300,
            output_tokens: 360,
          },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-surface"]')).not.toBeNull()
    expect(container.textContent).toContain('fus-1')
    expect(container.textContent).toContain('Which deploy path should we take?')
    expect(container.textContent).toContain('gpt-5')
    expect(container.textContent).toContain('claude-sonnet-4')
    expect(container.textContent).toContain('Canary has the best rollback evidence.')
    expect(container.textContent).toContain('Ship canary first, then expand.')
    expect(container.textContent).toContain('1,300')
    expect(container.textContent).toContain('360')
    expect(container.querySelector('[data-testid="fusion-pipe"]')).not.toBeNull()
    expect(container.querySelector('.fus-rdot.done')).not.toBeNull()
    expect(container.textContent).toContain('panel ×2')
    expect(container.textContent).toContain('chat · board')
  })

  it('calls ringFocusClasses() for focus rings instead of stringifying the function', () => {
    boardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        title: 'Fusion deliberation (run fus-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-1',
          question: 'Which deploy path should we take?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Use the canary path.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary first.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    // Regression guard: a bare `${ringFocusClasses}` interpolation coerces the
    // function to its source text (which contains the `opts` parameter) into the
    // class attribute, so the resolved focus-ring utilities are never applied.
    const refresh = container.querySelector<HTMLButtonElement>('.fus-refresh')
    expect(refresh).not.toBeNull()
    expect(refresh?.className).toContain('focus-visible:outline-none')
    expect(refresh?.className).not.toContain('opts')

    const row = container.querySelector<HTMLButtonElement>('.fus-run-row')
    expect(row).not.toBeNull()
    expect(row?.className).toContain('focus-visible:outline-none')
    expect(row?.className).not.toContain('opts')
  })

  it('supports older nested fusion_deliberation metadata and route selection', () => {
    boardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        updated_at: '2026-06-19T01:00:00Z',
        meta: {
          fusion_deliberation: {
            run_id: 'fus-1',
            question: 'older run',
            panel: [],
            judge: { status: 'synthesized', resolved_answer: 'older answer' },
          },
        },
      }),
      boardPost({
        id: 'post-fus-2',
        updated_at: '2026-06-19T02:00:00Z',
        meta: {
          fusion_deliberation: {
            run_id: 'fus-2',
            question: 'newer run',
            panel: [],
            judge: { status: 'synthesized', resolved_answer: 'newer answer' },
          },
        },
      }),
    ]
    route.value = { tab: 'fusion', params: { run_id: 'fus-1' }, postId: null }

    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-detail"]')?.textContent).toContain('older answer')

    const secondRow = Array.from(container.querySelectorAll<HTMLButtonElement>('.fus-run-row'))
      .find(button => button.textContent?.includes('fus-2'))
    expect(secondRow).not.toBeUndefined()
    secondRow?.click()

    expect(route.value.tab).toBe('fusion')
    expect(route.value.params).toEqual({ run_id: 'fus-2' })
    expect(window.location.hash).toBe('#fusion?run_id=fus-2')
  })

  it('shows an empty state when no fusion board posts are loaded', () => {
    render(html`<${FusionSurface} />`, container)

    expect(container.querySelector('[data-testid="fusion-empty"]')).not.toBeNull()
    expect(container.textContent).toContain('No fusion runs found')
  })

  it('manual Refresh fans out to both the board-meta detail and the run-status registry', () => {
    render(html`<${FusionSurface} />`, container)
    const refresh = container.querySelector<HTMLButtonElement>('.fus-refresh')
    expect(refresh).not.toBeNull()
    refresh?.click()
    // The run-status panel reads the fusionRuns signal, a source refreshBoard
    // never touches; the button must trigger refreshFusionRuns too.
    expect(vi.mocked(refreshBoard)).toHaveBeenCalledTimes(1)
    expect(vi.mocked(refreshFusionRuns)).toHaveBeenCalledTimes(1)
  })

  it('disables Refresh while the run registry is loading even when the board is idle', () => {
    fusionRunsLoading.value = true
    render(html`<${FusionSurface} />`, container)
    const refresh = container.querySelector<HTMLButtonElement>('.fus-refresh')
    expect(refresh?.disabled).toBe(true)
    expect(refresh?.textContent).toContain('Refreshing')
  })
})
