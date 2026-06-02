// PersistenceStatus — persistence-state indicator atom (sec03 3.2.1).
//
// Maps CRDT-style sync states to a dot + icon + label row.
// Composes StatusDot so color semantics stay consistent with the rest
// of the dashboard.

import { html } from 'htm/preact'
import { formatRelativeAgeMs, normalizeTimestampMs } from '../../lib/format-time'
import { StatusDot } from './status-dot'

export type PersistenceState = 'saved' | 'syncing' | 'conflict' | 'offline'
export type PersistenceFreshness = 'fresh' | 'recent' | 'stale' | 'unknown'
export type PersistenceSeverity = 'ok' | 'busy' | 'attention' | 'offline'

export interface PersistenceStateConfig {
  toneClass: string
  icon: string
  label: string
  severity: PersistenceSeverity
}

const CONFIG: Record<PersistenceState, PersistenceStateConfig> = {
  saved:   { toneClass: 'bg-[var(--ok-20)]', icon: '✓', label: '저장됨', severity: 'ok' },
  syncing: { toneClass: 'bg-[var(--warn-20)]', icon: '↻', label: '동기화 중', severity: 'busy' },
  conflict:{ toneClass: 'bg-[var(--bad-20)]', icon: '!', label: '충돌', severity: 'attention' },
  offline: { toneClass: 'bg-[var(--accent-30)]', icon: '○', label: '오프라인', severity: 'offline' },
}

const FRESH_MS = 5 * 60 * 1000
const RECENT_MS = 60 * 60 * 1000

const FRESHNESS_LABEL: Record<PersistenceFreshness, string> = {
  fresh: '최신',
  recent: '최근',
  stale: '오래됨',
  unknown: '시간 정보 없음',
}

const FRESHNESS_CLASS: Record<PersistenceFreshness, string> = {
  fresh: 'text-[var(--color-status-ok)]',
  recent: 'text-[var(--color-fg-muted)]',
  stale: 'text-[var(--color-status-warn)]',
  unknown: 'text-[var(--color-fg-disabled)]',
}

export interface PersistenceStatusSummary {
  readonly status: PersistenceState
  readonly label: string
  readonly severity: PersistenceSeverity
  readonly freshness: PersistenceFreshness
  readonly actionRequired: boolean
  readonly lastSavedIso: string | null
  readonly ageMs: number | null
}

interface PersistenceStatusProps {
  status: PersistenceState
  lastSaved?: string | null
  now?: string | number | Date
  testId?: string
}

export function getPersistenceStatusConfig(status: PersistenceState): PersistenceStateConfig {
  return CONFIG[status]
}

function timestampMs(value?: string | null): number | null {
  if (!value) return null
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? null : parsed
}

function normalizeUnixMs(value: number): number {
  if (!Number.isFinite(value)) return Date.now()
  return normalizeTimestampMs(value)
}

function nowMs(value: string | number | Date | undefined): number {
  if (value instanceof Date) return value.getTime()
  if (typeof value === 'number') return normalizeUnixMs(value)
  if (typeof value === 'string') {
    const parsed = Date.parse(value)
    return Number.isNaN(parsed) ? Date.now() : parsed
  }
  return Date.now()
}

export function classifyPersistenceFreshness(
  lastSaved?: string | null,
  now?: string | number | Date,
): { freshness: PersistenceFreshness; ageMs: number | null; lastSavedIso: string | null } {
  const savedMs = timestampMs(lastSaved)
  if (savedMs === null) {
    return { freshness: 'unknown', ageMs: null, lastSavedIso: null }
  }

  const ageMs = Math.max(0, nowMs(now) - savedMs)
  if (ageMs <= FRESH_MS) {
    return { freshness: 'fresh', ageMs, lastSavedIso: new Date(savedMs).toISOString() }
  }
  if (ageMs <= RECENT_MS) {
    return { freshness: 'recent', ageMs, lastSavedIso: new Date(savedMs).toISOString() }
  }
  return { freshness: 'stale', ageMs, lastSavedIso: new Date(savedMs).toISOString() }
}

export function summarizePersistenceStatus(
  status: PersistenceState,
  lastSaved?: string | null,
  now?: string | number | Date,
): PersistenceStatusSummary {
  const cfg = getPersistenceStatusConfig(status)
  const freshness = classifyPersistenceFreshness(lastSaved, now)

  return {
    status,
    label: cfg.label,
    severity: cfg.severity,
    freshness: freshness.freshness,
    actionRequired: status === 'conflict' || status === 'offline',
    lastSavedIso: freshness.lastSavedIso,
    ageMs: freshness.ageMs,
  }
}

export function PersistenceStatus({
  status,
  lastSaved,
  now,
  testId,
}: PersistenceStatusProps) {
  const cfg = getPersistenceStatusConfig(status)
  const summary = summarizePersistenceStatus(status, lastSaved, now)
  const timeText =
    summary.lastSavedIso && summary.ageMs !== null
      ? formatRelativeAgeMs(summary.ageMs)
      : null
  const freshnessLabel = FRESHNESS_LABEL[summary.freshness]

  return html`
    <div
      class="inline-flex items-center gap-1.5 text-xs"
      data-persistence-status
      data-persistence-state=${summary.status}
      data-persistence-severity=${summary.severity}
      data-persistence-freshness=${summary.freshness}
      data-persistence-action-required=${summary.actionRequired ? 'true' : 'false'}
      data-persistence-last-saved=${summary.lastSavedIso ?? undefined}
      data-persistence-age-ms=${summary.ageMs === null ? undefined : Math.round(summary.ageMs)}
      data-testid=${testId}
      role="status"
      aria-live="polite"
      aria-busy=${status === 'syncing' ? 'true' : undefined}
      aria-label="${cfg.label}${timeText ? ' · ' + timeText : ''} · ${freshnessLabel}"
    >
      <${StatusDot}
        size="sm"
        class=${cfg.toneClass}
      />
      <span class="text-[var(--color-fg-muted)]" aria-hidden="true">${cfg.icon}</span>
      <span class="text-[var(--color-fg-muted)]">${cfg.label}</span>
      ${timeText
        ? html`<time
            class="ml-1 text-[var(--color-fg-muted)]"
            datetime=${summary.lastSavedIso ?? undefined}
            data-persistence-time
          >${timeText}</time>`
        : null}
      ${summary.freshness === 'unknown'
        ? null
        : html`<span
            class=${`text-3xs ${FRESHNESS_CLASS[summary.freshness]}`}
            data-persistence-freshness-label
          >${freshnessLabel}</span>`}
    </div>
  `
}
