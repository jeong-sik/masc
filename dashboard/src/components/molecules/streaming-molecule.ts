// keeper-v2 design streaming/live molecules — TpsLive + Sparkline from
// prototypes/keeper-v2/molecules.jsx.
//
// Live wiring (mark, don't fake):
//   - MoleculeTpsLive takes an observed rate (e.g. keeper
//     `last_output_tokens_per_sec`, src/types/core.ts). rate == null renders
//     nothing — the prototype's `rate = 41` default is catalog demo data and
//     is intentionally not ported.
//   - MoleculeSparkline takes observed values; the prototype's random-bar
//     fallback is not ported. No values → render nothing.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

/** Live throughput pill — renders only with an observed tok/s rate. */
export function MoleculeTpsLive({ rate }: { rate: number | null | undefined }): VNode | null {
  if (rate == null || !Number.isFinite(rate)) return null
  return html`
    <span class="tps-live"><span class="tps-dot"></span><span class="mono">${Math.round(rate)} tok/s</span></span>
  `
}

/** Sparkline of observed values (0..1 or raw — heights are normalized to the
 *  series max so the shape is what the operator actually measured). `label`
 *  renders the design's corner tag (.tps-spark-rt). */
export function MoleculeSparkline({ values, label }: { values: number[]; label?: string }): VNode | null {
  if (!values || values.length === 0) return null
  const max = Math.max(...values, 0.0001)
  return html`
    <div class="tps-spark">
      ${values.map((v, i) => html`<span key=${i} style=${{ height: `${Math.max(2, Math.round((v / max) * 100))}%` }} />`)}
      ${label ? html`<span class="tps-spark-rt">${label}</span>` : null}
    </div>
  `
}
