// RFC-0050 PR-1 — extracted from cost-dashboard.ts.
// Pure audit-ledger aggregation. Depends only on the AuditEntry shape
// from the dashboard API. No signals, no render, no module-level state.

import type { AuditEntry } from '../../api/dashboard'

export interface AuditActorSummary {
  actor: string
  count: number
  error: number
  warn: number
  info: number
  latest: string
  topKind: string
}

export interface AuditKindSummary {
  kind: string
  count: number
  error: number
  warn: number
  info: number
  latest: string
}

export function severityBuckets(entries: readonly AuditEntry[]): { error: number; warn: number; info: number } {
  let error = 0
  let warn = 0
  for (const entry of entries) {
    if (entry.severity === 'error') error += 1
    else if (entry.severity === 'warn') warn += 1
  }
  return { error, warn, info: Math.max(0, entries.length - error - warn) }
}

function latestTs(entries: readonly AuditEntry[]): string {
  return entries.reduce((latest, entry) => entry.ts > latest ? entry.ts : latest, '')
}

function mostFrequentKind(entries: readonly AuditEntry[]): string {
  const counts = new Map<string, number>()
  for (const entry of entries) {
    const kind = entry.kind.trim() || '(unknown)'
    counts.set(kind, (counts.get(kind) ?? 0) + 1)
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0]?.[0] ?? '—'
}

export function summarizeAuditActors(entries: readonly AuditEntry[]): AuditActorSummary[] {
  const byActor = new Map<string, AuditEntry[]>()
  for (const entry of entries) {
    const actor = entry.actor.trim() || '(unknown)'
    const bucket = byActor.get(actor) ?? []
    bucket.push(entry)
    byActor.set(actor, bucket)
  }
  return [...byActor.entries()]
    .map(([actor, actorEntries]) => ({
      actor,
      count: actorEntries.length,
      ...severityBuckets(actorEntries),
      latest: latestTs(actorEntries),
      topKind: mostFrequentKind(actorEntries),
    }))
    .sort((a, b) => b.count - a.count || a.actor.localeCompare(b.actor))
}

export function summarizeAuditKinds(entries: readonly AuditEntry[]): AuditKindSummary[] {
  const byKind = new Map<string, AuditEntry[]>()
  for (const entry of entries) {
    const kind = entry.kind.trim() || '(unknown)'
    const bucket = byKind.get(kind) ?? []
    bucket.push(entry)
    byKind.set(kind, bucket)
  }
  return [...byKind.entries()]
    .map(([kind, kindEntries]) => ({
      kind,
      count: kindEntries.length,
      ...severityBuckets(kindEntries),
      latest: latestTs(kindEntries),
    }))
    .sort((a, b) => b.count - a.count || a.kind.localeCompare(b.kind))
}

export function auditEntryMatchesLogId(entry: AuditEntry, logId: string | null): boolean {
  const needle = normalizeLogNeedle(logId)
  if (!needle) return false
  // `entry.id` is a structured identifier so demand exact (case-insensitive)
  // equality — otherwise log id `turn-1` would also match `turn-10`.  For
  // human-facing free text (`target`, `summary`) and payload contents we
  // accept token-boundary matches so a sentence like `failed at turn-1`
  // still pins the row but `failed at turn-10` does not.
  return stringEqualsLogNeedle(entry.id, needle)
    || [entry.target, entry.summary].some(value => stringMatchesLogNeedleWithBoundary(value, needle))
    || payloadContainsLogNeedle(entry.payload, needle)
}

export function prioritizeAuditEntriesByLogId(entries: readonly AuditEntry[], logId: string | null): AuditEntry[] {
  const needle = normalizeLogNeedle(logId)
  if (!needle) return [...entries]
  const matched: AuditEntry[] = []
  const rest: AuditEntry[] = []
  for (const entry of entries) {
    if (auditEntryMatchesLogId(entry, needle)) matched.push(entry)
    else rest.push(entry)
  }
  return [...matched, ...rest]
}

function normalizeLogNeedle(value: string | null | undefined): string | null {
  const trimmed = value?.trim().toLowerCase()
  return trimmed ? trimmed : null
}

function stringEqualsLogNeedle(value: string | undefined, needle: string): boolean {
  return typeof value === 'string' && value.trim().toLowerCase() === needle
}

// Token boundary = anything that is not `[A-Za-z0-9_-]`.  Log ids commonly
// contain `-` so the canonical word boundary `\b` is too aggressive
// (`\bturn-1\b` would still match `turn-10` because `-` is a word boundary
// for `\b`).  We bracket the needle with explicit non-id-character
// boundaries (or start/end of string) instead.
const LOG_NEEDLE_ID_CHARS = /[A-Za-z0-9_-]/

function stringMatchesLogNeedleWithBoundary(value: string | undefined, needle: string): boolean {
  if (typeof value !== 'string') return false
  const haystack = value.toLowerCase()
  const idx = haystack.indexOf(needle)
  if (idx < 0) return false
  const before = idx === 0 ? '' : haystack[idx - 1]
  const after = idx + needle.length >= haystack.length ? '' : haystack[idx + needle.length]
  return !LOG_NEEDLE_ID_CHARS.test(before) && !LOG_NEEDLE_ID_CHARS.test(after)
}

function payloadContainsLogNeedle(value: unknown, needle: string, depth = 0): boolean {
  if (depth > 4 || value == null) return false
  if (typeof value === 'string') return stringEqualsLogNeedle(value, needle)
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value).toLowerCase() === needle
  }
  if (Array.isArray(value)) {
    return value.some(item => payloadContainsLogNeedle(item, needle, depth + 1))
  }
  if (typeof value === 'object') {
    return Object.entries(value).some(([key, item]) =>
      stringEqualsLogNeedle(key, needle) || payloadContainsLogNeedle(item, needle, depth + 1),
    )
  }
  return false
}
