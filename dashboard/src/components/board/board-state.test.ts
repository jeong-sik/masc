import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    fetchBoardHearths: vi.fn(),
    fetchBoardFlairs: vi.fn(),
    fetchBoardPost: vi.fn(),
    commentPost: vi.fn(),
  }
})

vi.mock('../../store', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../store')>(),
  refreshBoard: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

import {
  boardFlairs,
  boardFlairsError,
  boardFlairsLoading,
  boardHearths,
  boardHearthsError,
  boardHearthsLoading,
  isUpdated,
  boardPostKind,
  contentCategory,
  categoryLabel,
  authorAvatar,
  kindLabel,
  visibilityLabel,
  postVisibilityAuditLabel,
  filterHint,
  splitVisiblePosts,
  refreshBoardFlairs,
  refreshBoardHearths,
  loadPostDetail,
  submitComment,
  commentText,
  loadOlderPostComments,
  detailPost,
  detailPostId,
  detailLoading,
  detailComments,
  detailCommentPage,
  type ContentCategory,
  type VisibleBoardGroups,
} from './board-state'
import type { BoardComment, BoardPost } from '../../types'
import { fetchBoardFlairs, fetchBoardHearths, fetchBoardPost, commentPost, type BoardFlair, type BoardHearth } from '../../api'
import { showToast } from '../common/toast'

// Reset module-scope signals between tests
import { boardHiddenCategories, boardExcludeAutomation } from '../../store'

function makePost(overrides: Partial<BoardPost> = {}): BoardPost {
  return {
    id: 'p1',
    author: 'test-agent',
    title: 'Test post',
    body: 'Test body content',
    meta: null,
    tags: [],
    votes: 0,
    vote_balance: 0,
    comment_count: 0,
    created_at: '2026-04-17T00:00:00Z',
    updated_at: '2026-04-17T00:00:00Z',
    post_kind: 'direct',
    flair: undefined,
    hearth: null,
    visibility: 'public',
    expires_at: null,
    hearth_count: 0,
    ...overrides,
  }
}

beforeEach(() => {
  detailPostId.value = null
  detailPost.value = null
  detailLoading.value = false
  detailComments.value = []
  detailCommentPage.value = { offset: 0, total: 0 }
  boardHiddenCategories.value = new Set()
  boardExcludeAutomation.value = false
  boardHearths.value = []
  boardHearthsError.value = false
  boardHearthsLoading.value = false
  boardFlairs.value = []
  boardFlairsError.value = false
  boardFlairsLoading.value = false
  vi.mocked(fetchBoardHearths).mockReset()
  vi.mocked(fetchBoardFlairs).mockReset()
  vi.mocked(fetchBoardPost).mockReset()
  vi.mocked(commentPost).mockReset()
  vi.mocked(showToast).mockReset()
})

describe('isUpdated', () => {
  it('returns false when timestamps match', () => {
    expect(isUpdated(makePost())).toBe(false)
  })

  it('returns true when updated_at differs', () => {
    expect(isUpdated(makePost({ updated_at: '2026-04-17T01:00:00Z' }))).toBe(true)
  })
})

describe('boardPostKind', () => {
  it('defaults to direct', () => {
    expect(boardPostKind(makePost({ post_kind: undefined }))).toBe('direct')
  })

  it('returns automation when set', () => {
    expect(boardPostKind(makePost({ post_kind: 'automation' }))).toBe('automation')
  })

  it('returns system when set', () => {
    expect(boardPostKind(makePost({ post_kind: 'system' }))).toBe('system')
  })
})

describe('contentCategory', () => {
  it('classifies system posts', () => {
    expect(contentCategory(makePost({ post_kind: 'system' }))).toBe('system')
  })

  it('uses explicit content category metadata before fallback policy', () => {
    expect(contentCategory(makePost({
      title: '일반 제목',
      meta: { content_category: 'review' },
    }))).toBe('review')
    expect(contentCategory(makePost({
      title: '일반 제목',
      meta: { board_category: 'notice' },
    }))).toBe('notice')
  })

  it('does not use flair labels as category signals', () => {
    expect(contentCategory(makePost({ flair: 'review' }))).toBe('article')
    expect(contentCategory(makePost({ flair: 'notice', post_kind: 'automation' }))).toBe('notice')
  })

  it('does not infer category from title keywords', () => {
    expect(contentCategory(makePost({ title: 'verdict: 코드 품질 양호' }))).toBe('article')
    expect(contentCategory(makePost({ title: 'alert: 서버 과부하' }))).toBe('article')
  })

  it('falls back to notice for automation posts', () => {
    expect(contentCategory(makePost({ post_kind: 'automation' }))).toBe('notice')
  })

  it('falls back to article for direct posts', () => {
    expect(contentCategory(makePost({ title: '일반 제목', body: '보통 내용' }))).toBe('article')
  })
})

describe('categoryLabel', () => {
  it('returns label for known categories', () => {
    expect(categoryLabel('article')).toBe('글/분석')
    expect(categoryLabel('review')).toBe('리뷰/판정')
    expect(categoryLabel('notice')).toBe('알림/상태')
    expect(categoryLabel('system')).toBe('시스템')
  })

  it('returns raw id for unknown', () => {
    expect(categoryLabel('unknown' as ContentCategory)).toBe('unknown')
  })
})

describe('authorAvatar', () => {
  it('returns a single emoji for any string', () => {
    const result = authorAvatar('test-agent')
    expect(result).toMatch(/\p{Emoji}/u)
    expect(result.length).toBeLessThanOrEqual(2) // emoji may be 1-2 chars
  })

  it('returns consistent avatar for same name', () => {
    expect(authorAvatar('keeper-1')).toBe(authorAvatar('keeper-1'))
  })

  it('returns different avatars for different names', () => {
    // Statistically unlikely to collide with different names
    expect(authorAvatar('keeper-1')).not.toBe(authorAvatar('keeper-2'))
  })
})

describe('kindLabel', () => {
  it('maps known kinds', () => {
    expect(kindLabel('direct')).toBe('직접')
    expect(kindLabel('automation')).toBe('자동화')
    expect(kindLabel('system')).toBe('시스템')
  })

  it('passes through unknown kinds', () => {
    expect(kindLabel('custom')).toBe('custom')
  })
})

describe('visibilityLabel', () => {
  it('maps known visibilities', () => {
    expect(visibilityLabel('internal')).toBe('내부')
    expect(visibilityLabel('unlisted')).toBe('비공개')
    expect(visibilityLabel('direct')).toBe('DM')
  })

  it('returns null for public', () => {
    expect(visibilityLabel('public')).toBeNull()
  })

  it('passes through unknown', () => {
    expect(visibilityLabel('secret')).toBe('secret')
  })
})

describe('postVisibilityAuditLabel', () => {
  it('summarizes visible, scoped, and updated state', () => {
    expect(postVisibilityAuditLabel(makePost({
      visibility: 'internal',
      comment_count: 13,
      votes: 3,
      updated_at: '2026-04-17T01:00:00Z',
    }))).toBe('표시 중 · 내부 · 댓글 13개 · 점수 3 · 최근 갱신됨')
  })

  it('uses public scope and numeric score for ordinary posts', () => {
    expect(postVisibilityAuditLabel(makePost({
      visibility: 'public',
      comment_count: 2,
      votes: 7,
    }))).toBe('표시 중 · 공개 · 댓글 2개 · 점수 7 · 원본 작성 시각 기준')
  })
})

describe('splitVisiblePosts', () => {
  it('groups posts by content category', () => {
    const posts = [
      makePost({ id: '1', title: '기술 탐색', body: 'x'.repeat(301) }),
      makePost({ id: '2', title: 'verdict: 양호' }),
      makePost({ id: '3', post_kind: 'system', title: '알림' }),
    ]
    const result = splitVisiblePosts(posts)
    expect(result.groups.length).toBeGreaterThanOrEqual(2)
  })

  it('hides posts in hidden categories', () => {
    const posts = [makePost({ id: '1', post_kind: 'system' })]
    boardHiddenCategories.value = new Set(['system'])
    const result = splitVisiblePosts(posts)
    const sysGroup = result.groups.find(g => g.category === 'system')
    expect(sysGroup!.hidden).toBe(1)
    expect(sysGroup!.posts.length).toBe(0)
  })

  it('returns empty groups for empty posts', () => {
    const result = splitVisiblePosts([])
    expect(result.groups).toEqual([])
    expect(result.totalDirect).toBe(0)
  })

  it('floats pinned posts to the top of their category, preserving order otherwise', () => {
    boardHiddenCategories.value = new Set()
    const posts = [
      makePost({ id: 'a' }),
      makePost({ id: 'b', pinned: true }),
      makePost({ id: 'c' }),
    ]
    const result = splitVisiblePosts(posts)
    const group = result.groups.find(g => g.posts.length === 3)
    expect(group).toBeDefined()
    expect(group!.posts.map(p => p.id)).toEqual(['b', 'a', 'c'])
  })
})

describe('filterHint', () => {
  it('returns null when nothing hidden', () => {
    const grouped: VisibleBoardGroups = {
      groups: [{ category: 'article', posts: [], total: 5, hidden: 0 }],
      direct: [],
      automation: [],
      system: [],
      totalDirect: 5,
      totalAutomation: 0,
      totalSystem: 0,
      hiddenAutomation: 0,
      hiddenSystem: 0,
    }
    expect(filterHint(grouped)).toBeNull()
  })

  it('returns hint when posts are hidden', () => {
    const grouped: VisibleBoardGroups = {
      groups: [{ category: 'system', posts: [], total: 3, hidden: 3 }],
      direct: [],
      automation: [],
      system: [],
      totalDirect: 0,
      totalAutomation: 0,
      totalSystem: 3,
      hiddenAutomation: 0,
      hiddenSystem: 3,
    }
    const hint = filterHint(grouped)
    expect(hint).toContain('숨겨져')
    expect(hint).toContain('3건')
  })
})

describe('refreshBoardHearths', () => {
  it('keeps a newer successful hearth refresh authoritative over stale failures', async () => {
    let rejectFirst: ((error: Error) => void) | undefined
    let resolveSecond: ((hearths: BoardHearth[]) => void) | undefined

    vi.mocked(fetchBoardHearths)
      .mockImplementationOnce(() => new Promise<BoardHearth[]>((_, reject) => { rejectFirst = reject }))
      .mockImplementationOnce(() => new Promise<BoardHearth[]>((resolve) => { resolveSecond = resolve }))

    const first = refreshBoardHearths()
    const second = refreshBoardHearths()

    resolveSecond!([{ name: 'ops', count: 2 }])
    await second

    expect(boardHearths.value).toEqual([{ name: 'ops', count: 2 }])
    expect(boardHearthsError.value).toBe(false)
    expect(boardHearthsLoading.value).toBe(false)

    rejectFirst!(new Error('stale failure'))
    await first

    expect(boardHearths.value).toEqual([{ name: 'ops', count: 2 }])
    expect(boardHearthsError.value).toBe(false)
    expect(boardHearthsLoading.value).toBe(false)
    expect(showToast).not.toHaveBeenCalled()
  })
})

describe('refreshBoardFlairs', () => {
  it('loads flair options for the composer catalog', async () => {
    const flairs: BoardFlair[] = [{ name: 'insight', emoji: '💡', label: 'Insight' }]
    vi.mocked(fetchBoardFlairs).mockResolvedValue(flairs)

    await refreshBoardFlairs()

    expect(boardFlairs.value).toEqual(flairs)
    expect(boardFlairsError.value).toBe(false)
    expect(boardFlairsLoading.value).toBe(false)
  })

  it('keeps the composer usable when flair loading fails', async () => {
    vi.mocked(fetchBoardFlairs).mockRejectedValue(new Error('offline'))

    await refreshBoardFlairs()

    expect(boardFlairs.value).toEqual([])
    expect(boardFlairsError.value).toBe(true)
    expect(boardFlairsLoading.value).toBe(false)
    expect(showToast).toHaveBeenCalledWith('Flair 목록을 불러오지 못했습니다', 'error')
  })
})

describe('loadPostDetail', () => {
  it('keeps detail-only evidence and viewer state through the real API decoder', async () => {
    const actual = await vi.importActual<typeof import('../../api/board')>('../../api/board')
    vi.mocked(fetchBoardPost).mockImplementationOnce(actual.fetchBoardPost)
    const response = {
      post: {
        id: 'detail-evidence', author: 'thread-owner', title: 'Evidence',
        body: 'Read the original trace', votes: 1, comment_count: 0,
        created_at: '2026-10-03T00:00:00Z', updated_at: '2026-10-03T00:00:00Z',
        meta: { attachments: [{ kind: 'external_link', url: 'https://example.test/trace' }] },
        origin: { turn_ref: 'trace-board#5', source: 'dashboard', fusion_run_id: null },
        current_vote: 'up', has_voted: true,
        reactions: [{ emoji: '👍', count: 2, reacted: true, recent_user_ids: ['viewer'] }],
        supported_reaction_emojis: ['👍'],
      },
      comments: [], comment_page: { offset: 0, total: 0 },
    }
    const fetch = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify(response), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    try {
      await loadPostDetail('detail-evidence')

      expect(detailPost.value?.origin).toEqual({ turn_ref: 'trace-board#5', source: 'dashboard' })
      expect(detailPost.value?.attachments).toEqual([{ ok: true, attachment: {
        kind: 'external_link', source: { kind: 'url', url: 'https://example.test/trace' },
      } }])
      expect(detailPost.value?.current_vote).toBe('up')
      expect(detailPost.value?.has_voted).toBe(true)
      expect(detailPost.value?.reactions).toEqual(response.post.reactions)
      expect(detailPost.value?.supported_reaction_emojis).toEqual(['👍'])
      expect(detailPost.value).not.toHaveProperty('comments')
      expect(detailPost.value).not.toHaveProperty('commentPage')
      expect(detailComments.value).toEqual([])
    } finally {
      fetch.mockRestore()
    }
  })

  it('carries the closed state through to detailPost', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      id: 'post-closed',
      author: 'thread-owner',
      title: 'Wrapped up',
      body: 'closing this out',
      tags: [],
      votes: 0,
      comment_count: 0,
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      closed: {
        closed_by: 'thread-owner',
        closed_at: '2026-04-02T01:00:00Z',
        successor_id: 'p-successor000000000000000000000',
        summary: 'moved to the successor',
      },
      comments: [],
      commentPage: { offset: 0, total: 0 },
    } as any)

    await loadPostDetail('post-closed')

    expect(detailPost.value?.closed).toEqual({
      closed_by: 'thread-owner',
      closed_at: '2026-04-02T01:00:00Z',
      successor_id: 'p-successor000000000000000000000',
      summary: 'moved to the successor',
    })
  })

  it('prepends older pages without losing the newest comments', async () => {
    const comment = (n: number) => ({ id: `c${n}`, content: `comment ${n}` })
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1', comment_count: 45 }),
        comments: Array.from({ length: 20 }, (_, index) => comment(index + 26)),
        commentPage: { offset: 25, total: 45 },
      } as any)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1', comment_count: 45 }),
        comments: Array.from({ length: 20 }, (_, index) => comment(index + 6)),
        commentPage: { offset: 5, total: 45 },
      } as any)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1', comment_count: 45 }),
        comments: Array.from({ length: 5 }, (_, index) => comment(index + 1)),
        commentPage: { offset: 0, total: 45 },
      } as any)

    await loadPostDetail('p1')
    expect(fetchBoardPost).toHaveBeenCalledTimes(1)
    expect(detailComments.value[0]?.id).toBe('c26')
    await loadOlderPostComments('p1')
    expect(fetchBoardPost).toHaveBeenNthCalledWith(2, 'p1', 5, 20)
    await loadOlderPostComments('p1')
    expect(fetchBoardPost).toHaveBeenNthCalledWith(3, 'p1', 0, 5)
    expect(detailCommentPage.value).toEqual({ offset: 0, total: 45 })
    expect(detailComments.value).toHaveLength(45)
    expect(detailComments.value[0]?.id).toBe('c1')
    expect(detailComments.value[44]?.id).toBe('c45')
  })

  it('uses one server context lookup for a focused reply and its ancestors', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValueOnce({ ...makePost(),
      comments: [{ id: 'root' }, { id: 'reply', parent_id: 'root' }],
      commentPage: { offset: 19980, total: 20000, revision: 'one' },
    } as any)
    await loadPostDetail('p1', 'reply')
    expect(fetchBoardPost).toHaveBeenCalledExactlyOnceWith('p1', undefined, undefined, 'reply')
    expect(detailComments.value.map(comment => comment.id)).toEqual(['root', 'reply'])
  })

  it('clearing route focus restores only the latest page and subsequent action requests stay unfocused', async () => {
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'old-root' }, { id: 'reply', parent_id: 'old-root' }],
        commentPage: { offset: 0, total: 41, revision: 'one' } } as any)
      .mockResolvedValue({ ...makePost(), comments: [{ id: 'latest' }],
        commentPage: { offset: 21, total: 41, revision: 'two' } } as any)
    await loadPostDetail('p1', 'reply')
    await loadPostDetail('p1', null)
    expect(detailComments.value.map(row => row.id)).toEqual(['latest'])
    await loadPostDetail('p1')
    expect(vi.mocked(fetchBoardPost).mock.calls).toEqual([
      ['p1', undefined, undefined, 'reply'], ['p1'], ['p1'],
    ])
  })

  it('does not scan older pages for a missing focus ID', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValueOnce({ ...makePost(),
      comments: [{ id: 'latest' }], commentPage: { offset: 19980, total: 20000, revision: 'one' },
    } as any)
    await loadPostDetail('p1', 'deleted-comment')
    expect(fetchBoardPost).toHaveBeenCalledTimes(1)
    expect(detailPost.value?.id).toBe('p1')
    expect(detailComments.value.map(comment => comment.id)).toEqual(['latest'])
  })

  it('retries a failed initial read with only the latest page', async () => {
    vi.mocked(fetchBoardPost)
      .mockRejectedValueOnce(new Error('temporary initial failure'))
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'latest' }],
        commentPage: { offset: 19980, total: 20000, revision: 'current' } } as any)
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      await loadPostDetail('p1')
      await loadPostDetail('p1')
      expect(fetchBoardPost).toHaveBeenCalledTimes(2)
      expect(detailComments.value.map(row => row.id)).toEqual(['latest'])
    } finally { warn.mockRestore() }
  })

  it('does not treat an in-progress initial page as loaded history', async () => {
    detailPostId.value = 'p1'
    detailPost.value = makePost()
    detailLoading.value = true
    detailCommentPage.value = { offset: 0, total: 0 }
    vi.mocked(fetchBoardPost).mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'focused' }],
      commentPage: { offset: 19980, total: 20000, revision: 'current' } } as any)
    await loadPostDetail('p1', 'focused')
    expect(fetchBoardPost).toHaveBeenCalledExactlyOnceWith('p1', undefined, undefined, 'focused')
  })

  it('refreshes the previously loaded range instead of dropping an old acted-on row', async () => {
    detailPostId.value = 'p1'
    detailPost.value = makePost()
    detailCommentPage.value = { offset: 0, total: 22, revision: 'old' }
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'latest' }],
        commentPage: { offset: 2, total: 22, revision: 'new' } } as any)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'old', votes: 2 }],
        commentPage: { offset: 0, total: 22, revision: 'new' } } as any)
    await loadPostDetail('p1')
    expect(fetchBoardPost).toHaveBeenNthCalledWith(2, 'p1', 0, 2)
    expect(detailComments.value.map(comment => comment.id)).toEqual(['old', 'latest'])
    expect(detailComments.value[0]?.votes).toBe(2)
    expect(detailCommentPage.value.offset).toBe(0)
  })

  it('rebuilds an older-page request with the new tail when the snapshot changes', async () => {
    const comment = (id: string): BoardComment => ({ id, post_id: 'p1', author: 'keeper',
      content: id, created_at: '2026-09-30T00:00:00Z' })
    detailPostId.value = 'p1'
    detailPost.value = makePost()
    detailComments.value = [comment('retained')]
    detailCommentPage.value = { offset: 20, total: 21, revision: 'old' }
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost(), comments: [comment('earlier')],
        commentPage: { offset: 0, total: 22, revision: 'new' } })
      .mockResolvedValueOnce({ ...makePost(), comments: [comment('retained'), comment('appended')],
        commentPage: { offset: 2, total: 22, revision: 'new' } })
      .mockResolvedValueOnce({ ...makePost(), comments: [comment('earlier')],
        commentPage: { offset: 0, total: 22, revision: 'new' } })
    await loadOlderPostComments('p1')
    expect(detailComments.value.map(row => row.id)).toEqual(['earlier', 'retained', 'appended'])
    expect(detailCommentPage.value).toEqual({ offset: 0, total: 22, revision: 'new' })
    expect(fetchBoardPost).toHaveBeenCalledTimes(3)
  })

  it('keeps a retained focused ancestor before newly loaded intermediate roots', async () => {
    const comment = (id: string, thread_offset: number): BoardComment => ({ id, thread_offset,
      post_id: 'p1', author: 'keeper', content: id, created_at: '2026-09-30T00:00:00Z' })
    detailPostId.value = 'p1'
    detailPost.value = makePost()
    detailComments.value = [comment('focused-root', 0), comment('latest', 21)]
    detailCommentPage.value = { offset: 20, total: 22, revision: 'same' }
    vi.mocked(fetchBoardPost).mockResolvedValueOnce({ ...makePost(),
      comments: [comment('middle', 6)], commentPage: { offset: 0, total: 22, revision: 'same' } })
    await loadOlderPostComments('p1')
    expect(detailComments.value.map(row => row.id)).toEqual(['focused-root', 'middle', 'latest'])
  })

  it('refuses mixed revisions while refreshing a retained range', async () => {
    detailPostId.value = 'p1'
    detailPost.value = makePost()
    detailCommentPage.value = { offset: 0, total: 22, revision: 'old' }
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'latest' }],
        commentPage: { offset: 2, total: 22, revision: 'new' } } as any)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'different' }],
        commentPage: { offset: 0, total: 22, revision: 'changed-again' } } as any)
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      await loadPostDetail('p1')
      expect(detailPost.value).toBeNull()
      expect(detailComments.value).toEqual([])
      expect(showToast).toHaveBeenCalled()
      expect(fetchBoardPost).toHaveBeenCalledTimes(2)
    } finally { warn.mockRestore() }
  })

  it('loads a focused reply ancestor chain across two older pages', async () => {
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1', comment_count: 45 }),
        comments: [{ id: 'reply', parent_id: 'parent' }],
        commentPage: { offset: 25, total: 45 },
      } as any)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1', comment_count: 45 }),
        comments: [{ id: 'parent', parent_id: 'root' }],
        commentPage: { offset: 5, total: 45 },
      } as any)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1', comment_count: 45 }),
        comments: [{ id: 'root', parent_id: null }],
        commentPage: { offset: 0, total: 45 },
      } as any)

    await loadPostDetail('p1', 'reply')

    expect(fetchBoardPost).toHaveBeenCalledTimes(3)
    expect(fetchBoardPost).toHaveBeenNthCalledWith(2, 'p1', 5, 20)
    expect(fetchBoardPost).toHaveBeenNthCalledWith(3, 'p1', 0, 5)
    expect(detailComments.value.map(comment => [comment.id, comment.parent_id]))
      .toEqual([['root', null], ['parent', 'root'], ['reply', 'parent']])
  })

  it('retains the current focused page when an ancestor belongs to a changed snapshot', async () => {
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'reply', parent_id: 'root' }],
        commentPage: { offset: 20, total: 21, revision: 'current' } } as any)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'root', parent_id: null }],
        commentPage: { offset: 0, total: 22, revision: 'changed' } } as any)
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      await loadPostDetail('p1', 'reply')
      expect(detailComments.value.map(comment => comment.id)).toEqual(['reply'])
      expect(detailCommentPage.value).toEqual({ offset: 20, total: 21, revision: 'current' })
      expect(showToast).toHaveBeenCalledWith('이전 댓글을 불러오는 데 실패했습니다', 'error')
    } finally { warn.mockRestore() }
  })

  it('deduplicates overlapping ancestor pages without replacing retained comments', async () => {
    const reply: BoardComment = {
      id: 'reply', post_id: 'p1', parent_id: 'parent', author: 'keeper',
      content: 'retained reply', created_at: '2026-09-30T00:00:00Z',
    }
    const parent: BoardComment = { ...reply, id: 'parent', parent_id: null, content: 'parent' }
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost(), comments: [reply],
        commentPage: { offset: 20, total: 21 } })
      .mockResolvedValueOnce({ ...makePost(),
        comments: [parent, { ...reply, content: 'overlapping reply' }, parent],
        commentPage: { offset: 0, total: 21 } })

    await loadPostDetail('p1', 'reply')

    expect(detailComments.value).toEqual([parent, reply])
    expect(fetchBoardPost).toHaveBeenCalledTimes(2)
  })

  it('retains the current focused page when an ancestor response changes revision', async () => {
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'reply', parent_id: 'root' }],
        commentPage: { offset: 20, total: 21, revision: 'current' } } as any)
      .mockResolvedValueOnce({ ...makePost(), comments: [{ id: 'root', parent_id: null }],
        commentPage: { offset: 0, total: 21, revision: 'changed' } } as any)
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      await loadPostDetail('p1', 'reply')
      expect(detailComments.value.map(comment => comment.id)).toEqual(['reply'])
      expect(detailCommentPage.value).toEqual({ offset: 20, total: 21, revision: 'current' })
      expect(showToast).toHaveBeenCalledWith('이전 댓글을 불러오는 데 실패했습니다', 'error')
    } finally { warn.mockRestore() }
  })

  it('does not fetch older pages for a focused root already in the newest page', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValueOnce({ ...makePost({ id: 'p1' }),
      comments: [{ id: 'root', parent_id: null }],
      commentPage: { offset: 20, total: 40 },
    } as any)

    await loadPostDetail('p1', 'root')

    expect(fetchBoardPost).toHaveBeenCalledTimes(1)
    expect(detailCommentPage.value.offset).toBe(20)
  })

  it('stops searching for a missing ancestor when older pages are exhausted', async () => {
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1' }),
        comments: [{ id: 'reply', parent_id: 'missing' }],
        commentPage: { offset: 20, total: 40 },
      } as any)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1' }),
        comments: [{ id: 'unrelated', parent_id: null }],
        commentPage: { offset: 0, total: 40 },
      } as any)

    await loadPostDetail('p1', 'reply')

    expect(fetchBoardPost).toHaveBeenCalledTimes(2)
    expect(detailCommentPage.value.offset).toBe(0)
    expect(detailComments.value.map(comment => comment.id)).toEqual(['unrelated', 'reply'])
  })

  it('does not loop or fetch unrelated pages for an already loaded ancestor cycle', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValueOnce({ ...makePost({ id: 'p1' }),
      comments: [{ id: 'reply', parent_id: 'parent' }, { id: 'parent', parent_id: 'reply' }],
      commentPage: { offset: 20, total: 40 },
    } as any)

    await loadPostDetail('p1', 'reply')

    expect(fetchBoardPost).toHaveBeenCalledTimes(1)
    expect(detailComments.value.map(comment => comment.id)).toEqual(['reply', 'parent'])
  })

  it('keeps a newer detail authoritative when an older ancestor page returns late', async () => {
    let resolveOlder!: (value: Awaited<ReturnType<typeof fetchBoardPost>>) => void
    let markOlderRequested!: () => void
    const olderRequested = new Promise<void>(resolve => { markOlderRequested = resolve })
    const older = new Promise<Awaited<ReturnType<typeof fetchBoardPost>>>(resolve => { resolveOlder = resolve })
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1' }),
        comments: [{ id: 'reply', parent_id: 'root' }],
        commentPage: { offset: 20, total: 40 },
      } as any)
      .mockImplementationOnce(() => { markOlderRequested(); return older })
      .mockResolvedValueOnce({ ...makePost({ id: 'p2' }),
        comments: [{ id: 'current', parent_id: null }],
        commentPage: { offset: 20, total: 40 },
      } as any)

    const pending = loadPostDetail('p1', 'reply')
    await olderRequested
    await loadPostDetail('p2', 'current')
    resolveOlder({ ...makePost({ id: 'p1' }),
      comments: [{ id: 'root', parent_id: null }],
      commentPage: { offset: 0, total: 40 },
    } as any)
    await pending

    expect(detailPost.value?.id).toBe('p2')
    expect(detailComments.value.map(comment => comment.id)).toEqual(['current'])
    expect(detailCommentPage.value.offset).toBe(20)
  })

  it('refuses a non-advancing ancestor page instead of repeating requests', async () => {
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1' }),
        comments: [{ id: 'reply', parent_id: 'missing' }],
        commentPage: { offset: 20, total: 40 },
      } as any)
      .mockResolvedValueOnce({ ...makePost({ id: 'p1' }),
        comments: [], commentPage: { offset: 20, total: 40 },
      } as any)

    await loadPostDetail('p1', 'reply')

    expect(fetchBoardPost).toHaveBeenCalledTimes(2)
    expect(detailPost.value?.id).toBe('p1')
    expect(detailComments.value.map(comment => comment.id)).toEqual(['reply'])
    expect(detailCommentPage.value.offset).toBe(20)
    expect(showToast).toHaveBeenCalledWith('이전 댓글을 불러오는 데 실패했습니다', 'error')
  })

  it('retains the older parent chain after submitting a new reply', async () => {
    const comment = (id: string, parent_id: string | null): BoardComment => ({
      id, parent_id, post_id: 'p1', author: 'fixture', content: id,
      created_at: '2026-09-30T00:00:00Z',
    })
    vi.mocked(commentPost).mockResolvedValue({})
    vi.mocked(fetchBoardPost).mockResolvedValueOnce({ ...makePost({ comment_count: 45 }),
      comments: [comment('root', null), comment('older-parent', 'root'), comment('new-reply', 'older-parent')],
      commentPage: { offset: 40, total: 45, revision: 'after-reply' },
    })
    commentText.value = 'Reply to the older page'
    await submitComment('p1', 'older-parent')
    expect(commentPost).toHaveBeenCalledWith('p1', expect.any(String), 'Reply to the older page', 'older-parent')
    expect(fetchBoardPost).toHaveBeenCalledExactlyOnceWith('p1', undefined, undefined, 'older-parent')
    expect(detailComments.value.map(comment => [comment.id, comment.parent_id])).toEqual([
      ['root', null], ['older-parent', 'root'], ['new-reply', 'older-parent'],
    ])
  })

  it('leaves detailPost.closed undefined for an open post', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      id: 'post-open',
      author: 'analyst',
      title: 'Still going',
      body: 'open row',
      tags: [],
      votes: 0,
      comment_count: 0,
      created_at: '2026-04-02T00:00:00Z',
      updated_at: '2026-04-02T00:00:00Z',
      comments: [],
      commentPage: { offset: 0, total: 0 },
    } as any)

    await loadPostDetail('post-open')

    expect(detailPost.value?.closed).toBeUndefined()
  })
})

describe('focused detail continuity', () => {
  it('retains focus across a same-route action reload and resets it for another post', async () => {
    const reply = { id: 'reply', parent_id: 'parent' } as BoardComment
    const parent = { id: 'parent', parent_id: null } as BoardComment
    vi.mocked(fetchBoardPost).mockImplementation(async (id, offset) => ({
      ...makePost({ id }), comments: offset === 0 ? [parent] : [reply],
      commentPage: { offset: offset === 0 ? 0 : 20, total: 21 },
    } as any))
    await loadPostDetail('focused-post', 'reply')
    await loadPostDetail('focused-post')
    expect(detailComments.value.map(comment => comment.id)).toEqual(['parent', 'reply'])
    expect(vi.mocked(fetchBoardPost).mock.calls.slice(-2)).toEqual([
      ['focused-post', undefined, undefined, 'reply'], ['focused-post', 0, 20],
    ])
    await loadPostDetail('another-post')
    expect(detailComments.value.map(comment => comment.id)).toEqual(['reply'])
    expect(fetchBoardPost).toHaveBeenCalledTimes(5)
  })

  it('clears retained focus for an ordinary reopen of the same post', async () => {
    vi.mocked(fetchBoardPost).mockImplementation(async (_id, offset) => ({
      ...makePost({ id: 'reopened-post' }),
      comments: offset === 0 ? [{ id: 'parent', parent_id: null }] : [{ id: 'reply', parent_id: 'parent' }],
      commentPage: { offset: offset === 0 ? 0 : 20, total: 21 },
    } as any))
    await loadPostDetail('reopened-post', 'reply')
    await loadPostDetail('reopened-post', null)
    expect(fetchBoardPost).toHaveBeenCalledTimes(3)
    expect(detailComments.value.map(comment => comment.id)).toEqual(['reply'])
    expect(showToast).not.toHaveBeenCalled()
  })

  it('keeps the successfully read post and pages when later ancestor paging fails', async () => {
    vi.mocked(fetchBoardPost)
      .mockResolvedValueOnce({ ...makePost({ id: 'partial-post' }), comments: [{ id: 'reply', parent_id: 'parent' }],
        commentPage: { offset: 40, total: 41 } } as any)
      .mockResolvedValueOnce({ ...makePost({ id: 'partial-post' }), comments: [{ id: 'parent', parent_id: 'root' }],
        commentPage: { offset: 20, total: 41 } } as any)
      .mockRejectedValueOnce(new Error('fixture older page unavailable'))
    await loadPostDetail('partial-post', 'reply')
    expect(detailPost.value?.id).toBe('partial-post')
    expect(detailComments.value.map(comment => comment.id)).toEqual(['parent', 'reply'])
    expect(detailCommentPage.value).toEqual({ offset: 20, total: 41 })
    expect(showToast).toHaveBeenCalledWith('이전 댓글을 불러오는 데 실패했습니다', 'error')
  })
})
