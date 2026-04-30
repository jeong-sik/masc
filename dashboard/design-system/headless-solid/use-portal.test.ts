// @vitest-environment happy-dom
//
// Tests for headless-solid/use-portal. Mirrors Preact adapter coverage:
// register/deregister lifecycle, z-index resolution, isolation between
// consumers via the swappable default manager.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRoot } from 'solid-js'
import { createPortalManager, PORTAL_Z_INDEX } from '../headless-core/portal-manager'
import { getPortalManager, setPortalManager, usePortal } from './use-portal'

let dispose: (() => void) | undefined

beforeEach(() => {
  setPortalManager(createPortalManager())
  dispose = undefined
})

afterEach(() => {
  dispose?.()
})

function withRoot<T>(fn: () => T): T {
  return createRoot((d) => {
    dispose = d
    return fn()
  })
}

describe('usePortal — z-index resolution', () => {
  it('returns layer default z-index when no override is given', () => {
    const result = withRoot(() => usePortal({ layer: 'toast' }))
    expect(result.zIndex).toBe(PORTAL_Z_INDEX.toast)
  })

  it('honors explicit zIndex override', () => {
    const result = withRoot(() => usePortal({ layer: 'toast', zIndex: 9999 }))
    expect(result.zIndex).toBe(9999)
  })
})

describe('usePortal — registration lifecycle', () => {
  it('registers on mount and includes layer in topmost()', () => {
    withRoot(() => usePortal({ layer: 'tooltip' }))
    const top = getPortalManager().topmost()
    expect(top).not.toBeNull()
    expect(top?.layer).toBe('tooltip')
  })

  it('deregisters when root disposes', () => {
    const localDispose = createRoot((d) => {
      usePortal({ layer: 'modal' })
      return d
    })
    expect(getPortalManager().layers().length).toBe(1)
    localDispose()
    expect(getPortalManager().layers().length).toBe(0)
  })

  it('skips registration when enabled=false', () => {
    withRoot(() => usePortal({ layer: 'tooltip', enabled: false }))
    expect(getPortalManager().layers().length).toBe(0)
  })

  it('multiple usePortal calls coexist with correct stack order', () => {
    withRoot(() => {
      usePortal({ layer: 'toast' })
      usePortal({ layer: 'tooltip' })
    })
    const layers = getPortalManager().layers()
    expect(layers.length).toBe(2)
    expect(layers[0]!.layer).toBe('toast')
    expect(layers[1]!.layer).toBe('tooltip')
  })
})

describe('usePortal — portalId', () => {
  it('returns a stable string id', () => {
    const a = withRoot(() => usePortal({ layer: 'toast' }))
    expect(typeof a.portalId).toBe('string')
    expect(a.portalId.length).toBeGreaterThan(0)
  })

  it('different hook calls produce different ids', () => {
    const ids = withRoot(() => {
      const a = usePortal({ layer: 'toast' })
      const b = usePortal({ layer: 'tooltip' })
      return [a.portalId, b.portalId]
    })
    expect(ids[0]).not.toBe(ids[1])
  })
})

describe('setPortalManager isolation', () => {
  it('swapping the manager isolates state between consumers', () => {
    const a = createPortalManager()
    setPortalManager(a)
    withRoot(() => usePortal({ layer: 'toast' }))
    expect(a.layers().length).toBe(1)

    const b = createPortalManager()
    setPortalManager(b)
    withRoot(() => usePortal({ layer: 'tooltip' }))
    expect(b.layers().length).toBe(1)
    // The first manager still has its registration alive (not disposed).
    expect(a.layers().length).toBe(1)
  })
})
