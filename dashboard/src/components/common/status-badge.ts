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
      return 'bg-[var(--color-status-warn)]'
    case 'awaiting_verification':
      return 'bg-[var(--color-accent-fg)]'
    case 'interrupted':
    case 'listening':
      return 'bg-[var(--color-accent-fg)]'
    case 'inactive':
    case 'offline':
      return 'bg-[#5f7199]'
    case 'active':
      return 'bg-[var(--color-status-ok)]'
    case 'busy':
    case 'stopped':
      return 'bg-[var(--text-slate)]'
    case 'error':
      return 'bg-[var(--color-status-err)]'
    default:
      return 'bg-[var(--color-fg-muted)]'
  }
}

export function StatusBadge({ status, label }: StatusBadgeProps) {
  return html`
    <span class="border border-solid border-[var(--color-border-default)] ${status} ${status === 'offline' ? 'text-[var(--color-fg-disabled)]' : ''}">
      <span class="size-1.5 rounded-sm inline-block ${statusDotColor(status)}"></span>
      ${label ?? statusLabel(status)}
    </span>
  `
}
