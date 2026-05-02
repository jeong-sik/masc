import { describe, expect, it } from 'vitest'
import {
  createAnchoredThreadRailStore,
  type AnchoredThread,
} from './anchored-thread-rail-store'

const file = 'runtime/cascade/router.ts'

const thread = (patch: Partial<AnchoredThread>): AnchoredThread => ({
  id: 'thread-1',
  kind: 'flag',
  author_keeper_id: 'nick0cave',
  anchor: { file_path: file, line_start: 10, line_end: 12, symbol_hint: 'fn:resolveCascade' },
  body: 'Check this branch before merge.',
  created_ms: 1000,
  resolved: false,
  reply_count: 1,
  ...patch,
})

describe('createAnchoredThreadRailStore', () => {
  it('publishes visible thread snapshots after seed and addThread', () => {
    const s = createAnchoredThreadRailStore(file)
    s.seed([
      thread({ id: 'older', created_ms: 1000 }),
      thread({ id: 'hidden', anchor: { file_path: 'other.ts', line_start: 1, line_end: 1 } }),
    ])
    const before = s.visibleThreads()

    s.addThread(thread({ id: 'newer', created_ms: 2000, author_keeper_id: 'sangsu' }))

    expect(before.map(item => item.id)).toEqual(['older'])
    expect(s.visibleThreads().map(item => item.id)).toEqual(['newer', 'older'])
    expect(s.knownAuthors()).toEqual(['nick0cave', 'sangsu'])
  })

  it('subscribers fire for seed, resolve, and focus changes', () => {
    const s = createAnchoredThreadRailStore(file)
    let calls = 0
    const unsubscribe = s.subscribe(() => {
      calls += 1
    })

    s.seed([thread({ id: 'a' })])
    s.resolveThread('a')
    s.focusThread('a')
    s.clearFocus()
    unsubscribe()
    s.addThread(thread({ id: 'b', created_ms: 2000 }))

    expect(calls).toBe(4)
    expect(s.visibleThreads()[0]).toMatchObject({ id: 'b' })
  })

  it('exposes line lookup and drops focus when reset switches files', () => {
    const s = createAnchoredThreadRailStore(file)
    s.seed([
      thread({ id: 'a', anchor: { file_path: file, line_start: 10, line_end: 12 } }),
      thread({ id: 'b', anchor: { file_path: file, line_start: null, line_end: null } }),
    ])

    expect(s.threadsForLine(11).map(item => item.id)).toEqual(['a'])
    expect(s.focusThread('a')).toBe(true)
    s.reset('runtime/fsm/lifeline.ts')
    expect(s.filePath()).toBe('runtime/fsm/lifeline.ts')
    expect(s.focusedThreadId()).toBe(null)
    expect(s.visibleThreads()).toEqual([])
  })
})
