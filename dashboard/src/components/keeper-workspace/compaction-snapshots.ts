// MASC v2 — compaction snapshot log for keeper context compactions.
//
// SSE/manual events are optimistic live updates. The durable backend endpoint
// (`/api/v1/keepers/:name/compaction-snapshots`) hydrates historical runtime
// manifest / keeper-meta events after opening the inspector. It still does not
// expose raw prompt text or kept/summarized/dropped message lists, so the drawer
// renders those as explicit data gaps.

import { signal, type Signal } from '@preact/signals'
import type { KeeperCompactionSnapshot as BackendCompactionSnapshot } from '../../api/dashboard'
import type { KeeperCompactionReinjectionObservation } from '../../api/dashboard-turn-records'

export interface CompactionSnapshotNumbers {
  readonly tok: number | null
  readonly msgs?: number | null
  readonly traces?: number | null
  readonly bytes?: number | null
  readonly toolUses?: number | null
  readonly toolResults?: number | null
}

export interface CompactionSnapshot {
  readonly id: string
  readonly at: string
  readonly atIso?: string | null
  readonly trigger: string
  readonly runtime: string
  readonly before: CompactionSnapshotNumbers
  readonly after: CompactionSnapshotNumbers
  readonly savedTokens?: number | null
  readonly traceId?: string | null
  readonly keeperTurnId?: number | null
  readonly status?: string | null
  readonly detailSource?: string | null
  readonly summarizedCount?: number | null
  readonly droppedCount?: number | null
  readonly reinjection?: KeeperCompactionReinjectionObservation
  readonly kept: readonly string[]
  readonly summarized: readonly string[]
  readonly dropped: readonly string[]
  readonly source: 'manual' | 'sse' | 'backend'
}

type PerKeeperSnapshots = Record<string, CompactionSnapshot[]>

export const compactionSnapshots: Signal<PerKeeperSnapshots> = signal({})

let fallbackIdSeq = 0

function formatHmUTC(d: Date): string {
  return `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}Z`
}

function hmLabel(d: Date): string {
  return formatHmUTC(d)
}

function nextId(prefix: string): string {
  const uuid = globalThis.crypto?.randomUUID?.()
  if (uuid) return `${prefix}_${uuid}`
  fallbackIdSeq = (fallbackIdSeq + 1) % Number.MAX_SAFE_INTEGER
  return `${prefix}_${Date.now().toString(36)}_${fallbackIdSeq.toString(36)}`
}

function finiteNumberOrNull(value: number | null | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

export function pushCompactionSnapshot(
  keeperName: string,
  snapshot: Omit<CompactionSnapshot, 'id' | 'at'>,
): void {
  const now = new Date()
  const next: CompactionSnapshot = {
    ...snapshot,
    id: nextId(snapshot.source === 'manual' ? 'cmp-m' : 'cmp-s'),
    at: hmLabel(now),
    atIso: snapshot.atIso ?? now.toISOString(),
  }
  compactionSnapshots.value = {
    ...compactionSnapshots.value,
    [keeperName]: [next, ...(compactionSnapshots.value[keeperName] ?? [])],
  }
}

function labelFromIso(iso: string): string {
  const ts = Date.parse(iso)
  if (!Number.isFinite(ts)) return iso
  return formatHmUTC(new Date(ts))
}

function backendSnapshotToLocal(snapshot: BackendCompactionSnapshot): CompactionSnapshot {
  const evidence = snapshot.exact_evidence
  return {
    id: snapshot.id,
    at: labelFromIso(snapshot.ts_iso),
    atIso: snapshot.ts_iso,
    trigger: snapshot.trigger,
    runtime: snapshot.display_runtime,
    before: {
      tok: finiteNumberOrNull(snapshot.before_tokens),
      msgs: evidence?.before_message_count ?? null,
      bytes: evidence?.before_checkpoint_bytes ?? null,
      toolUses: evidence?.before_tool_use_count ?? null,
      toolResults: evidence?.before_tool_result_count ?? null,
    },
    after: {
      tok: finiteNumberOrNull(snapshot.after_tokens),
      msgs: evidence?.after_message_count ?? null,
      bytes: evidence?.after_checkpoint_bytes ?? null,
      toolUses: evidence?.after_tool_use_count ?? null,
      toolResults: evidence?.after_tool_result_count ?? null,
    },
    savedTokens: finiteNumberOrNull(snapshot.saved_tokens),
    traceId: snapshot.trace_id,
    keeperTurnId: snapshot.keeper_turn_id,
    status: snapshot.status,
    detailSource: snapshot.source,
    summarizedCount: evidence?.summarized_message_count ?? null,
    droppedCount: evidence?.dropped_message_count ?? null,
    reinjection: snapshot.reinjection_observation,
    kept: [],
    summarized: [],
    dropped: [],
    source: 'backend',
  }
}

function snapshotSortKey(snapshot: CompactionSnapshot): number {
  if (snapshot.atIso) {
    const parsed = Date.parse(snapshot.atIso)
    if (Number.isFinite(parsed)) return parsed
  }
  return 0
}

function snapshotSourceRank(snapshot: CompactionSnapshot): number {
  if (snapshot.source === 'backend') return 2
  if (snapshot.source === 'sse') return 1
  return 0
}

function compareCompactionSnapshots(a: CompactionSnapshot, b: CompactionSnapshot): number {
  const byTime = snapshotSortKey(b) - snapshotSortKey(a)
  if (byTime !== 0) return byTime
  const bySource = snapshotSourceRank(b) - snapshotSourceRank(a)
  if (bySource !== 0) return bySource
  return b.id.localeCompare(a.id)
}

export function hydrateCompactionSnapshots(
  keeperName: string,
  snapshots: readonly BackendCompactionSnapshot[],
): CompactionSnapshot[] {
  const existing = compactionSnapshots.value[keeperName] ?? []
  const optimistic = existing.filter(snapshot => snapshot.source !== 'backend')
  const byId = new Map<string, CompactionSnapshot>()
  for (const snapshot of snapshots.map(backendSnapshotToLocal)) byId.set(snapshot.id, snapshot)
  for (const snapshot of optimistic) {
    if (!byId.has(snapshot.id)) byId.set(snapshot.id, snapshot)
  }
  const next = [...byId.values()].sort(compareCompactionSnapshots)
  compactionSnapshots.value = {
    ...compactionSnapshots.value,
    [keeperName]: next,
  }
  return next
}

export function recordManualCompaction(
  keeperName: string,
  beforeTokens: number | null | undefined,
  afterTokens: number | null | undefined,
  runtime: string,
): void {
  const before = finiteNumberOrNull(beforeTokens)
  const after = finiteNumberOrNull(afterTokens)
  pushCompactionSnapshot(keeperName, {
    trigger: '수동 — operator 요청 (지금 컴팩트)',
    runtime: runtime || '—',
    before: { tok: before },
    after: { tok: after },
    kept: [],
    summarized: [],
    dropped: [],
    source: 'manual',
  })
}

export function recordSseCompaction(
  keeperName: string,
  beforeTokens: number | null | undefined,
  afterTokens: number | null | undefined,
  trigger: string,
  runtime: string,
): void {
  const before = finiteNumberOrNull(beforeTokens)
  const after = finiteNumberOrNull(afterTokens)
  pushCompactionSnapshot(keeperName, {
    trigger: trigger || '자동 — SSE context_compacted',
    runtime: runtime || '—',
    before: { tok: before },
    after: { tok: after },
    kept: [],
    summarized: [],
    dropped: [],
    source: 'sse',
  })
}

export function keeperCompactionSnapshots(keeperName: string): CompactionSnapshot[] {
  return compactionSnapshots.value[keeperName] ?? []
}
