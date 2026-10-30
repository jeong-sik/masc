/**
 * useId — Preact adapter over headless-core/IdGenerator.
 *
 * Per RFC 0001 §"directory layout". Returns a stable id for the
 * lifetime of a component instance. Used by interactive primitives
 * (Drawer, Dialog, Popover) to wire `aria-labelledby` / `aria-controls`
 * between Trigger and Content nodes.
 *
 * Preference order:
 *   1. Preact's native `useId` (>= 10.11) — browser-correct, no
 *      collisions across concurrent trees, zero adapter cost.
 *   2. `createIdGenerator()` fallback — the deterministic counter from
 *      headless-core. Used in environments where Preact's hook isn't
 *      available (older Preact, custom renderers, manual SSR
 *      hydration replays).
 *
 * The fallback uses a module-scoped generator so successive
 * `useId()` calls within a single page yield distinct ids. Tests can
 * `__resetForTests()` between cases.
 *
 * The adapter intentionally does NOT accept arguments. Callers that
 * need a custom prefix should compose: `${useId()}-content`. This
 * matches React's useId surface and avoids a third API in the codebase.
 */

import { useId as preactUseId } from 'preact/hooks'
import { useRef } from 'preact/hooks'
import { createIdGenerator, type IdGenerator } from '../headless-core/id-generator'

const fallbackGenerator: IdGenerator = createIdGenerator('hc')

/**
 * Returns a stable id for the lifetime of the calling component.
 * Prefers Preact's built-in `useId` when available; otherwise allocates
 * via headless-core fallback on first render and caches via useRef.
 */
export function useId(): string {
  if (typeof preactUseId === 'function') {
    return preactUseId()
  }
  const ref = useRef<string | null>(null)
  if (ref.current === null) {
    ref.current = fallbackGenerator.next()
  }
  return ref.current
}

/**
 * Resets the fallback generator counter. Test-only — production code
 * should never call this. Exposed because Preact's useId is implicit
 * about its internal counter, and we want our fallback to behave the
 * same way for test isolation.
 */
export function __resetForTests(): void {
  fallbackGenerator.reset()
}
