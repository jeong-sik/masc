import { signal } from '@preact/signals'
import { hasNonEmptyStringField, isRecord } from '../common/normalize'

export type KeeperPresenceStatus = 'active' | 'idle' | 'blocked'

export interface KeeperPresenceEntry {
  readonly keeper_id: string
  readonly workspace_label: string
  readonly role: string
  readonly status: KeeperPresenceStatus
  readonly last_seen_ms: number
}

export type KeeperPresenceSnapshot =
  | { readonly kind: 'loading' }
  | { readonly kind: 'disconnected'; readonly reason: string }
  | {
      readonly kind: 'live'
      readonly runtime_id: string
      readonly branch?: string
      readonly supervisor?: string
      readonly entries: ReadonlyArray<KeeperPresenceEntry>
    }

export const LOADING_SNAPSHOT: KeeperPresenceSnapshot = Object.freeze({ kind: 'loading' })

export function disconnectedSnapshot(reason: string): KeeperPresenceSnapshot {
  return { kind: 'disconnected', reason }
}

export const globalPresenceSnapshot = signal<KeeperPresenceSnapshot>(LOADING_SNAPSHOT)

export function updateKeeperPresenceFromSSE(snapshot: unknown): boolean {
  const normalized = normalizeKeeperPresenceSnapshot(snapshot)
  if (normalized === null) return false
  globalPresenceSnapshot.value = normalized
  return true
}

export function setGlobalPresence(snapshot: KeeperPresenceSnapshot): void {
  globalPresenceSnapshot.value = snapshot
}

export interface KeeperPresenceStore {
  readonly seed: (snapshot: unknown) => boolean
  readonly snapshot: () => KeeperPresenceSnapshot
  readonly entries: () => ReadonlyArray<KeeperPresenceEntry>
  readonly activeEntries: () => ReadonlyArray<KeeperPresenceEntry>
  readonly entryForKeeper: (keeperId: string) => KeeperPresenceEntry | null
  readonly reset: () => void
  readonly subscribe: (listener: () => void) => () => void
}

const STATUS_ORDER: Record<KeeperPresenceStatus, number> = {
  active: 0,
  blocked: 1,
  idle: 2,
}

export const PRESENCE_DOT: Record<KeeperPresenceStatus, { readonly color: string; readonly label: string }> = {
  active: { color: 'var(--color-status-ok)', label: 'ACTIVE' },
  blocked: { color: 'var(--color-status-err)', label: 'BLOCKED' },
  idle: { color: 'var(--color-fg-muted)', label: 'IDLE' },
}

const VALID_STATUS = new Set<string>(['active', 'idle', 'blocked'])

function entriesOf(snap: KeeperPresenceSnapshot): ReadonlyArray<KeeperPresenceEntry> {
  return snap.kind === 'live' ? snap.entries : []
}

export function presenceEntries(
  snap: KeeperPresenceSnapshot | null | undefined,
): ReadonlyArray<KeeperPresenceEntry> {
  if (snap === null || snap === undefined) return []
  return entriesOf(snap)
}

export function createKeeperPresenceStore(
  initialSnapshot: KeeperPresenceSnapshot = LOADING_SNAPSHOT,
): KeeperPresenceStore {
  const snapshotSignal = signal<KeeperPresenceSnapshot>(withSortedEntries(initialSnapshot))

  const seed = (snapshot: unknown): boolean => {
    if (isPresenceSnapshot(snapshot)) {
      snapshotSignal.value = withSortedEntries(snapshot)
      return true
    }
    const normalized = normalizeKeeperPresenceSnapshot(snapshot)
    if (normalized === null) return false
    snapshotSignal.value = normalized
    return true
  }

  const reset = (): void => {
    snapshotSignal.value = LOADING_SNAPSHOT
  }

  const subscribe = (listener: () => void): (() => void) => {
    let sawInitialSnapshot = false
    return snapshotSignal.subscribe(() => {
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        return
      }
      listener()
    })
  }

  return {
    seed,
    snapshot: () => snapshotSignal.value,
    entries: () => entriesOf(snapshotSignal.value),
    activeEntries: () => entriesOf(snapshotSignal.value).filter(entry => entry.status === 'active'),
    entryForKeeper: (keeperId: string) =>
      entriesOf(snapshotSignal.value).find(entry => entry.keeper_id === keeperId) ?? null,
    reset,
    subscribe,
  }
}

function isPresenceSnapshot(value: unknown): value is KeeperPresenceSnapshot {
  if (!isRecord(value)) return false
  const k = value['kind']
  return k === 'loading' || k === 'disconnected' || k === 'live'
}

function withSortedEntries(snap: KeeperPresenceSnapshot): KeeperPresenceSnapshot {
  if (snap.kind !== 'live') return snap
  const sorted = [...snap.entries].sort(compareEntries)
  return { ...snap, entries: sorted }
}

/**
 * Parse the server-owned IDE presence payload.  Keeping this normalizer next
 * to the store makes REST bootstrap and the SSE stream use the same contract
 * instead of separately guessing which dashboard summary fields imply a
 * keeper is present.
 */
export function normalizeKeeperPresenceSnapshot(value: unknown): KeeperPresenceSnapshot | null {
  if (!isRecord(value)) return null
  if (!hasNonEmptyStringField(value, 'runtime_id')) return null
  if (!Array.isArray(value.entries)) return null

  const entries = value.entries
    .map(normalizeEntry)
    .filter((entry): entry is KeeperPresenceEntry => entry !== null)
    .sort(compareEntries)

  const branch = hasNonEmptyStringField(value, 'branch') ? (value['branch'] as string) : undefined
  const supervisor = hasNonEmptyStringField(value, 'supervisor') ? (value['supervisor'] as string) : undefined

  const live: KeeperPresenceSnapshot = {
    kind: 'live',
    runtime_id: value['runtime_id'] as string,
    entries,
    ...(branch !== undefined ? { branch } : {}),
    ...(supervisor !== undefined ? { supervisor } : {}),
  }
  return live
}

function normalizeEntry(value: unknown): KeeperPresenceEntry | null {
  if (!isRecord(value)) return null
  if (!hasNonEmptyStringField(value, 'keeper_id')) return null
  if (!hasNonEmptyStringField(value, 'workspace_label')) return null
  if (!hasNonEmptyStringField(value, 'role')) return null
  if (!isKeeperPresenceStatus(value['status'])) return null
  if (!Number.isFinite(value['last_seen_ms'])) return null

  return {
    keeper_id: value['keeper_id'] as string,
    workspace_label: value['workspace_label'] as string,
    role: value['role'] as string,
    status: value['status'] as KeeperPresenceStatus,
    last_seen_ms: value['last_seen_ms'] as number,
  }
}

function compareEntries(a: KeeperPresenceEntry, b: KeeperPresenceEntry): number {
  const statusDelta = STATUS_ORDER[a.status] - STATUS_ORDER[b.status]
  if (statusDelta !== 0) return statusDelta
  if (a.last_seen_ms !== b.last_seen_ms) return b.last_seen_ms - a.last_seen_ms
  return a.keeper_id.localeCompare(b.keeper_id)
}

function isKeeperPresenceStatus(value: unknown): value is KeeperPresenceStatus {
  return typeof value === 'string' && VALID_STATUS.has(value)
}
