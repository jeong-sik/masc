/**
 * usePortal — SolidJS adapter over headless-core/PortalManager
 * (RFC 0001 §"directory layout", RFC 0017 PR #2.2).
 *
 * Registers a portal layer with the shared manager on mount, deregisters
 * on root dispose, and returns the resolved z-index + a stable id for
 * aria-* wiring.
 *
 * Render strategy is the caller's choice — this hook does NOT call
 * Solid's `<Portal>`. Consumers can render in-place, into a `<Portal>`,
 * or via their own root.
 *
 * Module-scoped default manager keeps stack ordering consistent across
 * all consumers in a single page. Tests swap it via `setPortalManager()`.
 */

import { createUniqueId, onCleanup } from 'solid-js'
import {
  createPortalManager,
  PORTAL_Z_INDEX,
  type ActivePortalLayer,
  type PortalLayerKind,
  type PortalManager,
} from '../headless-core/portal-manager'

let defaultManager: PortalManager = createPortalManager()

/** Test-only: replaces the module-scoped manager for isolation. */
export function setPortalManager(manager: PortalManager): void {
  defaultManager = manager
}

/** Mostly useful for tests inspecting topmost() / layers(). */
export function getPortalManager(): PortalManager {
  return defaultManager
}

export interface UsePortalOptions {
  /** Layer kind — picks default z-index from PORTAL_Z_INDEX. */
  layer: PortalLayerKind
  /** Optional z-index override (e.g. tooltip pinned above toast). */
  zIndex?: number
  /**
   * Skip register side effect when false. Mirrors Preact adapter's
   * temporary-suppression pattern. Default: true.
   * Note: this is read once at hook call time. Consumers needing
   * dynamic toggling should wrap the hook call in `<Show when={...}>`
   * (Solid idiom for conditional mounting).
   */
  enabled?: boolean
}

export interface UsePortalResult {
  /** Resolved z-index (override or PORTAL_Z_INDEX[layer] default). */
  readonly zIndex: number
  /** Stable id assigned to this portal instance for aria-* wiring. */
  readonly portalId: string
}

export function usePortal(options: UsePortalOptions): UsePortalResult {
  const { layer, zIndex, enabled = true } = options
  const portalId = createUniqueId()
  const resolvedZ = zIndex ?? PORTAL_Z_INDEX[layer]

  if (enabled) {
    const active: ActivePortalLayer = defaultManager.push({
      id: portalId,
      layer,
      zIndex,
    })
    onCleanup(() => defaultManager.pop(active.id))
  }

  return { zIndex: resolvedZ, portalId }
}
