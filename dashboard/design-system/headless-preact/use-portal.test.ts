// @vitest-environment happy-dom
//
// Tests for headless-preact/use-portal. Verifies registration lifecycle,
// z-index resolution, and isolation between consumers via the default
// manager. The manager is swapped per-test via setPortalManager so the
// module-scoped state never leaks across cases.
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { createPortalManager, PORTAL_Z_INDEX } from '../headless-core/portal-manager'
import { __resetForTests as resetUseId } from './use-id'
import { getPortalManager, setPortalManager, usePortal } from './use-portal'

/**
 * Preact 10 schedules useEffect callbacks via requestAnimationFrame
 * (with a setTimeout fallback). happy-dom polyfills rAF as a setTimeout,
 * so a single setTimeout(0) tick is sufficient to flush effects.
 */
function flushEffects(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 16))
}

let container: HTMLElement

beforeEach(() => {
  resetUseId()
  setPortalManager(createPortalManager())
  container = document.createElement('div')
  document.body.append(container)
})

afterEach(() => {
  render(null, container)
  container.remove()
})

describe('usePortal — z-index resolution', () => {
  it('returns the layer default z-index when no override is given', () => {
    const captured: number[] = []
    function Probe(): unknown {
      const { zIndex } = usePortal({ layer: 'modal' })
      captured.push(zIndex)
      return html`<span>x</span>`
    }
    render(html`<${Probe} />`, container)
    expect(captured[0]).toBe(PORTAL_Z_INDEX.modal)
  })

  it('honors an explicit zIndex override', () => {
    const captured: number[] = []
    function Probe(): unknown {
      const { zIndex } = usePortal({ layer: 'toast', zIndex: 9999 })
      captured.push(zIndex)
      return html`<span>x</span>`
    }
    render(html`<${Probe} />`, container)
    expect(captured[0]).toBe(9999)
  })
})

describe('usePortal — registration lifecycle', () => {
  it('registers a layer on mount and deregisters on unmount', async () => {
    function Probe(): unknown {
      usePortal({ layer: 'drawer' })
      return html`<span>x</span>`
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(getPortalManager().layers()).toHaveLength(1)
    expect(getPortalManager().topmost()?.layer).toBe('drawer')

    render(null, container)
    await flushEffects()
    expect(getPortalManager().layers()).toHaveLength(0)
    expect(getPortalManager().topmost()).toBeNull()
  })

  it('two simultaneously mounted portals stack with topmost = highest z', async () => {
    function Two(): unknown {
      usePortal({ layer: 'drawer' })
      return html`<${Inner} />`
    }
    function Inner(): unknown {
      usePortal({ layer: 'modal' })
      return html`<span>x</span>`
    }
    render(html`<${Two} />`, container)
    await flushEffects()
    const layers = getPortalManager().layers()
    expect(layers).toHaveLength(2)
    expect(getPortalManager().topmost()?.layer).toBe('modal')
  })

  it('enabled=false skips registration', async () => {
    function Probe(): unknown {
      usePortal({ layer: 'modal', enabled: false })
      return html`<span>x</span>`
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(getPortalManager().layers()).toHaveLength(0)
  })
})

describe('usePortal — id assignment', () => {
  it('exposes a stable portalId across re-renders', () => {
    const captured: string[] = []
    function Probe(): unknown {
      const { portalId } = usePortal({ layer: 'modal' })
      captured.push(portalId)
      return html`<span>x</span>`
    }
    render(html`<${Probe} />`, container)
    render(html`<${Probe} />`, container)
    render(html`<${Probe} />`, container)
    expect(captured.length).toBeGreaterThanOrEqual(2)
    const first = captured[0]!
    captured.forEach((id) => {
      expect(id).toBe(first)
    })
  })

  it('two siblings get distinct portalIds', () => {
    const ids: string[] = []
    function Probe(): unknown {
      const { portalId } = usePortal({ layer: 'modal' })
      ids.push(portalId)
      return html`<span>x</span>`
    }
    render(html`<div><${Probe} /><${Probe} /></div>`, container)
    expect(ids.length).toBe(2)
    expect(ids[0]).not.toBe(ids[1])
  })
})

describe('usePortal — manager swap (test isolation)', () => {
  it('setPortalManager replaces the module-scoped instance', () => {
    const a = createPortalManager()
    const b = createPortalManager()
    setPortalManager(a)
    expect(getPortalManager()).toBe(a)
    setPortalManager(b)
    expect(getPortalManager()).toBe(b)
  })
})
