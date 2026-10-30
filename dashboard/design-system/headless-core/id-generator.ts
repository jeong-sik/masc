/**
 * IdGenerator — framework-agnostic, deterministic ID generator.
 *
 * Replaces ad-hoc `Math.random()` ID patterns in interactive primitives
 * (Drawer/Popover/Dialog) where the trigger and content need a stable
 * shared id for `aria-labelledby` / `aria-controls` wiring.
 *
 * Design (RFC 0001 §"First 3 primitives"):
 *   - Per-instance monotonic counter
 *   - Caller may supply a seed prefix (defaults to `"id"`); each `next()`
 *     call may also override the prefix at the call site
 *   - `reset()` zeroes the counter (for hydration boundaries / SSR replay)
 *   - Two independent generators with the same seed produce identical
 *     id sequences — sufficient for the SSR/hydration determinism the
 *     RFC sketches as a future requirement
 *
 * Out of scope (will land later if/when the dashboard adopts SSR):
 *   - Tree-aware id allocation (Preact useId is the right primitive there)
 *   - Web crypto seeded UUIDs
 *
 * No external dependencies. Pure TS. Safe to import from headless-preact
 * adapter or any other framework adapter.
 */

export interface IdGenerator {
  /**
   * Returns the next id in sequence, formatted as `<prefix>-<n>` where
   * `n` increments monotonically from 1. The optional `prefix` argument
   * overrides the seed for this call only.
   */
  next(prefix?: string): string

  /** Resets the counter to 0. Subsequent `next()` returns `<prefix>-1`. */
  reset(): void
}

const DEFAULT_SEED = 'id'

/**
 * Creates an IdGenerator. `seed` is the default prefix used when
 * `next()` is called with no argument; defaults to `"id"`.
 */
export function createIdGenerator(seed?: string): IdGenerator {
  // Empty string seed falls back to the default — `-1` style ids are
  // legal HTML5 but require CSS-selector escaping (`\-1`), which is a
  // sharp edge a caller almost never wants. Treat `""` as "not supplied".
  const defaultPrefix = seed && seed.length > 0 ? seed : DEFAULT_SEED
  let counter = 0

  return {
    next(prefix?: string): string {
      counter += 1
      return `${prefix ?? defaultPrefix}-${counter}`
    },
    reset(): void {
      counter = 0
    },
  }
}
