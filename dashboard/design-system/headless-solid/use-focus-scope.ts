/**
 * useFocusScope — SolidJS adapter over headless-core/FocusScope
 * (RFC 0001 §"directory layout", RFC 0017 PR #2.6).
 *
 * Activates a focus trap + restore scope around a container element
 * while the `active` accessor returns true. On deactivation (or root
 * dispose), restores focus to whatever was focused before the scope
 * took over.
 *
 * Solid convention: instead of a Preact RefObject, the caller passes a
 * getter `() => HTMLElement | null`. Solid's `let el!: HTMLElement; <div ref={el} />`
 * pattern naturally yields a getter via closure.
 *
 * Activation is reactive: pass `active: () => boolean` to flip via a
 * signal. Plain boolean works too (read once at hook call).
 */

import { createEffect, createMemo, onCleanup } from 'solid-js'
import {
  createFocusScope,
  type FocusScope,
  type InitialFocus,
} from '../headless-core/focus-scope'

export interface UseFocusScopeOptions {
  /**
   * Getter for the container element. Returning null is safe — the
   * scope no-ops until the element appears.
   */
  containerRef: () => HTMLElement | null
  /**
   * Activation flag. Pass an Accessor (getter) for reactive toggling,
   * or a plain boolean for static activation. Default true.
   */
  active?: boolean | (() => boolean)
  /** Tab cycles within the container. Default true. */
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

  const scope = createFocusScope({
    containerRef,
    loop,
    restoreFocus,
    initialFocus,
  })

  const isActive = typeof active === 'function'
    ? createMemo(active)
    : (): boolean => active

  createEffect(() => {
    if (isActive()) {
      scope.activate()
    } else {
      scope.deactivate()
    }
  })

  onCleanup(() => scope.deactivate())

  return { scope }
}
