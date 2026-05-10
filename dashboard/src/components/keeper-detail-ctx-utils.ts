import type { PromptSegmentTelemetry } from '../types'

// ── Context pressure thresholds (shared across KPIs, charts) ─
export const CTX_CRITICAL_PCT = 85
export const CTX_WARN_PCT = 70
export const CTX_COLOR_CRITICAL = 'var(--color-status-err)'
export const CTX_COLOR_WARN = 'var(--amber-bright)'
export const CTX_COLOR_OK = 'var(--emerald)'

export function ctxColor(pct: number): string {
  return pct > CTX_CRITICAL_PCT ? CTX_COLOR_CRITICAL : pct > CTX_WARN_PCT ? CTX_COLOR_WARN : CTX_COLOR_OK
}

export function autonomyHint(count: number | undefined, proactiveEnabled: boolean | undefined): string | undefined {
  if ((count ?? 0) === 0) return proactiveEnabled ? '활성 · 미발동' : '자율 비활성'
  return undefined
}

export const CTX_SEGMENT_LABELS: Record<string, string> = {
  system_prompt: '시스템 프롬프트',
  dynamic_context: '턴 컨텍스트',
  memory_context: '메모리',
  temporal_context: '시간',
  user_message: '현재 입력',
  history_user: '히스토리 · user',
  history_assistant_text: '히스토리 · assistant',
  history_tool_use: '히스토리 · tool use',
  history_tool_result: '히스토리 · tool result',
  history_other: '히스토리 · 기타',
  unattributed: '미할당',
}

export const CTX_SEGMENT_COLORS: Record<string, string> = {
  system_prompt: 'var(--amber-bright)',
  dynamic_context: 'var(--purple)',
  memory_context: 'var(--rose-light)',
  temporal_context: 'var(--cyan)',
  user_message: 'var(--sky-400)',
  history_user: 'var(--purple)',
  history_assistant_text: 'var(--blue-400)',
  history_tool_use: 'var(--color-status-ok)',
  history_tool_result: 'var(--bad-light)',
  history_other: 'var(--color-fg-muted)',
  unattributed: 'var(--color-border-default)',
}

export function ctxSegmentLabel(key: string): string {
  return CTX_SEGMENT_LABELS[key] ?? key.replace(/[_-]+/g, ' ')
}

export function ctxSegmentColor(key: string): string {
  return CTX_SEGMENT_COLORS[key] ?? 'var(--color-fg-muted)'
}

/**
 * Pure filter for CTX composition "latest breakdown" entries.
 *
 * Case-insensitive substring match against either the raw segment key
 * (e.g. `history_tool_result`) or its human label (e.g. `History · tool result`).
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

export function formatDuration(sec: number): string {
  if (sec < 60) return `${sec}초`
  if (sec < 3600) return `${Math.floor(sec / 60)}분`
  return `${Math.floor(sec / 3600)}시간 ${Math.floor((sec % 3600) / 60)}분`
}
