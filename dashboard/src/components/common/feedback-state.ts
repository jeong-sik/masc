// FeedbackState primitives — consistent empty/loading/error messages.
//
// 1-tier (existing): EmptyState, LoadingState, ErrorState — single
// message. ErrorState is the catch-all for unstructured failures.
//
// 2-tier (added per design-system v0.4 cb-group-g SPEC §G3): split
// recoverable/fatal so callers can distinguish "tried-and-bounced,
// retry will likely work" from "session/connection broken, reload
// is the only path forward". Each tier exposes a primary action slot.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { AlertTriangle, AlertOctagon, Loader2, RefreshCw } from 'lucide-preact'
import { ActionButton } from './button'

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

interface ErrorRecoverableProps {
  /** One-line summary surfaced as the alert headline. */
  title: string
  /** Optional second line — caller-supplied context (timing, provider,
      retry count). Rendered in the muted secondary tone. */
  detail?: string
  /** Click handler for the inline retry action. When omitted the button
      is not rendered (caller may be queueing retries elsewhere). */
  onRetry?: () => void
  /** Override the retry button label. Default: "다시 시도". */
  retryLabel?: string
  class?: string
}

/** Soft / amber tier — the operation bounced through fallback paths
    and ended up in a state where another attempt will likely succeed
    (e.g. cascade exhausted at provider X, retry will rotate to Y). */
export function ErrorRecoverable({
  title,
  detail,
  onRetry,
  retryLabel = '다시 시도',
  class: cx,
}: ErrorRecoverableProps) {
  return html`
    <section
      role="alert"
      class="flex flex-col gap-2 rounded border border-[var(--warn-20)] border-l-[3px] border-l-[var(--color-status-warn)] bg-[var(--warn-soft)] px-4 py-3 ${cx ?? ''}"
    >
      <div class="flex items-center gap-2">
        <${AlertTriangle} size=${16} class="shrink-0 text-[var(--warn-bright)]" aria-hidden="true" />
        <span class="text-2xs font-semibold uppercase tracking-1 text-[var(--warn-bright)]">
          복구 가능
        </span>
        ${onRetry ? html`
          <span class="ml-auto">
            <${ActionButton} variant="ghost" size="sm" onClick=${onRetry}>
              <span class="inline-flex items-center gap-1">
                <${RefreshCw} size=${12} aria-hidden="true" />
                ${retryLabel}
              </span>
            <//>
          </span>
        ` : null}
      </div>
      <div class="text-sm text-[var(--color-fg-primary)]">${title}</div>
      ${detail ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${detail}</div>` : null}
    </section>
  `
}

interface ErrorFatalProps {
  /** One-line summary surfaced as the alert headline. */
  title: string
  /** Optional second line — caller-supplied context (which connection,
      when it dropped, exhausted reconnect count). */
  detail?: string
  /** Click handler for the inline reload action. When omitted the
      button is not rendered (caller may have a different recovery
      surface like a top-level reload modal). */
  onReload?: () => void
  /** Override the reload button label. Default: "다시 불러오기". */
  reloadLabel?: string
  class?: string
}

/** Hard / bad tier — the underlying connection or session is gone and
    no retry of the in-flight operation will help. Reload is the path
    forward (e.g. WebSocket closed, auth token expired). */
export function ErrorFatal({
  title,
  detail,
  onReload,
  reloadLabel = '다시 불러오기',
  class: cx,
}: ErrorFatalProps) {
  return html`
    <section
      role="alert"
      class="flex flex-col gap-2 rounded border border-[var(--bad-20)] border-l-[3px] border-l-[var(--color-status-err)] bg-[var(--bad-soft)] px-4 py-3 ${cx ?? ''}"
    >
      <div class="flex items-center gap-2">
        <${AlertOctagon} size=${16} class="shrink-0 text-[var(--bad-light)]" aria-hidden="true" />
        <span class="text-2xs font-semibold uppercase tracking-1 text-[var(--bad-light)]">
          치명적
        </span>
        ${onReload ? html`
          <span class="ml-auto">
            <${ActionButton} variant="danger" size="sm" onClick=${onReload}>
              ${reloadLabel}
            <//>
          </span>
        ` : null}
      </div>
      <div class="text-sm text-[var(--color-fg-primary)]">${title}</div>
      ${detail ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${detail}</div>` : null}
    </section>
  `
}
