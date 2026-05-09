/** @jsxImportSource solid-js */
//
// Cascade Trace Overlay — per-line gutter chip showing provider/model/cost/latency
// for each cascade hit recorded in cascade_audit JSONL (RFC-0023, DS RFC-0020 extension).
//
// Uses SolidJS (large-N regime, RFC-0017 §7c): For<CascadeLineHit> avoids VDOM
// diffing when the hits array is large (many source lines with recorded cascade data).
//
// Rendering contract:
//   - Zero hits → empty `<ul>` with aria-label (no visual output; 0 hits is valid).
//   - Each hit → `<li>` with a provider-colored dot chip + model short-name + cost + latency.
//   - Provider color: uses `--color-p-{provider}` CSS token when available;
//     falls back to `--color-fg-muted` for unknown providers.
//   - Cost formatting: < $0.000001 → "< $0.000001"; otherwise in µ$ (microdollars)
//     when < $0.001, or in $ (2 decimal places) otherwise.
//   - Latency formatting: null → "—"; otherwise in ms or "Xs" for ≥ 1000 ms.

import { For, type JSX } from 'solid-js'

// ── Public types ───────────────────────────────────────────────────

/** A single cascade hit recorded against a source line. */
export interface CascadeLineHit {
  /** 1-indexed source line number the hit is attributed to. */
  readonly line: number
  /** Provider identifier, e.g. "anthropic", "openai", "ollama". */
  readonly provider: string
  /** Model identifier, e.g. "claude-3-5-sonnet-20241022". */
  readonly model: string
  /** Cost in USD; null when not available (local/ollama providers). */
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

// ── Known provider → CSS token key map ────────────────────────────
// Keyed by the provider strings used in cascade_audit JSONL.

const PROVIDER_COLOR_TOKEN: Record<string, string> = {
  anthropic: '--color-p-anthropic',
  'claude-code': '--color-p-anthropic',
  openai: '--color-p-openai',
  'openai-chat': '--color-p-openai',
  'openai-ext': '--color-p-openai',
  moonshot: '--color-p-moonshot',
  'kimi-cli': '--color-p-moonshot',
  xai: '--color-p-xai',
}

function providerColorStyle(provider: string): string {
  const token = PROVIDER_COLOR_TOKEN[provider.toLowerCase()]
  return token ? `var(${token})` : 'var(--color-fg-muted)'
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

/** Derive a short model label from a full model ID. */
export function shortModel(model: string): string {
  // e.g. "claude-3-5-sonnet-20241022" → "claude-3-5-sonnet"
  //      "gpt-4o-mini"               → "gpt-4o-mini"
  //      "ollama/llama3.2"           → "llama3.2"
  const trimmed = model.includes('/') ? model.split('/').pop() ?? model : model
  // strip trailing date suffix YYYYMMDD or -YYYYMMDD
  return trimmed.replace(/-?\d{8}$/, '')
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
            aria-label={`Line ${hit.line}: ${hit.provider} ${hit.model} · ${formatCost(hit.cost_usd)} · ${formatLatency(hit.latency_ms)}`}
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
            {/* Provider chip */}
            <span
              aria-hidden="true"
              style={{
                display: 'inline-flex',
                'align-items': 'center',
                gap: 'var(--sp-1)',
                padding: '1px var(--sp-2)',
                border: `1px solid ${providerColorStyle(hit.provider)}`,
                'border-radius': 'var(--r-2)',
                background: 'var(--color-bg-elevated)',
                color: providerColorStyle(hit.provider),
              }}
            >
              {/* Color dot */}
              <span
                style={{
                  display: 'inline-block',
                  width: '6px',
                  height: '6px',
                  'border-radius': '50%',
                  background: providerColorStyle(hit.provider),
                  'flex-shrink': '0',
                }}
              />
              <span>{hit.provider}</span>
            </span>
            {/* Model short name */}
            <span style={{ color: 'var(--color-fg-secondary)' }}>
              {shortModel(hit.model)}
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
