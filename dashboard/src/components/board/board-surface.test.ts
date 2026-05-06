import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { BoardSurface } from './board-surface'
import { boardPosts, boardLoading, boardSortMode, boardExcludeSystem, boardExcludeAutomation, boardHiddenCategories, boardAuthorFilter, boardHearthFilter, boardHasMore, boardLoadingMore, messages, shellAuthSummary } from '../../store'
import { route } from '../../router'
import { PAGE_SIZE, boardHearths, boardHearthsError, categoryVisibleLimits, contentCategory, newPostHearth, newPostSubmitting, showNewPostForm } from './board-state'
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
  afterEach(async () => {
    cleanup()
    await vi.dynamicImportSettled()
    await Promise.resolve()
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
    vi.stubGlobal('IntersectionObserver', class {
      observe = vi.fn()
      disconnect = vi.fn()
    })
    boardPosts.value = []
    boardLoading.value = false
    boardHasMore.value = false
    boardLoadingMore.value = false
    boardSortMode.value = 'recent'
    boardExcludeSystem.value = true
    boardExcludeAutomation.value = false
    boardHiddenCategories.value = new Set(['system'])
    boardAuthorFilter.value = ''
    boardHearthFilter.value = ''
    boardHearths.value = [{ name: 'ops', count: 0 }]
    boardHearthsError.value = false
    showNewPostForm.value = false
    newPostHearth.value = ''
    newPostSubmitting.value = false
    categoryVisibleLimits.value = {
      article: PAGE_SIZE,
      review: PAGE_SIZE,
      notice: PAGE_SIZE,
      system: PAGE_SIZE,
    }
    messages.value = []
    shellAuthSummary.value = null
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

  it('renders post authors as keyboard-discoverable links', () => {
    boardPosts.value = [
      makePost({
        id: 'post-1',
        title: 'Accessible author link',
        body: 'content',
        author: 'ani1999',
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByRole('link', { name: 'ani1999' })).toHaveAttribute('href')
  })

  it('renders embedded reaction summaries on post cards', () => {
    boardPosts.value = [
      makePost({
        id: 'post-reacted',
        title: 'Reaction preview',
        body: 'content',
        author: 'ani1999',
        reactions: [{
          emoji: '🔥',
          count: 2,
          reacted: true,
          has_reacted: true,
          recent_user_ids: ['ani1999'],
        }],
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByRole('button', { name: '🔥 리액션 2개' })).toHaveAttribute('aria-pressed', 'true')
  })

  it('routes the mention inbox focus to the message surface', () => {
    route.value = { params: { focus: 'mention-inbox' } } as any
    messages.value = [{ id: 'm-1', from: 'sojin', content: '@dashboard needs review' }]

    render(h(BoardSurface, null))

    expect(screen.getByRole('heading', { name: 'Mention inbox' })).toBeInTheDocument()
    expect(screen.queryByText('+ 새 글 작성')).not.toBeInTheDocument()
  })

  it('routes the message room focus to the room timeline surface', () => {
    route.value = { params: { focus: 'messages-room' } } as any
    messages.value = [{ id: 'm-room', from: 'sangsu', room: 'ops', content: 'room update' }]

    render(h(BoardSurface, null))

    expect(screen.getByRole('heading', { name: 'Room timeline' })).toBeInTheDocument()
    expect(screen.queryByText('+ 새 글 작성')).not.toBeInTheDocument()
  })

  it('routes the state-block focus to the message surface', () => {
    route.value = { params: { focus: 'state-block' } } as any
    messages.value = [{ id: 'm-state', from: 'sangsu', content: '[STATE]\nGoal: keep context\n[/STATE]' }]

    render(h(BoardSurface, null))

    expect(screen.getByRole('heading', { name: 'State-block messages' })).toBeInTheDocument()
    expect(screen.queryByText('+ 새 글 작성')).not.toBeInTheDocument()
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

  it('keeps hearth refresh available without showing an error for a valid empty list', () => {
    boardHearths.value = []
    boardHearthsError.value = false

    render(h(BoardSurface, null))

    expect(screen.queryByText('hearth 목록을 불러오지 못했습니다')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'hearth 목록 새로고침' })).toBeInTheDocument()
  })

  it('shows the hearth load error only after a failed refresh', () => {
    boardHearths.value = []
    boardHearthsError.value = true

    render(h(BoardSurface, null))

    expect(screen.getByText('hearth 목록을 불러오지 못했습니다')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'hearth 목록 새로고침' })).toBeInTheDocument()
  })

  it('prefills the compose hearth from the active hearth filter', () => {
    boardHearthFilter.value = 'ops'

    render(h(BoardSurface, null))
    fireEvent.click(screen.getByRole('button', { name: '+ 새 글 작성' }))

    expect(screen.getByLabelText('새 글 hearth')).toHaveValue('ops')
    expect(newPostHearth.value).toBe('ops')
  })

  it('disables compose cancel while a post is submitting', () => {
    showNewPostForm.value = true
    newPostSubmitting.value = true

    render(h(BoardSurface, null))

    expect(screen.getByRole('button', { name: '취소' })).toBeDisabled()
  })

  it('uses shared cursor pagination for category expansion', () => {
    boardPosts.value = Array.from({ length: PAGE_SIZE + 1 }, (_, index) => makePost({
      id: `post-${index}`,
      title: `기술 탐색: topic ${index}`,
      body: 'exploration content here',
      author: 'keeper',
      post_kind: 'direct',
    }))

    render(h(BoardSurface, null))

    const nav = screen.getByRole('navigation', { name: '글/분석 게시글 페이지' })
    expect(nav).toBeInTheDocument()
    expect(nav.textContent).toContain('표시')
    fireEvent.click(screen.getByRole('button', { name: /더 보기/ }))

    expect(categoryVisibleLimits.value.article).toBe(PAGE_SIZE * 2)
  })

  it('lets category pagination collapse an expanded category', () => {
    categoryVisibleLimits.value = {
      article: PAGE_SIZE * 2,
      review: PAGE_SIZE,
      notice: PAGE_SIZE,
      system: PAGE_SIZE,
    }
    boardPosts.value = Array.from({ length: PAGE_SIZE * 2 + 1 }, (_, index) => makePost({
      id: `post-${index}`,
      title: `기술 탐색: topic ${index}`,
      body: 'exploration content here',
      author: 'keeper',
      post_kind: 'direct',
    }))

    render(h(BoardSurface, null))
    fireEvent.click(screen.getByRole('button', { name: '줄이기' }))

    expect(categoryVisibleLimits.value.article).toBe(PAGE_SIZE)
  })
})
