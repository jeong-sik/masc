import { describe, expect, it } from 'vitest'
import {
  createRunActivityStore,
  type RunActivityEvent,
} from './run-activity-store'

const runId = 'run-47'

const event = (patch: Partial<RunActivityEvent>): RunActivityEvent => ({
  id: 'event-1',
  run_id: runId,
  keeper_id: 'nick0cave',
  verb: 'edited',
  target: 'router.ts:34',
  timestamp_ms: 1000,
  detail: '+1 -0',
  ...patch,
})

describe('createRunActivityStore', () => {
  it('scopes events to the active run and orders newest first', () => {
    const s = createRunActivityStore(runId)
    s.seed([
      event({ id: 'older', timestamp_ms: 1000 }),
      event({ id: 'newer', timestamp_ms: 2000, keeper_id: 'sangsu' }),
      event({ id: 'other-run', run_id: 'run-99', timestamp_ms: 3000 }),
    ])

    expect(s.events().map(item => item.id)).toEqual(['newer', 'older'])
    expect(s.knownKeepers()).toEqual(['nick0cave', 'sangsu'])
  })

  it('rejects malformed appended public input', () => {
    const s = createRunActivityStore(runId)
    expect(s.append(event({ id: '' }))).toBe(false)
    expect(s.append(event({ keeper_id: '' }))).toBe(false)
    expect(s.append({ ...event({}), keeper_id: null })).toBe(false)
    expect(s.append({ ...event({}), verb: 'deleted' })).toBe(false)
    expect(s.append(event({ timestamp_ms: Number.NaN }))).toBe(false)
    expect(s.append({ ...event({}), kind: { bad: true } })).toBe(false)
    expect(s.append({ ...event({}), tags: ['ok', 1] })).toBe(false)
    expect(s.append({ ...event({}), context: { line: 0 } })).toBe(false)
    expect(s.append({ ...event({}), context: { pr_id: '' } })).toBe(false)
    expect(s.append(event({ id: 'ok' }))).toBe(true)
    expect(s.events().map(item => item.id)).toEqual(['ok'])
  })

  it('preserves structured context links on valid activity events', () => {
    const s = createRunActivityStore(runId)
    s.seed([
      event({
        id: 'with-context',
        context: {
          file_path: 'lib/runtime.ml',
          line: 42,

          task_id: 'task-runtime',
          board_post_id: 'post-1',
          comment_id: 'comment-1',
          pr_id: '15000',
          git_ref: 'main',
          log_id: 'turn-7',
        },
      }),
    ])

    expect(s.events()[0]?.context).toMatchObject({
      file_path: 'lib/runtime.ml',
      line: 42,

      task_id: 'task-runtime',
      comment_id: 'comment-1',
      pr_id: '15000',
    })
  })

  it('filters malformed seeded public input', () => {
    const s = createRunActivityStore(runId)
    s.seed([
      null,
      event({ id: 'ok' }),
      { ...event({ id: 'missing-keeper' }), keeper_id: null },
      { ...event({ id: 'bad-verb' }), verb: 'deleted' },
      { ...event({ id: 'bad-detail' }), detail: { lines: 3 } },
      { ...event({ id: 'bad-tags' }), tags: ['ok', null] },
    ])

    expect(s.events().map(item => item.id)).toEqual(['ok'])
  })

  it('notifies subscribers for seed, append, and reset', () => {
    const s = createRunActivityStore(runId)
    let calls = 0
    const unsubscribe = s.subscribe(() => {
      calls += 1
    })

    s.seed([event({ id: 'a' })])
    s.append(event({ id: 'b', keeper_id: 'sangsu' }))
    s.reset('run-48')
    unsubscribe()
    s.append(event({ id: 'c', run_id: 'run-48' }))

    expect(calls).toBe(3)
    expect(s.runId()).toBe('run-48')
    expect(s.eventsForKeeper('sangsu')).toEqual([])
  })

  it('caps visible history without losing deterministic order', () => {
    const s = createRunActivityStore(runId, { maxEvents: 2 })
    s.seed([
      event({ id: 'a', timestamp_ms: 1 }),
      event({ id: 'b', timestamp_ms: 2 }),
      event({ id: 'c', timestamp_ms: 3 }),
    ])

    expect(s.events().map(item => item.id)).toEqual(['c', 'b'])
  })

  it('bounds appended active-run history in sorted order', () => {
    const s = createRunActivityStore(runId, { maxEvents: 2 })
    expect(s.append(event({ id: 'a', timestamp_ms: 1 }))).toBe(true)
    expect(s.append(event({ id: 'c', timestamp_ms: 3 }))).toBe(true)
    expect(s.append(event({ id: 'b', timestamp_ms: 2 }))).toBe(true)

    expect(s.events().map(item => item.id)).toEqual(['c', 'b'])
  })

  it('falls back to the default cap for invalid maxEvents values', () => {
    const s = createRunActivityStore(runId, { maxEvents: -1 })
    s.seed([
      event({ id: 'a', timestamp_ms: 1 }),
      event({ id: 'b', timestamp_ms: 2 }),
      event({ id: 'c', timestamp_ms: 3 }),
    ])

    expect(s.events().map(item => item.id)).toEqual(['c', 'b', 'a'])
  })
})
