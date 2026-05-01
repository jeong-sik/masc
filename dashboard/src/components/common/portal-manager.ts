// portal-manager.ts — framework-agnostic portal container management
//
// Kimi design system sec08 8.1.1 / 8.5.1: manages portal containers with
// z-index stack integration so nested dialogs, tooltips, and popovers
// layer correctly without arbitrary hard-coded values.

import { pushLayer, popLayer, type LayerKey } from './z-index-stack'

export interface ManagedPortal {
  container: HTMLElement
  zIndex: number
  layer: LayerKey
}

const _active = new Set<HTMLElement>()

/** Create a portal container with an allocated z-index. */
export function mountPortal(layer: LayerKey): ManagedPortal {
  const zIndex = pushLayer(layer)
  const container = document.createElement('div')
  container.setAttribute('data-masc-portal', layer)
  container.style.position = 'fixed'
  container.style.inset = '0'
  container.style.pointerEvents = 'none'
  container.style.zIndex = String(zIndex)
  document.body.appendChild(container)
  _active.add(container)
  return { container, zIndex, layer }
}

/** Remove a portal container and release its z-index. */
export function unmountPortal(portal: ManagedPortal): void {
  if (_active.has(portal.container)) {
    _active.delete(portal.container)
    if (portal.container.parentNode) {
      document.body.removeChild(portal.container)
    }
    popLayer(portal.zIndex)
  }
}

/** Count currently active portal containers. */
export function activePortalCount(): number {
  return _active.size
}

/** Reset tracking set — for tests only. */
export function resetPortalTracking(): void {
  _active.clear()
}
