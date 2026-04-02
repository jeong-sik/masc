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
  visibilityLabel: () => '',
  visibilityBadgeColor: () => '',
  boardPostKind: () => 'human',
  votePost: vi.fn(),
  refreshBoard: vi.fn(),
}))

import { CommentThread } from './memory-post-detail'

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
