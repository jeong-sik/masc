// Status indicator badge — reusable across agent/task/connection displays

import { html } from 'htm/preact'
import { statusLabel } from '../../lib/status-label'

interface StatusBadgeProps {
  status: string
  label?: string
}

export function statusDotColor(status: string): string {
  switch (status) {
    case 'in_progress':
    case 'running':
      return 'bg-[var(--warn)]'
    case 'awaiting_verification':
      return 'bg-[var(--accent)]'
    case 'interrupted':
    case 'listening':
      return 'bg-[var(--accent)]'
    case 'inactive':
    case 'offline':
      return 'bg-[#5f7199]'
    case 'active':
      return 'bg-[var(--ok)]'
    case 'busy':
    case 'stopped':
      return 'bg-[var(--text-slate)]'
    case 'error':
      return 'bg-[var(--bad)]'
    default:
      return 'bg-[var(--text-muted)]'
  }
}

export function StatusBadge({ status, label }: StatusBadgeProps) {
  return html`
    <span class="border border-solid border-[var(--card-border)] ${status} ${status === 'offline' ? 'text-[var(--text-dim)]' : ''}">
      <span class="size-1.5 rounded-sm inline-block ${statusDotColor(status)}" aria-hidden="true"></span>
      ${label ?? statusLabel(status)}
    </span>
  `
}
