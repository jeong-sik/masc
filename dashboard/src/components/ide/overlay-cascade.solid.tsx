/** @jsxImportSource solid-js */
//
// Cascade Trace Overlay — per-line gutter chip showing runtime/cost/latency
// for each cascade hit recorded in cascade_audit JSONL (RFC-0023, DS RFC-0020 extension).
//
// Uses SolidJS (large-N regime, RFC-0017 §7c): For<CascadeLineHit> avoids VDOM
// diffing when the hits array is large (many source lines with recorded cascade data).
//
// Rendering contract:
//   - Zero hits → empty `<ul>` with aria-label (no visual output; 0 hits is valid).
//   - Each hit → `<li>` with a neutral runtime chip + cost + latency.
//   - Cost formatting: < $0.000001 → "< $0.000001"; otherwise in µ$ (microdollars)
//     when < $0.001, or in $ (2 decimal places) otherwise.
//   - Latency formatting: null → "—"; otherwise in ms or "Xs" for ≥ 1000 ms.

import { For, type JSX } from 'solid-js'

// ── Public types ───────────────────────────────────────────────────

/** A single cascade hit recorded against a source line. */
export interface CascadeLineHit {
  /** 1-indexed source line number the hit is attributed to. */
  readonly line: number
  /** Concrete provider identifier from the trace payload; never rendered directly. */
  readonly provider: string
  /** Concrete model identifier from the trace payload; never rendered directly. */
  readonly model: string
  /** Cost in USD; null when not available. */
  readonly cost_usd: number | null
  /** End-to-end latency in milliseconds; null when not recorded. */
  readonly latency_ms: number | null
}

export interface OverlayCascadeProps {
  /** Cascade hits to display, one chip per hit. */
  readonly hits: ReadonlyArray<CascadeLineHit>
  /** Forwarded to the `<ul>` container for test targeting. */
  readonly testId?: string
}

// ── Formatting helpers ─────────────────────────────────────────────

/** Format cost_usd into a compact display string. */
export function formatCost(cost: number | null): string {
  if (cost === null) return '—'
  if (cost === 0) return '$0'
  if (cost < 0.000001) return '< $0.000001'
  if (cost < 0.001) return `${(cost * 1_000_000).toFixed(0)} µ$`
  // parseFloat strips trailing zeros (e.g. 1.5000 → 1.5, 0.0015 → 0.0015)
  return `$${parseFloat(cost.toFixed(4))}`
}

/** Format latency_ms into a compact display string. */
export function formatLatency(ms: number | null): string {
  if (ms === null) return '—'
  if (ms < 1000) return `${ms}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

/** Return the neutral public label for any concrete runtime/model ID. */
export function shortModel(_model: string): string {
  return 'runtime'
}

// ── Component ──────────────────────────────────────────────────────

export function OverlayCascade(props: OverlayCascadeProps): JSX.Element {
  return (
    <ul
      role="list"
      aria-label={`Cascade overlay · ${props.hits.length} hit${props.hits.length !== 1 ? 's' : ''}`}
      data-testid={props.testId}
      style={{
        display: 'flex',
        'flex-direction': 'column',
        gap: 'var(--sp-1)',
        padding: 'var(--sp-2) var(--sp-3)',
        margin: '0',
        'list-style': 'none',
        'border-bottom': '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
        'font-size': 'var(--fs-11)',
        'overflow-x': 'auto',
      }}
    >
      <For each={props.hits as CascadeLineHit[]}>
        {(hit) => (
          <li
            aria-label={`Line ${hit.line}: runtime · ${formatCost(hit.cost_usd)} · ${formatLatency(hit.latency_ms)}`}
            style={{
              display: 'inline-flex',
              'align-items': 'center',
              gap: 'var(--sp-2)',
              'white-space': 'nowrap',
            }}
          >
            {/* Line number gutter */}
            <span
              aria-hidden="true"
              style={{
                'min-width': '2.5rem',
                'text-align': 'right',
                color: 'var(--color-fg-disabled)',
                'font-variant-numeric': 'tabular-nums',
              }}
            >
              {hit.line}
            </span>
            {/* Runtime chip */}
            <span
              aria-hidden="true"
              style={{
                display: 'inline-flex',
                'align-items': 'center',
                gap: 'var(--sp-1)',
                padding: '1px var(--sp-2)',
                border: '1px solid var(--color-border-default)',
                'border-radius': 'var(--r-2)',
                background: 'var(--color-bg-elevated)',
                color: 'var(--color-fg-secondary)',
              }}
            >
              {/* Color dot */}
              <span
                style={{
                  display: 'inline-block',
                  width: '6px',
                  height: '6px',
                  'border-radius': '50%',
                  background: 'var(--color-fg-muted)',
                  'flex-shrink': '0',
                }}
              />
              <span>runtime</span>
            </span>
            {/* Cost */}
            <span
              aria-hidden="true"
              style={{ color: 'var(--color-fg-muted)', 'font-variant-numeric': 'tabular-nums' }}
            >
              {formatCost(hit.cost_usd)}
            </span>
            {/* Latency */}
            <span
              aria-hidden="true"
              style={{ color: 'var(--color-fg-muted)', 'font-variant-numeric': 'tabular-nums' }}
            >
              {formatLatency(hit.latency_ms)}
            </span>
          </li>
        )}
      </For>
    </ul>
  )
}
