// Swimlane row — single keeper timeline lane.
//
// Ported from design-system v0.4 cb-group-b (preview/cb-group-b.jsx
// SwimlanesGlyph / SwimlanesDense / SwimlanesBars). Three source
// variants collapse into one atomic SwimlaneRow + two display knobs:
//
//   - Glyph  ≈ SwimlaneRow with point events (event.width undefined)
//             + selectable: true + onActivate
//   - Dense  ≈ same as Glyph but parent strip uses density='compact'
//             (this primitive doesn't care — density is a strip-level
//             concern, deferred to the future SwimlaneStrip composite)
//   - Bars   ≈ SwimlaneRow with span events (event.width set, 0..1)
//
// Event mode (point vs span) is auto-detected per event by whether
// `width` is set, so a single lane can mix dot pings and aggregated
// duration bars. The original .cb-swim / .lane / .ev / .agg CSS
// selectors live in design-system styles which the dashboard does
// NOT import — re-implementation against the dashboard token set +
// KeeperBadge (#10955) + tokens swept in #11102 (spacing/font-size).

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { KeeperBadge } from './keeper-badge'
import { MONO_STACK } from './common/font-stacks'

export type SwimlaneEventKind = 'ok' | 'warn' | 'err' | 'info' | 'neutral'

export interface SwimlaneEvent {
  /** Horizontal position along the track, 0..1 (left → right). */
  x: number
  /** Optional duration width 0..1. When set the event renders as a
   *  span (Bars pattern); when omitted a point dot (Glyph pattern). */
  width?: number
  /** Tone — drives the event color. Default 'neutral'. */
  kind?: SwimlaneEventKind
  /** Optional human-readable label (used in the row's composed
   *  aria-label so SR users hear "{kid} timeline: 3 events, last err"). */
  label?: string
}

export interface SwimlaneRowProps {
  keeperId: string
  events: SwimlaneEvent[]
  /** Drives KeeperBadge.beat — pulses the sigil for active keepers. */
  running?: boolean
  /** Visual selected state — emits aria-current="true" + brass border. */
  selected?: boolean
  /** Click + Enter/Space activator. When omitted the lane is non-interactive. */
  onActivate?: () => void
  /** Custom aria-label override. Default composes from keeperId,
   *  event count, and `selected`. */
  ariaLabel?: string
}

const EVENT_COLOR_BY_KIND: Record<SwimlaneEventKind, string> = {
  ok: 'var(--color-status-ok)',
  warn: 'var(--color-status-warn)',
  err: 'var(--color-status-err)',
  info: 'var(--color-accent-fg)',
  neutral: 'var(--color-fg-muted)',
}

const HEAD_WIDTH_PX = 130 // matches cb-group-b's lane-head fixed width


/** Pure: build the inline style for one event. Exposed for tests + for
 *  callers that want to render events into their own track (e.g. a
 *  composite SwimlaneStrip with overlapping NOW marker). */
export function swimlaneEventStyle(event: SwimlaneEvent): {
  left: string
  width?: string
  background: string
} {
  const kind = event.kind ?? 'neutral'
  const left = `${(event.x * 100).toFixed(2)}%`
  const background = EVENT_COLOR_BY_KIND[kind]
  if (event.width !== undefined && event.width > 0) {
    return { left, width: `${(event.width * 100).toFixed(2)}%`, background }
  }
  return { left, background }
}

/** Pure: compose the aria-label for a row. Same inputs always yield
 *  the same string — testable without DOM. */
export function swimlaneRowAriaLabel(props: SwimlaneRowProps): string {
  if (props.ariaLabel) return props.ariaLabel
  const count = props.events.length
  const lastKind = count > 0 ? (props.events[count - 1]!.kind ?? 'neutral') : null
  const tail = lastKind && lastKind !== 'neutral' ? `, last ${lastKind}` : ''
  const sel = props.selected ? ', selected' : ''
  const events = count === 0 ? 'no events' : count === 1 ? '1 event' : `${count} events`
  return `${props.keeperId} timeline: ${events}${tail}${sel}`
}

function activateOnEnterOrSpace(handler: () => void) {
  return (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      handler()
    }
  }
}

export function SwimlaneRow(props: SwimlaneRowProps): VNode {
  const interactive = props.onActivate !== undefined
  const ariaLabel = swimlaneRowAriaLabel(props)

  const containerStyle = {
    display: 'flex',
    alignItems: 'center',
    gap: 'var(--spacing-element)',
    padding: `4px var(--spacing-element)`,
    borderRadius: 'var(--r-1)',
    border: `1px solid ${props.selected ? 'var(--color-accent-brass)' : 'transparent'}`,
    background: props.selected ? 'var(--bg-panel)' : 'transparent',
    cursor: interactive ? 'pointer' : 'default',
    outline: 'none',
  }

  const headStyle = {
    display: 'inline-flex',
    alignItems: 'center',
    gap: 'var(--sp-1-5)',
    width: `${HEAD_WIDTH_PX}px`,
    flex: 'none',
    fontFamily: MONO_STACK,
  }

  const trackStyle = {
    position: 'relative' as const,
    flex: 1,
    height: '14px',
    background: 'var(--bg-panel)',
    border: '1px solid var(--border-base)',
    borderRadius: 'var(--r-0)',
    overflow: 'hidden',
  }

  const eventCommon = {
    position: 'absolute' as const,
    top: '3px',
    height: '8px',
    borderRadius: 'var(--r-00)',
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
      <div style=${headStyle}>
        <${KeeperBadge}
          id=${props.keeperId}
          variant="sigil"
          size="sm"
          beat=${props.running === true}
        />
        <span
          aria-hidden="true"
          style=${{
            fontSize: 'var(--font-size-2xs)',
            color: 'var(--color-fg-secondary)',
            fontWeight: 500,
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >${props.keeperId}</span>
      </div>
      <div aria-hidden="true" style=${trackStyle}>
        ${props.events.map((evt, i) => {
          const evStyle = swimlaneEventStyle(evt)
          const isPoint = evt.width === undefined || evt.width <= 0
          return html`
            <span
              key=${i}
              style=${{
                ...eventCommon,
                ...evStyle,
                width: isPoint ? '4px' : evStyle.width,
                marginLeft: isPoint ? '-2px' : undefined,
                opacity: 0.85,
              }}
            ></span>
          `
        })}
      </div>
    </div>
  `
}
