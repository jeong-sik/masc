/**
 * ToastManager — singleton notification queue (RFC 0007).
 *
 * Owns a priority-ordered queue of severity-keyed notifications with
 * dedup by key, hover/focus/region pause, and automatic dismiss.
 *
 * MVP scope (RFC 0007 §3, §4, §5, §6):
 *   - severity → priority + duration + role + aria-live mapping
 *     (error=4/sticky/alert/assertive, warning=3/8s, success/info=
 *     2-1/5s/status/polite)
 *   - max visible default 5; 6th queues; error preempts oldest
 *     low-priority visible
 *   - dedupKey replaces in place + resets timer (cross-component)
 *   - pause / resume preserve elapsed time (not restart)
 *   - region pause: pausing one toast pauses all visible timers
 *   - action button does NOT make error sticky — action IS the
 *     response signal, default duration applies
 *
 * No DOM access. Pure TS. The adapter (use-toasts.ts) wires DOM
 * pointer-enter/leave + focus events to pause/resume and renders
 * each toast inside a usePortal({ layer: 'toast' }) tree.
 */

export type ToastSeverity = 'info' | 'success' | 'warning' | 'error'

export type ToastState = 'queued' | 'visible' | 'dismissed'

export interface ToastAction {
  readonly label: string
  readonly onClick: () => void
}

export interface ToastDescriptor {
  /** Optional explicit id; auto-generated otherwise. */
  id?: string
  readonly severity: ToastSeverity
  readonly message: string
  readonly description?: string
  readonly action?: ToastAction
  /** ms; 0 = sticky. When omitted, default by severity. */
  readonly duration?: number
  /** Cross-component dedup key. */
  readonly dedupKey?: string
}

export interface Toast {
  readonly id: string
  readonly severity: ToastSeverity
  readonly message: string
  readonly description?: string
  readonly action?: ToastAction
  readonly duration: number
  readonly dedupKey?: string
  readonly priority: number
  readonly createdAt: number
  readonly state: ToastState
}

export interface ToastManagerOptions {
  /** Max simultaneously visible toasts. Default 5. */
  maxVisible?: number
  /** Override default ID generator. */
  generateId?: () => string
}

const DEFAULT_MAX_VISIBLE = 5

const SEVERITY_PRIORITY: Readonly<Record<ToastSeverity, number>> = Object.freeze({
  error: 4,
  warning: 3,
  success: 2,
  info: 1,
})

const SEVERITY_DEFAULT_DURATION_MS: Readonly<Record<ToastSeverity, number>> = Object.freeze({
  error: 0, // sticky
  warning: 8000,
  success: 5000,
  info: 5000,
})

export interface ToastManager {
  notify(descriptor: ToastDescriptor): string
  dismiss(id: string): void
  dismissAll(): void
  pause(id: string): void
  resume(id: string): void
  /** Pause every visible toast (region pause). */
  pauseAll(): void
  /** Resume every visible toast. */
  resumeAll(): void

  getQueue(): ReadonlyArray<Toast>

  subscribe(listener: (queue: ReadonlyArray<Toast>) => void): () => void
}

interface InternalToast extends Toast {
  /** State mutation hook keeps the readonly Toast surface clean. */
  state: ToastState
  /** ms remaining when paused — null while running. */
  pausedRemaining: number | null
  /** Wall-clock ms when current run-segment started. */
  runStartedAt: number
  timer: ReturnType<typeof setTimeout> | null
}

function nextDefaultId(counter: { n: number }): string {
  counter.n += 1
  return `toast-${counter.n}`
}

/** Sort active (queued+visible) toasts in ToastManager render order. */
function sortToasts(a: Toast, b: Toast): number {
  if (a.priority !== b.priority) return b.priority - a.priority
  return a.createdAt - b.createdAt
}

export function createToastManager(opts?: ToastManagerOptions): ToastManager {
  const maxVisible = opts?.maxVisible ?? DEFAULT_MAX_VISIBLE
  const idCounter = { n: 0 }
  const generateId = opts?.generateId ?? (() => nextDefaultId(idCounter))

  // Internal storage. Keep insertion-time creation order for FIFO at
  // same priority. State transitions mutate in place; we expose
  // immutable snapshots via getQueue().
  const toasts = new Map<string, InternalToast>()
  const listeners = new Set<(queue: ReadonlyArray<Toast>) => void>()

  function snapshot(): ReadonlyArray<Toast> {
    // Return *active + dismissed* in priority/created order. State
    // discriminator carries the lifecycle for the consumer.
    const arr: Toast[] = []
    for (const t of toasts.values()) {
      arr.push({
        id: t.id,
        severity: t.severity,
        message: t.message,
        description: t.description,
        action: t.action,
        duration: t.duration,
        dedupKey: t.dedupKey,
        priority: t.priority,
        createdAt: t.createdAt,
        state: t.state,
      })
    }
    arr.sort(sortToasts)
    return Object.freeze(arr)
  }

  function emit(): void {
    const snap = snapshot()
    for (const listener of listeners) listener(snap)
  }

  function clearTimer(t: InternalToast): void {
    if (t.timer !== null) {
      clearTimeout(t.timer)
      t.timer = null
    }
  }

  function startTimer(t: InternalToast, ms: number): void {
    if (ms <= 0) return
    t.runStartedAt = Date.now()
    t.timer = setTimeout(() => {
      t.timer = null
      transitionToDismissed(t)
    }, ms)
  }

  function transitionToVisible(t: InternalToast): void {
    if (t.state === 'visible') return
    t.state = 'visible'
    if (t.duration > 0) {
      startTimer(t, t.duration)
    }
  }

  function transitionToDismissed(t: InternalToast): void {
    if (t.state === 'dismissed') return
    clearTimer(t)
    t.state = 'dismissed'
    emit()
    promoteFromQueue()
  }

  function visibleCount(): number {
    let n = 0
    for (const t of toasts.values()) {
      if (t.state === 'visible') n += 1
    }
    return n
  }

  function promoteFromQueue(): void {
    if (visibleCount() >= maxVisible) return
    const queued: InternalToast[] = []
    for (const t of toasts.values()) {
      if (t.state === 'queued') queued.push(t)
    }
    queued.sort((a, b) => sortToasts(a, b))
    while (queued.length > 0 && visibleCount() < maxVisible) {
      const head = queued.shift()!
      transitionToVisible(head)
      emit()
    }
  }

  /**
   * Eviction comparator. Negative when `a` is *more* dismissable than `b`.
   * Render order (sortToasts) is high-priority + FIFO; eviction order is
   * inverse for FIFO (oldest dies first) so we can't reuse sortToasts.
   * Lower priority = more dismissable; at same priority, older = more.
   */
  function moreDismissable(a: InternalToast, b: InternalToast): number {
    if (a.priority !== b.priority) return a.priority - b.priority
    return a.createdAt - b.createdAt
  }

  function preemptForError(incomingPriority: number): void {
    if (visibleCount() < maxVisible) return
    if (incomingPriority < SEVERITY_PRIORITY.error) return
    // Find the *most dismissable* visible toast strictly below the
    // incoming priority. Lowest priority first; oldest at same priority.
    let victim: InternalToast | null = null
    for (const t of toasts.values()) {
      if (t.state !== 'visible') continue
      if (t.priority >= incomingPriority) continue
      if (victim === null || moreDismissable(t, victim) < 0) victim = t
    }
    if (victim !== null) {
      transitionToDismissed(victim)
    }
  }

  function findByDedupKey(key: string): InternalToast | null {
    for (const t of toasts.values()) {
      if (t.dedupKey === key && t.state !== 'dismissed') return t
    }
    return null
  }

  function notifyImpl(descriptor: ToastDescriptor): string {
    // Dedup: if an active toast carries the same key, replace its
    // mutable fields in-place and reset its timer.
    if (descriptor.dedupKey !== undefined) {
      const existing = findByDedupKey(descriptor.dedupKey)
      if (existing !== null) {
        existing.severity = descriptor.severity
        existing.message = descriptor.message
        existing.description = descriptor.description
        existing.action = descriptor.action
        existing.priority = SEVERITY_PRIORITY[descriptor.severity]
        existing.duration =
          descriptor.duration ?? SEVERITY_DEFAULT_DURATION_MS[descriptor.severity]
        if (existing.state === 'visible') {
          clearTimer(existing)
          if (existing.duration > 0) startTimer(existing, existing.duration)
        }
        existing.pausedRemaining = null
        emit()
        return existing.id
      }
    }

    const id = descriptor.id ?? generateId()
    const priority = SEVERITY_PRIORITY[descriptor.severity]
    const duration =
      descriptor.duration ?? SEVERITY_DEFAULT_DURATION_MS[descriptor.severity]
    const t: InternalToast = {
      id,
      severity: descriptor.severity,
      message: descriptor.message,
      description: descriptor.description,
      action: descriptor.action,
      duration,
      dedupKey: descriptor.dedupKey,
      priority,
      createdAt: Date.now(),
      state: 'queued',
      pausedRemaining: null,
      runStartedAt: 0,
      timer: null,
    }
    toasts.set(id, t)

    // Decide whether to promote immediately or queue.
    if (priority === SEVERITY_PRIORITY.error) {
      preemptForError(priority)
    }
    if (visibleCount() < maxVisible) {
      transitionToVisible(t)
    }
    emit()
    return id
  }

  return {
    notify(descriptor: ToastDescriptor): string {
      return notifyImpl(descriptor)
    },

    dismiss(id: string): void {
      const t = toasts.get(id)
      if (t === undefined) return
      transitionToDismissed(t)
    },

    dismissAll(): void {
      for (const t of toasts.values()) {
        if (t.state !== 'dismissed') {
          clearTimer(t)
          t.state = 'dismissed'
        }
      }
      emit()
    },

    pause(id: string): void {
      const t = toasts.get(id)
      if (t === undefined || t.state !== 'visible') return
      if (t.timer === null) return // already paused or sticky
      const elapsed = Date.now() - t.runStartedAt
      t.pausedRemaining = Math.max(0, t.duration - elapsed)
      clearTimer(t)
    },

    resume(id: string): void {
      const t = toasts.get(id)
      if (t === undefined || t.state !== 'visible') return
      if (t.pausedRemaining === null) return
      const remaining = t.pausedRemaining
      t.pausedRemaining = null
      if (remaining <= 0) {
        transitionToDismissed(t)
        return
      }
      startTimer(t, remaining)
    },

    pauseAll(): void {
      for (const t of toasts.values()) {
        if (t.state !== 'visible' || t.timer === null) continue
        const elapsed = Date.now() - t.runStartedAt
        t.pausedRemaining = Math.max(0, t.duration - elapsed)
        clearTimer(t)
      }
    },

    resumeAll(): void {
      for (const t of toasts.values()) {
        if (t.state !== 'visible' || t.pausedRemaining === null) continue
        const remaining = t.pausedRemaining
        t.pausedRemaining = null
        if (remaining <= 0) {
          transitionToDismissed(t)
          continue
        }
        startTimer(t, remaining)
      }
    },

    getQueue(): ReadonlyArray<Toast> {
      return snapshot()
    },

    subscribe(listener: (queue: ReadonlyArray<Toast>) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}

export const SEVERITY_TO_ROLE: Readonly<Record<ToastSeverity, 'status' | 'alert'>> =
  Object.freeze({
    error: 'alert',
    warning: 'status',
    success: 'status',
    info: 'status',
  })

export const SEVERITY_TO_ARIA_LIVE: Readonly<
  Record<ToastSeverity, 'polite' | 'assertive'>
> = Object.freeze({
  error: 'assertive',
  warning: 'polite',
  success: 'polite',
  info: 'polite',
})

export { SEVERITY_PRIORITY, SEVERITY_DEFAULT_DURATION_MS }
