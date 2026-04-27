// Ticker item — single event row in a fleet activity ticker.
//
// Ported from design-system v0.4 cb-group-a (preview/cb-group-a.jsx
// TickerMarquee / TickerChunks / TickerVertical). Two primitives:
//
//   TickerItem  — atomic event row: keeper sigil + name + body
//                 (+ optional time prefix/suffix). Drop-in for any
//                 list-style activity stream.
//
//   TickerStrip — composite container: role="log" + aria-live="polite",
//                 arrays TickerItems. Layout is a flex row by default
//                 ("marquee/chunks" stripe); pass orientation="vertical"
//                 to stack rows.
//
// The original .cb-ticker / .evt CSS selectors live in design-system
// styles which the dashboard does NOT import — re-implementation
// against the dashboard token set + KeeperBadge (#10955) + htm/preact.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { KeeperBadge } from './keeper-badge'

export type TickerItemKind = 'ok' | 'warn' | 'err' | 'info' | 'neutral'
export type TickerTimePosition = 'leading' | 'trailing' | 'none'

export interface TickerItemProps {
  /** Keeper id powering the sigil + identity color (via KeeperBadge). */
  keeperId: string
  /** Event description body. */
  text: string
  /** Tone of the event — drives the body color. Default 'neutral'. */
  kind?: TickerItemKind
  /** Pre-formatted time string ("14:32:18Z" or "14:32:18"). When
   *  omitted the time slot is empty regardless of `timePosition`. */
  time?: string
  /** Where the time appears relative to the keeper. Default 'trailing'. */
  timePosition?: TickerTimePosition
  /** Truncate body to N chars (chunks pattern). 0 or undefined = no truncation. */
  bodyMaxChars?: number
}

const MONO_STACK = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'

const BODY_COLOR_BY_KIND: Record<TickerItemKind, string> = {
  ok: 'var(--color-status-ok)',
  warn: 'var(--color-status-warn)',
  err: 'var(--color-status-err)',
  info: 'var(--color-accent-fg)',
  neutral: 'var(--color-fg-secondary)',
}

/** Pure: build the ARIA announcement for a ticker item — exposed for
 *  tests and for parent strips that want to compose a single
 *  consolidated label. The rendered visual surface is aria-hidden so
 *  this is the only thing SR users hear. */
export function tickerItemAriaLabel(props: TickerItemProps): string {
  const kind = props.kind && props.kind !== 'neutral' ? ` ${props.kind}` : ''
  const time = props.time ? `, at ${props.time}` : ''
  const text = truncate(props.text, props.bodyMaxChars)
  return `${props.keeperId}${kind}: ${text}${time}`
}

function truncate(s: string, max?: number): string {
  if (max === undefined || max <= 0) return s
  return s.length > max ? s.slice(0, max) : s
}

export function TickerItem(props: TickerItemProps): VNode {
  const kind = props.kind ?? 'neutral'
  const timePosition = props.timePosition ?? 'trailing'
  const bodyText = truncate(props.text, props.bodyMaxChars)
  const showLeadingTime = timePosition === 'leading' && props.time !== undefined
  const showTrailingTime = timePosition === 'trailing' && props.time !== undefined

  const timeNode = props.time
    ? html`
        <span
          aria-hidden="true"
          style=${{
            fontFamily: MONO_STACK,
            fontSize: '10px',
            color: 'var(--color-fg-disabled)',
            fontVariantNumeric: 'tabular-nums',
            letterSpacing: '0.04em',
            flex: 'none',
          }}
        >${props.time}</span>
      `
    : null

  return html`
    <span
      role="listitem"
      aria-label=${tickerItemAriaLabel(props)}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: '6px',
        padding: '2px 8px',
        fontFamily: MONO_STACK,
        fontSize: '11px',
        whiteSpace: 'nowrap',
      }}
    >
      ${showLeadingTime ? timeNode : null}
      <${KeeperBadge} id=${props.keeperId} variant="sigil" size="sm" />
      <span
        aria-hidden="true"
        style=${{
          color: 'var(--color-fg-primary)',
          fontWeight: 500,
        }}
      >${props.keeperId}</span>
      <span
        aria-hidden="true"
        style=${{
          color: BODY_COLOR_BY_KIND[kind],
          fontWeight: 400,
          textOverflow: 'ellipsis',
          overflow: 'hidden',
        }}
      >${bodyText}</span>
      ${showTrailingTime ? timeNode : null}
    </span>
  `
}

export type TickerOrientation = 'horizontal' | 'vertical'

export interface TickerStripProps {
  events: TickerItemProps[]
  /** `horizontal` = inline flex row (marquee/chunks pattern).
   *  `vertical` = stacked column (vertical pattern). Default 'horizontal'. */
  orientation?: TickerOrientation
  /** Required label for the log region (Korean default). */
  ariaLabel?: string
}

export function TickerStrip({
  events,
  orientation = 'horizontal',
  ariaLabel = '플릿 이벤트 티커',
}: TickerStripProps): VNode {
  return html`
    <div
      role="log"
      aria-live="polite"
      aria-label=${ariaLabel}
      style=${{
        display: 'flex',
        flexDirection: orientation === 'vertical' ? 'column' : 'row',
        gap: orientation === 'vertical' ? '4px' : '12px',
        alignItems: orientation === 'vertical' ? 'stretch' : 'center',
        overflow: 'hidden',
      }}
    >
      ${events.map((evt, i) => html`<${TickerItem} key=${i} ...${evt} />`)}
    </div>
  `
}
