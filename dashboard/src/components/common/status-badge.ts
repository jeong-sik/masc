// Status indicator badge — reusable across agent/task/connection displays

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { statusLabel } from '../../lib/status-label'

type StatusBadgeTone = 'ok' | 'warn' | 'bad' | 'info' | 'neutral'

interface StatusBadgeProps {
  status?: string
  label?: string
  tone?: StatusBadgeTone
  children?: ComponentChildren
}

const DOT_CLASS: Record<StatusBadgeTone, string> = {
  ok: 'bg-[var(--color-status-ok)]',
  warn: 'bg-[var(--color-status-warn)]',
  bad: 'bg-[var(--color-status-err)]',
  info: 'bg-[var(--color-info-fg)]',
  neutral: 'bg-[var(--color-status-idle)]',
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
      return 'warn'
    case 'awaiting_verification':
    case 'interrupted':
    case 'listening':
      return 'info'
    case 'inactive':
    case 'offline':
    case 'stopped':
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

export function StatusBadge({ status, label, tone, children }: StatusBadgeProps) {
  const resolvedTone = tone ?? (status != null ? statusBadgeTone(status) : 'neutral')
  const statusClass = status ?? resolvedTone
  const content = children ?? label ?? (status != null ? statusLabel(status) : '')
  return html`
    <span
      class="status-badge border border-solid border-[var(--color-border-default)] ${statusClass} ${status === 'offline' ? 'text-[var(--color-fg-disabled)]' : ''}"
      data-status-badge-tone=${resolvedTone}
    >
      <span class="size-1.5 rounded-sm inline-block ${DOT_CLASS[resolvedTone]}"></span>
      ${content}
    </span>
  `
}
