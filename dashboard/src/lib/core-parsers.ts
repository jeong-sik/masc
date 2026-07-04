// Total parsers for closed dashboard unions — SSOT membership co-located with
// each type, replacing the inline `=== 'a' || === 'b'` OR-chains in
// store-normalizers.ts. Each `<NAME>_VALUES` is `as const satisfies
// ReadonlyArray<T>` (every element is a valid member) AND is guarded by a
// compile-time completeness check (every member is present), so adding a
// variant to the underlying type breaks the build here instead of being
// silently rejected by a hand-written OR-chain. Mirrors the lib/agent-status.ts
// precedent and closes the completeness gap that precedent left open.

import type { Task, ExecutionSignalTruth, EvidenceSourceCore } from '../types/core'
import type { DashboardExecutionQueueItem } from '../types/dashboard-execution'

type TaskStatus = NonNullable<Task['status']>
type ExecutionTone = NonNullable<DashboardExecutionQueueItem['severity']>

/** Compile-time completeness guard. When a union gains a member that is absent
 *  from its VALUES array, `Exclude` yields that member (a non-`never` type),
 *  which violates the `extends never` bound and fails to compile at the
 *  `type _…Complete = …` line below. */
type NoMissingVariant<Missing extends never> = Missing

// ── Task.status ──────────────────────────────────────────────
export const TASK_STATUS_VALUES = [
  'todo',
  'in_progress',
  'claimed',
  'awaiting_verification',
  'done',
  'cancelled',
] as const satisfies ReadonlyArray<TaskStatus>
export type _TaskStatusComplete = NoMissingVariant<
  Exclude<TaskStatus, (typeof TASK_STATUS_VALUES)[number]>
>
const TASK_STATUS_SET: ReadonlySet<string> = new Set(TASK_STATUS_VALUES)

/** Task.status total parser: trims + lowercases, maps the legacy `inprogress`
 *  alias to `in_progress`, and returns undefined for unknown tokens. */
export function parseTaskStatus(value: unknown): TaskStatus | undefined {
  const raw = typeof value === 'string' ? value.trim().toLowerCase() : ''
  if (TASK_STATUS_SET.has(raw)) return raw as TaskStatus
  if (raw === 'inprogress') return 'in_progress'
  return undefined
}

// ── DashboardExecutionQueueItem.severity (execution tone) ─────
export const EXECUTION_TONE_VALUES = [
  'ok',
  'warn',
  'bad',
] as const satisfies ReadonlyArray<ExecutionTone>
export type _ExecutionToneComplete = NoMissingVariant<
  Exclude<ExecutionTone, (typeof EXECUTION_TONE_VALUES)[number]>
>
const EXECUTION_TONE_SET: ReadonlySet<string> = new Set(EXECUTION_TONE_VALUES)

/** Execution-tone total parser: lowercases (no trim, matching the original
 *  callsite), returns undefined for unknown tokens. */
export function parseExecutionTone(value: unknown): ExecutionTone | undefined {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  return EXECUTION_TONE_SET.has(raw) ? (raw as ExecutionTone) : undefined
}

// ── ExecutionSignalTruth ─────────────────────────────────────
export const SIGNAL_TRUTH_VALUES = [
  'live',
  'stale',
  'absent',
] as const satisfies ReadonlyArray<ExecutionSignalTruth>
export type _SignalTruthComplete = NoMissingVariant<
  Exclude<ExecutionSignalTruth, (typeof SIGNAL_TRUTH_VALUES)[number]>
>
const SIGNAL_TRUTH_SET: ReadonlySet<string> = new Set(SIGNAL_TRUTH_VALUES)

/** ExecutionSignalTruth parser over an already-coerced string (the callsite
 *  applies `asString`). Case-sensitive, matching the original OR-chain. */
export function parseSignalTruth(
  raw: string | undefined,
): ExecutionSignalTruth | undefined {
  return raw != null && SIGNAL_TRUTH_SET.has(raw)
    ? (raw as ExecutionSignalTruth)
    : undefined
}

// ── EvidenceSourceCore ───────────────────────────────────────
export const EVIDENCE_SOURCE_VALUES = [
  'message',
  'presence',
  'none',
] as const satisfies ReadonlyArray<EvidenceSourceCore>
export type _EvidenceSourceComplete = NoMissingVariant<
  Exclude<EvidenceSourceCore, (typeof EVIDENCE_SOURCE_VALUES)[number]>
>
const EVIDENCE_SOURCE_SET: ReadonlySet<string> = new Set(EVIDENCE_SOURCE_VALUES)

/** EvidenceSourceCore parser over an already-coerced string (the callsite
 *  applies `asString`). Case-sensitive, matching the original OR-chain. */
export function parseEvidenceSource(
  raw: string | undefined,
): EvidenceSourceCore | undefined {
  return raw != null && EVIDENCE_SOURCE_SET.has(raw)
    ? (raw as EvidenceSourceCore)
    : undefined
}
