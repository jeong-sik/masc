import { h } from 'preact'
import { render, screen } from '@testing-library/preact'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { Memory, filterBoardPosts } from './memory'
import { boardPosts, boardLoading, boardSortMode, boardExcludeSystem, boardExcludeAutomation, boardHiddenCategories, boardAuthorFilter } from '../store'
import { route } from '../router'
import { contentCategory } from './memory-state'
import type { BoardPost } from '../types'

import '@testing-library/jest-dom'

vi.mock('../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../store')>()
  return {
    ...actual,
    refreshBoard: vi.fn(),
  }
})

vi.mock('../router', () => ({
  route: { value: { params: {} } },
  navigate: vi.fn(),
  navigateToPost: vi.fn(),
}))

vi.mock('../api', () => ({
  fetchBoardPost: vi.fn(),
  votePost: vi.fn(),
  commentPost: vi.fn(),
  createPost: vi.fn(),
}))

vi.mock('../api/actions', () => ({
  deleteBoardPost: vi.fn(),
}))

vi.mock('./memory-state', async () => {
  const actual = await vi.importActual<Record<string, unknown>>('./memory-state')
  const store = await vi.importMock<typeof import('../store')>('../store')
  return {
    ...actual,
    ...store,
    votePost: vi.fn(),
    deleteBoardPost: vi.fn(),
    fetchBoardPost: vi.fn(),
    commentPost: vi.fn(),
    createPost: vi.fn(),
  }
})

function makePost(overrides: Partial<BoardPost> & { id: string; title: string; author: string }): BoardPost {
  return {
    body: '',
    content: '',
    meta: null,
    tags: [],
    votes: 0,
    vote_balance: 0,
    comment_count: 0,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    post_kind: 'automation',
    hearth: null,
    visibility: 'internal',
    expires_at: null,
    hearth_count: 0,
    ...overrides,
  } as BoardPost
}

// ── Content category classifier tests ─────────────────────────────
describe('contentCategory', () => {
  it('classifies tech exploration titles as article', () => {
    const post = makePost({ id: '1', title: '기술 탐색: GraphRAG', author: 'ani1999', body: 'long content...' })
    expect(contentCategory(post)).toBe('article')
  })

  it('classifies verdict titles as review', () => {
    const post = makePost({ id: '2', title: 'Verdict: 7건 일괄 판정', author: 'verdict', body: 'details' })
    expect(contentCategory(post)).toBe('review')
  })

  it('classifies PR review titles as review', () => {
    const post = makePost({ id: '3', title: 'PR 리뷰: #7106 refactor', author: 'sojin', body: 'review content' })
    expect(contentCategory(post)).toBe('review')
  })

  it('classifies alert titles as notice', () => {
    const post = makePost({ id: '4', title: 'PR/Task 불균형 경고', author: 'poe', body: 'alert details' })
    expect(contentCategory(post)).toBe('notice')
  })

  it('classifies status update titles as notice', () => {
    const post = makePost({ id: '5', title: 'Sprint 상태 업데이트 #3', author: 'poe', body: 'status info' })
    expect(contentCategory(post)).toBe('notice')
  })

  it('classifies system post_kind as system', () => {
    const post = makePost({ id: '6', title: 'Internal ops', author: 'ecosystem', post_kind: 'system', body: 'ops' })
    expect(contentCategory(post)).toBe('system')
  })

  it('falls back to article for long body without title signals', () => {
    const post = makePost({ id: '7', title: 'Some random title', author: 'keeper', body: 'x'.repeat(400) })
    expect(contentCategory(post)).toBe('article')
  })

  it('falls back to notice for short body from non-direct author', () => {
    const post = makePost({ id: '8', title: 'Short note', author: 'keeper', body: 'brief' })
    expect(contentCategory(post)).toBe('notice')
  })

  it('classifies issue triage as review', () => {
    const post = makePost({ id: '9', title: 'Open Issue 20건 — Assignee 제안', author: 'sojin', body: 'proposals' })
    expect(contentCategory(post)).toBe('review')
  })

  it('classifies needs-evidence as review', () => {
    const post = makePost({ id: '10', title: 'Verdict: #7112 needs-evidence', author: 'verdict', body: 'details' })
    expect(contentCategory(post)).toBe('review')
  })
})

// ── Memory component rendering tests ──────────────────────────────
describe('Memory Component', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    boardPosts.value = []
    boardLoading.value = false
    boardSortMode.value = 'recent'
    boardExcludeSystem.value = true
    boardExcludeAutomation.value = false
    boardHiddenCategories.value = new Set(['system'])
    boardAuthorFilter.value = ''
    route.value = { params: {} } as any
  })

  it('renders empty state when there are no posts', () => {
    render(h(Memory, null))
    expect(screen.getByText(/아직 게시글이 없습니다/)).toBeInTheDocument()
  })

  it('renders loading state when loading', () => {
    boardLoading.value = true
    render(h(Memory, null))
    expect(screen.getByText(/메모리 피드 불러오는 중/)).toBeInTheDocument()
  })

  it('renders article category for a tech exploration post', () => {
    boardPosts.value = [
      makePost({
        id: 'post-1',
        title: '기술 탐색: test topic',
        body: 'exploration content here',
        author: 'ani1999',
      }),
    ]
    render(h(Memory, null))
    expect(screen.getByText(/기술 탐색: test topic/)).toBeInTheDocument()
  })

  it('hides system posts by default', () => {
    boardPosts.value = [
      makePost({
        id: 'post-system',
        title: 'System Post',
        body: 'ops',
        author: 'keeper-alert-bot',
        post_kind: 'system',
      }),
    ]
    render(h(Memory, null))
    expect(screen.queryByText('System Post')).not.toBeInTheDocument()
  })
})

// ── filterBoardPosts pure-function tests ──────────────────────────
describe('filterBoardPosts', () => {
  const a = makePost({ id: 'p1', title: 'GraphRAG 기술 탐색', body: 'hybrid retrieval notes', author: 'ani1999' })
  const b = makePost({ id: 'p2', title: 'PR 리뷰: #7106', body: 'refactor of cascade router', author: 'sojin' })
  const c = makePost({ id: 'p3', title: 'Sprint 상태 업데이트', body: 'budget stable, GraphRAG shipped', author: 'poe' })
  const d = makePost({ id: 'p4', title: 'Verdict: 7건 일괄 판정', body: '', author: 'verdict' })
  const rows = [a, b, c, d] as const

  it('returns the input reference unchanged for an empty query', () => {
    expect(filterBoardPosts(rows, '')).toBe(rows)
  })

  it('returns the input reference unchanged for a whitespace-only query', () => {
    expect(filterBoardPosts(rows, '   ')).toBe(rows)
  })

  it('matches on title (case-insensitive)', () => {
    expect(filterBoardPosts(rows, 'graphrag').map(p => p.id)).toEqual(['p1', 'p3'])
  })

  it('matches on body (case-insensitive)', () => {
    expect(filterBoardPosts(rows, 'CASCADE').map(p => p.id)).toEqual(['p2'])
  })

  it('matches Korean substring on title', () => {
    expect(filterBoardPosts(rows, '리뷰').map(p => p.id)).toEqual(['p2'])
  })

  it('trims surrounding whitespace before matching', () => {
    expect(filterBoardPosts(rows, '   verdict   ').map(p => p.id)).toEqual(['p4'])
  })

  it('returns an empty array when no post matches', () => {
    expect(filterBoardPosts(rows, 'nonexistent-needle-xyz')).toEqual([])
  })

  it('does not mutate the input array', () => {
    const copy = [...rows]
    filterBoardPosts(rows, 'graphrag')
    expect(rows).toEqual(copy)
  })

  it('handles posts with empty body without throwing', () => {
    const result = filterBoardPosts(rows, 'verdict')
    expect(result.map(p => p.id)).toEqual(['p4'])
  })

  it('title match takes precedence when both title and body could match', () => {
    // Post c has "GraphRAG" in both title-adjacent context and body; both should count as match.
    const onlyC = makePost({ id: 'only-c', title: 'stable', body: 'graphrag shipped', author: 'x' })
    expect(filterBoardPosts([onlyC], 'graphrag').map(p => p.id)).toEqual(['only-c'])
  })
})
