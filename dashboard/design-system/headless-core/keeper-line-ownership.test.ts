import { describe, expect, it } from 'vitest'
import {
  createKeeperLineOwnershipAccumulator,
  keeperHueIndex,
  type KeeperEdit,
} from './keeper-line-ownership'

const file = 'runtime/cascade/router.ts'

const edit = (patch: Partial<KeeperEdit>): KeeperEdit => ({
  file_path: file,
  line_start: 1,
  line_end: 1,
  keeper_id: 'nick0cave',
  timestamp_ms: 1000,
  kind: 'edit',
  ...patch,
})

describe('createKeeperLineOwnershipAccumulator', () => {
  it('starts empty for the active file', () => {
    const s = createKeeperLineOwnershipAccumulator(file)
    expect(s.filePath()).toBe(file)
    expect([...s.ownership().entries()]).toEqual([])
    expect(s.knownKeepers()).toEqual([])
  })

  it('expands multi-line edits into per-line ownership', () => {
    const s = createKeeperLineOwnershipAccumulator(file)
    expect(s.ingest(edit({ line_start: 2, line_end: 4 }))).toBe(true)
    expect([...s.ownership().keys()]).toEqual([2, 3, 4])
    expect(s.ownership().get(3)).toMatchObject({
      keeper_id: 'nick0cave',
      last_edit_kind: 'edit',
      last_edit_ms: 1000,
    })
  })

  it('uses latest timestamp per line and preserves line history', () => {
    const s = createKeeperLineOwnershipAccumulator(file)
    s.ingest(edit({ line_start: 3, line_end: 3, keeper_id: 'nick0cave', timestamp_ms: 2000 }))
    s.ingest(edit({ line_start: 3, line_end: 3, keeper_id: 'sangsu', timestamp_ms: 1500, kind: 'refactor' }))
    s.ingest(edit({ line_start: 3, line_end: 3, keeper_id: 'masc-improver', timestamp_ms: 2500, kind: 'revert' }))

    expect(s.ownership().get(3)).toMatchObject({
      keeper_id: 'masc-improver',
      last_edit_kind: 'revert',
      last_edit_ms: 2500,
    })
    expect(s.eventsForLine(3).map((event) => event.keeper_id)).toEqual([
      'nick0cave',
      'sangsu',
      'masc-improver',
    ])
  })

  it('ignores events for other files and invalid ranges', () => {
    const s = createKeeperLineOwnershipAccumulator(file)
    expect(s.ingest(edit({ file_path: 'other.ts' }))).toBe(false)
    expect(s.ingest(edit({ line_start: 4, line_end: 2 }))).toBe(false)
    expect(s.ingest(edit({ line_start: 0, line_end: 1 }))).toBe(false)
    expect(s.ingest(edit({ line_start: Number.NaN, line_end: 1 }))).toBe(false)
    expect(s.ingest(edit({ line_start: 1, line_end: Number.POSITIVE_INFINITY }))).toBe(false)
    expect(s.ingest(edit({ line_start: Number.MAX_SAFE_INTEGER + 1, line_end: Number.MAX_SAFE_INTEGER + 1 }))).toBe(false)
    expect(s.ownership().size).toBe(0)
  })

  it('rejects non-finite timestamps without poisoning ownership comparisons', () => {
    const s = createKeeperLineOwnershipAccumulator(file)
    expect(s.ingest(edit({ line_start: 2, line_end: 2, timestamp_ms: 1000 }))).toBe(true)
    expect(s.ingest(edit({ line_start: 2, line_end: 2, keeper_id: 'sangsu', timestamp_ms: Number.NaN }))).toBe(false)
    expect(s.ingest(edit({ line_start: 2, line_end: 2, keeper_id: 'rama', timestamp_ms: Number.POSITIVE_INFINITY }))).toBe(false)

    expect(s.ownership().get(2)).toMatchObject({
      keeper_id: 'nick0cave',
      last_edit_ms: 1000,
    })
    expect(s.eventsForLine(2).map((event) => event.keeper_id)).toEqual(['nick0cave'])
    expect(s.knownKeepers()).toEqual(['nick0cave'])
  })

  it('knownKeepers is sorted and de-duplicated', () => {
    const s = createKeeperLineOwnershipAccumulator(file)
    s.ingest(edit({ keeper_id: 'sangsu', line_start: 1, line_end: 1 }))
    s.ingest(edit({ keeper_id: 'nick0cave', line_start: 2, line_end: 2 }))
    s.ingest(edit({ keeper_id: 'sangsu', line_start: 3, line_end: 3 }))
    expect(s.knownKeepers()).toEqual(['nick0cave', 'sangsu'])
  })

  it('reset keeps subscribers possible by clearing in place and optionally switches file', () => {
    const s = createKeeperLineOwnershipAccumulator(file)
    s.ingest(edit({ line_start: 1, line_end: 2 }))
    s.reset('runtime/fsm/lifeline.ts')
    expect(s.filePath()).toBe('runtime/fsm/lifeline.ts')
    expect(s.ownership().size).toBe(0)
    expect(s.knownKeepers()).toEqual([])
    expect(s.ingest(edit({ line_start: 1, line_end: 1 }))).toBe(false)
  })
})

describe('keeperHueIndex', () => {
  it('is deterministic and maps to the existing 1..12 keeper token slots', () => {
    expect(keeperHueIndex('nick0cave')).toBe(keeperHueIndex('nick0cave'))
    for (const keeper of ['nick0cave', 'sangsu', 'masc-improver', 'rama']) {
      expect(keeperHueIndex(keeper)).toBeGreaterThanOrEqual(1)
      expect(keeperHueIndex(keeper)).toBeLessThanOrEqual(12)
    }
  })
})
