// EmptyState / LoadingState — consistent feedback messages
// Replaces 107 empty-state + 14 loading-state inline patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface EmptyStateProps {
  class?: string
  children: ComponentChildren
}

/** Empty state message — centered, muted text */
export function EmptyState({ class: cx, children }: EmptyStateProps) {
  return html`
    <div class="text-center py-6 text-[13px] text-[var(--text-muted)] ${cx ?? ''}">${children}</div>
  `
}

interface LoadingStateProps {
  class?: string
  children?: ComponentChildren
}

/** Loading indicator with pulse animation */
export function LoadingState({ class: cx, children }: LoadingStateProps) {
  return html`
    <div class="text-center py-6 text-[13px] text-[var(--text-muted)] animate-pulse ${cx ?? ''}">
      ${children ?? '불러오는 중...'}
    </div>
  `
}

/** Error state — red tinted */
export function ErrorState({ class: cx, children }: { class?: string; children: ComponentChildren }) {
  return html`
    <div class="text-center py-6 text-[13px] text-[var(--bad)] ${cx ?? ''}">${children}</div>
  `
}
