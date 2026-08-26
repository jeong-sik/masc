// Tool-call output store.
//
// The keeper chat stream never carries tool *results* — TOOL_CALL_END only
// flips a row to "delivered" (keeper-stream.ts), and the persisted chat
// history row holds the arguments only (keeper_chat_store). The output lives
// on a separate surface, GET /api/v1/keepers/:name/tool-calls. Both surfaces
// carry MASC's canonical execution_id, which is the only cross-store join
// authority. Provider tool_use_id remains opaque, optional correlation data:
// it may be blank or reused and never identifies a dashboard row or output.
import { signal } from '@preact/signals'
import type { ToolCallEntry } from './api/dashboard'

export function nonBlankToolCallId(
  toolCallId: string | null | undefined,
): string | null {
  return toolCallId?.trim() ? toolCallId : null
}

function nonBlankExecutionId(executionId: string | null | undefined): string | null {
  return executionId?.trim() ? executionId : null
}

// Global join table: canonical execution_id → tool-call IO entry.
// Replaced (not mutated) on each merge so signal subscribers re-render.
export const toolCallOutputsByExecutionId = signal<Map<string, ToolCallEntry>>(new Map())

interface ToolCallOutputHydrationState {
  inFlight: number
  coveredSinceMs: number | null
  coveredThroughMs: number | null
  failed: boolean
  failureReason: string | null
  lastStartedAtMs: number | null
  lastCompletedAtMs: number | null
}

export const toolCallOutputHydrationByKeeper = signal<Record<string, ToolCallOutputHydrationState>>({})

export type ToolCallOutputHydrationStatus = 'idle' | 'hydrating' | 'hydrated' | 'failed'

export interface ToolCallOutputHydrationContract {
  source: 'tool_calls_endpoint'
  status: ToolCallOutputHydrationStatus
  failureReason: string | null
  startedAtMs: number | null
  completedAtMs: number | null
  coveredSinceMs: number | null
  coveredThroughMs: number | null
}

function keeperKey(keeperName: string): string {
  return keeperName.trim()
}

function currentHydrationState(keeperName: string): ToolCallOutputHydrationState {
  return toolCallOutputHydrationByKeeper.value[keeperName] ?? {
    inFlight: 0,
    coveredSinceMs: null,
    coveredThroughMs: null,
    failed: false,
    failureReason: null,
    lastStartedAtMs: null,
    lastCompletedAtMs: null,
  }
}

function updateHydrationState(
  keeperName: string,
  update: (current: ToolCallOutputHydrationState) => ToolCallOutputHydrationState,
): void {
  const key = keeperKey(keeperName)
  if (!key) return
  const current = currentHydrationState(key)
  const next = update(current)
  if (
    current.inFlight === next.inFlight
    && current.coveredSinceMs === next.coveredSinceMs
    && current.coveredThroughMs === next.coveredThroughMs
    && current.failed === next.failed
    && current.failureReason === next.failureReason
    && current.lastStartedAtMs === next.lastStartedAtMs
    && current.lastCompletedAtMs === next.lastCompletedAtMs
  ) return
  toolCallOutputHydrationByKeeper.value = {
    ...toolCallOutputHydrationByKeeper.value,
    [key]: next,
  }
}

export function markToolCallOutputsHydrating(keeperName: string): number {
  const startedAtMs = Date.now()
  const key = keeperKey(keeperName)
  if (!key) return startedAtMs
  updateHydrationState(key, current => ({
    ...current,
    inFlight: current.inFlight + 1,
    failed: false,
    failureReason: null,
    lastStartedAtMs: startedAtMs,
  }))
  return startedAtMs
}

function mergeCoveredSince(current: number | null, next: number | null): number | null {
  if (current == null || next == null) return null
  return Math.min(current, next)
}

export function markToolCallOutputsHydrated(
  keeperName: string,
  coveredThroughMs: number,
  coveredSinceMs: number | null = null,
): void {
  updateHydrationState(keeperName, current => ({
    ...current,
    inFlight: Math.max(0, current.inFlight - 1),
    coveredSinceMs: current.coveredThroughMs == null
      ? coveredSinceMs
      : mergeCoveredSince(current.coveredSinceMs, coveredSinceMs),
    coveredThroughMs: Math.max(current.coveredThroughMs ?? 0, coveredThroughMs),
    failed: false,
    failureReason: null,
    lastCompletedAtMs: Date.now(),
  }))
}

export function markToolCallOutputsHydrationFailed(
  keeperName: string,
  reason: string | null = null,
): void {
  const key = keeperKey(keeperName)
  if (!key) return
  updateHydrationState(key, current => ({
    ...current,
    inFlight: Math.max(0, current.inFlight - 1),
    failed: true,
    failureReason: reason,
    lastCompletedAtMs: Date.now(),
  }))
}

export function toolCallOutputsCoveredThroughMs(keeperName: string): number | null {
  const key = keeperKey(keeperName)
  return key ? (toolCallOutputHydrationByKeeper.value[key]?.coveredThroughMs ?? null) : null
}

export function toolCallOutputsCoveredSinceMs(keeperName: string): number | null {
  const key = keeperKey(keeperName)
  return key ? (toolCallOutputHydrationByKeeper.value[key]?.coveredSinceMs ?? null) : null
}

export function toolCallOutputHydrationStatus(keeperName: string): ToolCallOutputHydrationStatus {
  const key = keeperKey(keeperName)
  if (!key) return 'idle'
  const state = toolCallOutputHydrationByKeeper.value[key]
  if (!state) return 'idle'
  if (state.inFlight > 0) return 'hydrating'
  if (state.failed) return 'failed'
  if (state.coveredThroughMs != null) return 'hydrated'
  return 'idle'
}

export function toolCallOutputHydrationFailureReason(keeperName: string): string | null {
  const key = keeperKey(keeperName)
  return key ? (toolCallOutputHydrationByKeeper.value[key]?.failureReason ?? null) : null
}

export function toolCallOutputHydrationContract(
  keeperName: string,
): ToolCallOutputHydrationContract {
  const key = keeperKey(keeperName)
  const state = key ? toolCallOutputHydrationByKeeper.value[key] : undefined
  return {
    source: 'tool_calls_endpoint',
    status: key ? toolCallOutputHydrationStatus(key) : 'idle',
    failureReason: state?.failureReason ?? null,
    startedAtMs: state?.lastStartedAtMs ?? null,
    completedAtMs: state?.lastCompletedAtMs ?? null,
    coveredSinceMs: state?.coveredSinceMs ?? null,
    coveredThroughMs: state?.coveredThroughMs ?? null,
  }
}

/** Merge tool-call entries by exact canonical execution_id. */
export function recordToolCallOutputs(entries: readonly ToolCallEntry[]): void {
  let changed = false
  const next = new Map(toolCallOutputsByExecutionId.value)
  for (const entry of entries) {
    const executionId = nonBlankExecutionId(entry.execution_id)
    if (!executionId) continue
    next.set(executionId, entry)
    changed = true
  }
  if (changed) toolCallOutputsByExecutionId.value = next
}

/** Look up output by canonical execution_id. */
export function lookupToolCallOutput(
  executionId: string | null | undefined,
): ToolCallEntry | null {
  const id = nonBlankExecutionId(executionId)
  if (!id) return null
  return toolCallOutputsByExecutionId.value.get(id) ?? null
}

/** Test/teardown helper: drop all recorded outputs. */
export function resetToolCallOutputs(): void {
  toolCallOutputsByExecutionId.value = new Map()
  toolCallOutputHydrationByKeeper.value = {}
}
