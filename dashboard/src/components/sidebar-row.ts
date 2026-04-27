// Sidebar row — keeper entry in a fleet/standby sidebar list.
//
// Ported from design-system v0.4 cb-group-b (preview/cb-group-b.jsx
// SidebarFleet / SidebarGrouped / SidebarIcons). All three variants
// share the same row shape: KeeperBadge sigil + keeper id + meta text.
// The compact variant (SidebarIcons) hides the keeper id and meta
// behind a tooltip; that's a strip-level concern, not row-level —
// this primitive renders the full content and the future strip can
// suppress optional fields via CSS.
//
// Token alignment matches #11102 (font-size / spacing scale);
// KeeperBadge usage matches #10955.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { KeeperBadge } from './keeper-badge'

export type SidebarRowStatus = 'running' | 'idle' | 'stalled' | 'fail' | 'pending'

export interface SidebarRowProps {
  keeperId: string
  /** Right-aligned secondary text — typically current task slug or
   *  a short status string ("queued", "fixing CI", etc.). */
  meta?: string
  status?: SidebarRowStatus
  /** Visual selected state — emits aria-current="true" + filled background. */
  selected?: boolean
  /** Click + Enter/Space activator. When omitted the row is non-interactive. */
  onActivate?: () => void
  /** Custom aria-label override; default composes from keeperId + meta + status. */
  ariaLabel?: string
}

const MONO_STACK = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'

/** Pure: compose the SR sentence. Exposed for tests + parent strips. */
export function sidebarRowAriaLabel(props: SidebarRowProps): string {
  if (props.ariaLabel) return props.ariaLabel
  const meta = props.meta ? ` · ${props.meta}` : ''
  const status = props.status ? ` · ${props.status}` : ''
  const sel = props.selected ? ' · selected' : ''
  return `${props.keeperId}${meta}${status}${sel}`
}

function activateOnEnterOrSpace(handler: () => void) {
  return (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      handler()
    }
  }
}

export function SidebarRow(props: SidebarRowProps): VNode {
  const interactive = props.onActivate !== undefined
  const ariaLabel = sidebarRowAriaLabel(props)
  const isIdle = props.status === 'idle' || props.status === 'stalled'

  const containerStyle = {
    display: 'flex',
    alignItems: 'center',
    gap: '6px',
    padding: `4px var(--spacing-element)`,
    borderRadius: '3px',
    background: props.selected ? 'var(--bg-panel-hover)' : 'transparent',
    border: `1px solid ${props.selected ? 'var(--color-accent-brass)' : 'transparent'}`,
    cursor: interactive ? 'pointer' : 'default',
    fontFamily: MONO_STACK,
    opacity: isIdle ? 0.6 : 1,
    minWidth: '0',
  }

  const nameStyle = {
    fontSize: 'var(--font-size-2xs)',
    color: 'var(--color-fg-primary)',
    fontWeight: 500,
    overflow: 'hidden' as const,
    textOverflow: 'ellipsis' as const,
    whiteSpace: 'nowrap' as const,
    flex: '0 1 auto',
  }

  const metaStyle = {
    fontSize: 'var(--font-size-3xs)',
    color: 'var(--color-fg-muted)',
    overflow: 'hidden' as const,
    textOverflow: 'ellipsis' as const,
    whiteSpace: 'nowrap' as const,
    marginLeft: 'auto',
    flex: '0 1 auto',
  }

  return html`
    <div
      role="listitem"
      aria-label=${ariaLabel}
      aria-current=${props.selected ? 'true' : undefined}
      tabindex=${interactive ? 0 : undefined}
      onClick=${interactive ? props.onActivate : undefined}
      onKeyDown=${interactive && props.onActivate ? activateOnEnterOrSpace(props.onActivate) : undefined}
      style=${containerStyle}
    >
      <${KeeperBadge}
        id=${props.keeperId}
        variant="sigil"
        size="sm"
        beat=${props.status === 'running'}
      />
      <span aria-hidden="true" style=${nameStyle}>${props.keeperId}</span>
      ${props.meta
        ? html`<span aria-hidden="true" style=${metaStyle}>${props.meta}</span>`
        : null}
    </div>
  `
}
