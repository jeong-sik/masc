// Telemetry v2 molecules — port of keeper-v2 design-system visualization atoms.
//
// These components are prop-driven only (no backend wiring) and are intended
// for reuse in monitoring surfaces: trace counts, turn phase waterfalls,
// keeper FSM steppers, throughput chips, and streaming indicators.
//
// Existing dashboard equivalents:
//   - Sparkline       -> common/sparkline.ts (Canvas-based, kept in place)
//   - ProgressBar     -> common/progress-bar.ts (single-value, kept in place)
//   - SegmentedBar    -> common/distribution-bars.ts (stacked labeled split)
// We add here the v2 shapes that were missing: TelemetryBars, Waterfall,
// FsmLifeline, TpsLive, SegmentedProgress, and StreamingCaret.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

/* ════════════════════════════════════════════════════════════════
   TELEMETRY BARS — vertical/horizontal density bars for trace counts
   ════════════════════════════════════════════════════════════════ */

export interface TelemetryBar {
  /** 0–100 bar height / length. */
  h: number
  /** Optional "hot" highlight. */
  hot?: boolean
}

export interface TelemetryBarsProps {
  /** Predefined bars; if omitted, random demo bars are generated. */
  values?: TelemetryBar[]
  /** Number of demo bars when values is omitted. */
  count?: number
  /** Fraction of bars to mark hot in demo mode (default 0.22). */
  hotRate?: number
  class?: string
  testId?: string
}

function clampPct(value: number): number {
  if (!Number.isFinite(value)) return 0
  return Math.max(0, Math.min(100, value))
}

export function TelemetryBars({
  values,
  count = 24,
  hotRate = 0.22,
  class: cx,
  testId,
}: TelemetryBarsProps) {
  const bars = useMemo(
    () =>
      values?.length
        ? values.map(b => ({ h: clampPct(b.h), hot: b.hot === true }))
        : Array.from({ length: count }, () => ({
            h: 18 + Math.random() * 80,
            hot: Math.random() < hotRate,
          })),
    [values, count, hotRate],
  )

  return html`
    <div
      class=${`telemetry-bars ${cx ?? ''}`.trim()}
      role="img"
      aria-label=${`Telemetry bars: ${bars.length} samples`}
      data-testid=${testId}
    >
      ${bars.map(
        (b, i) =>
          html`<div
            key=${i}
            class=${`telemetry-bars__bar ${b.hot ? 'is-hot' : ''}`}
            style=${`height: ${b.h.toFixed(2)}%;`}
          />`,
      )}
    </div>
  `
}

/* ════════════════════════════════════════════════════════════════
   WATERFALL — Gantt-style timing bars for turn phases
   ════════════════════════════════════════════════════════════════ */

export type WaterfallKind = 'ctx' | 'reason' | 'tool' | 'gen'

export interface WaterfallRow {
  kind: WaterfallKind
  label: string
  /** Render label in mono font. */
  mono?: boolean
  /** Start offset as % of total timeline. */
  left: number
  /** Duration as % of total timeline. */
  width: number
  /** Human duration string. */
  dur: string
}

export interface WaterfallProps {
  rows?: WaterfallRow[]
  total?: string
  class?: string
  testId?: string
}

const WATERFALL_KIND_LABEL: Record<WaterfallKind, string> = {
  ctx: 'ctx',
  reason: 'reason',
  tool: 'tool',
  gen: 'gen',
}

export function Waterfall({ rows = [], total, class: cx, testId }: WaterfallProps) {
  return html`
    <div class=${`waterfall ${cx ?? ''}`.trim()} data-testid=${testId}>
      ${rows.map(
        (r, i) => html`
          <div key=${i} class="waterfall__row">
            <div class="waterfall__label">
              <span class=${`waterfall__ico waterfall__ico--${r.kind}`} aria-hidden="true" />
              <span class=${`waterfall__name ${r.mono ? 'waterfall__name--mono' : ''}`}>
                ${r.label}
              </span>
            </div>
            <div class="waterfall__track" aria-hidden="true">
              <div
                class=${`waterfall__bar waterfall__bar--${r.kind}`}
                style=${`left: ${clampPct(r.left).toFixed(2)}%; width: ${clampPct(r.width).toFixed(2)}%;`}
              />
            </div>
            <div class="waterfall__dur">${r.dur}</div>
          </div>
        `,
      )}
      <div class="waterfall__foot">
        <span>total <b>${total ?? '—'}</b></span>
        <div class="waterfall__legend">
          ${(Object.keys(WATERFALL_KIND_LABEL) as WaterfallKind[]).map(
            kind => html`
              <span key=${kind}>
                <i class=${`waterfall__ico waterfall__ico--${kind}`} aria-hidden="true" />
                ${WATERFALL_KIND_LABEL[kind]}
              </span>
            `,
          )}
        </div>
      </div>
    </div>
  `
}

/* ════════════════════════════════════════════════════════════════
   FSM LIFELINE — vertical stepper showing keeper FSM states
   ════════════════════════════════════════════════════════════════ */

export interface FsmStep {
  label: string
  /** 'done' | 'cur' | anything else for pending. */
  state?: string
}

export interface FsmLifelineProps {
  steps?: FsmStep[]
  class?: string
  testId?: string
}

export function FsmLifeline({ steps = [], class: cx, testId }: FsmLifelineProps) {
  return html`
    <div
      class=${`fsm-lifeline-v2 ${cx ?? ''}`.trim()}
      role="list"
      aria-label="Keeper FSM lifeline"
      data-testid=${testId}
    >
      ${steps.map(
        (s, i) => html`
          <div key=${i} class=${`fsm-lifeline-v2__step fsm-lifeline-v2__step--${s.state ?? ''}`} role="listitem">
            <span class="fsm-lifeline-v2__pip" aria-hidden="true" />
            <span class="fsm-lifeline-v2__label">${s.label}</span>
          </div>
        `,
      )}
    </div>
  `
}

/* ════════════════════════════════════════════════════════════════
   TPS LIVE — live tokens-per-second chip
   ════════════════════════════════════════════════════════════════ */

export interface TpsLiveProps {
  rate?: number
  class?: string
  testId?: string
}

export function TpsLive({ rate = 41, class: cx, testId }: TpsLiveProps) {
  return html`
    <span class=${`tps-live ${cx ?? ''}`.trim()} data-testid=${testId}>
      <span class="tps-live__dot" aria-hidden="true" />
      <span class="tps-live__value" aria-label="${rate} tokens per second">${rate} tok/s</span>
    </span>
  `
}

/* ════════════════════════════════════════════════════════════════
   SEGMENTED PROGRESS — stacked segmented progress bar
   ════════════════════════════════════════════════════════════════ */

export interface SegmentedProgressProps {
  done?: number
  wip?: number
  blocked?: number
  /** Total value for flex ratio; defaults to sum of segments clamped to at least 1. */
  total?: number
  class?: string
  testId?: string
}

export function SegmentedProgress({
  done = 0,
  wip = 0,
  blocked = 0,
  total,
  class: cx,
  testId,
}: SegmentedProgressProps) {
  const segments = useMemo(() => {
    const d = Math.max(0, done)
    const w = Math.max(0, wip)
    const b = Math.max(0, blocked)
    const t = total != null && Number.isFinite(total) && total > 0 ? total : Math.max(1, d + w + b)
    const rest = Math.max(0, t - d - w - b)
    return [
      { key: 'done', value: d, cls: 'segmented-progress__seg--done' },
      { key: 'wip', value: w, cls: 'segmented-progress__seg--wip' },
      { key: 'blocked', value: b, cls: 'segmented-progress__seg--blocked' },
      { key: 'rest', value: rest, cls: 'segmented-progress__seg--rest' },
    ].filter(s => s.value > 0)
  }, [done, wip, blocked, total])

  return html`
    <div
      class=${`segmented-progress ${cx ?? ''}`.trim()}
      role="img"
      aria-label=${`Progress: ${done} done, ${wip} in progress, ${blocked} blocked`}
      data-testid=${testId}
    >
      ${segments.map(
        s => html`<div key=${s.key} class=${`segmented-progress__seg ${s.cls}`} style=${`flex: ${s.value};`} />`,
      )}
    </div>
  `
}

/* ════════════════════════════════════════════════════════════════
   STREAMING CARET — blinking caret for streaming text
   ════════════════════════════════════════════════════════════════ */

export interface StreamingCaretProps {
  class?: string
  testId?: string
}

export function StreamingCaret({ class: cx, testId }: StreamingCaretProps) {
  return html`<span class=${`streaming-caret ${cx ?? ''}`.trim()} aria-hidden="true" data-testid=${testId} />`
}
