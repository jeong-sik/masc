import { describe, it, expect } from 'vitest'
import { reconcileBoardPosts } from './store'
import type { BoardPost } from './types'

function makePost(overrides: Partial<BoardPost> = {}): BoardPost {
  return {
    id: 'p-1',
    author: 'keeper-a',
    title: 'title',
    body: 'body',
    content: 'content',
    tags: [],
    votes: 0,
    comment_count: 0,
    created_at: '2026-04-11T00:00:00Z',
    updated_at: '2026-04-11T00:00:00Z',
    ...overrides,
  }
}

describe('reconcileBoardPosts', () => {
  it('returns next array as-is when prev is empty', () => {
    const next = [makePost()]
    expect(reconcileBoardPosts([], next)).toBe(next)
  })

  it('returns prev when nothing changed', () => {
    const post = makePost()
    const prev = [post]
    const next = [{ ...post }]
    const result = reconcileBoardPosts(prev, next)
    expect(result).toBe(prev)
    expect(result[0]).toBe(post)
  })

  it('preserves reference for unchanged posts in a mixed update', () => {
    const unchanged = makePost({ id: 'p-1' })
    const changed = makePost({ id: 'p-2', votes: 0 })
    const prev = [unchanged, changed]

    const updatedChanged = { ...changed, votes: 5 }
    const next = [{ ...unchanged }, updatedChanged]

    const result = reconcileBoardPosts(prev, next)
    expect(result[0]).toBe(unchanged)
    expect(result[1]).toBe(updatedChanged)
    expect(result[1]!.votes).toBe(5)
  })

  it('detects change when updated_at differs', () => {
    const post = makePost()
    const prev = [post]
    const updated = { ...post, updated_at: '2026-04-11T01:00:00Z' }
    const result = reconcileBoardPosts(prev, [updated])
    expect(result[0]).toBe(updated)
    expect(result[0]).not.toBe(post)
  })

  it('detects change when comment_count differs', () => {
    const post = makePost()
    const prev = [post]
    const updated = { ...post, comment_count: 3 }
    const result = reconcileBoardPosts(prev, [updated])
    expect(result[0]).toBe(updated)
  })

  it('detects change when array length differs (new post added)', () => {
    const existing = makePost({ id: 'p-1' })
    const prev = [existing]
    const added = makePost({ id: 'p-2' })
    const result = reconcileBoardPosts(prev, [{ ...existing }, added])
    expect(result).toHaveLength(2)
    expect(result[0]).toBe(existing)
    expect(result[1]).toBe(added)
  })

  it('detects change when a post is removed', () => {
    const a = makePost({ id: 'p-1' })
    const b = makePost({ id: 'p-2' })
    const prev = [a, b]
    const result = reconcileBoardPosts(prev, [{ ...a }])
    expect(result).toHaveLength(1)
    expect(result[0]).toBe(a)
  })
})
