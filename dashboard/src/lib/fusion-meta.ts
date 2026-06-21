// Fusion sink compatibility helpers shared by Board evidence, the standalone
// Fusion surface, and keeper chat cards. All consumers parse the same
// `meta.source === 'fusion'` payload emitted by `fusion_sink.ml`; this module
// is the single source of truth for that normalization.

function decodeOcamlStringLiteral(value: string): string {
  return value
    .replace(/\\\\/g, '\u0000')
    .replace(/\\"/g, '"')
    .replace(/\\n/g, '\n')
    .replace(/\\t/g, '\t')
    .replace(/\u0000/g, '\\')
}

function normalizeProviderAttribution(model: string, reason: string): string {
  const unknownPrefix = "Provider 'unknown'"
  if (model === '?' || !reason.startsWith(unknownPrefix)) return reason
  return `Provider '${model}'${reason.slice(unknownPrefix.length)}`
}

/**
 * Unwrap OCaml `Fusion_types.Provider_error / Timeout / Empty_response`
 * literals and re-attribute `Provider 'unknown'` failures to the real model id.
 */
export function normalizeFusionPanelReason(model: string, reason: string | undefined): string | undefined {
  if (!reason) return undefined
  const trimmed = reason.trim()
  const providerMatch = trimmed.match(/^\(?\s*Fusion_types\.Provider_error\s+"([\s\S]*)"\s*\)?$/)
  if (providerMatch) {
    return normalizeProviderAttribution(model, decodeOcamlStringLiteral(providerMatch[1] ?? '').trim())
  }
  if (/^\(?\s*Fusion_types\.Timeout\s*\)?$/.test(trimmed)) return 'timeout'
  if (/^\(?\s*Fusion_types\.Empty_response\s*\)?$/.test(trimmed)) return 'empty response'
  return normalizeProviderAttribution(model, trimmed)
}

// ---------------------------------------------------------------------------
// Generic defensive helpers for loose wire metadata
// ---------------------------------------------------------------------------

export function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
}

export function asRecord(value: unknown): Record<string, unknown> | null {
  return isRecord(value) ? value : null
}

export function asString(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

export function asNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'string') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

export function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const text = asString(item)
    return text ? [text] : []
  })
}

export function firstString(source: Record<string, unknown>, keys: string[]): string | null {
  for (const key of keys) {
    const value = asString(source[key])
    if (value) return value
  }
  return null
}

export function firstNumber(source: Record<string, unknown>, keys: string[]): number | null {
  for (const key of keys) {
    const value = asNumber(source[key])
    if (value !== null) return value
  }
  return null
}

// ---------------------------------------------------------------------------
// Shared fusion evidence types
// ---------------------------------------------------------------------------

export type FusionPanelEntry = {
  model: string
  status: string
  answer?: string | null
  reason?: string | null
  reasonCode?: string | null
  inputTokens?: number | null
  outputTokens?: number | null
}

export type FusionJudgeView = {
  status: string
  decision?: string | null
  // `render_judge` markdown from fusion_sink.ml. Prefer this; fall back to
  // `resolvedAnswer` for older posts written before synthesis was serialized.
  synthesis?: string | null
  resolvedAnswer?: string | null
  error?: string | null
}

export type FusionUsage = {
  inputTokens?: number | null
  outputTokens?: number | null
}

export type FusionEvidence = {
  source: 'fusion'
  runId?: string | null
  question?: string | null
  panel: FusionPanelEntry[]
  judge: FusionJudgeView | null
  usage: FusionUsage | null
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

function normalizePanelEntry(value: unknown, index: number): FusionPanelEntry | null {
  const entry = asRecord(value)
  if (!entry) return null
  const usage = asRecord(entry.usage)
  const model = firstString(entry, ['model', 'name', 'provider']) ?? `panel-${index + 1}`
  const reasonRaw = firstString(entry, ['reason_detail', 'reason', 'error', 'error_text'])
  return {
    model,
    status: firstString(entry, ['status']) ?? 'unknown',
    answer: firstString(entry, ['answer', 'content', 'output']),
    reason: reasonRaw ? normalizeFusionPanelReason(model, reasonRaw) : undefined,
    reasonCode: firstString(entry, ['reason_code']) ?? undefined,
    inputTokens:
      firstNumber(entry, ['input_tokens', 'inputTokens'])
      ?? firstNumber(usage ?? {}, ['input_tokens', 'inputTokens'])
      ?? undefined,
    outputTokens:
      firstNumber(entry, ['output_tokens', 'outputTokens'])
      ?? firstNumber(usage ?? {}, ['output_tokens', 'outputTokens'])
      ?? undefined,
  }
}

export function normalizeFusionPanel(value: unknown): FusionPanelEntry[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry, index) => {
    const normalized = normalizePanelEntry(entry, index)
    return normalized ? [normalized] : []
  })
}

export function normalizeFusionJudge(value: unknown): FusionJudgeView | null {
  const judge = asRecord(value)
  if (!judge) return null
  return {
    status: firstString(judge, ['status']) ?? 'unknown',
    decision: firstString(judge, ['decision', 'verdict']) ?? undefined,
    synthesis: firstString(judge, ['synthesis', 'rationale', 'summary']) ?? undefined,
    resolvedAnswer: firstString(judge, ['resolved_answer', 'resolvedAnswer', 'answer']) ?? undefined,
    error: firstString(judge, ['error', 'reason', 'error_text']) ?? undefined,
  }
}

export function normalizeFusionUsage(
  meta: Record<string, unknown>,
  panel?: FusionPanelEntry[],
): FusionUsage {
  const observed = asRecord(meta.observed_usage) ?? {}
  const summedInput = (panel ?? []).reduce((sum, entry) => sum + (entry.inputTokens ?? 0), 0)
  const summedOutput = (panel ?? []).reduce((sum, entry) => sum + (entry.outputTokens ?? 0), 0)
  const inputTokens =
    firstNumber(observed, ['input_tokens', 'inputTokens'])
    ?? firstNumber(meta, ['input_tokens', 'inputTokens'])
    ?? (summedInput > 0 ? summedInput : null)
  const outputTokens =
    firstNumber(observed, ['output_tokens', 'outputTokens'])
    ?? firstNumber(meta, ['output_tokens', 'outputTokens'])
    ?? (summedOutput > 0 ? summedOutput : null)
  return {
    inputTokens: inputTokens ?? undefined,
    outputTokens: outputTokens ?? undefined,
  }
}

export function extractFusionEvidence(meta: unknown): FusionEvidence | null {
  if (!isRecord(meta)) return null

  const nested = asRecord(meta.fusion_deliberation)
  const effective: Record<string, unknown> = nested ? { ...nested, source: 'fusion' } : meta

  const panel = normalizeFusionPanel(effective.panel)
  const judge = normalizeFusionJudge(effective.judge)
  const runId = firstString(effective, ['run_id', 'runId', 'id'])

  // Explicit source tag is canonical. As a defensive fallback, treat any meta
  // carrying panel + (judge | run_id) as fusion evidence so older payloads or
  // schema drift still render.
  const isFusion =
    asString(effective.source) === 'fusion'
    || (panel.length > 0 && (judge !== null || Boolean(runId)))
  if (!isFusion) return null

  return {
    source: 'fusion',
    runId,
    question: firstString(effective, ['question', 'prompt']),
    panel,
    judge,
    usage: normalizeFusionUsage(effective, panel),
  }
}
