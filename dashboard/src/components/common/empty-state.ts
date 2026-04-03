// EmptyState — shared empty state component
// Replaces 100+ inline "empty-state" divs across the dashboard.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface EmptyStateProps {
  message: string
  icon?: string
  action?: ComponentChildren
  compact?: boolean
}

export function EmptyState({ message, icon, action, compact }: EmptyStateProps) {
  return html`
    <div class="feedback-panel feedback-panel-empty flex flex-col items-center justify-center gap-2 ${compact ? 'py-4' : 'py-8'} text-center">
      ${icon ? html`<span class="text-2xl opacity-40">${icon}</span>` : null}
      <span class="text-[length:var(--fs-sm)] text-[var(--text-muted)] leading-relaxed">${message}</span>
      ${action ?? null}
    </div>
  `
}
