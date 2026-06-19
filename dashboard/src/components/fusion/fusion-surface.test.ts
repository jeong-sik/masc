import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { BoardPost } from '../../types'
import { route } from '../../router'
import { boardLoading, boardPosts } from '../../store'
import { FusionSurface } from './fusion-surface'

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
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    boardLoading.value = false
    boardPosts.value = []
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
})
