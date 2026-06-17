import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { BoardSurface } from './board-surface'
import { boardPosts, boardLoading, boardSortMode, boardExcludeSystem, boardExcludeAutomation, boardHiddenCategories, boardAuthorFilter, boardHearthFilter, boardHasMore, boardLoadingMore, messages, shellAuthSummary } from '../../store'
import { route } from '../../router'
import { PAGE_SIZE, boardFlairs, boardFlairsError, boardHearths, boardHearthsError, categoryVisibleLimits, contentCategory, selectedBoardPostId, boardFilterMode, boardComposerMode } from './board-state'
import { resetBoardLatencyMetrics } from '../../board-metrics'
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
  fetchSubBoards: vi.fn().mockResolvedValue([]),
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

// ── Board v2 component rendering tests ────────────────────────────
describe('BoardSurface Component', () => {
  afterEach(async () => {
    cleanup()
    await vi.dynamicImportSettled()
    await Promise.resolve()
    vi.unstubAllGlobals()
    resetBoardLatencyMetrics()
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
    boardFlairs.value = [
      { name: 'insight', emoji: '💡', label: 'Insight' },
      { name: 'bug', emoji: '🐛', label: 'Bug Report' },
    ]
    boardFlairsError.value = false
    resetBoardLatencyMetrics()
    categoryVisibleLimits.value = {
      article: PAGE_SIZE,
      review: PAGE_SIZE,
      notice: PAGE_SIZE,
      system: PAGE_SIZE,
    }
    selectedBoardPostId.value = null
    boardFilterMode.value = 'all'
    boardComposerMode.value = 'post'
    messages.value = []
    shellAuthSummary.value = null
    route.value = { params: {} } as any
  })

  it('renders empty state when there are no posts', () => {
    render(h(BoardSurface, null))
    expect(screen.getByText(/아직 게시글이 없습니다/)).toBeInTheDocument()
  })

  it('wraps the board surface in the v2 board surface class', () => {
    const { container } = render(h(BoardSurface, null))
    expect(container.querySelector('.v2-board-surface')).not.toBeNull()
  })

  it('keeps v2 workspace panels for category cards', () => {
    boardPosts.value = [
      makePost({ id: 'post-1', title: '기술 탐색: test topic', body: 'content', author: 'keeper' }),
    ]
    const { container } = render(h(BoardSurface, null))
    expect(container.querySelectorAll('.v2-workspace-panel').length).toBeGreaterThanOrEqual(1)
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

  it('renders a 고정 badge for a pinned post', () => {
    boardPosts.value = [
      makePost({
        id: 'post-pinned',
        title: '고정된 공지',
        body: 'pinned content here',
        author: 'ani1999',
        pinned: true,
      }),
    ]
    render(h(BoardSurface, null))
    expect(screen.getByTitle('고정된 게시글')).toBeInTheDocument()
  })

  it('omits the 고정 badge for an unpinned post', () => {
    boardPosts.value = [
      makePost({
        id: 'post-plain',
        title: '일반 글',
        body: 'plain content here',
        author: 'ani1999',
      }),
    ]
    render(h(BoardSurface, null))
    expect(screen.queryByTitle('고정된 게시글')).not.toBeInTheDocument()
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

  it('keeps reaction controls visible for zero-reaction post cards', () => {
    boardPosts.value = [
      makePost({
        id: 'post-zero-reactions',
        title: 'Reaction affordance',
        body: 'content',
        author: 'ani1999',
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByRole('button', { name: '👍 리액션 0개' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: '👀 리액션 0개' })).toBeInTheDocument()
  })

  it('renders flair badges on post cards', () => {
    boardPosts.value = [
      makePost({
        id: 'post-flair',
        title: 'Flair projection',
        body: 'content',
        author: 'ani1999',
        flair: 'insight',
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByText('flair:insight')).toBeInTheDocument()
  })

  it('renders moderation status badge on post cards', () => {
    boardPosts.value = [
      makePost({
        id: 'post-flagged',
        title: 'Needs moderation',
        body: 'content',
        author: 'ani1999',
        report_count: 2,
        moderation_status: 'flagged',
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByText('모더레이션 대기')).toBeInTheDocument()
  })

  it('renders vote-blind post scores as hidden until voting', () => {
    boardPosts.value = [
      makePost({
        id: 'post-blind',
        title: 'Blind score',
        body: 'content',
        author: 'ani1999',
        votes: null,
        vote_balance: null,
        vote_blind: true,
        vote_blind_reason: 'vote_before_score',
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByLabelText('점수 투표 후 공개')).toHaveTextContent(/투표 후 공개/)
  })

  it('renders contributor quality badges on post cards', () => {
    boardPosts.value = [
      makePost({
        id: 'post-quality',
        title: 'Quality signal',
        body: 'content',
        author: 'ani1999',
        contributor_quality: {
          score: 0.72,
          band: 'strong',
          source: 'agent_reputation',
        },
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByLabelText(/기여자 품질 72점/)).toHaveTextContent('품질 72')
  })

  it('renders a state block panel when the post body contains one', () => {
    boardPosts.value = [
      makePost({
        id: 'post-state',
        title: 'State transition',
        body: '[STATE]\nfrom: idle\nto: running\nctx: ops\naction: start\n[/STATE]',
        author: 'ani1999',
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-stateblock')).toBeInTheDocument()
    expect(screen.getByText('상태 전이')).toBeInTheDocument()
    expect(screen.getByText(/idle/)).toBeInTheDocument()
  })

  it('renders sub-board rail and filters posts by sub-board', () => {
    boardHearths.value = [
      { name: 'ops', count: 1 },
      { name: 'review', count: 0 },
    ]
    boardPosts.value = [
      makePost({ id: 'post-ops', title: 'Ops note', body: 'ops', author: 'keeper', hearth: 'ops' }),
      makePost({ id: 'post-review', title: 'Review note', body: 'review', author: 'keeper', hearth: 'review' }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-sub-all')).toBeInTheDocument()
    expect(screen.getByTestId('bd-sub-ops')).toBeInTheDocument()

    fireEvent.click(screen.getByTestId('bd-sub-ops'))

    expect(boardHearthFilter.value).toBe('ops')
  })

  it('renders filter chips for state and moderation', () => {
    boardPosts.value = [
      makePost({ id: 'post-state', title: 'State', body: '[STATE]\nGoal: x\n[/STATE]', author: 'keeper' }),
      makePost({ id: 'post-mod', title: 'Mod', body: 'mod', author: 'keeper', moderation_status: 'flagged' }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-filter-all')).toBeInTheDocument()
    expect(screen.getByTestId('bd-filter-state')).toBeInTheDocument()
    expect(screen.getByTestId('bd-filter-mod')).toBeInTheDocument()

    fireEvent.click(screen.getByTestId('bd-filter-state'))
    expect(boardFilterMode.value).toBe('state')
  })

  it('opens a thread detail side panel when a post is selected', () => {
    boardPosts.value = [
      makePost({ id: 'post-1', title: 'Selectable post', body: 'body', author: 'keeper', comment_count: 3 }),
    ]

    render(h(BoardSurface, null))
    fireEvent.click(screen.getByTestId('bd-post-post-1'))

    expect(screen.getByTestId('bd-thread-detail')).toBeInTheDocument()
    expect(screen.getByText('스레드')).toBeInTheDocument()
  })

  it('switches composer mode tabs', () => {
    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-comp-tab-post')).toHaveAttribute('aria-selected', 'true')

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    expect(boardComposerMode.value).toBe('mention')

    fireEvent.click(screen.getByTestId('bd-comp-tab-state'))
    expect(boardComposerMode.value).toBe('state')
  })

  it('routes the mention inbox focus to the message surface', () => {
    route.value = { params: { focus: 'mention-inbox' } } as any
    messages.value = [{ id: 'm-1', from: 'sojin', content: '@dashboard needs review', timestamp: new Date().toISOString() }]

    render(h(BoardSurface, null))

    expect(screen.getByRole('heading', { name: 'Mention inbox' })).toBeInTheDocument()
  })

  it('routes the message workspace focus to the workspace timeline surface', () => {
    route.value = { params: { focus: 'messages-workspace' } } as any
    messages.value = [{ id: 'm-workspace', from: 'sangsu', workspace: 'ops', content: 'workspace update', timestamp: new Date().toISOString() }]

    render(h(BoardSurface, null))

    expect(screen.getByRole('heading', { name: 'Workspace timeline' })).toBeInTheDocument()
  })

  it('routes the state-block focus to the message surface', () => {
    route.value = { params: { focus: 'state-block' } } as any
    messages.value = [{ id: 'm-state', from: 'sangsu', content: '[STATE]\nGoal: keep context\n[/STATE]', timestamp: new Date().toISOString() }]

    render(h(BoardSurface, null))

    expect(screen.getByRole('heading', { name: 'State-block messages' })).toBeInTheDocument()
  })

  it('routes the curation focus to the board curation surface', async () => {
    route.value = { params: { focus: 'curation' } } as any
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ snapshot: null }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    render(h(BoardSurface, null))

    expect(await screen.findByRole('heading', { name: 'AI curation snapshot' })).toBeInTheDocument()
  })

  it('routes the karma focus to the board karma surface', async () => {
    route.value = { params: { focus: 'karma' } } as any
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        events: [],
        count: 0,
        scoring_rule: '',
        totals: [],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    render(h(BoardSurface, null))

    expect(await screen.findByRole('heading', { name: 'Karma ledger' })).toBeInTheDocument()
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
