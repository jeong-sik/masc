// Fusion sink compatibility helpers shared by Board evidence, the standalone
// Fusion surface, and keeper chat cards. All consumers parse the same
// `meta.source === 'fusion'` payload emitted by `fusion_sink.ml`; this module
// is the single source of truth for that normalization.

import { isRecord } from './type-guards'
import { asRecord, asString, asBoolean } from './json-coerce'

/**
 * Normalize the structured `reason_detail` emitted by `fusion_sink.ml`.
 * Failure attribution is carried by separate structured fields; this function
 * never reclassifies or rewrites human-readable detail strings.
 */
export function normalizeFusionPanelReason(reason: string | undefined): string | undefined {
  if (!reason) return undefined
  const trimmed = reason.trim()
  if (trimmed === '') return undefined
  return trimmed
}

// ---------------------------------------------------------------------------
// Generic defensive helpers for loose wire metadata
// ---------------------------------------------------------------------------

// `asString`/`asRecord` are imported from `lib/json-coerce.ts` so this module
// stays in the `lib/` layer and does not depend on `components/`. `asNumber`
// is kept local because fusion wire data emits token counts as both numbers and
// numeric strings, which the stricter `json-coerce.asNumber` rejects.

function asNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'string') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
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
  // RFC-0284 per-judge-node observation array. Additive alongside the canonical
  // singular `judge`; `[]` when the meta predates the `judges` array. Carries the
  // execution topology (JoJ / refine / simple) for the board evidence card.
  judges: FusionJudgeNode[]
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
    reason: reasonRaw ? normalizeFusionPanelReason(reasonRaw) : undefined,
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

// ---------------------------------------------------------------------------
// RFC-0284 judge-node observation array (`judges`)
// ---------------------------------------------------------------------------

// One judge execution node from `fusion_sink.ml judge_node_meta`. `role` is the
// closed backend enum (single | refine | first | meta) but kept as a string so
// an unanticipated role degrades to a raw badge instead of being dropped.
// Successful Synthesized nodes carry per-node decision/summary, while failed
// nodes carry failure attribution. The compact topology strip still reads only
// the observed array shape.
export type FusionJudgeNode = {
  role: string
  identity: string
  failed: boolean
  error?: string | null
  decision?: string | null
  summary?: string | null
  failureCode?: string | null
  elapsedS?: number | null
  timedOut?: boolean
  inputTokens?: number | null
  outputTokens?: number | null
}

// Structural classification of a judges array, derived from shape alone (the
// array carries no topology field). Language-free so the lib stays i18n-neutral;
// the component maps it to a display label.
export type FusionJudgeShape = 'single' | 'refine' | 'judge-of-judges' | 'custom'

/**
 * Normalize the RFC-0284 `judges` observation array. Each element is a
 * Synthesized node (role/identity + synthesis sections + per-node usage) or a
 * Judge_failed node (role/identity + status:"failed" + error + usage); only the
 * Judge_failed node carries `status`, so absence of `status === 'failed'` marks
 * a successful node. Non-record elements are dropped (total over loose wire
 * data); missing role/identity get safe defaults rather than being discarded.
 */
export function normalizeFusionJudgeNodes(value: unknown): FusionJudgeNode[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item, index) => {
    const node = asRecord(item)
    if (!node) return []
    const failed = firstString(node, ['status']) === 'failed'
    return [
      {
        role: firstString(node, ['role']) ?? 'judge',
        identity: firstString(node, ['identity', 'model', 'name']) ?? `judge-${index + 1}`,
        failed,
        error: failed ? firstString(node, ['error', 'reason', 'error_text']) ?? undefined : undefined,
        decision: failed ? undefined : firstString(node, ['decision', 'verdict']) ?? undefined,
        summary: failed
          ? undefined
          : firstString(node, ['resolved_answer', 'resolvedAnswer', 'synthesis']) ?? undefined,
        failureCode: failed ? firstString(node, ['failure_code']) ?? undefined : undefined,
        elapsedS: failed ? firstNumber(node, ['elapsed_s', 'elapsedS']) ?? undefined : undefined,
        timedOut: failed ? asBoolean(node.timed_out) : undefined,
        inputTokens: firstNumber(node, ['input_tokens', 'inputTokens']) ?? undefined,
        outputTokens: firstNumber(node, ['output_tokens', 'outputTokens']) ?? undefined,
      },
    ]
  })
}

/**
 * Classify a judges array by its shape, never by a topology field (RFC-0284
 * §line 27: the frontend must not hardcode topology-name vocabulary). The
 * classification reads the per-node `role` — an observed fact carried in each
 * array element, not a topology label — which is exactly the array shape and is
 * more robust than a raw node count:
 *  - any `first` node ⟹ judge-of-judges. `First` is JoJ-exclusive on the
 *    backend (`fusion_orchestrator.ml run_judge_of_judges`), so this also
 *    classifies an all-fail JoJ correctly, where the meta node is absent and a
 *    bare count of two first-judges would otherwise read as refine.
 *  - any `refine` node ⟹ refine (the `Refine_pass` 2nd judge of refine /
 *    conditional).
 *  - a single node ⟹ single (Simple, or a refine/conditional whose 1st judge
 *    failed before the 2nd ran).
 *  - anything else ⟹ custom, so an unanticipated topology still renders.
 */
export function classifyFusionJudgeShape(nodes: readonly FusionJudgeNode[]): FusionJudgeShape {
  if (nodes.some(node => node.role === 'first')) return 'judge-of-judges'
  if (nodes.some(node => node.role === 'refine')) return 'refine'
  if (nodes.length === 1) return 'single'
  return 'custom'
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
    judges: normalizeFusionJudgeNodes(effective.judges),
    usage: normalizeFusionUsage(effective, panel),
  }
}
