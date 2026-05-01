import { describe, expect, it, beforeEach, afterEach } from 'vitest'
import {
  mountPortal,
  unmountPortal,
  activePortalCount,
  resetPortalTracking,
} from './portal-manager'
import { resetZIndexStack } from './z-index-stack'

describe('mountPortal', () => {
  beforeEach(() => {
    resetPortalTracking()
    resetZIndexStack()
    document.body.innerHTML = ''
  })

  afterEach(() => {
    resetPortalTracking()
    resetZIndexStack()
    document.body.innerHTML = ''
  })

  it('creates a fixed container on body', () => {
    const portal = mountPortal('modal')
    expect(portal.container).toBeInstanceOf(HTMLDivElement)
    expect(portal.container.parentNode).toBe(document.body)
    expect(portal.container.getAttribute('data-masc-portal')).toBe('modal')
    expect(portal.container.style.position).toBe('fixed')
    expect(portal.container.style.inset).toBe('0')
    expect(portal.container.style.pointerEvents).toBe('none')
    unmountPortal(portal)
  })

  it('allocates a z-index from the stack', () => {
    const portal = mountPortal('modal')
    expect(typeof portal.zIndex).toBe('number')
    expect(portal.zIndex).toBeGreaterThan(0)
    unmountPortal(portal)
  })

  it('returns the layer key', () => {
    const portal = mountPortal('tooltip')
    expect(portal.layer).toBe('tooltip')
    unmountPortal(portal)
  })

  it('increments active count', () => {
    expect(activePortalCount()).toBe(0)
    const p1 = mountPortal('modal')
    expect(activePortalCount()).toBe(1)
    const p2 = mountPortal('popover')
    expect(activePortalCount()).toBe(2)
    unmountPortal(p1)
    unmountPortal(p2)
  })
})

describe('unmountPortal', () => {
  beforeEach(() => {
    resetPortalTracking()
    resetZIndexStack()
    document.body.innerHTML = ''
  })

  afterEach(() => {
    resetPortalTracking()
    resetZIndexStack()
    document.body.innerHTML = ''
  })

  it('removes the container from body', () => {
    const portal = mountPortal('modal')
    expect(document.body.contains(portal.container)).toBe(true)
    unmountPortal(portal)
    expect(document.body.contains(portal.container)).toBe(false)
  })

  it('decrements active count', () => {
    const p1 = mountPortal('modal')
    const p2 = mountPortal('popover')
    expect(activePortalCount()).toBe(2)
    unmountPortal(p1)
    expect(activePortalCount()).toBe(1)
    unmountPortal(p2)
    expect(activePortalCount()).toBe(0)
  })

  it('is safe to call twice', () => {
    const portal = mountPortal('modal')
    unmountPortal(portal)
    unmountPortal(portal)
    expect(activePortalCount()).toBe(0)
    expect(document.body.contains(portal.container)).toBe(false)
  })

  it('releases z-index back to stack', () => {
    const p1 = mountPortal('modal')
    const z1 = p1.zIndex
    unmountPortal(p1)
    const p2 = mountPortal('modal')
    expect(p2.zIndex).toBe(z1)
    unmountPortal(p2)
  })
})
