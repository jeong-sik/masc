/**
 * useFocusScope — Preact adapter over headless-core/FocusScope.
 *
 * Per RFC 0001 §"directory layout". Activates a focus trap + restore
 * scope around a container element while `active` is true. On
 * deactivation (or unmount), restores focus to whatever was focused
 * before the scope took over.
 *
 * Replaces the inline `useRef + useEffect + manual document keydown
 * handler` patterns currently scattered across Drawer/Popover/Dialog
 * primitives — those will migrate to this hook in follow-up PRs.
 *
 * Caller controls the container via a Preact ref (matches the rest of
 * the dashboard's ref discipline) and toggles activation via the
 * `active` flag. The hook honors RFC 0001 §"focus-scope.ts" options
 * 1:1: `loop`, `restoreFocus`, `initialFocus`.
 *
 * Returns the underlying FocusScope handle so callers that need
 * imperative `.focusFirst()` / `.focusLast()` / `.tabbables()` access
 * (e.g. a "back to top" focus button) can grab them. Callers that
 * only need lifecycle wiring can ignore the return value.
 */

import type { RefObject } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import {
  createFocusScope,
  type FocusScope,
  type InitialFocus,
} from '../headless-core/focus-scope'

export interface UseFocusScopeOptions {
  /**
   * Ref to the container element. The scope's `containerRef` reads
   * `.current` lazily so an as-yet-unmounted ref returns null and the
   * scope safely no-ops until the next render.
   */
  containerRef: RefObject<HTMLElement | null>
  /**
   * Activate the scope. Default true. Flip to false when the wrapping
   * dialog/popover closes — the hook will deactivate and restore
   * prior focus.
   */
  active?: boolean
  /** Tab cycles within the container. Default true (matches FocusScope). */
  loop?: boolean
  /** Restore focus to the previously focused element on deactivate. Default true. */
  restoreFocus?: boolean
  /** Where to land focus on activate. Default 'first'. */
  initialFocus?: InitialFocus
}

export interface UseFocusScopeResult {
  readonly scope: FocusScope
}

export function useFocusScope(options: UseFocusScopeOptions): UseFocusScopeResult {
  const {
    containerRef,
    active = true,
    loop = true,
    restoreFocus = true,
    initialFocus = 'first',
  } = options

  // Lazily build the FocusScope on first render; stash via ref so
  // re-renders don't reinstantiate (and lose the priorFocus stash).
  const scopeRef = useRef<FocusScope | null>(null)
  if (scopeRef.current === null) {
    scopeRef.current = createFocusScope({
      containerRef: () => containerRef.current,
      loop,
      restoreFocus,
      initialFocus,
    })
  }

  useEffect(() => {
    const scope = scopeRef.current
    if (scope === null) return
    if (active) {
      scope.activate()
      return () => scope.deactivate()
    }
    // active=false at this render — make sure any prior activation is
    // torn down. Calling deactivate() before activate() is a no-op
    // (per FocusScope idempotency contract).
    scope.deactivate()
    return undefined
  }, [active])

  return { scope: scopeRef.current }
}
