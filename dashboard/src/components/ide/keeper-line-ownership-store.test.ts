import { describe, expect, it } from 'vitest'
import {
  createKeeperLineOwnershipStore,
  type KeeperEdit,
} from './keeper-line-ownership-store'

const file = 'runtime/cascade/router.ts'

const event = (patch: Partial<KeeperEdit>): KeeperEdit => ({
  file_path: file,
  line_start: 1,
  line_end: 1,
  keeper_id: 'nick0cave',
  timestamp_ms: 1000,
  kind: 'edit',
  ...patch,
})

describe('createKeeperLineOwnershipStore', () => {
  it('publishes immutable ownership snapshots after ingest', () => {
    const s = createKeeperLineOwnershipStore(file)
    const before = s.ownership()
    expect(s.ingest(event({ line_start: 2, line_end: 3 }))).toBe(true)
    const after = s.ownership()
    expect(before).not.toBe(after)
    expect([...after.keys()]).toEqual([2, 3])
  })

  it('subscribers fire only for accepted events and reset', () => {
    const s = createKeeperLineOwnershipStore(file)
    let calls = 0
    const unsubscribe = s.subscribe(() => {
      calls += 1
    })

    s.ingest(event({ file_path: 'other.ts' }))
    s.ingest(event({ line_start: 1, line_end: 1 }))
    s.reset()
    unsubscribe()
    s.ingest(event({ line_start: 2, line_end: 2 }))

    expect(calls).toBe(2)
  })

  it('exposes line history and sorted known keepers', () => {
    const s = createKeeperLineOwnershipStore(file)
    s.ingest(event({ line_start: 5, line_end: 5, keeper_id: 'sangsu' }))
    s.ingest(event({ line_start: 5, line_end: 5, keeper_id: 'nick0cave', timestamp_ms: 2000 }))

    expect(s.eventsForLine(5).map((item) => item.keeper_id)).toEqual([
      'sangsu',
      'nick0cave',
    ])
    expect(s.knownKeepers()).toEqual(['nick0cave', 'sangsu'])
  })

  it('reset can switch active file', () => {
    const s = createKeeperLineOwnershipStore(file)
    s.reset('runtime/fsm/lifeline.ts')
    expect(s.filePath()).toBe('runtime/fsm/lifeline.ts')
    expect(s.ingest(event({ line_start: 1, line_end: 1 }))).toBe(false)
    expect(s.ingest(event({ file_path: 'runtime/fsm/lifeline.ts' }))).toBe(true)
  })
})
