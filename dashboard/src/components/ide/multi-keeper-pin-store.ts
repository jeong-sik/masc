import { computed, signal } from '@preact/signals'

/**
 * RFC-0027 PR-α: multi-keeper pin store.
 *
 * Replaces the single `inspectorKeeperPin` signal in `inspector-keeper-bdi.ts`
 * with a bounded LRU collection (max 4) while preserving the legacy single-pin
 * API for callers that have not yet migrated. Layout decisions about how many
 * pins to render concurrently belong to the consumer (`InspectorMultiKeeperBDI`),
 * not the store.
 *
 * Backward-compat (RFC-0027 §10):
 *   - `pinInspectorKeeper(name, line)` re-exported from `inspector-keeper-bdi.ts`
 *     forwards into `pinKeeper(name, line)`. Callers see no shape change.
 *   - `inspectorKeeperPin` re-exported from `inspector-keeper-bdi.ts` is a
 *     `computed` projection of the head entry (`entries[0]`). Read-only access
 *     remains identical; tests that previously did
 *     `inspectorKeeperPin.value = null` must move to `clearPins()`.
 *
 * Cap = 4 ties to RFC-0027 §11 #1 (320px inspector rail + compact-fold). The
 * cap is a constant in the store rather than a runtime parameter so test
 * surface is small.
 */

export const PIN_CAP = 4

export interface PinnedKeeperEntry {
  readonly keeperName: string
  readonly pinnedAtMs: number
  readonly line: number | null
}

export interface PinnedKeepers {
  readonly entries: ReadonlyArray<PinnedKeeperEntry>
  readonly cap: number
}

const initialState: PinnedKeepers = { entries: [], cap: PIN_CAP }

export const pinnedKeepers = signal<PinnedKeepers>(initialState)

/**
 * Pin a keeper, moving it to the head of `entries`. If already present the
 * existing entry is removed first, so timestamp + line are refreshed and the
 * relative order does not drift. When `entries.length` would exceed `cap`,
 * the oldest entry by `pinnedAtMs` is dropped (LRU eviction).
 *
 * Empty/whitespace `keeperName` is a no-op.
 */
export function pinKeeper(keeperName: string, line: number | null = null): void {
  const trimmed = keeperName.trim()
  if (!trimmed) return
  const now = Date.now()
  const prev = pinnedKeepers.value
  const newEntry: PinnedKeeperEntry = {
    keeperName: trimmed,
    pinnedAtMs: now,
    line,
  }
  const filtered = prev.entries.filter(entry => entry.keeperName !== trimmed)
  const next = [newEntry, ...filtered].slice(0, prev.cap)
  pinnedKeepers.value = { ...prev, entries: next }
}

/**
 * Remove a single pin by keeper name. No-op if not pinned.
 */
export function unpinKeeper(keeperName: string): void {
  const trimmed = keeperName.trim()
  if (!trimmed) return
  const prev = pinnedKeepers.value
  const next = prev.entries.filter(entry => entry.keeperName !== trimmed)
  if (next.length === prev.entries.length) return
  pinnedKeepers.value = { ...prev, entries: next }
}

/**
 * Drop every pin. Used by tests that previously set
 * `inspectorKeeperPin.value = null`.
 */
export function clearPins(): void {
  if (pinnedKeepers.value.entries.length === 0) return
  pinnedKeepers.value = { ...pinnedKeepers.value, entries: [] }
}

/**
 * Head entry projection for legacy single-pin callers. Returns `null` when no
 * keeper is pinned.
 */
export const headPinnedKeeper = computed<PinnedKeeperEntry | null>(
  () => pinnedKeepers.value.entries[0] ?? null,
)
