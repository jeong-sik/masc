// FeedbackState primitives — consistent empty/loading/error messages.
//
// 1-tier (existing): EmptyState, LoadingState, ErrorState — single
// message. ErrorState is the catch-all for unstructured failures.
//
import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { ActionButton } from './button'

export type FeedbackStateKind = 'empty' | 'loading' | 'error' | 'fatal'

export interface FeedbackStateSummary {
  kind: FeedbackStateKind
  compact: boolean
  hasIcon: boolean
  hasAction: boolean
  hasDetail: boolean
}

export function summarizeFeedbackState(
  kind: FeedbackStateKind,
  options: {
    compact?: boolean
    icon?: unknown
    action?: unknown
    detail?: unknown
  } = {},
): FeedbackStateSummary {
  return {
    kind,
    compact: Boolean(options.compact),
    hasIcon: Boolean(options.icon),
    hasAction: Boolean(options.action),
    hasDetail: Boolean(options.detail),
  }
}

function feedbackStateAttrs(summary: FeedbackStateSummary) {
  return {
    'data-feedback-state': '',
    'data-feedback-kind': summary.kind,
    'data-feedback-compact': summary.compact,
    'data-feedback-has-icon': summary.hasIcon,
    'data-feedback-has-action': summary.hasAction,
    'data-feedback-has-detail': summary.hasDetail,
  }
}

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
  const summary = summarizeFeedbackState('empty', { compact, icon, action })

  return html`
    <div
      class="flex flex-col items-center justify-center gap-2 text-center ${compact ? 'py-4' : 'py-8'} text-sm text-[var(--color-fg-muted)] ${cx ?? ''}"
      role="status"
      ...${feedbackStateAttrs(summary)}
    >
      ${icon
        ? html`
            <span
              class="inline-flex h-6 min-w-6 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-1 font-mono text-[10px] opacity-60"
              aria-hidden="true"
              data-feedback-icon
            >
              ${icon}
            </span>
          `
        : null}
      ${content ? html`<span class="leading-relaxed">${content}</span>` : null}
      ${action ?? null}
    </div>
  `
}

interface LoadingStateProps {
  class?: string
  children?: ComponentChildren
}

/** Loading indicator with a pulsing mono glyph. */
export function LoadingState({ class: cx, children }: LoadingStateProps) {
  const summary = summarizeFeedbackState('loading', { icon: true })
  return html`
    <div
      class="loading-state flex flex-col items-center py-8 text-sm ${cx ?? ''}"
      role="status"
      aria-live="polite"
      ...${feedbackStateAttrs(summary)}
    >
      <span
        class="mb-3 inline-flex h-6 min-w-6 animate-pulse items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-subtle)] px-1 font-mono text-[10px] text-[var(--color-fg-accent)] opacity-70"
        aria-hidden="true"
        data-feedback-icon
      >
        LD
      </span>
      <span>${children ?? '불러오는 중...'}</span>
    </div>
  `
}

interface ErrorStateProps {
  message: string
  class?: string
}

export function ErrorState({ message, class: cx }: ErrorStateProps) {
  const summary = summarizeFeedbackState('error', { icon: true })
  return html`
    <div
      class="flex items-start gap-2 rounded-[var(--r-0)] border border-[var(--bad-30)] bg-[var(--bad-12)] px-4 py-3 text-sm text-[var(--bad-light)] ${cx ?? ''}"
      role="alert"
      ...${feedbackStateAttrs(summary)}
    >
      <span class="mt-0.5 inline-flex h-5 min-w-5 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--bad-30)] px-1 font-mono text-[10px]" aria-hidden="true" data-feedback-icon>
        ER
      </span>
      <span>${message}</span>
    </div>
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

/** Hard / bad tier with an explicit whole-surface reload action. */
export function ErrorFatal({
  title,
  detail,
  onReload,
  reloadLabel = '다시 불러오기',
  class: cx,
}: ErrorFatalProps) {
  const summary = summarizeFeedbackState('fatal', {
    icon: true,
    action: onReload,
    detail,
  })
  return html`
    <section
      role="alert"
      class="flex flex-col gap-2 rounded-[var(--r-0)] border border-[var(--bad-20)] border-l-[3px] border-l-[var(--color-status-err)] bg-[var(--bad-soft)] px-4 py-3 ${cx ?? ''}"
      ...${feedbackStateAttrs(summary)}
    >
      <div class="flex items-center gap-2">
        <span class="inline-flex h-5 min-w-5 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--bad-20)] px-1 font-mono text-[10px] text-[var(--bad-light)]" aria-hidden="true" data-feedback-icon>
          FT
        </span>
        <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--bad-light)]">
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
