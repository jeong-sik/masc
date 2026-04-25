// Telemetry source metadata — SSOT for labels, colors, and icons.
// Used by telemetry-unified, fleet-telemetry-panel, and any view rendering
// the append-only JSONL telemetry stores.

type TelemetrySourceKey =
  | 'keeper_metric'
  | 'agent_event'
  | 'tool_call_io'
  | 'trajectory_tool_call'
  | 'tool_usage'
  | 'oas_event'
  | 'execution_receipt'
  | 'goal_event'
  | 'tool_metric'

interface TelemetrySourceMeta {
  label: string
  sublabel: string
  color: string
  icon: string
}

export const TELEMETRY_SOURCE_META: Record<TelemetrySourceKey, TelemetrySourceMeta> = {
  keeper_metric: { label: 'Keeper 턴 로그', sublabel: 'heartbeat ~80%, 실제 추론 턴 ~20%', color: 'text-blue-400', icon: 'K' },
  agent_event: { label: 'Agent 이벤트', sublabel: 'tool_called 다수, join/leave/task 포함', color: 'text-emerald-400', icon: 'A' },
  tool_call_io: { label: 'Keeper Tool I/O', sublabel: 'keeper->tool 입출력 전체 기록', color: 'text-amber-400', icon: 'T' },
  trajectory_tool_call: { label: 'Trajectory Tool', sublabel: 'tool-stats durable rows', color: 'text-lime-400', icon: 'R' },
  tool_usage: { label: 'Keeper 내부 호출', sublabel: 'keeper_internal caller 기록', color: 'text-purple-400', icon: 'U' },
  oas_event: { label: 'OAS 이벤트', sublabel: 'native/custom event bus durable relay', color: 'text-rose-400', icon: 'O' },
  execution_receipt: { label: 'Execution Receipt', sublabel: 'keeper turn terminal receipts', color: 'text-orange-400', icon: 'E' },
  goal_event: { label: 'Goal FSM 이벤트', sublabel: 'goal lifecycle and verification events', color: 'text-sky-400', icon: 'G' },
  tool_metric: { label: 'Tool 성능', sublabel: 'duration/success 측정', color: 'text-cyan-400', icon: 'M' },
}

/** Get source label — returns Korean label, falls back to raw key. */
export function telemetrySourceLabel(source: string): string {
  return TELEMETRY_SOURCE_META[source as TelemetrySourceKey]?.label ?? source
}

/** Get full source meta — returns defaults for unknown sources. */
export function telemetrySourceMeta(source: string): TelemetrySourceMeta {
  return TELEMETRY_SOURCE_META[source as TelemetrySourceKey]
    ?? { label: source, sublabel: '', color: 'text-gray-400', icon: '?' }
}
