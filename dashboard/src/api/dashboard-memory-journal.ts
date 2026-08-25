// MASC Dashboard — the librarian's own account of each pass.
//
// Route: GET /api/v1/keepers/:name/memory-journal
//
// The internal-agents monitor could already show that a librarian pass ran.
// This is what the pass decided: what it kept, what it dropped and why, or —
// for the case an operator actually opens — why it produced nothing.

import { get, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import { isRecord, asNumber, asString } from '../components/common/normalize'

export type MemoryJournalDrop = {
  readonly memoryId: string
  readonly reason: string
}

export type MemoryJournalFact = {
  readonly claim: string
  readonly category: string
  readonly firstSeen: number
}

export type MemoryJournalSourceKind = 'librarian' | 'explicit_write'

// A committed pass wrote a revision. A failed pass did not, so the two are
// separate members rather than one shape with nulls — a reader that has to
// check a null to tell them apart will eventually forget to.
export type MemoryJournalEntry =
  | {
      readonly ok: true
      readonly outcome: 'committed'
      readonly recordedAt: number
      readonly revision: number
      readonly traceId: string
      readonly sourceKind: MemoryJournalSourceKind
      readonly added: readonly MemoryJournalFact[]
      readonly removed: readonly MemoryJournalFact[]
      readonly retained: number
      readonly drops: readonly MemoryJournalDrop[]
    }
  | {
      readonly ok: true
      readonly outcome: 'failed'
      readonly recordedAt: number
      readonly traceId: string
      readonly kind: string
      readonly detail: string
      readonly snapshotPresent: boolean
      readonly cadenceDeferred: boolean
    }
  | { readonly ok: false; readonly error: string }

export type MemoryJournal = {
  readonly keeper: string
  readonly returned: number
  readonly undecodableLines: number
  readonly entries: readonly MemoryJournalEntry[]
}

function decodeDrop(raw: unknown): MemoryJournalDrop | null {
  if (!isRecord(raw)) return null
  const memoryId = asString(raw.memory_id)
  const reason = asString(raw.reason)
  return memoryId == null || reason == null ? null : { memoryId, reason }
}

function decodeFact(raw: unknown): MemoryJournalFact | null {
  if (!isRecord(raw)) return null
  const claim = asString(raw.claim)
  const category = asString(raw.category)
  const firstSeen = asNumber(raw.first_seen)
  return claim == null || category == null || firstSeen == null
    ? null
    : { claim, category, firstSeen }
}

function decodeFacts(raw: unknown): readonly MemoryJournalFact[] | null {
  if (!Array.isArray(raw)) return null
  const facts: MemoryJournalFact[] = []
  for (const item of raw) {
    const fact = decodeFact(item)
    if (fact === null) return null
    facts.push(fact)
  }
  return facts
}

function decodeCommitted(raw: Record<string, unknown>): MemoryJournalEntry | null {
  const recordedAt = asNumber(raw.recorded_at)
  const revision = asNumber(raw.revision)
  if (recordedAt == null || revision == null) return null
  if (!isRecord(raw.source) || !isRecord(raw.change)) return null
  const traceId = asString(raw.source.trace_id)
  const sourceKind = asString(raw.source.kind)
  const retained = asNumber(raw.change.retained)
  if (
    traceId == null
    || (sourceKind !== 'librarian' && sourceKind !== 'explicit_write')
    || retained == null
  ) return null
  const added = decodeFacts(raw.change.added)
  const removed = decodeFacts(raw.change.removed)
  if (added === null || removed === null) return null
  const drops: MemoryJournalDrop[] = []
  if (raw.dropped !== undefined) {
    if (!Array.isArray(raw.dropped)) return null
    for (const item of raw.dropped) {
      const drop = decodeDrop(item)
      // The librarian's drop reasons ride this line and nothing else stores
      // them. Skipping one loses it for good.
      if (drop === null) return null
      drops.push(drop)
    }
  }
  return {
    ok: true,
    outcome: 'committed',
    recordedAt,
    revision,
    traceId,
    sourceKind,
    added,
    removed,
    retained,
    drops,
  }
}

function decodeFailed(raw: Record<string, unknown>): MemoryJournalEntry | null {
  const recordedAt = asNumber(raw.recorded_at)
  const traceId = asString(raw.trace_id)
  const kind = asString(raw.kind)
  const detail = asString(raw.detail)
  const snapshotPresent = typeof raw.snapshot_present === 'boolean' ? raw.snapshot_present : null
  const cadenceDeferred = typeof raw.cadence_deferred === 'boolean' ? raw.cadence_deferred : null
  if (recordedAt == null || traceId == null || kind == null || detail == null) return null
  if (snapshotPresent === null || cadenceDeferred === null) return null
  return {
    ok: true,
    outcome: 'failed',
    recordedAt,
    traceId,
    kind,
    detail,
    snapshotPresent,
    cadenceDeferred,
  }
}

function decodeEntry(raw: unknown): MemoryJournalEntry | null {
  if (!isRecord(raw)) return null
  if (raw.ok === false) {
    const error = asString(raw.error)
    return error == null ? null : { ok: false, error }
  }
  if (raw.ok !== true) return null
  switch (raw.outcome) {
    case 'committed':
      return decodeCommitted(raw)
    case 'failed':
      return decodeFailed(raw)
    default:
      // An outcome this build does not know came from a wider one. Rendering
      // it as something else would describe a pass that never happened.
      return null
  }
}

export async function fetchKeeperMemoryJournal(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<MemoryJournal> {
  await ensureDevToken()
  const params = limit == null ? '' : `?limit=${encodeURIComponent(String(limit))}`
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/memory-journal${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    if (!isRecord(raw) || !Array.isArray(raw.entries)) {
      throw new Error('유효하지 않은 memory journal payload')
    }
    const keeper = asString(raw.keeper)
    const returned = asNumber(raw.returned)
    const undecodableLines = asNumber(raw.undecodable_lines)
    if (keeper == null || returned == null || undecodableLines == null) {
      throw new Error('유효하지 않은 memory journal payload')
    }
    const entries: MemoryJournalEntry[] = []
    for (const item of raw.entries) {
      const entry = decodeEntry(item)
      if (entry === null) throw new Error('유효하지 않은 memory journal payload')
      entries.push(entry)
    }
    return { keeper, returned, undecodableLines, entries }
  })
}
