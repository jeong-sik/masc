import type { PromptSegmentTelemetry } from '../types'
import type { TurnInputComponentId } from '../api/dashboard-turn-records'

// ── Context pressure thresholds (shared across KPIs, charts) ─
export const CTX_CRITICAL_PCT = 85
export const CTX_WARN_PCT = 70
export const CTX_COLOR_CRITICAL = 'var(--color-status-err)'
export const CTX_COLOR_WARN = 'var(--amber-bright)'
export const CTX_COLOR_OK = 'var(--emerald)'

export function ctxColor(pct: number): string {
  return pct > CTX_CRITICAL_PCT ? CTX_COLOR_CRITICAL : pct > CTX_WARN_PCT ? CTX_COLOR_WARN : CTX_COLOR_OK
}

// Segment keys are `Turn_record.input_component_id` tokens
// (keeper_agent_prompt_metrics.ml), so both maps are keyed by the decoder's
// TurnInputComponentId and a new component is a type error until it is named.
export const CTX_SEGMENT_LABELS: Readonly<Record<TurnInputComponentId, string>> = {
  'prompt.keeper_instructions': 'Keeper 지침',
  'prompt.dynamic_context': '턴 컨텍스트',
  'prompt.temporal_summary': '시간 요약',
  'prompt.memory_os_recall': '메모리 회상',
  'prompt.operator_note': '운영자 노트',
  'prompt.skill_compositions': '스킬 구성',
  tool_schemas: '도구 스키마',
  message_user: '메시지 · user',
  message_system: '메시지 · system',
  message_assistant_text: '메시지 · assistant',
  message_thinking: '메시지 · thinking',
  message_redacted_thinking: '메시지 · redacted thinking',
  message_tool_use: '메시지 · tool use',
  message_tool_result: '메시지 · tool result',
  message_image: '메시지 · image',
  message_document: '메시지 · document',
  message_audio: '메시지 · audio',
}

export const CTX_SEGMENT_COLORS: Readonly<Record<TurnInputComponentId, string>> = {
  'prompt.keeper_instructions': 'var(--amber-bright)',
  'prompt.dynamic_context': 'var(--purple)',
  'prompt.temporal_summary': 'var(--cyan)',
  'prompt.memory_os_recall': 'var(--rose-light)',
  'prompt.operator_note': 'var(--amber-bright)',
  'prompt.skill_compositions': 'var(--sky-400)',
  tool_schemas: 'var(--amber-bright)',
  message_user: 'var(--sky-400)',
  message_system: 'var(--color-fg-muted)',
  message_assistant_text: 'var(--blue-400)',
  message_thinking: 'var(--purple)',
  message_redacted_thinking: 'var(--purple)',
  message_tool_use: 'var(--color-status-ok)',
  message_tool_result: 'var(--bad-light)',
  message_image: 'var(--sky-400)',
  message_document: 'var(--amber-bright)',
  message_audio: 'var(--color-status-ok)',
}

export function ctxSegmentLabel(key: string): string {
  return (CTX_SEGMENT_LABELS as Readonly<Record<string, string | undefined>>)[key]
    ?? key.replace(/[_-]+/g, ' ')
}

export function ctxSegmentColor(key: string): string {
  return (CTX_SEGMENT_COLORS as Readonly<Record<string, string | undefined>>)[key]
    ?? 'var(--color-fg-muted)'
}

/**
 * Pure filter for CTX composition "latest breakdown" entries.
 *
 * Case-insensitive substring match against either the raw segment key
 * (e.g. `message_tool_result`) or its human label (e.g. `메시지 · tool result`).
 * This lets operators search by either form — raw key is what shows up in
 * backend logs, label is what the dashboard renders.
 *
 * Empty/whitespace query returns the input reference unchanged so the
 * default render path avoids an unnecessary array allocation. Does not
 * mutate the input.
 */
export function filterCtxCompositionEntries(
  entries: ReadonlyArray<readonly [string, PromptSegmentTelemetry]>,
  query: string,
): ReadonlyArray<readonly [string, PromptSegmentTelemetry]> {
  const needle = query.trim().toLowerCase()
  if (needle === '') return entries
  return entries.filter(([key]) => {
    if (key.toLowerCase().includes(needle)) return true
    return ctxSegmentLabel(key).toLowerCase().includes(needle)
  })
}
