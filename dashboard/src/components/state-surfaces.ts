// MASC Dashboard v2 — empty / error / loading state surfaces
// Ported from keeper-v2 organisms-5 (organisms-5.jsx). Local-only, no backend.

import { html } from 'htm/preact'
import type { JSX } from 'preact'
import { ActionButton } from './common/button'

type CSSProperties = JSX.CSSProperties

interface StateSurfaceBaseProps {
  compact?: boolean
  class?: string
  style?: CSSProperties
}

interface EmptyStateProps extends StateSurfaceBaseProps {
  glyph?: string
  title?: string
  hint?: string
  action?: string
  onAction?: () => void
}

interface ErrorStateProps extends StateSurfaceBaseProps {
  glyph?: string
  title?: string
  detail?: string
  action?: string
  onAction?: () => void
}

interface LoadingStateProps extends StateSurfaceBaseProps {
  title?: string
  rows?: number
}

function stateClasses(kind: 'empty' | 'error' | 'loading', compact: boolean, cx?: string): string {
  const base = `kv-state ${kind}`
  const mods = [compact ? 'compact' : '', cx ?? ''].filter(Boolean).join(' ')
  return mods ? `${base} ${mods}` : base
}

/** Empty state surface — glyph, title, optional hint and primary action. */
export function EmptyState({
  glyph = '◌',
  title,
  hint,
  action,
  onAction,
  compact,
  class: cx,
  style,
}: EmptyStateProps) {
  return html`
    <div
      class=${stateClasses('empty', compact ?? false, cx)}
      data-testid="empty-state"
      role="status"
      style=${style}
    >
      <div class="kv-state-g" aria-hidden="true">${glyph}</div>
      ${title ? html`<div class="kv-state-t">${title}</div>` : null}
      ${hint ? html`<div class="kv-state-h">${hint}</div>` : null}
      ${action && onAction
        ? html`
          <div class="kv-state-a">
            <${ActionButton} variant="primary" size="sm" onClick=${onAction}>${action}<//>
          </div>
        `
        : null}
    </div>
  `
}

/** Error state surface — glyph, title, optional detail and retry action. */
export function ErrorState({
  glyph = '⚠',
  title,
  detail,
  action = '다시 시도',
  onAction,
  compact,
  class: cx,
  style,
}: ErrorStateProps) {
  return html`
    <div
      class=${stateClasses('error', compact ?? false, cx)}
      data-testid="error-state"
      role="alert"
      style=${style}
    >
      <div class="kv-state-g" aria-hidden="true">${glyph}</div>
      ${title ? html`<div class="kv-state-t">${title}</div>` : null}
      ${detail ? html`<div class="kv-state-h mono">${detail}</div>` : null}
      ${onAction
        ? html`
          <div class="kv-state-a">
            <${ActionButton} variant="ghost" size="sm" onClick=${onAction}>${action}<//>
          </div>
        `
        : null}
    </div>
  `
}

/** Loading state surface — animated bar plus skeleton rows. */
export function LoadingState({
  title = '불러오는 중…',
  rows = 3,
  compact,
  class: cx,
  style,
}: LoadingStateProps) {
  return html`
    <div
      class=${stateClasses('loading', compact ?? false, cx)}
      data-testid="loading-state"
      role="status"
      aria-live="polite"
      style=${style}
    >
      <div class="kv-state-g" aria-hidden="true">⟳</div>
      <div class="kv-skel-list">
        ${Array.from({ length: rows }).map(
          (_, i) => html`
            <div key=${i} class="kv-skel-row">
              <span class="kv-skel-av" />
              <span class="kv-skel-lines">
                <span class="kv-skel-line" />
                <span class="kv-skel-line short" />
              </span>
            </div>
          `,
        )}
      </div>
      <div class="kv-state-h">${title}</div>
    </div>
  `
}
