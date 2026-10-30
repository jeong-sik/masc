import type { TurnRecordEntry } from '../api/dashboard-turn-records'

/** Same-turn evidence only: a request is not a measurement of client capacity. */
export function turnContextWindow(record: TurnRecordEntry) {
  const configured = record.context_window ?? null
  const reported = record.provider_context_window ?? null
  const window = reported ?? configured
  const label = reported !== null ? '실측 컨텍스트' : '설정 기준 컨텍스트'
  const input = record.input_tokens
  const percent = record.usage_scope === 'per_request'
    && input != null && window !== null && window > 0 && input <= window
    ? input / window * 100
    : null
  return { configured, reported, window, label, percent }
}
