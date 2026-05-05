import { h } from 'preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

vi.mock('../router', () => ({
  navigate: vi.fn(),
}))

vi.mock('../keeper-message', () => ({
  stripStateBlocks: (value: string) => value,
}))

vi.mock('./common/card', () => ({
  Card: ({ children }: { children?: any }) => h('div', {}, children),
}))

vi.mock('./common/time-ago', () => ({
  TimeAgo: ({ timestamp }: { timestamp: string }) => h('span', {}, timestamp),
}))

vi.mock('./common/markdown', () => ({
  Markdown: ({ text }: { text: string }) => h('div', {}, text),
}))

vi.mock('./common/toast', () => ({
  showToast: vi.fn(),
}))

vi.mock('./common/empty-state', () => ({
  EmptyState: ({ message }: { message: string }) => h('div', {}, message),
}))

vi.mock('./common/input', () => ({
  TextInput: (props: Record<string, unknown>) => h('input', props),
  TextArea: (props: Record<string, unknown>) => h('textarea', props),
}))

vi.mock('./memory-state', () => ({
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
  refreshBoard: vi.fn(),
}))

import { CommentThread, PostDetail, countCommentDescendants, filterCommentTree } from './memory-post-detail'
import type { BoardComment } from '../types/core'

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

describe('countCommentDescendants', () => {
  // Tree:
  //   r1 "alpha"
  //     c11 "beta"
  //       c111 "gamma"
  //   r2 "delta"
  //     c21 "epsilon"
  const countsMap = new Map<string, readonly any[]>([
    ['r1', [{ id: 'c11' }]],
    ['c11', [{ id: 'c111' }]],
    ['r2', [{ id: 'c21' }]],
  ])

  it('counts all descendants for a root with nested replies', () => {
    expect(countCommentDescendants('r1', countsMap)).toBe(2)
  })

  it('counts direct children when there are no deeper descendants', () => {
    expect(countCommentDescendants('r2', countsMap)).toBe(1)
  })

  it('counts leaf nodes as zero', () => {
    expect(countCommentDescendants('c111', countsMap)).toBe(0)
    expect(countCommentDescendants('c21', countsMap)).toBe(0)
  })

  it('returns zero for a missing id', () => {
    expect(countCommentDescendants('missing', countsMap)).toBe(0)
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
      comments: [],
    } as any

    render(h(PostDetail, { post }))

    expect(screen.getByText(/분류 근거:/)).toBeInTheDocument()
    expect(screen.getByText(/Direct board post without automation provenance/)).toBeInTheDocument()
    expect(screen.getByText('직접')).toBeInTheDocument()
  })
})
