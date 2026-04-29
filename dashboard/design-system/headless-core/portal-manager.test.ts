// Pure TS unit tests for PortalManager. No DOM, no Preact runtime.
import { describe, it, expect } from 'vitest'
import {
  createPortalManager,
  PORTAL_Z_INDEX,
  type PortalLayer,
} from './portal-manager'

describe('createPortalManager', () => {
  it('starts empty: topmost() is null and layers() is []', () => {
    const m = createPortalManager()
    expect(m.topmost()).toBeNull()
    expect(m.layers()).toEqual([])
  })

  it('push() returns the layer with z-index resolved from PORTAL_Z_INDEX', () => {
    const m = createPortalManager()
    const active = m.push({ id: 'a', layer: 'modal' })
    expect(active.id).toBe('a')
    expect(active.layer).toBe('modal')
    expect(active.zIndex).toBe(PORTAL_Z_INDEX.modal)
  })

  it('explicit zIndex override is respected and survives in topmost()', () => {
    const m = createPortalManager()
    m.push({ id: 'tooltip', layer: 'toast', zIndex: 9999 })
    expect(m.topmost()?.zIndex).toBe(9999)
  })

  it('topmost() picks the highest z-index across kinds', () => {
    const m = createPortalManager()
    m.push({ id: 'd', layer: 'drawer' }) // 60
    m.push({ id: 'm', layer: 'modal' }) // 80
    m.push({ id: 's', layer: 'sticky' }) // 20
    expect(m.topmost()?.id).toBe('m')
  })

  it('ties at the same z-index break to the most recently pushed', () => {
    const m = createPortalManager()
    m.push({ id: 'm1', layer: 'modal' })
    m.push({ id: 'm2', layer: 'modal' })
    m.push({ id: 'm3', layer: 'modal' })
    expect(m.topmost()?.id).toBe('m3')
  })

  it('pop() removes the layer by id; topmost recomputes', () => {
    const m = createPortalManager()
    m.push({ id: 'd', layer: 'drawer' })
    m.push({ id: 'm', layer: 'modal' })
    expect(m.topmost()?.id).toBe('m')
    m.pop('m')
    expect(m.topmost()?.id).toBe('d')
    m.pop('d')
    expect(m.topmost()).toBeNull()
  })

  it('pop() is a no-op when the id is not present', () => {
    const m = createPortalManager()
    m.push({ id: 'a', layer: 'modal' })
    expect(() => m.pop('does-not-exist')).not.toThrow()
    expect(m.layers()).toHaveLength(1)
  })

  it('layers() returns an immutable snapshot in push order', () => {
    const m = createPortalManager()
    m.push({ id: 'a', layer: 'sticky' })
    m.push({ id: 'b', layer: 'modal' })
    m.push({ id: 'c', layer: 'toast' })
    const snap = m.layers()
    expect(snap.map((l) => l.id)).toEqual(['a', 'b', 'c'])
    // Mutating the snapshot must not affect manager state — frozen.
    expect(() => {
      ;(snap as unknown as PortalLayer[]).push({ id: 'x', layer: 'overlay' })
    }).toThrow()
    expect(m.layers()).toHaveLength(3)
  })

  it('PORTAL_Z_INDEX matches existing raw token values (drift guard)', () => {
    // Mirrors dashboard/design-system/tokens/source.ts raw tier
    // (--z-base/sticky/dropdown/overlay/drawer/modal/toast).
    // Update both together if the canon shifts.
    expect(PORTAL_Z_INDEX).toEqual({
      base: 1,
      sticky: 20,
      dropdown: 30,
      overlay: 40,
      drawer: 60,
      modal: 80,
      toast: 100,
    })
  })

  it('drawer over modal scenario: explicit override wins over default', () => {
    // If a drawer needs to render above a modal (rare but valid), the
    // override is the escape hatch.
    const m = createPortalManager()
    m.push({ id: 'modal-1', layer: 'modal' }) // 80
    m.push({ id: 'drawer-1', layer: 'drawer', zIndex: 90 }) // overridden
    expect(m.topmost()?.id).toBe('drawer-1')
  })
})
