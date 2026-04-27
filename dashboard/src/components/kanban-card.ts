// Kanban card — single task tile with keeper attribution.
//
// Ported from design-system v0.4 cb-group-b (preview/cb-group-b.jsx
// DeckKanban). Each card carries: task id + title + keeper attribution
// (full KeeperBadge with sigil + name) + relative time. Visual state
// follows the task status — `running` lifts a brass accent border,
// `fail` paints a danger left edge.
//
// Token alignment matches #11102 (font-size / spacing scale).
// KeeperBadge usage matches #10955 (sigil for compact rows, full for
// card foots where the keeper is the primary attribution).

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { KeeperBadge } from './keeper-badge'

export type KanbanCardKind = 'queued' | 'running' | 'pending' | 'blocked' | 'fail' | 'done'

export interface KanbanCardProps {
  /** Stable task id ("PK-12345" or similar). */
  id: string
  /** Task title — the headline of the card. */
  title: string
  /** Keeper currently attributed to the task. */
  keeperId: string
  /** Optional relative time string ("2m", "13:42", etc.). */
  time?: string
  /** Visual state. */
  kind?: KanbanCardKind
  /** Click + Enter/Space activator. When given the card is interactive. */
  onActivate?: () => void
  /** Custom aria-label override; default composes from id + title + keeper + time. */
  ariaLabel?: string
}

const MONO_STACK = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'

const KIND_BORDER_LEFT_BY_KIND: Record<KanbanCardKind, string> = {
  queued: 'transparent',
  running: 'var(--color-accent-fg)',
  pending: 'var(--color-status-warn)',
  blocked: 'var(--color-status-warn)',
  fail: 'var(--color-status-err)',
  done: 'var(--color-status-ok)',
}

/** Pure: compose the SR sentence. Exposed for tests + for callers
 *  (e.g. a column composite) that want to consolidate labels. */
export function kanbanCardAriaLabel(props: KanbanCardProps): string {
  if (props.ariaLabel) return props.ariaLabel
  const kind = props.kind && props.kind !== 'queued' ? ` · ${props.kind}` : ''
  const time = props.time ? ` · ${props.time}` : ''
  return `${props.id} · ${props.title} · ${props.keeperId}${kind}${time}`
}

function activateOnEnterOrSpace(handler: () => void) {
  return (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      handler()
    }
  }
}

export function KanbanCard(props: KanbanCardProps): VNode {
  const interactive = props.onActivate !== undefined
  const kind = props.kind ?? 'queued'
  const ariaLabel = kanbanCardAriaLabel(props)

  const containerStyle = {
    display: 'flex',
    flexDirection: 'column' as const,
    gap: '4px',
    padding: `var(--spacing-element) var(--spacing-group)`,
    borderRadius: '3px',
    background: 'var(--bg-panel)',
    border: '1px solid var(--border-base)',
    borderLeft: `3px solid ${KIND_BORDER_LEFT_BY_KIND[kind]}`,
    cursor: interactive ? 'pointer' : 'default',
    fontFamily: MONO_STACK,
    minWidth: '0',
  }

  const idStyle = {
    fontSize: 'var(--font-size-3xs)',
    color: 'var(--color-fg-disabled)',
    letterSpacing: '0.06em',
    fontVariantNumeric: 'tabular-nums' as const,
    textTransform: 'uppercase' as const,
  }

  const titleStyle = {
    fontSize: 'var(--font-size-2xs)',
    color: 'var(--color-fg-primary)',
    fontWeight: 500,
    lineHeight: 1.3,
    overflow: 'hidden' as const,
    textOverflow: 'ellipsis' as const,
    display: '-webkit-box',
    WebkitLineClamp: 2,
    WebkitBoxOrient: 'vertical' as const,
  }

  const footStyle = {
    display: 'flex',
    alignItems: 'center',
    gap: '6px',
    fontSize: 'var(--font-size-3xs)',
    color: 'var(--color-fg-muted)',
    marginTop: '2px',
  }

  return html`
    <div
      role="listitem"
      aria-label=${ariaLabel}
      tabindex=${interactive ? 0 : undefined}
      onClick=${interactive ? props.onActivate : undefined}
      onKeyDown=${interactive && props.onActivate ? activateOnEnterOrSpace(props.onActivate) : undefined}
      style=${containerStyle}
    >
      <span aria-hidden="true" style=${idStyle}>${props.id}</span>
      <span aria-hidden="true" style=${titleStyle}>${props.title}</span>
      <span aria-hidden="true" style=${footStyle}>
        <${KeeperBadge}
          id=${props.keeperId}
          variant="full"
          size="sm"
          beat=${kind === 'running'}
        />
        ${props.time
          ? html`
              <span style=${{
                color: 'var(--color-fg-disabled)',
                fontVariantNumeric: 'tabular-nums',
              }}>· ${props.time}</span>
            `
          : null}
      </span>
    </div>
  `
}
