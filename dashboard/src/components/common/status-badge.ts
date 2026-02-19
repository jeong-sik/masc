// Status indicator badge — reusable across agent/task/connection displays

import { html } from 'htm/preact'

interface StatusBadgeProps {
  status: string
  label?: string
}

export function StatusBadge({ status, label }: StatusBadgeProps) {
  return html`
    <span class="status-badge ${status}">
      <span class="status-dot-inline ${status}"></span>
      ${label ?? status}
    </span>
  `
}
