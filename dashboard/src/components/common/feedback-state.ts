// EmptyState / LoadingState — consistent feedback messages
// Replaces 107 empty-state + 14 loading-state inline patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { Loader2 } from 'lucide-preact'

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

/** Loading indicator with spin animation */
export function LoadingState({ class: cx, children }: LoadingStateProps) {
  return html`
    <div class="flex flex-col items-center justify-center py-8 text-[13px] text-[var(--text-muted)] ${cx ?? ''}">
      <${Loader2} size=${24} class="animate-spin mb-3 opacity-60 text-accent" />
      <span class="animate-pulse">${children ?? '불러오는 중...'}</span>
    </div>
  `
}
