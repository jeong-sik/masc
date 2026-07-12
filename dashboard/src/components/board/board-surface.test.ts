import { h } from 'preact'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  BOARD_DETAIL_WIDTH_DEFAULT,
  BOARD_DETAIL_WIDTH_MAX,
  BOARD_DETAIL_WIDTH_MIN,
  BOARD_DETAIL_WIDTH_STORAGE_KEY,
  BoardSurface,
  normalizeBoardDetailWidth,
} from './board-surface'
import { boardPosts, boardLoading, boardSortMode, boardExcludeSystem, boardExcludeAutomation, boardHiddenCategories, boardAuthorFilter, boardHearthFilter, boardHasMore, boardLoadingMore, messages, shellAuthSummary, keepers } from '../../store'
import { route } from '../../router'
import { createPost } from '../../api'
import { requestBoardContextInference } from '../../api/board'
import { dispatchOperatorAction, operatorSnapshot } from '../../operator-store'
import { PAGE_SIZE, boardFlairs, boardFlairsError, boardHearths, boardHearthsError, categoryVisibleLimits, contentCategory, selectedBoardPostId, boardFilterMode, boardComposerMode } from './board-state'
import { resetBoardLatencyMetrics } from '../../board-metrics'
import type { BoardPost, OperatorSnapshot } from '../../types'

import '@testing-library/jest-dom'

const voiceStartMock = vi.hoisted(() => vi.fn())
const voiceStopMock = vi.hoisted(() => vi.fn())
const voiceInputState = vi.hoisted(() => ({
  state: 'idle' as 'idle' | 'recording' | 'transcribing',
  supported: true,
  transcript: '스케줄러 결과 확인 바람',
}))

vi.mock('../../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../store')>()
  return {
    ...actual,
    refreshBoard: vi.fn(),
  }
})

vi.mock('../../router', () => ({
  route: { value: { tab: 'board', params: {}, postId: null } },
  navigate: vi.fn(),
  navigateToPost: vi.fn(),
  hashForRoute: vi.fn(() => '#board'),
}))

vi.mock('../../api', () => ({
  currentDashboardActor: vi.fn(() => 'dashboard-test'),
  fetchBoardPost: vi.fn(),
  votePost: vi.fn(),
  fetchBoardHearths: vi.fn().mockResolvedValue([]),
  fetchSubBoards: vi.fn().mockResolvedValue([]),
  commentPost: vi.fn(),
  createPost: vi.fn(),
  sendBroadcast: vi.fn(),
}))

vi.mock('../../api/actions', () => ({
  deleteBoardPost: vi.fn(),
}))

vi.mock('../../api/board', () => ({
  requestBoardContextInference: vi.fn(),
  fetchBoardReactionState: vi.fn().mockResolvedValue({
    summaries: [],
    supportedEmojis: ['👍', '❤️', '🎉', '🚀', '👀', '😕', '👏', '🔥'],
  }),
  toggleReaction: vi.fn(),
}))

vi.mock('../../operator-store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../operator-store')>()
  return {
    ...actual,
    dispatchOperatorAction: vi.fn(),
  }
})

vi.mock('../chat/voice-input', () => ({
  useVoiceInput: (options: { onTranscribed: (text: string) => void }) => ({
    state: voiceInputState.state,
    supported: voiceInputState.supported,
    start: voiceStartMock.mockImplementation(() => {
      options.onTranscribed(voiceInputState.transcript)
      return Promise.resolve()
    }),
    stop: voiceStopMock,
  }),
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
    supported_reaction_emojis: ['👍', '❤️', '🎉', '🚀', '👀', '😕', '👏', '🔥'],
    ...overrides,
  } as BoardPost
}

function snapshotWithKeepers(keepers: Array<{
  name: string
  status?: string
  phase?: string | null
  pipeline_stage?: string | null
  paused?: boolean | null
}>): OperatorSnapshot {
  return {
    root: { paused: false, namespace: 'default' },
    sessions: [],
    keepers,
    recent_messages: [],
    pending_confirms: [],
    available_actions: [],
  } as unknown as OperatorSnapshot
}

function clearLocalStorage(): void {
  try {
    window.localStorage.clear()
  } catch {
    // localStorage can be disabled in some test runtimes.
  }
}

function setLocalStorageItem(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value)
  } catch {
    // Rendered state assertions will fail if storage cannot be read.
  }
}

function getLocalStorageItem(key: string): string | null {
  try {
    return window.localStorage.getItem(key)
  } catch {
    return null
  }
}

// ── Content category classifier tests ─────────────────────────────
describe('contentCategory', () => {
  it('classifies direct posts as article without title heuristics', () => {
    const post = makePost({ id: '1', title: '기술 탐색: GraphRAG', author: 'ani1999', body: 'long content...', post_kind: 'direct' })
    expect(contentCategory(post)).toBe('article')
  })

  it('classifies explicit category metadata as review', () => {
    const post = makePost({ id: '2', title: 'ordinary title', author: 'verdict', body: 'details', meta: { category: 'review' } })
    expect(contentCategory(post)).toBe('review')
  })

  it('ignores non-canonical category metadata tokens', () => {
    const post = makePost({ id: '3', title: 'ordinary title', author: 'sojin', body: 'review content', meta: { content_category: 'verdict' }, post_kind: 'direct' })
    expect(contentCategory(post)).toBe('article')
  })

  it('does not classify flair labels as categories', () => {
    const post = makePost({ id: '4', title: 'PR/Task 불균형 경고', author: 'poe', body: 'alert details', flair: 'status', post_kind: 'direct' })
    expect(contentCategory(post)).toBe('article')
  })

  it('classifies automation fallback as notice', () => {
    const post = makePost({ id: '5', title: 'Sprint 상태 업데이트 #3', author: 'poe', body: 'status info', post_kind: 'automation' })
    expect(contentCategory(post)).toBe('notice')
  })

  it('classifies system post_kind as system', () => {
    const post = makePost({ id: '6', title: 'Internal ops', author: 'ecosystem', post_kind: 'system', body: 'ops' })
    expect(contentCategory(post)).toBe('system')
  })

  it('does not classify issue-triage wording as review without explicit metadata', () => {
    const post = makePost({ id: '9', title: 'Open Issue 20건 — Assignee 제안', author: 'sojin', body: 'proposals', post_kind: 'direct' })
    expect(contentCategory(post)).toBe('article')
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
    clearLocalStorage()
  })

  beforeEach(() => {
    vi.clearAllMocks()
    voiceStartMock.mockReset()
    voiceStopMock.mockReset()
    voiceInputState.state = 'idle'
    voiceInputState.supported = true
    voiceInputState.transcript = '스케줄러 결과 확인 바람'
    clearLocalStorage()
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
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'sangsu', status: 'active' },
      { name: 'albini', status: 'paused', paused: true },
    ])
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

  it('renders no title header — board goes straight to the feed (matches prototype)', () => {
    const { container } = render(h(BoardSurface, null))
    // The board surface intentionally omits SurfaceHeader; the sub-board rail
    // and "전체 피드" heading are the only structure above the posts. board is
    // in SURFACE_OWN_LEAD_IDS so the generic SurfaceLead is also suppressed.
    expect(container.querySelector('header.v2-surface-header')).toBeNull()
    expect(container.querySelector('h1')?.textContent).toBe('Board')
  })

  it('collapses the detail column by default (two-column rail + feed)', () => {
    const { container } = render(h(BoardSurface, null))
    // No post selected and the mention inbox closed: neither detail rail renders
    // and .bd-body collapses to two columns by setting the inline
    // --bd-detail-width to 0 (the third grid track). Matches the v2 prototype,
    // which only expands the detail column on demand.
    expect(container.querySelector('[data-testid="bd-mention-detail"]')).toBeNull()
    expect(container.querySelector('[data-testid="bd-thread-detail"]')).toBeNull()
    const surface = container.querySelector<HTMLElement>('.v2-board-surface')
    const body = container.querySelector<HTMLElement>('.bd-body')
    expect(surface?.getAttribute('data-detail-open')).toBe('false')
    // Collapse is driven by the inline custom property (0px third track), not a
    // .no-detail class that would race the legacy grid on load order.
    expect(body?.getAttribute('style')).toContain('--bd-detail-width: 0px')
  })

  it('opens the mention inbox detail rail from the rail queue action', () => {
    const { container } = render(h(BoardSurface, null))
    fireEvent.click(screen.getByTestId('bd-queue-mentions'))
    expect(container.querySelector('[data-testid="bd-mention-detail"]')).not.toBeNull()
    const surface = container.querySelector<HTMLElement>('.v2-board-surface')
    const body = container.querySelector<HTMLElement>('.bd-body')
    expect(surface?.getAttribute('data-detail-open')).toBe('true')
    // Opening a detail rail restores a non-zero third track via the same inline
    // property (the persisted/default width), not a class toggle.
    expect(body?.getAttribute('style')).toContain(
      `--bd-detail-width: ${BOARD_DETAIL_WIDTH_DEFAULT}px`,
    )
  })

  it('normalizes persisted Board detail rail widths to the supported range', () => {
    expect(normalizeBoardDetailWidth(200)).toBe(BOARD_DETAIL_WIDTH_MIN)
    expect(normalizeBoardDetailWidth(333.6)).toBe(334)
    expect(normalizeBoardDetailWidth(800)).toBe(BOARD_DETAIL_WIDTH_MAX)
    expect(normalizeBoardDetailWidth('bad')).toBe(BOARD_DETAIL_WIDTH_DEFAULT)
    // The widened range now admits 700px (was clamped to the old 520 max).
    expect(BOARD_DETAIL_WIDTH_MAX).toBeGreaterThanOrEqual(700)
    expect(normalizeBoardDetailWidth(700)).toBe(700)
  })

  it('hydrates the persisted Board detail rail width into the grid and resize handle', () => {
    setLocalStorageItem(BOARD_DETAIL_WIDTH_STORAGE_KEY, JSON.stringify(430))

    const { container } = render(h(BoardSurface, null))
    // The detail column is collapsed until opened; open the mention inbox so the
    // persisted width is applied and the resize handle renders.
    fireEvent.click(screen.getByTestId('bd-queue-mentions'))

    const surface = container.querySelector<HTMLElement>('.v2-board-surface')
    const body = container.querySelector<HTMLElement>('.bd-body')
    const handle = screen.getByTestId('bd-detail-resize')
    expect(surface?.getAttribute('data-detail-width')).toBe('430')
    expect(body?.getAttribute('style')).toContain('--bd-detail-width: 430px')
    expect(handle).toHaveAttribute('aria-valuenow', '430')
  })

  it('resizes the Board detail rail with pointer drag and keyboard controls', async () => {
    const { container } = render(h(BoardSurface, null))
    // Open the mention inbox so the detail rail (and its resize handle) renders.
    fireEvent.click(screen.getByTestId('bd-queue-mentions'))

    const surface = container.querySelector<HTMLElement>('.v2-board-surface')
    const handle = screen.getByTestId('bd-detail-resize') as HTMLButtonElement
    expect(surface?.getAttribute('data-detail-width')).toBe(String(BOARD_DETAIL_WIDTH_DEFAULT))
    expect(handle).toHaveAttribute('aria-valuenow', String(BOARD_DETAIL_WIDTH_DEFAULT))

    fireEvent.pointerDown(handle, { button: 0, clientX: 1000 })
    fireEvent.pointerMove(window, { clientX: 920 })
    expect(surface?.getAttribute('data-detail-width')).toBe('440')
    expect(handle).toHaveAttribute('aria-valuenow', '440')
    expect(getLocalStorageItem(BOARD_DETAIL_WIDTH_STORAGE_KEY)).toBe('440')

    // Drag well past the cap (360 + (1000 - 500) = 860) → clamps to MAX (760).
    fireEvent.pointerMove(window, { clientX: 500 })
    expect(surface?.getAttribute('data-detail-width')).toBe(String(BOARD_DETAIL_WIDTH_MAX))
    fireEvent.pointerCancel(window)

    fireEvent.keyDown(handle, { key: 'Home' })
    expect(surface?.getAttribute('data-detail-width')).toBe(String(BOARD_DETAIL_WIDTH_MIN))
    expect(getLocalStorageItem(BOARD_DETAIL_WIDTH_STORAGE_KEY)).toBe(String(BOARD_DETAIL_WIDTH_MIN))

    fireEvent.keyDown(handle, { key: 'End' })
    expect(surface?.getAttribute('data-detail-width')).toBe(String(BOARD_DETAIL_WIDTH_MAX))
    expect(getLocalStorageItem(BOARD_DETAIL_WIDTH_STORAGE_KEY)).toBe(String(BOARD_DETAIL_WIDTH_MAX))
  })

  it('opens and closes the mention inbox detail rail from the mobile queue action', () => {
    messages.value = [
      { id: 'm-1', from: 'sojin', content: '@dashboard needs review', timestamp: new Date().toISOString() },
      { id: 'm-2', from: 'sangsu', content: 'plain update', timestamp: new Date().toISOString() },
      { id: 'm-3', from: 'albini', type: 'mention', content: 'manual mention routing', timestamp: new Date().toISOString() },
    ]
    render(h(BoardSurface, null))

    // Detail column is collapsed until the mention inbox is opened.
    expect(screen.queryByTestId('bd-mention-detail')).toBeNull()

    const queues = screen.getByTestId('bd-mobile-queues')
    const mentionQueue = within(queues).getByTestId('bd-mobile-queue-mentions')
    expect(mentionQueue).toHaveTextContent('멘션 인박스')
    expect(mentionQueue).toHaveTextContent('1')

    fireEvent.click(mentionQueue)
    const detail = screen.getByTestId('bd-mention-detail')
    expect(detail).toHaveClass('is-mobile-open')
    expect(within(detail).getByText('@dashboard')).toBeInTheDocument()

    fireEvent.click(screen.getByLabelText('멘션 인박스 닫기'))
    expect(screen.queryByTestId('bd-mention-detail')).toBeNull()
  })

  it('keeps v2 workspace panels for category cards', () => {
    boardPosts.value = [
      makePost({ id: 'post-1', title: '기술 탐색: test topic', body: 'content', author: 'keeper' }),
    ]
    const { container } = render(h(BoardSurface, null))
    expect(container.querySelectorAll('.v2-workspace-panel').length).toBeGreaterThanOrEqual(1)
  })

  it('applies StyleSeed surface/card classes', () => {
    boardPosts.value = [
      makePost({ id: 'post-1', title: '기술 탐색: test topic', body: 'content', author: 'keeper' }),
    ]
    const { container } = render(h(BoardSurface, null))
    expect(container.querySelector('.v2-board-surface.ss-surface.bg-surface-page.text-text-primary')).not.toBeNull()
    expect(container.querySelectorAll('.v2-workspace-panel.ss-card').length).toBeGreaterThanOrEqual(1)
  })

  it('applies the v2 board summary class on focus surfaces', () => {
    route.value = { params: { focus: 'mention-inbox' } } as any
    boardPosts.value = [
      makePost({ id: 'post-1', title: '기술 탐색: test topic', body: 'content', author: 'keeper' }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-summary')).toHaveClass('bd-summary')
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

  it('renders claim evidence state badges on post cards', () => {
    boardPosts.value = [
      makePost({
        id: 'post-needs-evidence',
        title: 'Evidence state',
        body: 'content',
        author: 'ani1999',
        claim_evidence: {
          state: 'needs_evidence',
          label: 'Needs evidence',
          total_count: 1,
          allowed_count: 0,
          rejected_count: 1,
          artifact_missing_count: 0,
          artifact_unknown_count: 0,
          missing_source_snapshot_count: 1,
          stale_source_snapshot_count: 0,
          artifact_not_verified_count: 0,
        },
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByLabelText(/Needs evidence/)).toHaveTextContent('Needs evidence')
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
          accountability_score: 0.72,
          source: 'agent_reputation',
          board_posts: 1,
        },
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByLabelText(/기여자 품질 72점/)).toHaveTextContent('품질 72')
  })

  it('hides default contributor quality priors on post cards', () => {
    boardPosts.value = [
      makePost({
        id: 'post-quality-prior',
        title: 'Quality prior',
        body: 'content',
        author: 'ani1999',
        contributor_quality: {
          accountability_score: 1,
          source: 'agent_reputation',
          board_posts: 0,
          board_comments: 0,
          completion_rate: 0,
          response_rate: 0,
          autonomy_level: 'standard',
          thompson_confidence: 0.5,
          evidence_state: 'default',
        },
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.queryByText(/품질 100/)).not.toBeInTheDocument()
  })

  it('renders contributor quality badges even when score is 100 if evidence_state is measured', () => {
    boardPosts.value = [
      makePost({
        id: 'post-quality-100-measured',
        title: 'Quality measured 100',
        body: 'content',
        author: 'ani1999',
        contributor_quality: {
          accountability_score: 1,
          source: 'agent_reputation',
          evidence_state: 'measured',
        },
      }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByLabelText(/기여자 품질 100점/)).toHaveTextContent('품질 100')
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

  it('renders every hearth in an available-space scroll region while queues stay outside it', () => {
    boardHearths.value = Array.from({ length: 9 }, (_, index) => ({
      name: `hearth-${index + 1}`,
      count: index,
    }))

    const { container } = render(h(BoardSurface, null))

    const hearthScroll = container.querySelector('.bd-hearth-scroll')
    const queueSection = container.querySelector('.bd-queue-section')
    expect(hearthScroll?.querySelectorAll('[data-testid^="bd-sub-hearth-"]')).toHaveLength(9)
    expect(hearthScroll?.querySelector('[data-testid="bd-sub-hearth-9"]')).not.toBeNull()
    expect(container.querySelector('.bd-sub-more')).toBeNull()
    expect(queueSection?.querySelector('[data-testid="bd-queue-mod"]')).not.toBeNull()
    expect(queueSection?.querySelector('[data-testid="bd-queue-mentions"]')).not.toBeNull()
  })

  it('counts desktop mention queue from messages instead of board posts', () => {
    boardPosts.value = [
      makePost({ id: 'post-ops', title: 'Ops note', body: 'ops', author: 'keeper', hearth: 'ops' }),
      makePost({ id: 'post-review', title: 'Review note', body: 'review', author: 'keeper', hearth: 'review' }),
    ]
    messages.value = [
      { id: 'm-1', from: 'sojin', content: '@dashboard needs review', timestamp: new Date().toISOString() },
      { id: 'm-2', from: 'sangsu', content: 'plain update', timestamp: new Date().toISOString() },
    ]

    render(h(BoardSurface, null))

    const queue = screen.getByTestId('bd-queue-mentions')
    expect(queue).toHaveTextContent('멘션 인박스')
    expect(within(queue).getByText('1')).toBeInTheDocument()
    expect(within(queue).queryByText('2')).not.toBeInTheDocument()
  })

  it('renders filter chips for all posts and moderation', () => {
    boardPosts.value = [
      makePost({ id: 'post-mod', title: 'Mod', body: 'mod', author: 'keeper', moderation_status: 'flagged' }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-filter-all')).toBeInTheDocument()
    expect(screen.getByTestId('bd-filter-mod')).toBeInTheDocument()

    fireEvent.click(screen.getByTestId('bd-filter-mod'))
    expect(boardFilterMode.value).toBe('mod')
  })

  it('changes the server-backed board sort mode from the feed head', () => {
    boardPosts.value = [
      makePost({ id: 'post-sort', title: 'Sort target', body: 'content', author: 'keeper', post_kind: 'direct' }),
    ]

    render(h(BoardSurface, null))
    const sort = screen.getByTestId('bd-sort-mode') as HTMLSelectElement

    expect(sort).toHaveValue('recent')
    fireEvent.change(sort, { target: { value: 'discussed' } })

    expect(boardSortMode.value).toBe('discussed')
    expect(categoryVisibleLimits.value.article).toBe(PAGE_SIZE)
  })

  it('renders permalink, trackback, context inference, and X share actions for a post', () => {
    boardPosts.value = [
      makePost({ id: 'post-share', title: 'Share **this**', body: 'content', author: 'keeper', post_kind: 'direct' }),
    ]

    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-share-post-share')).toBeInTheDocument()
    expect(screen.getByTestId('bd-share-link-post-share')).toHaveAttribute('aria-label', '게시글 링크 복사: post-share')
    expect(screen.getByTestId('bd-share-trackback-post-share')).toHaveAttribute('aria-label', '트랙백 링크 복사: post-share')
    expect(screen.getByTestId('bd-context-infer-post-share')).toHaveAttribute('aria-label', '맥락 추론 요청: post-share')

    const xShare = screen.getByTestId('bd-share-x-post-share') as HTMLAnchorElement
    expect(xShare).toHaveClass('bd-share-x')
    expect(xShare).toHaveClass('bd-share-action')
    expect(screen.getByTestId('bd-share-link-post-share')).toHaveClass('bd-share-action')
    expect(xShare).toHaveAttribute('target', '_blank')
    expect(xShare).toHaveAttribute('rel', expect.stringContaining('noopener'))
    expect(xShare.href).toContain('https://twitter.com/intent/tweet?')
    const xUrl = new URL(xShare.href)
    expect(xUrl.searchParams.get('text')).toBe('Share this - MASC Board')
    expect(xUrl.searchParams.get('url')).toContain('#board?post=post-share')
  })

  it('opens a thread detail side panel when a post is selected', () => {
    boardPosts.value = [
      makePost({ id: 'post-1', title: 'Selectable post', body: 'body', author: 'keeper', comment_count: 3 }),
    ]

    render(h(BoardSurface, null))
    fireEvent.click(screen.getByTestId('bd-post-post-1'))

    expect(screen.getByTestId('bd-thread-detail')).toHaveClass('has-post')
    expect(screen.getByText('스레드')).toBeInTheDocument()
  })

  it('switches composer mode tabs', () => {
    render(h(BoardSurface, null))

    expect(screen.getByTestId('bd-comp-tab-post')).toHaveAttribute('aria-selected', 'true')

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    expect(boardComposerMode.value).toBe('mention')

  })

  it('starts the mobile composer shell collapsed and toggles it open', () => {
    render(h(BoardSurface, null))

    const composer = screen.getByTestId('bd-composer')
    const toggle = screen.getByTestId('bd-composer-mobile-toggle')

    expect(composer).toHaveAttribute('data-mobile-open', 'false')
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(toggle).toHaveTextContent('새 글')

    fireEvent.click(toggle)

    expect(composer).toHaveAttribute('data-mobile-open', 'true')
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(toggle).toHaveTextContent('접기')
  })

  it('submits the mobile quick composer using the first body line as title', async () => {
    const createPostMock = vi.mocked(createPost)
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    fireEvent.input(screen.getByTestId('bd-composer-mobile-body'), {
      target: { value: 'Mobile quick note\nsecond line' },
    })
    fireEvent.click(screen.getByTestId('bd-composer-mobile-send'))

    expect(createPostMock).toHaveBeenCalledWith(
      'Mobile quick note',
      'Mobile quick note\nsecond line',
      'dashboard-user',
      { hearth: undefined },
    )
  })

  it('submits the mobile mention quick composer through the keeper message action', () => {
    const dispatchMock = vi.mocked(dispatchOperatorAction)
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    fireEvent.input(screen.getByTestId('bd-composer-mobile-body'), {
      target: { value: '@sangsu check the queue' },
    })
    fireEvent.click(screen.getByTestId('bd-composer-mobile-send'))

    expect(dispatchMock).toHaveBeenCalledWith({
      actor: 'dashboard-test',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'sangsu',
      payload: { message: '@sangsu check the queue' },
    })
  })

  it('submits mobile mention quick composer through the target picker', () => {
    const dispatchMock = vi.mocked(dispatchOperatorAction)
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    const target = screen.getByLabelText('Mobile mention target') as HTMLSelectElement
    expect(Array.from(target.options).map(option => option.textContent)).toEqual(['sangsu', 'albini'])

    fireEvent.input(target, { target: { value: 'keeper:albini' } })
    fireEvent.input(screen.getByTestId('bd-composer-mobile-body'), {
      target: { value: 'check the queue' },
    })
    fireEvent.click(screen.getByTestId('bd-composer-mobile-send'))

    expect(dispatchMock).toHaveBeenCalledWith({
      actor: 'dashboard-test',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'albini',
      payload: { message: 'check the queue' },
    })
  })

  it('keeps plain mobile mention body text when changing the target picker', () => {
    const dispatchMock = vi.mocked(dispatchOperatorAction)
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    const target = screen.getByLabelText('Mobile mention target') as HTMLSelectElement
    const body = screen.getByTestId('bd-composer-mobile-body') as HTMLTextAreaElement

    fireEvent.input(body, { target: { value: 'check the queue' } })
    fireEvent.input(target, { target: { value: 'keeper:albini' } })
    expect(body.value).toBe('check the queue')

    fireEvent.click(screen.getByTestId('bd-composer-mobile-send'))

    expect(dispatchMock).toHaveBeenCalledWith({
      actor: 'dashboard-test',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'albini',
      payload: { message: 'check the queue' },
    })
  })

  it('completes mobile mention text through the compact autocomplete listbox', () => {
    const dispatchMock = vi.mocked(dispatchOperatorAction)
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    const body = screen.getByTestId('bd-composer-mobile-body') as HTMLTextAreaElement

    fireEvent.input(body, { target: { value: '@al' } })
    const listbox = screen.getByTestId('bd-composer-mobile-mention-listbox')
    fireEvent.click(within(listbox).getByRole('option', { name: /albini/ }))

    expect(body.value).toBe('@albini ')
    expect(screen.getByLabelText('Mobile mention target')).toHaveValue('keeper:albini')

    fireEvent.click(screen.getByTestId('bd-composer-mobile-send'))

    expect(dispatchMock).toHaveBeenCalledWith({
      actor: 'dashboard-test',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'albini',
      payload: { message: '@albini' },
    })
  })

  it('accepts the active mobile mention autocomplete option with Enter', () => {
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    const body = screen.getByTestId('bd-composer-mobile-body') as HTMLTextAreaElement

    fireEvent.input(body, { target: { value: '@sa' } })
    expect(screen.getByTestId('bd-composer-mobile-mention-listbox')).toBeInTheDocument()

    fireEvent.keyDown(body, { key: 'Enter' })

    expect(body.value).toBe('@sangsu ')
    expect(screen.queryByTestId('bd-composer-mobile-mention-listbox')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Mobile mention target')).toHaveValue('keeper:sangsu')
  })

  it('blocks compact mobile mention attachments until block transport is available', () => {
    const dispatchMock = vi.mocked(dispatchOperatorAction)
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    fireEvent.input(screen.getByLabelText('Mobile mention target'), { target: { value: 'keeper:sangsu' } })

    const fileInput = screen.getByTestId('bd-composer-mobile-file-input') as HTMLInputElement
    fireEvent.change(fileInput, {
      target: { files: [new File(['trace'], 'trace.log', { type: 'text/plain' })] },
    })
    fireEvent.input(screen.getByTestId('bd-composer-mobile-body'), {
      target: { value: 'check trace\n\n스케줄러 결과 확인 바람' },
    })

    expect(screen.getByTestId('bd-composer-mobile-draft-tray')).toHaveTextContent('trace.log')
    expect(screen.getByTestId('bd-composer-mobile-draft-tray')).toHaveTextContent('transport unavailable')
    expect(screen.getByTestId('bd-composer-mobile-body')).toHaveValue('check trace\n\n스케줄러 결과 확인 바람')
    expect(screen.getByTestId('bd-composer-mobile-send')).toBeDisabled()
    fireEvent.click(screen.getByTestId('bd-composer-mobile-send'))

    expect(dispatchMock).not.toHaveBeenCalled()
  })

  it('removes compact mobile mention attachment drafts', () => {
    render(h(BoardSurface, null))

    fireEvent.click(screen.getByTestId('bd-comp-tab-mention'))
    fireEvent.click(screen.getByTestId('bd-composer-mobile-toggle'))
    fireEvent.input(screen.getByLabelText('Mobile mention target'), { target: { value: 'keeper:sangsu' } })
    const send = screen.getByTestId('bd-composer-mobile-send')

    fireEvent.change(screen.getByTestId('bd-composer-mobile-file-input'), {
      target: { files: [new File(['trace'], 'trace.log', { type: 'text/plain' })] },
    })
    expect(send).toBeDisabled()
    fireEvent.click(screen.getByLabelText('Remove mobile attachment trace.log'))
    expect(screen.queryByTestId('bd-composer-mobile-draft-tray')).not.toBeInTheDocument()
    expect(send).toBeDisabled()
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

  it('renders the operator author sigil with the "OP" glyph and .op modifier', () => {
    boardPosts.value = [
      makePost({
        id: 'op-post',
        title: '기술 탐색: operator broadcast',
        body: 'operator authored content',
        author: 'operator',
        post_kind: 'direct',
      }),
    ]

    const { container } = render(h(BoardSurface, null))

    const sigil = container.querySelector<HTMLElement>('.bd-sigil')
    expect(sigil).not.toBeNull()
    expect(sigil?.classList.contains('op')).toBe(true)
    expect(sigil?.textContent).toBe('OP')
  })

  it('renders a keeper author sigil with a 2-letter monogram and no .op modifier', () => {
    boardPosts.value = [
      makePost({
        id: 'kp-post',
        title: '기술 탐색: keeper note',
        body: 'keeper authored content',
        author: 'sangsu',
        post_kind: 'direct',
      }),
    ]

    const { container } = render(h(BoardSurface, null))

    const sigil = container.querySelector<HTMLElement>('.bd-sigil')
    expect(sigil).not.toBeNull()
    expect(sigil?.classList.contains('op')).toBe(false)
    expect(sigil?.textContent).toBe('SA')
  })

  it('does not collapse every keeper author sigil to KE when identity key is generic', () => {
    boardPosts.value = [
      makePost({
        id: 'kp-generic-key-post',
        title: 'keeper identity note',
        body: 'keeper authored content',
        author: 'keeper',
        post_kind: 'direct',
        author_identity: {
          kind: 'keeper',
          id: 'albini',
          key: 'keeper',
          display_name: 'albini',
          raw: 'keeper-albini-agent',
        },
      }),
    ]

    const { container } = render(h(BoardSurface, null))

    const sigil = container.querySelector<HTMLElement>('.bd-sigil')
    expect(sigil).not.toBeNull()
    expect(sigil?.textContent).toBe('AL')
  })

  it('disables context inference button for non-keeper authored posts when keepers list is empty', () => {
    boardPosts.value = [
      makePost({
        id: 'post-non-keeper',
        title: 'non keeper post',
        body: 'hello world',
        author: 'operator',
        post_kind: 'direct',
        author_identity: {
          kind: 'agent',
          id: 'operator-1',
          key: 'operator',
          display_name: 'Operator',
          raw: 'operator-1',
        },
      }),
    ]
    keepers.value = []

    render(h(BoardSurface, null))

    const button = screen.getByTestId('bd-context-infer-post-non-keeper') as HTMLButtonElement
    expect(button).toBeDisabled()
    expect(button).toHaveAttribute('title', '맥락 추론을 실행할 등록된 keeper가 없습니다')
  })

  it('enables context inference button for non-keeper authored posts and uses first keeper as fallback', async () => {
    boardPosts.value = [
      makePost({
        id: 'post-non-keeper-2',
        title: 'non keeper post 2',
        body: 'hello world 2',
        author: 'operator',
        post_kind: 'direct',
        author_identity: {
          kind: 'agent',
          id: 'operator-1',
          key: 'operator',
          display_name: 'Operator',
          raw: 'operator-1',
        },
      }),
    ]
    keepers.value = [
      { name: 'keeper-sangsu' } as any,
      { name: 'keeper-chulsoo' } as any,
    ]

    const mockInfer = vi.mocked(requestBoardContextInference)
    mockInfer.mockResolvedValueOnce({ keeperName: 'keeper-sangsu', score: 1.0 } as any)

    render(h(BoardSurface, null))

    const button = screen.getByTestId('bd-context-infer-post-non-keeper-2') as HTMLButtonElement
    expect(button).not.toBeDisabled()
    expect(button).toHaveAttribute('title', '맥락 추론 요청 (keeper-sangsu)')

    fireEvent.click(button)
    expect(mockInfer).toHaveBeenCalledWith('post-non-keeper-2', 'keeper-sangsu')
  })
})
