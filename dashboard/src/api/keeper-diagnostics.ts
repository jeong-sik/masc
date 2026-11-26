/**
 * Shared Keeper diagnostic decoders and formatters (SSOT across Pulse, Keepers, and Work).
 */

import { observedAbsent, observedValue, type Observed } from '../core/resource-cache'
import { isRecord } from '../lib/type-guards'

export interface SharedKeeperPathRest {
  readonly status: 'serving' | 'resting'
  readonly runtime_id: string | null
  readonly release_at: string | null
  readonly release_basis: string | null
}

export interface SharedKeeperLaneFailure {
  readonly runtime_id: string | null
  readonly summary: string
  readonly fault_kind: string | null
  readonly attempt: number | null
  readonly dispatch: string | null
  readonly failure_kind: string | null
  readonly failure_detail: string | null
  readonly provider: string | null
  readonly network_kind: string | null
}

function asStr(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

function asNum(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function formatUnixOrIso(v: unknown): string | null {
  const s = asStr(v)
  if (s) return s
  const n = asNum(v)
  if (n === null) return null
  const ms = n < 1_000_000_000_000 ? n * 1000 : n
  const d = new Date(ms)
  return Number.isNaN(d.getTime()) ? null : d.toISOString()
}

export function decodeKeeperPathRest(raw: unknown): SharedKeeperPathRest | null {
  if (!isRecord(raw)) return null
  const st = asStr(raw.status)?.toLowerCase()
  if (st !== 'serving' && st !== 'resting') return null
  return {
    status: st,
    runtime_id: asStr(raw.runtime_id),
    release_at: formatUnixOrIso(raw.release_at) ?? formatUnixOrIso(raw.release_at_unix),
    release_basis: asStr(raw.release_basis),
  }
}

export function decodeSingleKeeperLaneFailure(row: unknown): SharedKeeperLaneFailure | null {
  if (!isRecord(row)) return null
  const failureCause = isRecord(row.failure) && isRecord(row.failure.cause) ? row.failure.cause : null
  const summary = asStr(row.summary)
    ?? (failureCause ? asStr(failureCause.detail) : null)
    ?? asStr(row.detail)
  if (!summary) return null
  const faultKind = isRecord(row.api_candidate_fault)
    ? asStr(row.api_candidate_fault.fact) ?? asStr(row.api_candidate_fault.kind)
    : failureCause
      ? asStr(failureCause.kind)
      : null
  return {
    runtime_id: asStr(row.runtime_id),
    summary,
    fault_kind: faultKind,
    attempt: typeof row.attempt === 'number' && Number.isFinite(row.attempt) ? Math.trunc(row.attempt) : null,
    dispatch: asStr(row.dispatch),
    failure_kind: failureCause ? asStr(failureCause.kind) : null,
    failure_detail: failureCause ? asStr(failureCause.detail) : null,
    provider: failureCause ? asStr(failureCause.provider) : null,
    network_kind: failureCause ? asStr(failureCause.network_kind) : null,
  }
}

export function decodeKeeperLaneFailures(raw: unknown): readonly SharedKeeperLaneFailure[] {
  if (!isRecord(raw)) return []
  const evidence = isRecord(raw.evidence) ? raw.evidence : raw
  const failuresRaw = Array.isArray(evidence.failures) ? evidence.failures : []
  const out: SharedKeeperLaneFailure[] = []
  for (const row of failuresRaw) {
    const parsed = decodeSingleKeeperLaneFailure(row)
    if (parsed) out.push(parsed)
  }
  if (isRecord(evidence.terminal) && asStr(evidence.terminal.kind) === 'candidate') {
    const term = decodeSingleKeeperLaneFailure(evidence.terminal)
    if (term && !out.some((f) => f.runtime_id === term.runtime_id && f.summary === term.summary)) {
      out.push(term)
    }
  }
  return out
}

/**
 * Exact decimal-string formatting for milli-Candle values (integers or fractional decayed milli strings).
 * Keeps integer strings exact beyond IEEE-754 MAX_SAFE_INTEGER and distinguishes `"0"` from absent (`"없음"`).
 */
export function formatMilliCandleObserved(raw: string | number | null | undefined): Observed<string> {
  if (raw === null || raw === undefined) return observedAbsent()
  let text: string
  if (typeof raw === 'number') {
    if (!Number.isFinite(raw)) return observedAbsent('invalid_milli')
    text = String(Math.round(raw))
  } else {
    const trimmed = raw.trim()
    if (/^-?\d+$/.test(trimmed)) {
      text = trimmed
    } else if (/^-?\d+\.\d+$/.test(trimmed)) {
      const parsed = Number(trimmed)
      if (!Number.isFinite(parsed)) return observedAbsent('invalid_milli')
      text = String(Math.round(parsed))
    } else {
      return observedAbsent('invalid_milli')
    }
  }
  const negative = text.startsWith('-')
  const digits = negative ? text.slice(1) : text
  const padded = digits.padStart(4, '0')
  const wholeRaw = padded.slice(0, padded.length - 3)
  const frac = padded.slice(padded.length - 3)
  const wholeFormatted = wholeRaw.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return observedValue(`${negative ? '-' : ''}${wholeFormatted}.${frac}`)
}

export type ContextSeverityTone = 'ok' | 'warn' | 'bad' | 'absent'

/** Canonical context-fill thresholds shared across Pulse, Keeper Header, and Keeper Chat. */
export function contextSeverityTone(pct: number | null): ContextSeverityTone {
  if (pct === null || !Number.isFinite(pct)) return 'absent'
  if (pct >= 85) return 'bad'
  if (pct >= 65) return 'warn'
  return 'ok'
}

export function isKeeperHealthFailing(k: {
  readonly directory_issue?: string | null
  readonly runtime_blocker_summary?: string | null
  readonly health: string
  readonly status?: string | null
}): boolean {
  if (k.directory_issue || k.runtime_blocker_summary) return true
  const h = k.health.toLowerCase()
  const s = (k.status ?? '').toLowerCase()
  return h === 'failing'
    || h === 'failed'
    || h === 'degraded'
    || h === 'error'
    || h === 'crashed'
    || s === 'error'
}
