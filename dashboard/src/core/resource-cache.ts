/**
 * Centralized GET deduplicator, TTL cache, topic invalidator & 5-state Observed<T> model.
 *
 * Invariants:
 * - Forbids `{ force: true }` refetch storms on route navigation or SSE push:
 *   only `reason: 'manual'` bypasses a fresh TTL entry; `mount` / `route` / `sse`
 *   coalesce into in-flight requests and respect TTL unless invalidated by topic.
 * - `Observed<T>` strictly separates `loading | value{data,stale,updatedAt} | absent | unreported | failed{error,retryable}`
 *   so missing data (`"없음"`) and unreported telemetry (`"미보고"`) are never confused with zero (`"0"`).
 * - Automatically clears cached entries & aborts in-flight loaders on `sessionEpoch` advance.
 */

import { signal, type ReadonlySignal, type Signal } from '@preact/signals'
import type { Result } from '../lib/result'
import { currentSessionEpoch, isEpochCurrent, sessionEpoch } from './auth'
import type { ApiError } from './transport'

export type Observed<T> =
  | { readonly kind: 'loading' }
  | { readonly kind: 'value'; readonly data: T; readonly stale: boolean; readonly updatedAt: number }
  | { readonly kind: 'absent'; readonly reason?: string }
  | { readonly kind: 'unreported'; readonly reason?: string }
  | { readonly kind: 'failed'; readonly error: ApiError; readonly retryable: boolean }

export function observedLoading<T = never>(): Observed<T> {
  return { kind: 'loading' }
}

export function observedValue<T>(data: T, updatedAt = Date.now(), stale = false): Observed<T> {
  return { kind: 'value', data, stale, updatedAt }
}

export function observedAbsent<T = never>(reason?: string): Observed<T> {
  return reason ? { kind: 'absent', reason } : { kind: 'absent' }
}

export function observedUnreported<T = never>(reason?: string): Observed<T> {
  return reason ? { kind: 'unreported', reason } : { kind: 'unreported' }
}

export function observedFailed<T = never>(error: ApiError): Observed<T> {
  return { kind: 'failed', error, retryable: error.retryable }
}

/**
 * Formats an `Observed<T>` value for display without conflating absence and zero.
 * - `absent` -> `"없음"`
 * - `unreported` -> `"미보고"`
 * - `loading` -> `"불러오는 중…"`
 * - `failed` -> `"오류"`
 * - `value(0)` -> `"0"` (NEVER `"없음"` or `"—"`)
 */
export function formatObserved<T>(
  obs: Observed<T>,
  formatValue: (value: T) => string = (v) => String(v),
): string {
  switch (obs.kind) {
    case 'loading':
      return '불러오는 중…'
    case 'absent':
      return '없음'
    case 'unreported':
      return '미보고'
    case 'failed':
      return '오류'
    case 'value':
      return formatValue(obs.data)
  }
}

export type FetchReason = 'mount' | 'route' | 'sse' | 'manual'

export interface CacheFetchOptions {
  readonly ttlMs?: number
  readonly topics?: readonly string[]
  readonly reason?: FetchReason
}

interface CacheEntry<T> {
  readonly state: Signal<Observed<T>>
  topics: ReadonlySet<string>
  ttlMs: number
  updatedAt: number
  invalidated: boolean
  epoch: number
  inFlight: Promise<Observed<T>> | null
  abortController: AbortController | null
}

const DEFAULT_TTL_MS = 15_000

export class ResourceCache {
  private readonly entries = new Map<string, CacheEntry<unknown>>()
  private readonly unsubEpoch: () => void
  private readonly now: () => number

  constructor(now: () => number = () => Date.now()) {
    this.now = now
    this.unsubEpoch = sessionEpoch.subscribe(() => {
      this.clearAll()
    })
  }

  private getOrCreate<T>(key: string, ttlMs: number, topics: readonly string[]): CacheEntry<T> {
    let entry = this.entries.get(key) as CacheEntry<T> | undefined
    if (!entry) {
      entry = {
        state: signal<Observed<T>>(observedLoading<T>()),
        topics: new Set(topics),
        ttlMs,
        updatedAt: 0,
        invalidated: false,
        epoch: currentSessionEpoch(),
        inFlight: null,
        abortController: null,
      }
      this.entries.set(key, entry as CacheEntry<unknown>)
    } else {
      entry.ttlMs = ttlMs
      if (topics.length > 0) {
        entry.topics = new Set([...entry.topics, ...topics])
      }
    }
    return entry
  }

  observe<T>(key: string): ReadonlySignal<Observed<T>> {
    return this.getOrCreate<T>(key, DEFAULT_TTL_MS, []).state
  }

  peek<T>(key: string): Observed<T> | undefined {
    const entry = this.entries.get(key) as CacheEntry<T> | undefined
    return entry?.state.peek()
  }

  /**
   * Deduplicated, TTL-aware resource fetch.
   * Only `reason: 'manual'` bypasses a fresh TTL entry. Route nav / SSE pushes
   * NEVER bypass fresh cache unless the topic was explicitly invalidated.
   */
  fetch<T>(
    key: string,
    loader: (signal: AbortSignal) => Promise<Result<T | null, ApiError>>,
    opts: CacheFetchOptions = {},
  ): Promise<Observed<T>> {
    const ttlMs = opts.ttlMs ?? DEFAULT_TTL_MS
    const topics = opts.topics ?? []
    const reason: FetchReason = opts.reason ?? 'mount'
    const entry = this.getOrCreate<T>(key, ttlMs, topics)
    const startEpoch = currentSessionEpoch()

    // Coalesce concurrent callers into the single in-flight request
    if (entry.inFlight !== null && entry.epoch === startEpoch) {
      return entry.inFlight
    }

    const cur = entry.state.peek()
    const isFresh =
      entry.epoch === startEpoch
      && !entry.invalidated
      && cur.kind === 'value'
      && this.now() - entry.updatedAt < entry.ttlMs

    // Forbid force-refetch storms on route nav or SSE push; only manual refresh bypasses fresh TTL
    if (isFresh && reason !== 'manual') {
      return Promise.resolve(cur)
    }

    const controller = new AbortController()
    entry.abortController = controller
    entry.epoch = startEpoch

    if (cur.kind === 'value') {
      entry.state.value = { ...cur, stale: true }
    } else if (cur.kind !== 'loading') {
      entry.state.value = observedLoading<T>()
    }

    const run = (async (): Promise<Observed<T>> => {
      try {
        let result: Result<T | null, ApiError>
        try {
          result = await loader(controller.signal)
        } catch (cause) {
          if (!isEpochCurrent(startEpoch) || controller.signal.aborted) {
            return entry.state.peek()
          }
          const next = observedFailed<T>({
            kind: 'network',
            status: null,
            code: 'loader_threw',
            message: cause instanceof Error ? cause.message : String(cause),
            retryable: true,
            cause,
          })
          entry.state.value = next
          return next
        }
        if (!isEpochCurrent(startEpoch) || controller.signal.aborted) {
          return entry.state.peek()
        }
        if (result.ok) {
          const ts = this.now()
          const next: Observed<T> = result.value === null
            ? observedAbsent<T>()
            : observedValue<T>(result.value, ts, false)
          entry.updatedAt = ts
          entry.invalidated = false
          entry.state.value = next
          return next
        }
        if (result.error.kind === 'aborted' || result.error.kind === 'epoch_stale') {
          return entry.state.peek()
        }
        if (result.error.kind === 'not_found') {
          const next = observedAbsent<T>(result.error.message)
          entry.updatedAt = this.now()
          entry.invalidated = false
          entry.state.value = next
          return next
        }
        const next = observedFailed<T>(result.error)
        entry.state.value = next
        return next
      } finally {
        if (entry.abortController === controller) {
          entry.abortController = null
          entry.inFlight = null
        }
      }
    })()

    entry.inFlight = run
    return run
  }

  /**
   * Marks all entries subscribed to `topic` as stale without triggering a refetch storm.
   * Mounted views will refresh lazily on their next read or scheduled observation cycle.
   */
  invalidateTopic(topic: string): number {
    let count = 0
    for (const entry of this.entries.values()) {
      if (!entry.topics.has(topic)) continue
      entry.invalidated = true
      const cur = entry.state.peek()
      if (cur.kind === 'value' && !cur.stale) {
        entry.state.value = { ...cur, stale: true }
      }
      count += 1
    }
    return count
  }

  invalidateKey(key: string): boolean {
    const entry = this.entries.get(key)
    if (!entry) return false
    entry.invalidated = true
    const cur = entry.state.peek()
    if (cur.kind === 'value' && !cur.stale) {
      entry.state.value = { ...cur, stale: true }
    }
    return true
  }

  invalidateAll(): number {
    let count = 0
    for (const entry of this.entries.values()) {
      entry.invalidated = true
      const cur = entry.state.peek()
      if (cur.kind === 'value' && !cur.stale) {
        entry.state.value = { ...cur, stale: true }
      }
      count += 1
    }
    return count
  }

  clearAll(): void {
    for (const entry of this.entries.values()) {
      entry.abortController?.abort('cache_cleared')
      entry.abortController = null
      entry.inFlight = null
      entry.updatedAt = 0
      entry.invalidated = true
      entry.state.value = observedLoading()
    }
  }

  size(): number {
    return this.entries.size
  }

  dispose(): void {
    this.clearAll()
    this.unsubEpoch()
    this.entries.clear()
  }
}

export const resourceCache = new ResourceCache()
