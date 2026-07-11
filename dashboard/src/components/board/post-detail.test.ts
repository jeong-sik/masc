import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

const routerMock = vi.hoisted(() => {
  const route = { value: { params: {} as Record<string, string> } }
  const replaceRoute = vi.fn((_tab: string, params?: Record<string, string>) => {
    route.value = { params: params ?? {} }
  })
  return {
    route,
    navigate: vi.fn(),
    replaceRoute,
  }
})

vi.mock('../../router', () => routerMock)

vi.mock('../common/card', () => ({
  SectionCard: ({ children }: { children?: any }) => h('div', {}, children),
  SurfaceCard: ({ children }: { children?: any }) => h('div', {}, children),
}))

vi.mock('../common/time-ago', () => ({
  TimeAgo: ({ timestamp }: { timestamp: string }) => h('span', {}, timestamp),
}))

vi.mock('../common/markdown', () => ({
  Markdown: ({ text }: { text: string }) => h('div', {}, text),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

vi.mock('../common/feedback-state', () => ({
  EmptyState: ({ message }: { message: string }) => h('div', {}, message),
}))

vi.mock('../../api/board', () => ({
  fetchBoardReactionState: vi.fn().mockResolvedValue({
    summaries: [],
    supportedEmojis: ['👍', '❤️', '🎉', '🚀', '👀', '😕', '👏', '🔥'],
  }),
  votePost: vi.fn().mockResolvedValue(undefined),
  voteComment: vi.fn().mockResolvedValue(undefined),
  requestBoardContextInference: vi.fn().mockResolvedValue({
    ok: true,
    requestId: 'kmsg-post-share',
    keeperName: 'sleepers',
    postId: 'post-share',
    status: 'queued',
    targetSource: 'explicit_target',
  }),
  toggleReaction: vi.fn().mockResolvedValue({
    target_type: 'comment',
    target_id: 'c1',
    user_id: 'dashboard-reviewer',
    emoji: '🚀',
    reacted: true,
    summary: [{
      emoji: '🚀',
      count: 1,
      reacted: true,
      has_reacted: true,
      recent_user_ids: ['dashboard-reviewer'],
    }],
  }),
}))

vi.mock('../common/input', () => ({
  TextInput: (props: Record<string, unknown>) => h('input', props),
  TextArea: (props: Record<string, unknown>) => h('textarea', props),
}))

vi.mock('./board-state', () => ({
  detailComments: { value: [] },
  detailLoading: { value: false },
  detailPostId: { value: null },
  commentText: { value: '' },
  commentSubmitting: { value: false },
  replyingTo: { value: null },
  loadPostDetail: vi.fn(),
  submitComment: vi.fn(),
  authorAvatar: (author: string) => `@${author}`,
  kindBadgeColor: () => '',
  kindLabel: (kind: string) => (kind === 'direct' ? '직접' : kind),
  visibilityLabel: () => '',
  visibilityBadgeColor: () => '',
  postVisibilityAuditLabel: (post: any) => {
    const visibility = post.visibility === 'internal' ? '내부' : '공개'
    const score = post.vote_blind ? '점수 투표 후 공개' : `점수 ${post.votes ?? 0}`
    const updated = post.updated_at !== post.created_at ? '최근 갱신됨' : '원본 작성 시각 기준'
    return `표시 중 · ${visibility} · 댓글 ${post.comment_count ?? 0}개 · ${score} · ${updated}`
  },
  boardPostKind: () => 'direct',
  refreshBoard: vi.fn(),
}))

// Stub the shared turn-inspector drawer so the board affordance can be tested
// without the real KeeperTurnInspector self-fetching turn records. Renders the
// anchor props as data attributes only when open, mirroring the real testId.
vi.mock('../keeper-turn-inspector-drawer', () => ({
  TurnInspectorDrawer: ({ keeperName, initialTurnRef, open, testId }: any) =>
    open
      ? h('div', {
          'data-testid': `${testId}-drawer`,
          'data-keeper': keeperName,
          'data-initial-turn-ref': initialTurnRef ?? '',
        })
      : null,
}))

import {
  CommentThread,
  PostDetail,
  buildCommentDescendantCounts,
  countCommentDescendants,
  filterCommentTree,
} from './post-detail'
import { detailComments } from './board-state'
import { requestBoardContextInference, toggleReaction, voteComment, votePost } from '../../api/board'
import type { BoardComment } from '../../types/core'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  routerMock.route.value = { params: {} }
  detailComments.value = []
})

describe('CommentThread', () => {
  it('renders nested replies beyond one level', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'root-agent', content: 'root comment', created_at: '2026-04-02T00:00:00Z' },
      { id: 'c2', post_id: 'post-1', parent_id: 'c1', author: 'child-agent', content: 'child reply', created_at: '2026-04-02T00:01:00Z' },
      { id: 'c3', post_id: 'post-1', parent_id: 'c2', author: 'grandchild-agent', content: 'grandchild reply', created_at: '2026-04-02T00:02:00Z' },
    ] as any

    const { container } = render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.getByText('root comment')).toBeInTheDocument()
    expect(screen.getByText('child reply')).toBeInTheDocument()
    expect(screen.getByText('grandchild reply')).toBeInTheDocument()
    expect(container.querySelectorAll('.v2-workspace-row').length).toBeGreaterThanOrEqual(3)
  })

  it('shows orphaned replies as root comments when the parent is missing', () => {
    const comments = [
      { id: 'c2', post_id: 'post-1', parent_id: 'missing-parent', author: 'orphan-agent', content: 'orphan reply still visible', created_at: '2026-04-02T00:01:00Z' },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.getByText('orphan reply still visible')).toBeInTheDocument()
    expect(screen.getByText(/댓글 1개/)).toBeInTheDocument()
  })

  it('collapses and expands a reply subtree from the thread control', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'root-agent', content: 'root comment', created_at: '2026-04-02T00:00:00Z' },
      { id: 'c2', post_id: 'post-1', parent_id: 'c1', author: 'child-agent', content: 'child reply', created_at: '2026-04-02T00:01:00Z' },
      { id: 'c3', post_id: 'post-1', parent_id: 'c2', author: 'grandchild-agent', content: 'grandchild reply', created_at: '2026-04-02T00:02:00Z' },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    fireEvent.click(screen.getByRole('button', { name: '답글 2개 접기' }))
    expect(screen.queryByText('child reply')).not.toBeInTheDocument()
    expect(screen.getByText('답글 2개 접힘')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: '답글 2개 펼치기' }))
    expect(screen.getByText('child reply')).toBeInTheDocument()
  })

  it('paginates sibling replies inside a busy branch', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'root-agent', content: 'root comment', created_at: '2026-04-02T00:00:00Z' },
      ...Array.from({ length: 7 }, (_, index) => ({
        id: `c${index + 2}`,
        post_id: 'post-1',
        parent_id: 'c1',
        author: 'child-agent',
        content: `sibling reply ${index + 1}`,
        created_at: `2026-04-02T00:0${index + 1}:00Z`,
      })),
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.getByText('sibling reply 1')).toBeInTheDocument()
    expect(screen.getByText('sibling reply 5')).toBeInTheDocument()
    expect(screen.queryByText('sibling reply 6')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: '답글 2개 더 보기' }))

    expect(screen.getByText('sibling reply 6')).toBeInTheDocument()
    expect(screen.getByText('sibling reply 7')).toBeInTheDocument()
  })

  it('keeps replies past depth five behind an explicit continue control', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'agent', content: 'level 0', created_at: '2026-04-02T00:00:00Z' },
      { id: 'c2', post_id: 'post-1', parent_id: 'c1', author: 'agent', content: 'level 1', created_at: '2026-04-02T00:01:00Z' },
      { id: 'c3', post_id: 'post-1', parent_id: 'c2', author: 'agent', content: 'level 2', created_at: '2026-04-02T00:02:00Z' },
      { id: 'c4', post_id: 'post-1', parent_id: 'c3', author: 'agent', content: 'level 3', created_at: '2026-04-02T00:03:00Z' },
      { id: 'c5', post_id: 'post-1', parent_id: 'c4', author: 'agent', content: 'level 4', created_at: '2026-04-02T00:04:00Z' },
      { id: 'c6', post_id: 'post-1', parent_id: 'c5', author: 'agent', content: 'level 5', created_at: '2026-04-02T00:05:00Z' },
      { id: 'c7', post_id: 'post-1', parent_id: 'c6', author: 'agent', content: 'level 6 hidden', created_at: '2026-04-02T00:06:00Z' },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.getByText('level 5')).toBeInTheDocument()
    expect(screen.queryByText('level 6 hidden')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /스레드 계속 펼치기/ }))
    expect(screen.getByText('level 6 hidden')).toBeInTheDocument()
  })

  it('surfaces deep matching replies while the comment filter is active', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'agent', content: 'level 0', created_at: '2026-04-02T00:00:00Z' },
      { id: 'c2', post_id: 'post-1', parent_id: 'c1', author: 'agent', content: 'level 1', created_at: '2026-04-02T00:01:00Z' },
      { id: 'c3', post_id: 'post-1', parent_id: 'c2', author: 'agent', content: 'level 2', created_at: '2026-04-02T00:02:00Z' },
      { id: 'c4', post_id: 'post-1', parent_id: 'c3', author: 'agent', content: 'level 3', created_at: '2026-04-02T00:03:00Z' },
      { id: 'c5', post_id: 'post-1', parent_id: 'c4', author: 'agent', content: 'level 4', created_at: '2026-04-02T00:04:00Z' },
      { id: 'c6', post_id: 'post-1', parent_id: 'c5', author: 'agent', content: 'level 5', created_at: '2026-04-02T00:05:00Z' },
      { id: 'c7', post_id: 'post-1', parent_id: 'c6', author: 'agent', content: 'needle at level 6', created_at: '2026-04-02T00:06:00Z' },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.queryByText('needle at level 6')).not.toBeInTheDocument()
    fireEvent.input(screen.getByPlaceholderText('댓글 내용 검색'), {
      target: { value: 'needle' },
    })

    expect(screen.getByText('needle at level 6')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /스레드 계속 펼치기/ })).not.toBeInTheDocument()
  })

  it('ignores a manual collapsed state while the comment filter is active', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'root-agent', content: 'root comment', created_at: '2026-04-02T00:00:00Z' },
      { id: 'c2', post_id: 'post-1', parent_id: 'c1', author: 'child-agent', content: 'needle child reply', created_at: '2026-04-02T00:01:00Z' },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    fireEvent.click(screen.getByRole('button', { name: '답글 1개 접기' }))
    expect(screen.queryByText('needle child reply')).not.toBeInTheDocument()

    fireEvent.input(screen.getByPlaceholderText('댓글 내용 검색'), {
      target: { value: 'needle' },
    })

    expect(screen.getByText('needle child reply')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '답글 1개 접기' })).not.toBeInTheDocument()
    expect(screen.queryByText('답글 1개 접힘')).not.toBeInTheDocument()

    fireEvent.input(screen.getByPlaceholderText('댓글 내용 검색'), {
      target: { value: '' },
    })

    expect(screen.queryByText('needle child reply')).not.toBeInTheDocument()
    expect(screen.getByText('답글 1개 접힘')).toBeInTheDocument()
  })

  it('sends comment votes through the board comment vote tool', async () => {
    const comments = [
      {
        id: 'c1',
        post_id: 'post-1',
        parent_id: null,
        author: 'agent',
        content: 'vote on me',
        created_at: '2026-04-02T00:00:00Z',
        vote_balance: 4,
      },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    fireEvent.click(screen.getByRole('button', { name: '댓글 추천' }))
    await Promise.resolve()

    expect(voteComment).toHaveBeenCalledWith('c1', 'up')
    expect(screen.getByText('4')).toBeInTheDocument()
  })

  it('renders comment moderation projection badges', () => {
    const comments = [
      {
        id: 'c1',
        post_id: 'post-1',
        parent_id: null,
        author: 'agent',
        content: 'review me',
        created_at: '2026-04-02T00:00:00Z',
        report_count: 1,
        moderation_status: 'hidden',
      },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.getByLabelText('댓글 moderation 숨김 1건')).toHaveTextContent('숨김 1')
  })

  it('renders vote-blind comment scores as hidden until voting', () => {
    const comments = [
      {
        id: 'c1',
        post_id: 'post-1',
        parent_id: null,
        author: 'agent',
        content: 'review me',
        created_at: '2026-04-02T00:00:00Z',
        votes: null,
        vote_balance: null,
        vote_blind: true,
        vote_blind_reason: 'vote_before_score',
      },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.getByLabelText('댓글 점수 투표 후 공개')).toHaveTextContent('투표 후 공개')
  })

  it('marks the current comment vote as pressed', () => {
    const comments = [
      {
        id: 'c1',
        post_id: 'post-1',
        parent_id: null,
        author: 'agent',
        content: 'already voted',
        created_at: '2026-04-02T00:00:00Z',
        vote_balance: 4,
        current_vote: 'up',
        has_voted: true,
      },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    const upvote = screen.getByRole('button', { name: '댓글 추천' })
    expect(upvote).toHaveAttribute('aria-pressed', 'true')
    expect(upvote).toBeDisabled()
    expect(screen.getByRole('button', { name: '댓글 비추천' })).toHaveAttribute('aria-pressed', 'false')
  })

  it('toggles a comment reaction from the thread', async () => {
    const comments = [
      {
        id: 'c1',
        post_id: 'post-1',
        parent_id: null,
        author: 'agent',
        content: 'react to me',
        created_at: '2026-04-02T00:00:00Z',
      },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    fireEvent.click(await screen.findByRole('button', { name: '🚀 리액션 0개' }))

    await waitFor(() => {
      expect(toggleReaction).toHaveBeenCalledWith('comment', 'c1', '🚀')
    })
  })

  it('surfaces an older root comment when it is route-focused', () => {
    const comments = Array.from({ length: 7 }, (_, index) => ({
      id: `c${index + 1}`,
      post_id: 'post-1',
      parent_id: null,
      author: 'agent',
      content: index === 0 ? 'old focused comment' : `visible comment ${index + 1}`,
      created_at: `2026-04-02T00:0${index}:00Z`,
    })) as any

    render(h(CommentThread, { comments, postId: 'post-1', focusedCommentId: 'c1' }))

    expect(screen.getByText('old focused comment')).toBeInTheDocument()
    expect(document.querySelector('[data-route-focused-comment="c1"]')).not.toBeNull()
    expect(screen.queryByRole('button', { name: /이전 댓글/ })).not.toBeInTheDocument()
  })

  it('expands a busy reply branch when a hidden reply is route-focused', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'root-agent', content: 'root comment', created_at: '2026-04-02T00:00:00Z' },
      ...Array.from({ length: 7 }, (_, index) => ({
        id: `c${index + 2}`,
        post_id: 'post-1',
        parent_id: 'c1',
        author: 'child-agent',
        content: `sibling reply ${index + 1}`,
        created_at: `2026-04-02T00:0${index + 1}:00Z`,
      })),
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1', focusedCommentId: 'c8' }))

    expect(screen.getByText('sibling reply 7')).toBeInTheDocument()
    expect(document.querySelector('[data-route-focused-comment="c8"]')).not.toBeNull()
    expect(screen.queryByRole('button', { name: /답글 2개 더 보기/ })).not.toBeInTheDocument()
  })
})

describe('filterCommentTree', () => {
  const comment = (
    id: string,
    parent_id: string | null,
    content: string,
  ): BoardComment => ({
    id,
    post_id: 'post-1',
    parent_id,
    author: 'agent',
    content,
    created_at: '2026-04-17T00:00:00Z',
  })

  // Tree:
  //   r1 "alpha"
  //     c11 "beta"
  //       c111 "gamma"
  //   r2 "delta"
  //     c21 "epsilon"
  const r1 = comment('r1', null, 'alpha')
  const c11 = comment('c11', 'r1', 'beta')
  const c111 = comment('c111', 'c11', 'gamma')
  const r2 = comment('r2', null, 'delta')
  const c21 = comment('c21', 'r2', 'epsilon')

  const roots: readonly BoardComment[] = [r1, r2]
  const childrenMap = new Map<string, readonly BoardComment[]>([
    ['r1', [c11]],
    ['c11', [c111]],
    ['r2', [c21]],
  ])

  it('counts all descendants for collapse labels', () => {
    expect(countCommentDescendants('r1', childrenMap)).toBe(2)
    expect(countCommentDescendants('r2', childrenMap)).toBe(1)
    expect(countCommentDescendants('missing', childrenMap)).toBe(0)
  })

  it('precomputes descendant counts for O(1) render lookups', () => {
    const counts = buildCommentDescendantCounts(childrenMap)
    expect(counts.get('r1')).toBe(2)
    expect(counts.get('c11')).toBe(1)
    expect(counts.get('c111')).toBe(0)
    expect(counts.get('r2')).toBe(1)
    expect(counts.get('c21')).toBe(0)
  })

  it('returns original references on empty query (ref-equal)', () => {
    const out = filterCommentTree(roots, childrenMap, '')
    expect(out.roots).toBe(roots)
    expect(out.childrenMap).toBe(childrenMap)
  })

  it('returns original references on whitespace-only query', () => {
    const out = filterCommentTree(roots, childrenMap, '   ')
    expect(out.roots).toBe(roots)
    expect(out.childrenMap).toBe(childrenMap)
  })

  it('matches direct root substring case-insensitively', () => {
    const out = filterCommentTree(roots, childrenMap, 'ALPHA')
    expect(out.roots.map(c => c.id)).toEqual(['r1'])
    // r1 alone matches; its descendants are not kept (only ancestor chain is preserved up, not descendants down).
    expect(out.childrenMap.get('r1')).toBeUndefined()
  })

  it('preserves ancestor chain when a deep descendant matches', () => {
    const out = filterCommentTree(roots, childrenMap, 'gamma')
    expect(out.roots.map(c => c.id)).toEqual(['r1'])
    expect(out.childrenMap.get('r1')?.map(c => c.id)).toEqual(['c11'])
    expect(out.childrenMap.get('c11')?.map(c => c.id)).toEqual(['c111'])
    expect(out.childrenMap.get('r2')).toBeUndefined()
    expect(out.childrenMap.get('c21')).toBeUndefined()
  })

  it('preserves ancestor when intermediate child matches', () => {
    const out = filterCommentTree(roots, childrenMap, 'beta')
    expect(out.roots.map(c => c.id)).toEqual(['r1'])
    expect(out.childrenMap.get('r1')?.map(c => c.id)).toEqual(['c11'])
    // c11 itself matches but has no matched descendants -> no entry for c11.
    expect(out.childrenMap.get('c11')).toBeUndefined()
  })

  it('returns empty roots on no match', () => {
    const out = filterCommentTree(roots, childrenMap, 'zzzzz')
    expect(out.roots).toEqual([])
    expect(out.childrenMap.size).toBe(0)
  })

  it('trims the query before matching', () => {
    const out = filterCommentTree(roots, childrenMap, '   alpha   ')
    expect(out.roots.map(c => c.id)).toEqual(['r1'])
  })

  it('does not mutate the original collections', () => {
    const rootsSnapshot = [...roots]
    const childrenSnapshot = new Map(
      [...childrenMap.entries()].map(([k, v]) => [k, [...v]] as const),
    )
    filterCommentTree(roots, childrenMap, 'gamma')
    expect(roots).toEqual(rootsSnapshot)
    expect(childrenMap.size).toBe(childrenSnapshot.size)
    for (const [k, v] of childrenSnapshot) {
      expect([...(childrenMap.get(k) ?? [])]).toEqual([...v])
    }
  })
})

describe('PostDetail', () => {
  it('renders the classification reason when present', () => {
    const post = {
      id: 'post-1',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'direct',
      classification_reason: 'Direct board post without automation provenance.',
      report_count: 1,
      moderation_status: 'approved',
      contributor_quality: {
        score: 0.91,
        ups: 20,
        downs: 1,
        source: 'board_votes',
        evidence_state: 'measured',
      },
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.getByText(/분류 근거:/)).toBeInTheDocument()
    expect(screen.getByText(/Direct board post without automation provenance/)).toBeInTheDocument()
    expect(screen.getByText('직접')).toBeInTheDocument()
    expect(screen.getByLabelText('게시글 moderation 승인됨 1건')).toHaveTextContent('승인됨 1')
    expect(screen.getByLabelText('기여자 품질 91점 (Wilson lower bound) · 👍20 👎1')).toHaveTextContent('품질 91')
  })

  it('renders contributor quality when it is the only detail badge', () => {
    const post = {
      id: 'post-quality',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'direct',
      moderation_status: 'none',
      contributor_quality: {
        score: 0.42,
        ups: 5,
        downs: 5,
        source: 'board_votes',
        evidence_state: 'measured',
      },
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.getByLabelText('기여자 품질 42점 (Wilson lower bound) · 👍5 👎5')).toHaveTextContent('품질 42')
  })

  it('renders claim evidence when it is the only detail badge', () => {
    const post = {
      id: 'post-claim-evidence',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'direct',
      moderation_status: 'none',
      claim_evidence: {
        state: 'artifact_missing',
        label: 'Artifact missing',
        total_count: 1,
        allowed_count: 1,
        rejected_count: 0,
        artifact_missing_count: 1,
        artifact_unknown_count: 0,
        missing_source_snapshot_count: 0,
        stale_source_snapshot_count: 0,
        artifact_not_verified_count: 0,
      },
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.getByLabelText(/Artifact missing/)).toHaveTextContent('Artifact missing')
  })

  it('marks the current post vote as pressed', async () => {
    const post = {
      id: 'post-1',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 7,
      vote_balance: 7,
      current_vote: 'down',
      has_voted: true,
      comment_count: 0,
      post_kind: 'direct',
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    const downvote = screen.getByRole('button', { name: '▼ 비추천' })
    expect(downvote).toHaveAttribute('aria-pressed', 'true')
    expect(downvote).toBeDisabled()
    expect(screen.getByRole('button', { name: '▲ 추천' })).toHaveAttribute('aria-pressed', 'false')

    fireEvent.click(screen.getByRole('button', { name: '▲ 추천' }))
    await waitFor(() => {
      expect(votePost).toHaveBeenCalledWith('post-1', 'up')
    })
  })

  it('renders vote-blind post scores as hidden until voting', () => {
    const post = {
      id: 'post-1',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: null,
      vote_balance: null,
      vote_blind: true,
      vote_blind_reason: 'vote_before_score',
      comment_count: 0,
      post_kind: 'direct',
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.getByLabelText('게시글 점수 투표 후 공개')).toHaveTextContent('투표 후 공개')
  })

  it('renders permalink, trackback, context inference, and X share actions on the full post detail route', async () => {
    const post = {
      id: 'post-share',
      author: 'sleepers',
      author_identity: {
        kind: 'keeper',
        id: 'sleepers',
        key: 'keeper:sleepers',
        display_name: 'Sleepers',
        raw: 'sleepers',
      },
      title: 'Share **this**',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'direct',
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.getByTestId('bd-share-post-share')).toBeInTheDocument()
    expect(screen.getByTestId('bd-share-link-post-share')).toHaveAttribute('aria-label', '게시글 링크 복사: post-share')
    expect(screen.getByTestId('bd-share-trackback-post-share')).toHaveAttribute('aria-label', '트랙백 링크 복사: post-share')
    expect(screen.getByTestId('bd-context-infer-post-share')).toHaveAttribute('aria-label', '맥락 추론 요청: post-share')
    expect(screen.getByTestId('bd-share-x-post-share')).toHaveAttribute('href', expect.stringContaining('https://twitter.com/intent/tweet?'))

    fireEvent.click(screen.getByTestId('bd-context-infer-post-share'))

    await waitFor(() => {
      expect(requestBoardContextInference).toHaveBeenCalledWith('post-share', 'sleepers')
    })
  })

  it('renders board visibility audit details on post detail', () => {
    const post = {
      id: 'post-1',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T01:00:00Z',
      votes: null,
      vote_balance: null,
      vote_blind: true,
      comment_count: 5,
      visibility: 'internal',
      post_kind: 'direct',
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    const audit = screen.getByLabelText(/게시글 표시 감사:/)
    expect(audit).toHaveTextContent('표시 감사: 표시 중 · 내부 · 댓글 5개 · 점수 투표 후 공개 · 최근 갱신됨')
    expect(audit).toHaveTextContent('목록 정렬/필터에 따라 위치가 바뀔 수 있습니다.')
  })

  it('renders fusion panel and judge evidence from board meta', () => {
    const post = {
      id: 'post-fusion',
      author: 'fusion-keeper',
      title: 'Fusion deliberation (run fus-1): answer',
      body: 'Fusion deliberation headline',
      content: 'Fusion deliberation headline',
      created_at: '2026-06-19T00:00:00Z',
      updated_at: '2026-06-19T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'system',
      comments: [],
      meta: {
        source: 'fusion',
        run_id: 'fus-1234567890',
        question: 'Should we ship the fusion board renderer?',
        panel: [
          {
            model: 'ollama_cloud.kimi-k2-6',
            status: 'answered',
            answer: 'Panel one answer',
            input_tokens: 700,
            output_tokens: 1200,
          },
          {
            model: 'ollama_cloud.minimax-m3',
            status: 'failed',
            reason: '(Fusion_types.Provider_error\n   "Provider \'unknown\' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout")',
          },
        ],
        judge: {
          status: 'synthesized',
          decision: 'answer — ship',
          synthesis: '**[judge]** synthesis\n\n**Consensus**\n- Judge synthesis answer (models: ollama_cloud.kimi-k2-6)\n\n**Resolved answer**\nShip it.\n\n**Decision**: answer — ship\n',
          resolved_answer: 'Resolved answer fallback',
        },
        observed_usage: {
          input_tokens: 300,
          output_tokens: 3432,
        },
      },
    } as any

    const { container } = render(h(PostDetail, { post }))

    const evidence = screen.getByTestId('fusion-board-evidence')
    expect(evidence).toHaveTextContent('Fusion 심의 증거')
    expect(evidence).toHaveTextContent('fus-1234567890')
    expect(evidence).toHaveTextContent('1/2')
    expect(evidence).toHaveTextContent('3,432 tok')
    expect(evidence).toHaveTextContent('Should we ship the fusion board renderer?')
    expect(evidence).toHaveTextContent('Panel one answer')
    expect(evidence).toHaveTextContent("Provider 'ollama_cloud.minimax-m3' timeout phase=http_operation")
    expect(evidence).not.toHaveTextContent('Fusion_types.Provider_error')
    expect(evidence).not.toHaveTextContent("Provider 'unknown'")
    expect(evidence).toHaveTextContent('**[judge]** synthesis')
    expect(evidence).toHaveTextContent('Consensus')
    expect(evidence).toHaveTextContent('Judge synthesis answer')
    expect(evidence).not.toHaveTextContent('Resolved answer fallback')
    expect(container.querySelectorAll('[data-fusion-panel]')).toHaveLength(2)
  })

  it('does not render fusion evidence for ordinary board meta', () => {
    const post = {
      id: 'post-ordinary',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-06-19T00:00:00Z',
      updated_at: '2026-06-19T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'direct',
      comments: [],
      meta: {
        source: 'manual',
      },
    } as any

    render(h(PostDetail, { post }))

    expect(screen.queryByTestId('fusion-board-evidence')).not.toBeInTheDocument()
    expect(screen.getByText(/출처:/)).toBeInTheDocument()
  })

  it('renders and clears the board comment route focus receipt', () => {
    const post = {
      id: 'post-1',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 0,
      comment_count: 1,
      post_kind: 'direct',
      comments: [],
    } as any
    detailComments.value = [
      {
        id: 'comment-1',
        post_id: 'post-1',
        parent_id: null,
        author: 'keeper-alpha',
        content: 'focused route comment',
        created_at: '2026-04-02T00:00:00Z',
      },
    ] as any
    routerMock.route.value = {
      params: { section: 'board', post: 'post-1', comment: 'comment-1', focus: 'curation' },
    }

    render(h(PostDetail, { post }))

    expect(screen.getByTestId('board-comment-route-focus')).toBeInTheDocument()
    expect(screen.getByText('COMMENT comment-1')).toBeInTheDocument()
    expect(screen.getByText('author keeper-alpha')).toBeInTheDocument()
    expect(document.querySelector('[data-route-focused-comment="comment-1"]')).not.toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'CLEAR' }))

    expect(routerMock.route.value.params).toEqual({
      section: 'board',
      post: 'post-1',
      focus: 'curation',
    })
  })

  it('shows a turn affordance and opens the inspector at the post origin turn_ref', () => {
    const post = {
      id: 'post-origin',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'direct',
      moderation_status: 'none',
      origin: { turn_ref: 'trace-x#5', source: 'dashboard', fusion_run_id: null },
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    // Drawer stays closed until the affordance is clicked.
    expect(screen.queryByTestId('board-post-turn-inspector-drawer')).toBeNull()

    fireEvent.click(screen.getByLabelText('원본 턴 검사'))

    const drawer = screen.getByTestId('board-post-turn-inspector-drawer')
    // keeperName falls back to post.author when no keeper is resolved in-test;
    // initialTurnRef is the exact origin turn_ref join key (RFC-0233 §7).
    expect(drawer.getAttribute('data-keeper')).toBe('sleepers')
    expect(drawer.getAttribute('data-initial-turn-ref')).toBe('trace-x#5')
  })

  it('omits the turn affordance when the post has no origin turn_ref (e.g. fusion-origin)', () => {
    const post = {
      id: 'post-no-origin',
      author: 'sleepers',
      title: 'Post',
      body: 'Body',
      content: 'Body',
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      votes: 0,
      comment_count: 0,
      post_kind: 'direct',
      moderation_status: 'none',
      // A fusion-origin post carries fusion_run_id but no turn_ref → no affordance.
      origin: { turn_ref: null, source: 'fusion', fusion_run_id: 'fus-1' },
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.queryByLabelText('원본 턴 검사')).toBeNull()
    expect(screen.queryByTestId('board-post-turn-inspector-drawer')).toBeNull()
  })
})
