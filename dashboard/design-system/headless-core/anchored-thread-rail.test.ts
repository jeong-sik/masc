import { describe, expect, it } from 'vitest'
import {
  createAnchoredThreadRail,
  type AnchoredThread,
} from './anchored-thread-rail'

const file = 'runtime/cascade/router.ts'

const thread = (patch: Partial<AnchoredThread>): AnchoredThread => ({
  id: 'thread-1',
  kind: 'flag',
  author_keeper_id: 'nick0cave',
  anchor: {
    file_path: file,
    line_start: 34,
    line_end: 35,
    symbol_hint: 'if:moonshot-tool-choice',
  },
  body: 'Schema failure matches the live cascade logs.',
  created_ms: 1000,
  resolved: false,
  reply_count: 0,
  ...patch,
})

describe('createAnchoredThreadRail', () => {
  it('scopes visibleThreads to the active file and keeps resolved threads visible', () => {
    const threads = [
      thread({ id: 'older', created_ms: 1000 }),
      thread({ id: 'newer', created_ms: 2000, resolved: true, reply_count: 3 }),
      thread({ id: 'other-file', anchor: { file_path: 'other.ts', line_start: 1, line_end: 1 } }),
    ]
    const rail = createAnchoredThreadRail({ filePath: () => file, threads: () => threads })

    expect(rail.visibleThreads().map(item => item.id)).toEqual(['newer', 'older'])
    expect(rail.visibleThreads()[0]).toMatchObject({ resolved: true, reply_count: 3 })
  })

  it('returns threads whose anchor range contains the requested line', () => {
    const threads = [
      thread({ id: 'wide', anchor: { file_path: file, line_start: 10, line_end: 14 } }),
      thread({ id: 'single', anchor: { file_path: file, line_start: 12, line_end: 12 } }),
      thread({ id: 'file-level', anchor: { file_path: file, line_start: null, line_end: null } }),
    ]
    const rail = createAnchoredThreadRail({ filePath: () => file, threads: () => threads })

    expect(rail.threadsForLine(12).map(item => item.id)).toEqual(['single', 'wide'])
    expect(rail.threadsForLine(15)).toEqual([])
    expect(rail.threadsForLine(Number.NaN)).toEqual([])
  })

  it('focuses visible threads and notifies subscribers on focus changes', () => {
    const rail = createAnchoredThreadRail({
      filePath: () => file,
      threads: () => [
        thread({ id: 'visible' }),
        thread({ id: 'hidden', anchor: { file_path: 'other.ts', line_start: 1, line_end: 1 } }),
      ],
    })
    const focused: Array<string | null> = []
    const unsubscribe = rail.subscribe(() => focused.push(rail.focusedThreadId()))

    expect(rail.focusThread('hidden')).toBe(false)
    expect(rail.focusThread('visible')).toBe(true)
    expect(rail.focusedThreadId()).toBe('visible')
    rail.clearFocus()
    unsubscribe()
    rail.focusThread('visible')

    expect(focused).toEqual(['visible', null])
  })

  it('drops malformed public input before it reaches visible state', () => {
    const rail = createAnchoredThreadRail({
      filePath: () => file,
      threads: () => [
        thread({ id: '' }),
        thread({ id: 'bad-replies', reply_count: -1 }),
        thread({ id: 'bad-time', created_ms: Number.NaN }),
        thread({ id: 'bad-anchor', anchor: { file_path: file, line_start: 4, line_end: 2 } }),
        thread({ id: 'ok-file', anchor: { file_path: file, line_start: null, line_end: null } }),
      ],
    })

    expect(rail.visibleThreads().map(item => item.id)).toEqual(['ok-file'])
  })
})
