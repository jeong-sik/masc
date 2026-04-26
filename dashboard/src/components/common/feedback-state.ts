// FeedbackState primitives — consistent empty/loading/error messages.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { AlertTriangle, Loader2 } from 'lucide-preact'

interface EmptyStateProps {
  message?: string
  icon?: string
  action?: ComponentChildren
  class?: string
  compact?: boolean
  children?: ComponentChildren
}

export function EmptyState({
  message,
  icon,
  action,
  class: cx,
  compact,
  children,
}: EmptyStateProps) {
  const content = children ?? message

  return html`
    <div class="flex flex-col items-center justify-center gap-2 text-center ${compact ? 'py-4' : 'py-8'} text-sm text-[var(--color-fg-muted)] ${cx ?? ''}" role="status">
      ${icon ? html`<span class="text-2xl opacity-40" aria-hidden="true">${icon}</span>` : null}
      ${content ? html`<span class="leading-relaxed">${content}</span>` : null}
      ${action ?? null}
    </div>
  `
}

interface LoadingStateProps {
  class?: string
  children?: ComponentChildren
}

/** Loading indicator with spin animation */
export function LoadingState({ class: cx, children }: LoadingStateProps) {
  return html`
    <div class="loading-state flex flex-col items-center py-8 text-sm ${cx ?? ''}" role="status" aria-live="polite">
      <${Loader2} size=${24} class="animate-spin mb-3 opacity-60 text-accent" aria-hidden="true" />
      <span>${children ?? '불러오는 중...'}</span>
    </div>
  `
}

interface ErrorStateProps {
  message: string
  class?: string
}

export function ErrorState({ message, class: cx }: ErrorStateProps) {
  return html`
    <div class="flex items-start gap-2 rounded border border-[var(--bad-30)] bg-[var(--bad-12)] px-4 py-3 text-sm text-[var(--bad-light)] ${cx ?? ''}" role="alert">
      <${AlertTriangle} size=${16} class="mt-0.5 shrink-0" aria-hidden="true" />
      <span>${message}</span>
    </div>
  `
}
