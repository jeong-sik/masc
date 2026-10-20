// MASC v2 — fusion decision display constants (ported from prototype
// fusion-data.jsx). Judge decision → label + tone class + glyph for the
// `.fus-dec-badge` / `.msg-fusion` prototype markup. Pure data.

export interface FusionDecisionSpec {
  readonly lbl: string
  readonly cls: string
  readonly glyph: string
}

export const FUSION_DECISION: Readonly<Record<string, FusionDecisionSpec>> = {
  Answer: { lbl: '해결 답안', cls: 'ok', glyph: '✓' },
  Recommend: { lbl: '권고 (advisory)', cls: 'volt', glyph: '▸' },
  Insufficient: { lbl: '심의 무효 · 부족', cls: 'warn', glyph: '⚠' },
}

/** Decision spec lookup with a neutral fallback (unknown decisions render
 * with the raw key rather than throwing). */
export function fusionDecisionSpec(decision: string | null | undefined): FusionDecisionSpec {
  return (decision && FUSION_DECISION[decision]) || { lbl: decision || '미결', cls: '', glyph: '◈' }
}
