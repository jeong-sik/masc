import type { TurnInputProvenance, TurnRecordEntry } from '../api/dashboard-turn-records'

// How a gauge may read a row's input count, as the server's context projection
// reads it (lib/keeper/keeper_context_observation_projection.ml): a measured
// request or the context an ACP agent counted its session holding is a fill;
// an estimate is shown as one; a row written before provenance existed is
// neither.
type FillReading = 'counted' | 'estimated' | 'unknown'

function fillReading(provenance: TurnInputProvenance | undefined): FillReading {
  switch (provenance) {
    case 'measured_request':
    case 'agent_held_context':
      return 'counted'
    case 'context_estimate':
      return 'estimated'
    case undefined:
      return 'unknown'
    default: {
      const unhandled: never = provenance
      return unhandled
    }
  }
}

/** Same-turn evidence only: a request is not a measurement of client capacity. */
export function turnContextWindow(record: TurnRecordEntry) {
  const configured = record.context_window ?? null
  const reported = record.provider_context_window ?? null
  const window = reported ?? configured
  const label = reported !== null ? '실측 컨텍스트' : '설정 기준 컨텍스트'
  const input = record.input_tokens
  const fill = record.usage_scope === 'per_request'
    && input != null && window !== null && window > 0 && input <= window
    ? input / window * 100
    : null
  const reading = fillReading(record.input_provenance)
  const percent = reading === 'counted' ? fill : null
  const estimatedPercent = reading === 'estimated' ? fill : null
  return { configured, reported, window, label, percent, estimatedPercent }
}

/** The fill as an inspector writes it: a counted percent, an estimate marked
 *  with `~`, or null when the row holds neither. */
export function formatContextFill(
  context: { readonly percent: number | null; readonly estimatedPercent: number | null },
  fractionDigits: number,
): string | null {
  if (context.percent !== null) return `${context.percent.toFixed(fractionDigits)}%`
  if (context.estimatedPercent !== null) return `~${context.estimatedPercent.toFixed(fractionDigits)}%`
  return null
}
