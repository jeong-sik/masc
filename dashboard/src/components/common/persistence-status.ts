// PersistenceStatus — persistence-state indicator atom (sec03 3.2.1).
//
// Maps CRDT-style sync states to a dot + icon + label row.
// Composes StatusDot so color semantics stay consistent with the rest
// of the dashboard.

import { html } from 'htm/preact'
import { StatusDot } from './status-dot'
import { relativeTime } from '../../lib/format-time'

export type PersistenceState = 'saved' | 'syncing' | 'conflict' | 'offline'

interface StateConfig {
  toneClass: string
  icon: string
  label: string
}

const CONFIG: Record<PersistenceState, StateConfig> = {
  saved:   { toneClass: 'bg-[var(--ok-20)]', icon: '✓', label: '저장됨' },
  syncing: { toneClass: 'bg-[var(--warn-20)]', icon: '↻', label: '동기화 중' },
  conflict:{ toneClass: 'bg-[var(--bad-20)]', icon: '!', label: '충돌' },
  offline: { toneClass: 'bg-[var(--accent-30)]', icon: '○', label: '오프라인' },
}

interface PersistenceStatusProps {
  status: PersistenceState
  lastSaved?: string | null
  testId?: string
}

export function PersistenceStatus({
  status,
  lastSaved,
  testId,
}: PersistenceStatusProps) {
  const cfg = CONFIG[status]
  const timeText = lastSaved ? relativeTime(lastSaved) : null

  return html`
    <div
      class="inline-flex items-center gap-1.5 text-xs"
      data-testid=${testId}
      role="status"
      aria-live="polite"
      aria-label="${cfg.label}${timeText ? ' · ' + timeText : ''}"
    >
      <${StatusDot}
        size="sm"
        class=${cfg.toneClass}
        ariaLabel=${cfg.label}
      />
      <span class="text-[var(--color-fg-muted)]">${cfg.icon}</span>
      <span class="text-[var(--color-fg-muted)]">${cfg.label}</span>
      ${timeText
        ? html`<span class="text-[var(--color-fg-muted)] ml-1">${timeText}</span>`
        : null}
    </div>
  `
}
