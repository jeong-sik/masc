// Status indicator badge — reusable across agent/task/connection displays

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { statusLabel } from '../../lib/status-label'
import { PHASE_TONE, type FleetTone, type KeeperPhaseToken } from '../../lib/fleet-tone'

// Exported so a caller mapping its own closed status vocabulary onto these
// tones names this type instead of restating the union — one definition of the
// tone set, not one per panel.
export type StatusBadgeTone = 'ok' | 'warn' | 'bad' | 'info' | 'neutral'

interface StatusBadgeProps {
  status?: string
  label?: string
  tone?: StatusBadgeTone
  children?: ComponentChildren
}

const DOT_CLASS: Record<StatusBadgeTone, string> = {
  ok: 'bg-success',
  warn: 'bg-warning',
  bad: 'bg-destructive',
  info: 'bg-info',
  neutral: 'bg-text-disabled',
}

export function statusBadgeTone(status: string): StatusBadgeTone {
  const normalized = status.trim().toLowerCase().replace(/-/g, '_')
  switch (normalized) {
    case 'ok':
      return 'ok'
    case 'warn':
      return 'warn'
    case 'bad':
      return 'bad'
    case 'info':
      return 'info'
    case 'neutral':
      return 'neutral'
    case 'in_progress':
    case 'claimed':
    case 'running':
    case 'paused':
      return 'warn'
    case 'awaiting_verification':
    case 'interrupted':
    case 'listening':
      return 'info'
    case 'inactive':
    case 'offline':
    case 'stopped':
    case 'cancelled':
    case 'todo':
      return 'neutral'
    case 'active':
    case 'done':
    case 'completed':
      return 'ok'
    case 'busy':
      return 'warn'
    case 'error':
    case 'failed':
      return 'bad'
    default:
      return 'neutral'
  }
}

export function statusDotColor(status: string): string {
  return DOT_CLASS[statusBadgeTone(status)]
}

/** Keeper tone → badge tone.
 *
 *  `statusBadgeTone` above answers for task-shaped statuses. Most keeper
 *  phase tokens have no arm there and hit its `default: neutral`, so a
 *  `crashed` or `dead` keeper rendered grey in this badge while the fleet
 *  panel painted it red from `PHASE_TONE`; `running` rendered `warn`
 *  (orange) here and `ok` (green) there. Keeper surfaces route their token
 *  through this map instead of relying on the string switch.
 *
 *  `busy → info` rather than `warn`: a transitional phase (handoff /
 *  restarting) is progress, not an operator warning. `idle` is
 *  the fleet tone for stopped/unbooted, so it maps to `neutral`. */
const FLEET_TONE_TO_BADGE_TONE: Readonly<Record<FleetTone, StatusBadgeTone>> = {
  ok: 'ok',
  warn: 'warn',
  bad: 'bad',
  busy: 'info',
  idle: 'neutral',
}

export function statusBadgeToneForKeeper(token: KeeperPhaseToken): StatusBadgeTone {
  return FLEET_TONE_TO_BADGE_TONE[PHASE_TONE[token]]
}

export function StatusBadge({ status, label, tone, children }: StatusBadgeProps) {
  const resolvedTone = tone ?? (status != null ? statusBadgeTone(status) : 'neutral')
  const normalizedStatus = status?.trim().toLowerCase().replace(/_/g, '-')
  const content = children ?? label ?? (status != null ? statusLabel(status) : '')
  if (content == null || content === '') return null
  return html`
    <span
      class="status-badge ${resolvedTone}"
      data-status-badge-tone=${resolvedTone}
      data-status-badge-status=${normalizedStatus}
    >
      <span class="size-1.5 rounded-[var(--r-0)] inline-block ${DOT_CLASS[resolvedTone]}"></span>
      ${content}
    </span>
  `
}
