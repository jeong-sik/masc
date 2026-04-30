import { describe, expect, it } from 'vitest'

import {
  createLayeredOverlay,
  parseActive,
  serializeActive,
  type OverlayLayer,
} from './layered-overlay'

const LAYERS: ReadonlyArray<OverlayLayer> = [
  { kind: 'time', label: 'Time', description: 'recency gradient' },
  { kind: 'parallel', label: 'Parallel', description: 'multi-keeper edits' },
  { kind: 'tools', label: 'Tools', description: 'mcp tool calls' },
  { kind: 'approve', label: 'Approve', description: 'approve threads' },
  { kind: 'notes', label: 'Notes', description: 'note threads' },
  { kind: 'explode', label: 'EXPLODE', description: 'per-keeper ghost copies', mutuallyExclusive: true },
]

describe('createLayeredOverlay', () => {
  it('starts with no active layers', () => {
    const c = createLayeredOverlay(LAYERS)
    expect([...c.active()]).toEqual([])
    expect(c.isActive('time')).toBe(false)
  })

  it('toggles layers in and out', () => {
    const c = createLayeredOverlay(LAYERS)
    c.toggle('time')
    expect(c.isActive('time')).toBe(true)
    c.toggle('approve')
    expect([...c.active()].sort()).toEqual(['approve', 'time'])
    c.toggle('time')
    expect([...c.active()]).toEqual(['approve'])
  })

  it('ignores unknown layer kinds', () => {
    const c = createLayeredOverlay(LAYERS)
    c.toggle('bogus')
    expect([...c.active()]).toEqual([])
  })

  it('rejects duplicate layer registrations at construction', () => {
    expect(() =>
      createLayeredOverlay([
        { kind: 'time', label: 'a', description: '' },
        { kind: 'time', label: 'b', description: '' },
      ]),
    ).toThrow(/duplicate layer kind/)
  })

  it('clears all layers', () => {
    const c = createLayeredOverlay(LAYERS)
    c.toggle('time')
    c.toggle('approve')
    c.clear()
    expect([...c.active()]).toEqual([])
  })

  it('activating an exclusive layer clears the rest', () => {
    const c = createLayeredOverlay(LAYERS)
    c.toggle('time')
    c.toggle('approve')
    c.toggle('explode')
    expect([...c.active()]).toEqual(['explode'])
  })

  it('activating any non-exclusive layer drops the exclusive one', () => {
    const c = createLayeredOverlay(LAYERS)
    c.toggle('explode')
    expect([...c.active()]).toEqual(['explode'])
    c.toggle('time')
    expect([...c.active()]).toEqual(['time'])
  })

  it('toggling exclusive layer twice clears it (returns to empty)', () => {
    const c = createLayeredOverlay(LAYERS)
    c.toggle('explode')
    c.toggle('explode')
    expect([...c.active()]).toEqual([])
  })

  it('subscribers receive the new active set on each change', () => {
    const c = createLayeredOverlay(LAYERS)
    const seen: Array<ReadonlyArray<string>> = []
    c.subscribe(active => seen.push([...active].sort()))

    c.toggle('time')
    c.toggle('approve')
    c.clear()

    expect(seen).toEqual([['time'], ['approve', 'time'], []])
  })

  it('subscribe returns an unsubscribe function', () => {
    const c = createLayeredOverlay(LAYERS)
    let count = 0
    const unsub = c.subscribe(() => {
      count += 1
    })
    c.toggle('time')
    unsub()
    c.toggle('approve')
    expect(count).toBe(1)
  })

  it('clear is a no-op when nothing is active', () => {
    const c = createLayeredOverlay(LAYERS)
    let count = 0
    c.subscribe(() => {
      count += 1
    })
    c.clear()
    expect(count).toBe(0)
  })

  it('active() snapshots are isolated from internal state', () => {
    const c = createLayeredOverlay(LAYERS)
    c.toggle('time')
    const snapshot = c.active() as Set<string>
    snapshot.add('parallel')
    expect(c.isActive('parallel')).toBe(false)
  })
})

describe('serializeActive / parseActive', () => {
  const KNOWN = new Set(LAYERS.map(l => l.kind))

  it('serializes alphabetically', () => {
    expect(serializeActive(new Set(['time', 'approve']))).toBe('approve,time')
    expect(serializeActive(new Set())).toBe('')
  })

  it('round-trips active sets through parse/serialize', () => {
    const active = new Set(['time', 'approve', 'notes'])
    const serialized = serializeActive(active)
    const parsed = parseActive(serialized, KNOWN)
    expect([...parsed].sort()).toEqual(['approve', 'notes', 'time'])
  })

  it('drops unknown kinds during parse', () => {
    const parsed = parseActive('time,bogus,approve', KNOWN)
    expect([...parsed].sort()).toEqual(['approve', 'time'])
  })

  it('handles empty / whitespace input', () => {
    expect([...parseActive('', KNOWN)]).toEqual([])
    expect([...parseActive('   ', KNOWN)]).toEqual([])
    expect([...parseActive(',,', KNOWN)]).toEqual([])
  })
})
