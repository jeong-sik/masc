// MASC v2 — lightweight client-side log of keeper context compactions.
//
// The backend exposes compaction results as discrete events (SSE
// `keeper_compaction` / `oas:context_compacted` and the manual
// `masc_keeper_compact` MCP response). It does not yet expose per-event
// kept/summarized/dropped lists or full before/after message/trace counts, so
// this store records what we *do* see and surfaces the rest as honest gaps.

import { signal, type Signal } from '@preact/signals'

export interface CompactionSnapshotNumbers {
  readonly tok: number
  readonly msgs?: number | null
  readonly traces?: number | null
}

export interface CompactionSnapshot {
  readonly id: string
  readonly at: string
  readonly trigger: string
  readonly runtime: string
  readonly before: CompactionSnapshotNumbers
  readonly after: CompactionSnapshotNumbers
  readonly kept: readonly string[]
  readonly summarized: readonly string[]
  readonly dropped: readonly string[]
  readonly source: 'manual' | 'sse'
}

type PerKeeperSnapshots = Record<string, CompactionSnapshot[]>

export const compactionSnapshots: Signal<PerKeeperSnapshots> = signal({})

function nowHM(): string {
  const d = new Date()
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function nextId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`
}

export function pushCompactionSnapshot(
  keeperName: string,
  snapshot: Omit<CompactionSnapshot, 'id' | 'at'>,
): void {
  const next: CompactionSnapshot = {
    ...snapshot,
    id: nextId(snapshot.source === 'manual' ? 'cmp-m' : 'cmp-s'),
    at: nowHM(),
  }
  compactionSnapshots.value = {
    ...compactionSnapshots.value,
    [keeperName]: [next, ...(compactionSnapshots.value[keeperName] ?? [])],
  }
}

export function recordManualCompaction(
  keeperName: string,
  beforeTokens: number | null | undefined,
  afterTokens: number | null | undefined,
  runtime: string,
): void {
  const before = typeof beforeTokens === 'number' && Number.isFinite(beforeTokens) ? beforeTokens : 0
  const after = typeof afterTokens === 'number' && Number.isFinite(afterTokens) ? afterTokens : 0
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
  const before = typeof beforeTokens === 'number' && Number.isFinite(beforeTokens) ? beforeTokens : 0
  const after = typeof afterTokens === 'number' && Number.isFinite(afterTokens) ? afterTokens : 0
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
