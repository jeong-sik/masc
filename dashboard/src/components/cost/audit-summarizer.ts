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
