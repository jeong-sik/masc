import { signal } from '@preact/signals'

export const globalPresenceSnapshot = signal<KeeperPresenceSnapshot | null>(null)

export function updateKeeperPresenceFromSSE(snapshot: unknown): boolean {
  const normalized = normalizeSnapshot(snapshot)
  if (normalized === null) return false
  globalPresenceSnapshot.value = normalized
  return true
}

export type KeeperPresenceStatus = 'active' | 'idle' | 'blocked'

export interface KeeperPresenceEntry {
  readonly keeper_id: string
  readonly workspace_label: string
  readonly branch: string
  readonly role: string
  readonly status: KeeperPresenceStatus
  readonly last_seen_ms: number
}

export interface KeeperPresenceSnapshot {
  readonly runtime_id: string
  readonly branch: string
  readonly supervisor: string
  readonly connected: boolean
  readonly entries: ReadonlyArray<KeeperPresenceEntry>
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

const EMPTY_SNAPSHOT: KeeperPresenceSnapshot = Object.freeze({
  runtime_id: 'runtime',
  branch: 'main',
  supervisor: 'local',
  connected: false,
  entries: [],
})

const STATUS_ORDER: Record<KeeperPresenceStatus, number> = {
  active: 0,
  blocked: 1,
  idle: 2,
}

const VALID_STATUS = new Set<string>(['active', 'idle', 'blocked'])

export function createKeeperPresenceStore(
  initialSnapshot: unknown = EMPTY_SNAPSHOT,
): KeeperPresenceStore {
  const snapshotSignal = signal<KeeperPresenceSnapshot>(EMPTY_SNAPSHOT)

  const seed = (snapshot: unknown): boolean => {
    const normalized = normalizeSnapshot(snapshot)
    if (normalized === null) return false
    snapshotSignal.value = normalized
    return true
  }

  const reset = (): void => {
    snapshotSignal.value = EMPTY_SNAPSHOT
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

  seed(initialSnapshot)

  return {
    seed,
    snapshot: () => snapshotSignal.value,
    entries: () => snapshotSignal.value.entries,
    activeEntries: () => snapshotSignal.value.entries.filter(entry => entry.status === 'active'),
    entryForKeeper: (keeperId: string) =>
      snapshotSignal.value.entries.find(entry => entry.keeper_id === keeperId) ?? null,
    reset,
    subscribe,
  }
}

type UnknownRecord = Record<string, unknown>

function normalizeSnapshot(value: unknown): KeeperPresenceSnapshot | null {
  if (!isRecord(value)) return null
  if (!hasNonEmptyString(value, 'runtime_id')) return null
  if (!hasNonEmptyString(value, 'branch')) return null
  if (!hasNonEmptyString(value, 'supervisor')) return null
  if (typeof value.connected !== 'boolean') return null
  if (!Array.isArray(value.entries)) return null

  const entries = value.entries
    .map(normalizeEntry)
    .filter((entry): entry is KeeperPresenceEntry => entry !== null)
    .sort(compareEntries)

  return {
    runtime_id: value.runtime_id as string,
    branch: value.branch as string,
    supervisor: value.supervisor as string,
    connected: value.connected as boolean,
    entries,
  }
}

function normalizeEntry(value: unknown): KeeperPresenceEntry | null {
  if (!isRecord(value)) return null
  if (!hasNonEmptyString(value, 'keeper_id')) return null
  if (!hasNonEmptyString(value, 'workspace_label')) return null
  if (!hasNonEmptyString(value, 'branch')) return null
  if (!hasNonEmptyString(value, 'role')) return null
  if (!isKeeperPresenceStatus(value.status)) return null
  if (!Number.isFinite(value.last_seen_ms)) return null

  return {
    keeper_id: value.keeper_id as string,
    workspace_label: value.workspace_label as string,
    branch: value.branch as string,
    role: value.role as string,
    status: value.status as KeeperPresenceStatus,
    last_seen_ms: value.last_seen_ms as unknown as number,
  }
}

function compareEntries(a: KeeperPresenceEntry, b: KeeperPresenceEntry): number {
  const statusDelta = STATUS_ORDER[a.status] - STATUS_ORDER[b.status]
  if (statusDelta !== 0) return statusDelta
  if (a.last_seen_ms !== b.last_seen_ms) return b.last_seen_ms - a.last_seen_ms
  return a.keeper_id.localeCompare(b.keeper_id)
}

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function hasNonEmptyString(record: UnknownRecord, key: string): record is UnknownRecord & Record<typeof key, string> {
  const value = record[key]
  return typeof value === 'string' && value.trim() !== ''
}

function isKeeperPresenceStatus(value: unknown): value is KeeperPresenceStatus {
  return typeof value === 'string' && VALID_STATUS.has(value)
}
