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
    <div class="feedback-panel feedback-panel-empty text-center text-[13px] leading-relaxed ${cx ?? ''}">${children}</div>
  `
}

interface LoadingStateProps {
  class?: string
  children?: ComponentChildren
}

/** Loading indicator with pulse animation */
export function LoadingState({ class: cx, children }: LoadingStateProps) {
  return html`
    <div class="feedback-panel feedback-panel-loading text-center text-[13px] animate-pulse ${cx ?? ''}">
      ${children ?? '불러오는 중...'}
    </div>
  `
}

interface ErrorStateProps {
  class?: string
  children: ComponentChildren
}

export function ErrorState({ class: cx, children }: ErrorStateProps) {
  return html`
    <div class="feedback-panel feedback-panel-error text-[13px] leading-relaxed ${cx ?? ''}">
      ${children}
    </div>
  `
}
