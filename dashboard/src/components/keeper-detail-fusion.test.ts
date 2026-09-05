import { html } from 'htm/preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardPost } from '../types'
import { navigate } from '../router'
import { fusionBoardPosts, refreshFusionBoard } from '../store'
import { KeeperFusionRuns } from './keeper-detail-fusion'

vi.mock('../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../store')>()
  return { ...actual, refreshFusionBoard: vi.fn() }
})

vi.mock('../router', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../router')>()
  return { ...actual, navigate: vi.fn() }
})

function fusionPost(overrides: {
  id: string
  author: string
  runId: string
  question: string
}): BoardPost {
  const { id, author, runId, question } = overrides
  return {
    id,
    author,
    post_kind: 'automation',
    pinned: false,
    title: `Fusion deliberation (run ${runId}): answer`,
    body: 'Fusion body',
    meta: {
      started_at: 1_780_000_000,
      question,
      panel: [
        { model: 'gpt-5', status: 'answered', answer: 'A.', input_tokens: 100, output_tokens: 20 },
      ],
      judge: {
        status: 'synthesized',
        decision: 'answer',
        synthesis: 'S.',
        resolved_answer: 'R.',
      },
      observed_usage: { input_tokens: 120, output_tokens: 30 },
      origin: { source: 'fusion', fusion_run_id: runId },
    },
    tags: [],
    votes: 0,
    comment_count: 0,
    created_at: '2026-09-04T19:08:00Z',
    updated_at: '2026-09-04T19:09:00Z',
    origin: { source: 'fusion', fusion_run_id: runId },
  } as BoardPost
}

describe('KeeperFusionRuns', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    fusionBoardPosts.value = []
    vi.mocked(refreshFusionBoard).mockClear()
    vi.mocked(navigate).mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    fusionBoardPosts.value = []
  })

  it('fetches the board-sink track on mount', async () => {
    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, container)
    await waitFor(() => expect(refreshFusionBoard).toHaveBeenCalledTimes(1))
  })

  it('lists only this keeper runs and links each to the fusion surface', () => {
    fusionBoardPosts.value = [
      fusionPost({
        id: 'post-other',
        author: 'rondo',
        runId: 'fus-rondo',
        question: '다른 keeper의 질문',
      }),
      fusionPost({
        id: 'post-mine',
        author: 'polisher',
        runId: 'fus-mine',
        question: '어떤 배포 경로를 쓸까?',
      }),
    ]

    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, container)

    const rows = container.querySelectorAll('[data-testid="keeper-fusion-runs"] button')
    expect(rows.length).toBe(1)
    expect(rows[0]?.getAttribute('data-run-id')).toBe('fus-mine')
    expect(container.textContent).toContain('어떤 배포 경로를 쓸까?')

    rows[0]?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(navigate).toHaveBeenCalledWith('fusion', { run_id: 'fus-mine' })
  })

  it('renders nothing when this keeper has no fusion runs', () => {
    fusionBoardPosts.value = [
      fusionPost({
        id: 'post-other',
        author: 'rondo',
        runId: 'fus-rondo',
        question: '다른 keeper의 질문',
      }),
    ]

    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, container)

    expect(container.querySelector('[data-testid="keeper-fusion-runs"]')).toBeNull()
    expect(container.textContent ?? '').not.toContain('Fusion deliberations')
  })
})
