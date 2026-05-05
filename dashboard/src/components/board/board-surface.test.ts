import { h } from 'preact'
import { fireEvent, render, screen } from '@testing-library/preact'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { BoardSurface } from './board-surface'
import { boardPosts, boardLoading, boardSortMode, boardExcludeSystem, boardExcludeAutomation, boardHiddenCategories, boardAuthorFilter, boardHearthFilter } from '../../store'
import { route } from '../../router'
import { boardHearths, contentCategory, newPostHearth } from './board-state'
import type { BoardPost } from '../../types'

import '@testing-library/jest-dom'

vi.mock('../../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../store')>()
  return {
    ...actual,
    refreshBoard: vi.fn(),
  }
})

vi.mock('../../router', () => ({
  route: { value: { params: {} } },
  navigate: vi.fn(),
  navigateToPost: vi.fn(),
}))

vi.mock('../../api', () => ({
  fetchBoardPost: vi.fn(),
  votePost: vi.fn(),
  fetchBoardHearths: vi.fn().mockResolvedValue([]),
  commentPost: vi.fn(),
  createPost: vi.fn(),
}))

vi.mock('../../api/actions', () => ({
  deleteBoardPost: vi.fn(),
}))

vi.mock('./board-state', async () => {
  const actual = await vi.importActual<Record<string, unknown>>('./board-state')
  const store = await vi.importMock<typeof import('../../store')>('../../store')
  return {
    ...actual,
    ...store,
    votePost: vi.fn(),
    deleteBoardPost: vi.fn(),
    fetchBoardPost: vi.fn(),
    commentPost: vi.fn(),
    createPost: vi.fn(),
    refreshBoardHearths: vi.fn(),
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

// ── Board component rendering tests ───────────────────────────────
describe('BoardSurface Component', () => {
  // PR #13152 review: vi.stubGlobal('fetch') in beforeEach without a matching
  // unstub leaks the mocked fetch into later tests in the same worker.  Add
  // an explicit afterEach that restores all stubbed globals.
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  beforeEach(() => {
    vi.clearAllMocks()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ posts: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))
    boardPosts.value = []
    boardLoading.value = false
    boardSortMode.value = 'recent'
    boardExcludeSystem.value = true
    boardExcludeAutomation.value = false
    boardHiddenCategories.value = new Set(['system'])
    boardAuthorFilter.value = ''
    boardHearthFilter.value = ''
    boardHearths.value = [{ name: 'ops', count: 0 }]
    newPostHearth.value = ''
    route.value = { params: {} } as any
  })

  it('renders empty state when there are no posts', () => {
    render(h(BoardSurface, null))
    expect(screen.getByText(/아직 게시글이 없습니다/)).toBeInTheDocument()
  })

  it('renders loading state when loading', () => {
    boardLoading.value = true
    render(h(BoardSurface, null))
    expect(screen.getByText(/게시판 불러오는 중/)).toBeInTheDocument()
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
    render(h(BoardSurface, null))
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
    render(h(BoardSurface, null))
    expect(screen.queryByText('System Post')).not.toBeInTheDocument()
  })

  it('applies a hearth filter from the server hearth list', () => {
    boardHearths.value = [{ name: 'ops', count: 2 }]
    boardPosts.value = [
      makePost({
        id: 'post-ops',
        title: 'Ops note',
        body: 'ops content',
        author: 'keeper',
        hearth: 'ops',
      }),
    ]

    render(h(BoardSurface, null))
    fireEvent.click(screen.getByRole('button', { name: 'hearth ops 2 posts' }))

    expect(boardHearthFilter.value).toBe('ops')
    expect(screen.getByRole('button', { name: 'hearth ops 2 posts' })).toHaveAttribute('aria-pressed', 'true')
  })

  it('prefills the compose hearth from the active hearth filter', () => {
    boardHearthFilter.value = 'ops'

    render(h(BoardSurface, null))
    fireEvent.click(screen.getByRole('button', { name: '+ 새 글 작성' }))

    expect(screen.getByLabelText('새 글 hearth')).toHaveValue('ops')
    expect(newPostHearth.value).toBe('ops')
  })
})
