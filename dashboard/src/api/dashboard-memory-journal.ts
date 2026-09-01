// MASC Dashboard — the librarian's own account of each pass.
//
// Route: GET /api/v1/keepers/:name/memory-journal
//
// The internal-agents monitor could already show that a librarian pass ran.
// This is what the pass decided: what it kept, what it dropped and why, or —
// for the case an operator actually opens — why it produced nothing.

import { get, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import { isRecord, asNumber } from '../components/common/normalize'
import {
  decodeMemoryOsBasis,
  isMemoryOsMemoryId,
  parseMemoryOsFactCategory,
  type MemoryOsFactBasis,
  type MemoryOsFactCategoryTag,
} from './dashboard-turn-records'

function hasExactKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(raw)
  return keys.length === allowed.length && keys.every(key => allowed.includes(key))
}

function exactNonEmptyString(raw: unknown): string | null {
  return typeof raw === 'string' && raw.trim().length > 0 ? raw : null
}

export type MemoryJournalDrop = {
  readonly memoryId: string
  readonly reason: string
}

export type MemoryJournalFact = {
  readonly claim: string
  readonly category: MemoryOsFactCategoryTag
  readonly firstSeen: number
  readonly lastSeen: number
  readonly reinforcement: number
  readonly origin: {
    readonly kind: 'authored' | 'injected'
    readonly traceId: string
  }
  readonly basis: MemoryOsFactBasis
}

export type MemoryJournalSupportInvalidation = {
  readonly fact: MemoryJournalFact
  readonly missingPremiseIds: readonly string[]
}

export type MemoryJournalSourceKind = 'librarian' | 'explicit_write' | 'explicit_retract'

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
      readonly invalidated: readonly MemoryJournalSupportInvalidation[]
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
  readonly dashboardSurface: '/api/v1/keepers/:name/memory-journal'
  readonly returned: number
  readonly undecodableLines: number
  readonly entries: readonly MemoryJournalEntry[]
}

function decodeDrop(raw: unknown): MemoryJournalDrop | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['memory_id', 'reason'])) return null
  const memoryId = exactNonEmptyString(raw.memory_id)
  const reason = exactNonEmptyString(raw.reason)
  return memoryId == null || !isMemoryOsMemoryId(memoryId) || reason == null
    ? null
    : { memoryId, reason }
}

function decodeFact(raw: unknown): MemoryJournalFact | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'claim',
    'category',
    'first_seen',
    'last_seen',
    'reinforcement',
    'origin',
    'basis',
  ])) return null
  const claim = exactNonEmptyString(raw.claim)
  const category = typeof raw.category === 'string'
    ? parseMemoryOsFactCategory(raw.category)?.tag ?? null
    : null
  const firstSeen = asNumber(raw.first_seen)
  const lastSeen = asNumber(raw.last_seen)
  const reinforcement = asNumber(raw.reinforcement)
  const basis = decodeMemoryOsBasis(raw.basis)
  const origin = isRecord(raw.origin) && hasExactKeys(raw.origin, ['kind', 'trace_id'])
    ? raw.origin
    : null
  const originKind = origin?.kind === 'authored' || origin?.kind === 'injected'
    ? origin.kind
    : null
  const traceId = origin != null && typeof origin.trace_id === 'string'
    ? origin.trace_id
    : null
  return claim == null
    || category == null
    || firstSeen == null
    || lastSeen == null
    || reinforcement == null
    || !Number.isSafeInteger(reinforcement)
    || reinforcement < 0
    || originKind == null
    || traceId == null
    || basis == null
    ? null
    : {
        claim,
        category,
        firstSeen,
        lastSeen,
        reinforcement,
        origin: { kind: originKind, traceId },
        basis,
      }
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

function decodeSupportInvalidations(
  raw: unknown,
): readonly MemoryJournalSupportInvalidation[] | null {
  if (!Array.isArray(raw)) return null
  const invalidated: MemoryJournalSupportInvalidation[] = []
  for (const item of raw) {
    if (!isRecord(item) || !hasExactKeys(item, ['fact', 'missing_premise_ids'])) return null
    const fact = decodeFact(item.fact)
    if (fact === null || fact.basis.kind !== 'derived' || !Array.isArray(item.missing_premise_ids)) {
      return null
    }
    const missingPremiseIds = item.missing_premise_ids
    if (
      missingPremiseIds.length === 0
      || !missingPremiseIds.every(isMemoryOsMemoryId)
      || new Set(missingPremiseIds).size !== missingPremiseIds.length
      || missingPremiseIds.some((value, index) => {
        const previous = missingPremiseIds[index - 1]
        return previous !== undefined && previous >= value
      })
    ) return null
    invalidated.push({ fact, missingPremiseIds })
  }
  return invalidated
}

function decodeCommitted(raw: Record<string, unknown>): MemoryJournalEntry | null {
  const allowed = ['ok', 'outcome', 'recorded_at', 'revision', 'source', 'change']
  const allowedWithDropped = [...allowed, 'dropped']
  if (!hasExactKeys(raw, raw.dropped === undefined ? allowed : allowedWithDropped)) return null
  const recordedAt = asNumber(raw.recorded_at)
  const revision = asNumber(raw.revision)
  if (
    recordedAt == null
    || revision == null
    || !Number.isSafeInteger(revision)
    || revision < 0
  ) return null
  if (!isRecord(raw.source) || !isRecord(raw.change)) return null
  if (!hasExactKeys(raw.source, ['kind', 'trace_id'])
    || !hasExactKeys(raw.change, ['added', 'removed', 'retained', 'invalidated'])) return null
  const traceId = exactNonEmptyString(raw.source.trace_id)
  const sourceKind = exactNonEmptyString(raw.source.kind)
  const retained = asNumber(raw.change.retained)
  if (
    traceId == null
    || (sourceKind !== 'librarian'
      && sourceKind !== 'explicit_write'
      && sourceKind !== 'explicit_retract')
    || retained == null
    || !Number.isSafeInteger(retained)
    || retained < 0
  ) return null
  const added = decodeFacts(raw.change.added)
  const removed = decodeFacts(raw.change.removed)
  const invalidated = decodeSupportInvalidations(raw.change.invalidated)
  if (added === null || removed === null || invalidated === null) return null
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
    invalidated,
    drops,
  }
}

function decodeFailed(raw: Record<string, unknown>): MemoryJournalEntry | null {
  if (!hasExactKeys(raw, [
    'ok',
    'outcome',
    'recorded_at',
    'trace_id',
    'kind',
    'detail',
    'snapshot_present',
    'cadence_deferred',
  ])) return null
  const recordedAt = asNumber(raw.recorded_at)
  const traceId = exactNonEmptyString(raw.trace_id)
  const kind = exactNonEmptyString(raw.kind)
  const detail = exactNonEmptyString(raw.detail)
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
    if (!hasExactKeys(raw, ['ok', 'error'])) return null
    const error = exactNonEmptyString(raw.error)
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
    if (!isRecord(raw)
      || !hasExactKeys(raw, [
        'keeper',
        'dashboard_surface',
        'returned',
        'undecodable_lines',
        'entries',
      ])
      || !Array.isArray(raw.entries)) {
      throw new Error('유효하지 않은 memory journal payload')
    }
    const keeper = exactNonEmptyString(raw.keeper)
    const dashboardSurface = raw.dashboard_surface === '/api/v1/keepers/:name/memory-journal'
      ? raw.dashboard_surface
      : null
    const returned = asNumber(raw.returned)
    const undecodableLines = asNumber(raw.undecodable_lines)
    if (
      keeper == null
      || dashboardSurface == null
      || returned == null
      || undecodableLines == null
      || !Number.isSafeInteger(returned)
      || returned < 0
      || !Number.isSafeInteger(undecodableLines)
      || undecodableLines < 0
      || undecodableLines > returned
    ) {
      throw new Error('유효하지 않은 memory journal payload')
    }
    const entries: MemoryJournalEntry[] = []
    for (const item of raw.entries) {
      const entry = decodeEntry(item)
      if (entry === null) throw new Error('유효하지 않은 memory journal payload')
      entries.push(entry)
    }
    if (returned !== entries.length) throw new Error('유효하지 않은 memory journal payload')
    return { keeper, dashboardSurface, returned, undecodableLines, entries }
  })
}
