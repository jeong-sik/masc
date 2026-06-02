/**
 * FetchScheduler — coalesces multiple refresh requests into minimal fetches.
 *
 * Pattern: write-back cache flush (same principle as OS page cache).
 * - Multiple callers mark data as stale via request() / requestNow()
 * - Scheduler debounces, enforces cooldown, deduplicates inflight requests
 * - At most one fetch is in flight at any time
 *
 * Comparable to: TanStack Query deduplication, SWR dedupingInterval,
 *                Elm single-update-channel, RTK Query cache invalidation.
 */

type FetchFn = () => Promise<void>
type Priority = 'none' | 'normal' | 'urgent'

interface FetchSchedulerConfig {
  /** Minimum ms between consecutive fetches. Prevents burst after rapid events. */
  cooldownMs: number
  /** Trailing-edge debounce window. Batches rapid invalidations into one fetch. */
  debounceMs: number
}

const DEFAULT_CONFIG: FetchSchedulerConfig = {
  cooldownMs: 2_000,
  debounceMs: 300,
}

export class FetchScheduler {
  private readonly fetchFn: FetchFn
  private readonly config: FetchSchedulerConfig

  private inflight: Promise<void> | null = null
  private lastFetchAt = 0
  private pendingPriority: Priority = 'none'
  private debounceTimer: ReturnType<typeof setTimeout> | null = null
  private cooldownTimer: ReturnType<typeof setTimeout> | null = null

  constructor(fetchFn: FetchFn, config?: Partial<FetchSchedulerConfig>) {
    this.fetchFn = fetchFn
    this.config = { ...DEFAULT_CONFIG, ...config }
  }

  /**
   * Request a refresh. Debounced and cooldown-enforced.
   * Multiple rapid calls collapse into a single fetch.
   */
  request(): void {
    if (this.inflight) {
      this.raisePriority('normal')
      return
    }
    this.raisePriority('normal')
    this.scheduleFlush()
  }

  /**
   * Request an immediate refresh. Skips debounce window, but still
   * deduplicates with any inflight request — sets urgent dirty flag
   * so a re-fetch fires as soon as the current one completes.
   */
  requestNow(): void {
    if (this.inflight) {
      this.raisePriority('urgent')
      return
    }
    this.clearTimers()
    this.pendingPriority = 'none'
    void this.doFetch()
  }

  /** Cancel all pending timers. Does not abort inflight requests. */
  dispose(): void {
    this.clearTimers()
    this.pendingPriority = 'none'
  }

  /** Whether a fetch is currently in progress. */
  get fetching(): boolean {
    return this.inflight !== null
  }

  /**
   * Expose inflight promise for callers that need to await current fetch.
   * Returns null when idle.
   */
  get inflightPromise(): Promise<void> | null {
    return this.inflight
  }

  private raisePriority(p: Priority): void {
    const rank: Record<Priority, number> = { none: 0, normal: 1, urgent: 2 }
    if (rank[p] > rank[this.pendingPriority]) {
      this.pendingPriority = p
    }
  }

  private scheduleFlush(): void {
    if (this.debounceTimer || this.cooldownTimer) return

    const elapsed = Date.now() - this.lastFetchAt
    const cooldownRemaining = this.config.cooldownMs - elapsed

    if (cooldownRemaining <= 0) {
      // Past cooldown — use debounce to batch rapid requests
      this.debounceTimer = setTimeout(() => {
        this.debounceTimer = null
        this.pendingPriority = 'none'
        void this.doFetch()
      }, this.config.debounceMs)
    } else {
      // Within cooldown — schedule at cooldown expiry
      this.cooldownTimer = setTimeout(() => {
        this.cooldownTimer = null
        this.pendingPriority = 'none'
        void this.doFetch()
      }, cooldownRemaining)
    }
  }

  private async doFetch(): Promise<void> {
    this.inflight = this.fetchFn()
    try {
      await this.inflight
    } catch {
      // Error handling is the fetchFn's responsibility (signals, retries, etc.).
      // Scheduler only manages timing.
    } finally {
      this.lastFetchAt = Date.now()
      this.inflight = null
      this.drainPending()
    }
  }

  /** After a fetch completes, decide what to do with accumulated requests. */
  private drainPending(): void {
    const priority = this.pendingPriority
    this.pendingPriority = 'none'

    if (priority === 'urgent') {
      void this.doFetch()
    } else if (priority === 'normal') {
      this.scheduleFlush()
    }
  }

  private clearTimers(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = null
    }
    if (this.cooldownTimer) {
      clearTimeout(this.cooldownTimer)
      this.cooldownTimer = null
    }
  }
}
