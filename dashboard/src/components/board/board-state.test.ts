import { beforeEach, describe, expect, it } from 'vitest'

import {
  isUpdated,
  boardPostKind,
  contentCategory,
  categoryLabel,
  authorAvatar,
  kindLabel,
  visibilityLabel,
  filterHint,
  splitVisiblePosts,
  type ContentCategory,
  type VisibleBoardGroups,
} from './board-state'
import type { BoardPost } from '../../types'

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

  it('classifies review by title keywords', () => {
    expect(contentCategory(makePost({ title: 'verdict: 코드 품질 양호' }))).toBe('review')
    expect(contentCategory(makePost({ title: 'PR 리뷰 완료' }))).toBe('review')
    expect(contentCategory(makePost({ title: 'Code Review 결과' }))).toBe('review')
  })

  it('classifies notice by title keywords', () => {
    expect(contentCategory(makePost({ title: 'alert: 서버 과부하' }))).toBe('notice')
    expect(contentCategory(makePost({ title: '상태 업데이트' }))).toBe('notice')
    expect(contentCategory(makePost({ title: 'Warning: CPU 90%' }))).toBe('notice')
  })

  it('classifies article by title keywords', () => {
    expect(contentCategory(makePost({ title: '기술 탐색: WebAssembly' }))).toBe('article')
    expect(contentCategory(makePost({ title: '연구 결과' }))).toBe('article')
    expect(contentCategory(makePost({ title: 'POC 실험' }))).toBe('article')
  })

  it('falls back to article for long body content', () => {
    const longBody = 'x'.repeat(301)
    expect(contentCategory(makePost({ title: '일반 제목', body: longBody }))).toBe('article')
  })

  it('falls back to article for default case', () => {
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
