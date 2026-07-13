import { describe, it, expect } from 'vitest'
import { reconcileBoardPosts, reconcileKeepers } from './store'
import type { BoardPost, Keeper } from './types'

function makePost(overrides: Partial<BoardPost> = {}): BoardPost {
  return {
    id: 'p-1',
    author: 'keeper-a',
    post_kind: 'direct',
    classification_reason: null,
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

  it('detects change when post_kind differs without updated_at changing', () => {
    const post = makePost()
    const prev = [post]
    const updated = { ...post, post_kind: 'automation' as const }
    const result = reconcileBoardPosts(prev, [updated])
    expect(result[0]).toBe(updated)
  })

  it('detects change when classification_reason differs without updated_at changing', () => {
    const post = makePost()
    const prev = [post]
    const updated = { ...post, classification_reason: 'reclassified' }
    const result = reconcileBoardPosts(prev, [updated])
    expect(result[0]).toBe(updated)
  })

  it('detects change when pinned differs without updated_at changing', () => {
    const post = makePost({ pinned: false })
    const prev = [post]
    const updated = { ...post, pinned: true }
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

  it('reorders posts when the server order changes while keeping stable references', () => {
    const a = makePost({ id: 'p-1' })
    const b = makePost({ id: 'p-2' })
    const prev = [a, b]
    const result = reconcileBoardPosts(prev, [{ ...b }, { ...a }])
    expect(result).not.toBe(prev)
    expect(result[0]).toBe(b)
    expect(result[1]).toBe(a)
  })
})

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'rondo',
    status: 'idle',
    runtime_class: 'keeper',
    pipeline_stage: 'idle',
    phase: 'Running',
    updated_at: '2026-06-16T04:00:00Z',
    last_activity_ago_s: 125,
    last_turn_ago_s: 125,
    recent_tool_names: ['keeper_task_claim'],
    latest_tool_names: ['keeper_task_claim'],
    latest_tool_call_count: 1,
    active_goal_ids: ['goal-1'],
    ...overrides,
  }
}

describe('reconcileKeepers', () => {
  it('returns next array as-is when prev is empty', () => {
    const next = [makeKeeper()]
    expect(reconcileKeepers([], next)).toBe(next)
  })

  it('keeps array and row references for relative-age drift within the same display bucket', () => {
    const keeper = makeKeeper({ last_activity_ago_s: 125.2, last_turn_ago_s: 128.7 })
    const prev = [keeper]
    const next = [
      makeKeeper({
        last_activity_ago_s: 179.9,
        last_turn_ago_s: 170.5,
      }),
    ]

    const result = reconcileKeepers(prev, next)

    expect(result).toBe(prev)
    expect(result[0]).toBe(keeper)
  })

  it('updates when a relative age crosses its display bucket', () => {
    const keeper = makeKeeper({ last_activity_ago_s: 125 })
    const updated = makeKeeper({ last_activity_ago_s: 185 })

    const result = reconcileKeepers([keeper], [updated])

    expect(result[0]).toBe(updated)
  })

  it('keeps row references for nested diagnostic countdown drift within the same display bucket', () => {
    const keeper = makeKeeper({
      diagnostic: {
        summary: 'Keeper is waiting for a scheduled wake.',
        health_state: 'healthy',
        quiet_reason: 'min_gap',
        next_action_path: 'direct_message',
        last_reply_status: 'never',
        next_eligible_at_s: 281.1,
      },
    })
    const next = makeKeeper({
      diagnostic: {
        summary: 'Keeper is waiting for a scheduled wake.',
        health_state: 'healthy',
        quiet_reason: 'min_gap',
        next_action_path: 'direct_message',
        last_reply_status: 'never',
        next_eligible_at_s: 275.5,
      },
    })

    const result = reconcileKeepers([keeper], [next])

    expect(result[0]).toBe(keeper)
  })

  it('updates immediately for meaningful keeper state changes', () => {
    const keeper = makeKeeper({ status: 'idle', pipeline_stage: 'idle' })
    const updated = makeKeeper({ status: 'offline', pipeline_stage: 'failing' })

    const result = reconcileKeepers([keeper], [updated])

    expect(result[0]).toBe(updated)
  })

  it('preserves unchanged rows in a mixed update', () => {
    const unchanged = makeKeeper({ name: 'rondo' })
    const changed = makeKeeper({ name: 'sangsu', status: 'idle' })
    const updatedChanged = makeKeeper({ name: 'sangsu', status: 'offline' })
    const prev = [unchanged, changed]

    const result = reconcileKeepers(
      prev,
      [{ ...unchanged, last_activity_ago_s: 130 }, updatedChanged],
    )

    expect(result).not.toBe(prev)
    expect(result[0]).toBe(unchanged)
    expect(result[1]).toBe(updatedChanged)
  })
})
