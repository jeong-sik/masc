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
  tool_schemas: '도구 스키마',
  canonical_history: '정식 히스토리',
  current_user: '현재 사용자 입력',
  extra_system_context: '추가 시스템 컨텍스트',
  'context_block.dynamic_context': '주입 블록 · 턴 컨텍스트',
  'context_block.temporal_summary': '주입 블록 · 시간 요약',
  'context_block.memory_os_recall': '주입 블록 · Memory OS recall',
}

export const CTX_SEGMENT_COLORS: Record<string, string> = {
  system_prompt: 'var(--amber-bright)',
  tool_schemas: 'var(--color-status-ok)',
  canonical_history: 'var(--blue-400)',
  current_user: 'var(--sky-400)',
  extra_system_context: 'var(--rose-light)',
  'context_block.dynamic_context': 'var(--purple)',
  'context_block.temporal_summary': 'var(--cyan)',
  'context_block.memory_os_recall': 'var(--rose-light)',
}

export function ctxSegmentLabel(key: string): string {
  if (key.startsWith('caller_projection.')) {
    return `호출자 projection · ${key.slice('caller_projection.'.length)}`
  }
  if (key.startsWith('context_block.')) {
    return CTX_SEGMENT_LABELS[key] ?? `주입 블록 · ${key.slice('context_block.'.length).replace(/[_-]+/g, ' ')}`
  }
  const parts = key.split('.')
  if (parts.length > 1) {
    const origin = ctxSegmentLabel(parts.slice(0, -1).join('.'))
    return `${origin} · ${parts[parts.length - 1]?.replace(/[_-]+/g, ' ')}`
  }
  return CTX_SEGMENT_LABELS[key] ?? key.replace(/[_-]+/g, ' ')
}

export function ctxSegmentColor(key: string): string {
  if (key.startsWith('canonical_history.')) {
    if (key.endsWith('.tool_result')) return 'var(--bad-light)'
    if (key.endsWith('.tool_use')) return 'var(--color-status-ok)'
    if (key.endsWith('.thinking') || key.endsWith('.reasoning_details')) return 'var(--purple)'
    return CTX_SEGMENT_COLORS.canonical_history ?? 'var(--blue-400)'
  }
  if (key.startsWith('context_block.memory_os_recall')) return 'var(--rose-light)'
  if (key.startsWith('caller_projection.')) return 'var(--cyan)'
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
