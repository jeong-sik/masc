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

import { batch, signal, type ReadonlySignal, type Signal } from '@preact/signals'
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
  readonly topics: Set<string>
  ttlMs: number
  updatedAt: number
  invalidated: boolean
  invalidationGen: number
  inFlightGen: number
  epoch: number
  inFlight: Promise<Observed<T>> | null
  abortController: AbortController | null
}

const DEFAULT_TTL_MS = 15_000

export class ResourceCache {
  private readonly entries = new Map<string, CacheEntry<unknown>>()
  private readonly entriesByTopic = new Map<string, Set<CacheEntry<unknown>>>()
  private readonly unsubEpoch: () => void
  private readonly now: () => number

  constructor(now: () => number = () => Date.now()) {
    this.now = now
    this.unsubEpoch = sessionEpoch.subscribe(() => {
      this.clearAll()
    })
  }

  private indexTopic(topic: string, entry: CacheEntry<unknown>): void {
    let bucket = this.entriesByTopic.get(topic)
    if (!bucket) {
      bucket = new Set()
      this.entriesByTopic.set(topic, bucket)
    }
    bucket.add(entry)
  }

  private markEntryInvalidated(entry: CacheEntry<unknown>): void {
    entry.invalidated = true
    entry.invalidationGen += 1
    const cur = entry.state.peek()
    if (cur.kind === 'value' && !cur.stale) {
      entry.state.value = { ...cur, stale: true }
    }
  }

  private getOrCreate<T>(key: string, ttlMs: number, topics: readonly string[]): CacheEntry<T> {
    let entry = this.entries.get(key) as CacheEntry<T> | undefined
    if (!entry) {
      const topicSet = new Set<string>(topics)
      entry = {
        state: signal<Observed<T>>(observedLoading<T>()),
        topics: topicSet,
        ttlMs,
        updatedAt: 0,
        invalidated: false,
        invalidationGen: 0,
        inFlightGen: -1,
        epoch: currentSessionEpoch(),
        inFlight: null,
        abortController: null,
      }
      this.entries.set(key, entry as CacheEntry<unknown>)
      for (const topic of topicSet) {
        this.indexTopic(topic, entry as CacheEntry<unknown>)
      }
    } else {
      entry.ttlMs = ttlMs
      if (topics.length > 0) {
        for (let i = 0; i < topics.length; i++) {
          const topic = topics[i]!
          if (!entry.topics.has(topic)) {
            entry.topics.add(topic)
            this.indexTopic(topic, entry as CacheEntry<unknown>)
          }
        }
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

    // Coalesce concurrent callers into the single in-flight request ONLY when
    // no invalidation occurred after that in-flight request started. A manual
    // read never joins it: the operator asked to read now, and a request that
    // does not answer would otherwise hold every later press with it.
    if (
      reason !== 'manual'
      && entry.inFlight !== null
      && entry.epoch === startEpoch
      && entry.inFlightGen === entry.invalidationGen
    ) {
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

    // Supersede the in-flight request: it started under an older invalidation
    // generation, or a manual read replaces it.
    if (entry.abortController !== null) {
      entry.abortController.abort(reason === 'manual' ? 'superseded_by_manual_read' : 'superseded_by_invalidation')
    }
    const controller = new AbortController()
    const fetchGen = entry.invalidationGen
    entry.abortController = controller
    entry.inFlightGen = fetchGen
    entry.epoch = startEpoch

    if (cur.kind === 'value' && !cur.stale) {
      entry.state.value = { ...cur, stale: true }
    } else if (cur.kind !== 'value' && cur.kind !== 'loading') {
      entry.state.value = observedLoading<T>()
    }

    const run = (async (): Promise<Observed<T>> => {
      try {
        let result: Result<T | null, ApiError>
        try {
          result = await loader(controller.signal)
        } catch (cause) {
          if (
            !isEpochCurrent(startEpoch)
            || controller.signal.aborted
            || entry.abortController !== controller
          ) {
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
        if (
          !isEpochCurrent(startEpoch)
          || controller.signal.aborted
          || entry.abortController !== controller
        ) {
          return entry.state.peek()
        }
        const stillCurrentGen = fetchGen === entry.invalidationGen
        if (result.ok) {
          const ts = this.now()
          const next: Observed<T> = result.value === null
            ? observedAbsent<T>()
            : observedValue<T>(result.value, ts, !stillCurrentGen)
          if (stillCurrentGen) {
            entry.updatedAt = ts
            entry.invalidated = false
          }
          entry.state.value = next
          return next
        }
        if (result.error.kind === 'aborted' || result.error.kind === 'epoch_stale') {
          return entry.state.peek()
        }
        if (result.error.kind === 'not_found') {
          const next = observedAbsent<T>(result.error.message)
          if (stillCurrentGen) {
            entry.updatedAt = this.now()
            entry.invalidated = false
          }
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
    const bucket = this.entriesByTopic.get(topic)
    if (!bucket || bucket.size === 0) return 0
    batch(() => {
      for (const entry of bucket) {
        this.markEntryInvalidated(entry)
      }
    })
    return bucket.size
  }

  /**
   * Coalesced multi-topic invalidation for SSE frame bursts: deduplicates entries
   * subscribed to overlapping topics so each entry bumps `invalidationGen` once and
   * all stale transitions flush inside a single Preact `batch()`.
   */
  invalidateTopics(topics: Iterable<string>): number {
    let singleBucket: Set<CacheEntry<unknown>> | null = null
    let matched: Set<CacheEntry<unknown>> | null = null
    for (const topic of topics) {
      const bucket = this.entriesByTopic.get(topic)
      if (!bucket || bucket.size === 0) continue
      if (singleBucket === null && matched === null) {
        singleBucket = bucket
      } else {
        if (matched === null) {
          matched = new Set(singleBucket!)
          singleBucket = null
        }
        for (const entry of bucket) {
          matched.add(entry)
        }
      }
    }
    const target = matched ?? singleBucket
    if (!target || target.size === 0) return 0
    batch(() => {
      for (const entry of target) {
        this.markEntryInvalidated(entry)
      }
    })
    return target.size
  }

  invalidateKey(key: string): boolean {
    const entry = this.entries.get(key)
    if (!entry) return false
    this.markEntryInvalidated(entry)
    return true
  }

  invalidateAll(): number {
    if (this.entries.size === 0) return 0
    let count = 0
    batch(() => {
      for (const entry of this.entries.values()) {
        this.markEntryInvalidated(entry)
        count += 1
      }
    })
    return count
  }

  clearAll(): void {
    if (this.entries.size === 0) return
    batch(() => {
      for (const entry of this.entries.values()) {
        entry.abortController?.abort('cache_cleared')
        entry.abortController = null
        entry.inFlight = null
        entry.updatedAt = 0
        entry.invalidated = true
        entry.invalidationGen += 1
        if (entry.state.peek().kind !== 'loading') {
          entry.state.value = observedLoading()
        }
      }
    })
  }

  size(): number {
    return this.entries.size
  }

  dispose(): void {
    this.clearAll()
    this.unsubEpoch()
    this.entries.clear()
    this.entriesByTopic.clear()
  }
}

export const resourceCache = new ResourceCache()
