/**
 * Typed evidence state for keeper detail composite/runtime fetches.
 *
 * Replaces the previous loose record `{ data, refreshedAtMs, error, loading }`
 * which silently kept the last successful `data` on fetch failure. That
 * shape is the Workaround Rejection Bar §2 anti-pattern: an Unknown
 * (fetch failed, current truth unknown) was mapped to a Permissive
 * Default (re-use last-known value, no operator signal). The dashboard
 * then rendered the keeper detail composite cards (phase/turn/fiber/
 * FSM/mem) with stale fields even though the /composite endpoint
 * returned 404 — operators saw "data" and assumed reality.
 *
 * The discriminated union below closes that gap. Consumers must
 * `switch (state.kind)` exhaustively (TypeScript enforces this with
 * `noFallthroughCasesInSwitch` + no `default:` branch); stale data
 * stays visible *only* when the consumer explicitly opts into the
 * `'stale'` arm. There is no implicit "fall back to data" path.
 */

/** Fresh — fetch succeeded; `data` reflects the wire response. */
export interface EvidenceStateFresh<T> {
  readonly kind: 'fresh'
  readonly data: T
  /** Wall-clock ms when the successful response was applied. */
  readonly fetchedAt: number
}

/** Stale — a previous fetch succeeded but the most recent one failed.
 *  Consumers may show `data` provided they also display the staleness
 *  banner (`stalenessMs` + `error`). Hiding the staleness is the bug
 *  this union exists to prevent. */
export interface EvidenceStateStale<T> {
  readonly kind: 'stale'
  readonly data: T
  readonly fetchedAt: number
  readonly stalenessMs: number
  readonly error: string
}

/** Error — no successful fetch yet (or the failure happened before any
 *  data ever arrived). Consumers must not render placeholder cards. */
export interface EvidenceStateError {
  readonly kind: 'error'
  readonly error: string
}

/** Loading — initial mount or a refetch in progress with no prior data. */
export interface EvidenceStateLoading {
  readonly kind: 'loading'
}

export type EvidenceState<T> =
  | EvidenceStateLoading
  | EvidenceStateFresh<T>
  | EvidenceStateStale<T>
  | EvidenceStateError

/** Returns the `data` field only when the state is `'fresh'`.
 *  Stale/error/loading collapse to `null`. Consumers that want to
 *  render stale data on purpose must read the union directly and
 *  handle `'stale'` themselves (with a visible staleness banner). */
export function evidenceFreshData<T>(state: EvidenceState<T>): T | null {
  switch (state.kind) {
    case 'fresh':
      return state.data
    case 'stale':
    case 'error':
    case 'loading':
      return null
  }
}

/** Transition to apply on fetch success. */
export function applyFetchSucceeded<T>(data: T, fetchedAt: number): EvidenceStateFresh<T> {
  return { kind: 'fresh', data, fetchedAt }
}

/** Transition to apply on fetch failure. Preserves prior data as
 *  `'stale'` when available; otherwise yields `'error'`. The decision
 *  is centralised here so the two hooks (`useKeeperCompositeEvidence`,
 *  `useKeeperRuntimeTraceEvidence`) cannot drift apart. */
export function applyFetchFailed<T>(
  prev: EvidenceState<T>,
  error: string,
  failedAt: number,
): EvidenceStateStale<T> | EvidenceStateError {
  switch (prev.kind) {
    case 'fresh':
      return {
        kind: 'stale',
        data: prev.data,
        fetchedAt: prev.fetchedAt,
        stalenessMs: Math.max(0, failedAt - prev.fetchedAt),
        error,
      }
    case 'stale':
      // Already stale — keep the original `fetchedAt`, refresh staleness
      // and error so the banner reflects the most recent failure.
      return {
        kind: 'stale',
        data: prev.data,
        fetchedAt: prev.fetchedAt,
        stalenessMs: Math.max(0, failedAt - prev.fetchedAt),
        error,
      }
    case 'loading':
    case 'error':
      return { kind: 'error', error }
  }
}

/** Initial state for the two evidence hooks. */
export const loadingEvidence: EvidenceStateLoading = { kind: 'loading' }
