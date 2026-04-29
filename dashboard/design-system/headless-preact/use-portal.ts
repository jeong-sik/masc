/**
 * usePortal — Preact adapter over headless-core/PortalManager.
 *
 * Per RFC 0001 §"directory layout". Registers a portal layer with the
 * shared PortalManager on mount, deregisters on unmount, and exposes
 * the resolved z-index + a stable id for aria-* wiring.
 *
 * Render strategy is the caller's choice: the hook does NOT call
 * Preact's `createPortal`. That keeps this file Preact-version-agnostic
 * (`preact/compat` not required) and lets callers decide whether to
 * render in-place, into a portal, or via their own root.
 *
 * Module-scoped default manager keeps stack ordering consistent across
 * all consumers in a single page. Tests can swap it via
 * `setPortalManager()` to isolate state.
 */

import { useEffect, useRef } from 'preact/hooks'
import {
  createPortalManager,
  PORTAL_Z_INDEX,
  type ActivePortalLayer,
  type PortalLayerKind,
  type PortalManager,
} from '../headless-core/portal-manager'
import { useId } from './use-id'

let defaultManager: PortalManager = createPortalManager()

/**
 * Replaces the module-scoped manager. Test-only — production code
 * never calls this. Use to isolate manager state between test cases.
 */
export function setPortalManager(manager: PortalManager): void {
  defaultManager = manager
}

/**
 * Returns the current default manager. Mostly useful for tests that
 * want to inspect `topmost()` / `layers()` without re-importing.
 */
export function getPortalManager(): PortalManager {
  return defaultManager
}

export interface UsePortalOptions {
  /** Layer kind — picks the default z-index from the raw token table. */
  layer: PortalLayerKind
  /** Optional z-index override (e.g. tooltip pinned above toast). */
  zIndex?: number
  /**
   * Skip register/deregister side effects when false. Useful for the
   * "open" prop pattern: caller returns null when closed, but unmount
   * also handles deregister; `enabled: false` is mainly for callers
   * that keep the hook mounted but want temporary suppression.
   * Default: true.
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
  const portalId = useId()
  const resolvedZ = zIndex ?? PORTAL_Z_INDEX[layer]

  // Track the active registration so cleanup uses the same id even if
  // useId's value churns between renders (it shouldn't, per RFC, but
  // we treat it as a contract not an assumption).
  const registeredRef = useRef<string | null>(null)

  useEffect(() => {
    if (!enabled) {
      if (registeredRef.current !== null) {
        defaultManager.pop(registeredRef.current)
        registeredRef.current = null
      }
      return
    }
    const active: ActivePortalLayer = defaultManager.push({ id: portalId, layer, zIndex })
    registeredRef.current = active.id
    return () => {
      if (registeredRef.current !== null) {
        defaultManager.pop(registeredRef.current)
        registeredRef.current = null
      }
    }
  }, [enabled, layer, zIndex, portalId])

  return { zIndex: resolvedZ, portalId }
}
