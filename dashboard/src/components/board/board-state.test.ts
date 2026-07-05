import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    fetchBoardHearths: vi.fn(),
    fetchBoardFlairs: vi.fn(),
  }
})

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
  type ContentCategory,
  type VisibleBoardGroups,
} from './board-state'
import type { BoardPost } from '../../types'
import { fetchBoardFlairs, fetchBoardHearths, type BoardFlair, type BoardHearth } from '../../api'
import { showToast } from '../common/toast'

// Reset module-scope signals between tests
import { boardHiddenCategories, boardExcludeAutomation } from '../../store'

function makePost(overrides: Partial<BoardPost> = {}): BoardPost {
  return {
    id: 'p1',
    author: 'test-agent',
    title: 'Test post',
    body: 'Test body content',
    content: '',
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
  it('summarizes visible, scoped, hidden-score, and updated state', () => {
    expect(postVisibilityAuditLabel(makePost({
      visibility: 'internal',
      comment_count: 13,
      votes: null,
      vote_blind: true,
      updated_at: '2026-04-17T01:00:00Z',
    }))).toBe('표시 중 · 내부 · 댓글 13개 · 점수 투표 후 공개 · 최근 갱신됨')
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
