import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

vi.mock('../../keeper-message', () => ({
  stripStateBlocks: (value: string) => value,
}))

vi.mock('../common/card', () => ({
  Card: ({ children }: { children?: any }) => h('div', {}, children),
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

vi.mock('../common/empty-state', () => ({
  EmptyState: ({ message }: { message: string }) => h('div', {}, message),
}))

vi.mock('../../api/board', () => ({
  fetchBoardReactions: vi.fn().mockResolvedValue([]),
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
  boardPostKind: () => 'direct',
  votePost: vi.fn(),
  voteComment: vi.fn().mockResolvedValue(undefined),
  refreshBoard: vi.fn(),
}))

import {
  CommentThread,
  PostDetail,
  buildCommentDescendantCounts,
  countCommentDescendants,
  filterCommentTree,
} from './post-detail'
import { voteComment, votePost } from './board-state'
import { toggleReaction } from '../../api/board'
import type { BoardComment } from '../../types/core'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('CommentThread', () => {
  it('renders nested replies beyond one level', () => {
    const comments = [
      { id: 'c1', post_id: 'post-1', parent_id: null, author: 'root-agent', content: 'root comment', created_at: '2026-04-02T00:00:00Z' },
      { id: 'c2', post_id: 'post-1', parent_id: 'c1', author: 'child-agent', content: 'child reply', created_at: '2026-04-02T00:01:00Z' },
      { id: 'c3', post_id: 'post-1', parent_id: 'c2', author: 'grandchild-agent', content: 'grandchild reply', created_at: '2026-04-02T00:02:00Z' },
    ] as any

    render(h(CommentThread, { comments, postId: 'post-1' }))

    expect(screen.getByText('root comment')).toBeInTheDocument()
    expect(screen.getByText('child reply')).toBeInTheDocument()
    expect(screen.getByText('grandchild reply')).toBeInTheDocument()
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
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.getByText(/분류 근거:/)).toBeInTheDocument()
    expect(screen.getByText(/Direct board post without automation provenance/)).toBeInTheDocument()
    expect(screen.getByText('직접')).toBeInTheDocument()
    expect(screen.getByLabelText('게시글 moderation 승인됨 1건')).toHaveTextContent('승인됨 1')
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
})
