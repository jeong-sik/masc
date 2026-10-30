// Generic memoizer with bounded LRU eviction.
//
// Motivation: DOMPurify sanitize, `marked` parse, and `mermaid.render` are
// pure functions of (input, config) but are re-run on every component mount.
// A Chrome trace of the keeper detail page (2026-06-23) showed
// `DOMParser.parseFromString` alone holding the main thread for 8.1s because
// identical markdown/SVG was re-sanitized thousands of times. A module-level
// cache keyed by the source string makes the repeated work O(1).
//
// The cache is keyed by a string derived from the argument (the argument
// itself by default). Eviction is strict LRU: on a hit the entry is moved to
// the most-recently-used position; on overflow the least-recently-used entry
// is dropped. `Map` preserves insertion order, so the first key returned by
// `keys()` is the LRU entry.

export interface Memoized<A, R> {
  (arg: A): R
  /** Number of entries currently held. Read-only view for tests/telemetry. */
  readonly size: number
  /** Drop the entry for `arg`, if present. Used to un-cache failed results. */
  delete(arg: A): void
  /** Drop all cached entries. */
  clear(): void
}

export interface MemoizeOptions<A> {
  /** Maximum number of entries before LRU eviction kicks in. */
  max: number
  /** Derive the cache key from the argument. Defaults to `String(arg)`. */
  key?: (arg: A) => string
}

export function memoizeLru<A, R>(
  compute: (arg: A) => R,
  options: MemoizeOptions<A>,
): Memoized<A, R> {
  if (options.max < 1) {
    throw new Error(`memoizeLru: max must be >= 1, got ${options.max}`)
  }
  const keyOf = options.key ?? ((arg: A) => String(arg))
  const store = new Map<string, R>()

  const memoized = ((arg: A): R => {
    const k = keyOf(arg)
    const cached = store.get(k)
    if (cached !== undefined || store.has(k)) {
      // Move to most-recently-used position.
      store.delete(k)
      store.set(k, cached as R)
      return cached as R
    }
    const value = compute(arg)
    store.set(k, value)
    if (store.size > options.max) {
      const lru = store.keys().next().value
      if (lru !== undefined) store.delete(lru)
    }
    return value
  }) as Memoized<A, R>

  Object.defineProperty(memoized, 'size', { get: () => store.size })
  memoized.delete = (arg: A) => { store.delete(keyOf(arg)) }
  memoized.clear = () => store.clear()
  return memoized
}
