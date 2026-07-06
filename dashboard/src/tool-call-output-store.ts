// Tool-call output store.
//
// The keeper chat stream never carries tool *results* — TOOL_CALL_END only
// flips a row to "delivered" (keeper-stream.ts), and the persisted chat
// history row holds the arguments only (keeper_chat_store). The output lives
// on a separate surface, GET /api/v1/keepers/:name/tool-calls, keyed by the
// provider-minted tool_use_id (RFC-0233 PR-2). That id is globally unique and
// equals the chat tool row's tool_call_id for the same execution
// (keeper_chat_store.normalize_tool_call_id passes a non-empty call id through
// verbatim), so a single global id→entry map lets the chat ToolCallBubble
// derive its output by stripping the `tool-` prefix off its entry id. No
// per-keeper scoping is needed because tool_use_ids do not collide across
// keepers.
import { signal } from '@preact/signals'
import type { ToolCallEntry } from './api/dashboard'

// Chat tool entries id their rows `tool-<tool_call_id>` on both the live
// stream and history paths (keeper-stream.ts / keeper-state.ts).
export const TOOL_ENTRY_ID_PREFIX = 'tool-'

export function toolEntryIdFromCallId(toolCallId: string): string {
  return `${TOOL_ENTRY_ID_PREFIX}${toolCallId}`
}

export function toolCallIdFromToolEntryId(entryId: string): string | null {
  return entryId.startsWith(TOOL_ENTRY_ID_PREFIX)
    ? entryId.slice(TOOL_ENTRY_ID_PREFIX.length)
    : null
}

// Global join table: tool_use_id → the tool-call IO entry (input + output).
// Replaced (not mutated) on each merge so signal subscribers re-render.
export const toolCallOutputsById = signal<Map<string, ToolCallEntry>>(new Map())

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

/** Merge tool-call entries into the store, keyed by tool_use_id. Entries
 *  without a tool_use_id are skipped — they have no stable join key to the
 *  chat transcript (and their output was not persisted either, since the log
 *  only writes tool_use_id when non-empty). A later fetch overwrites an
 *  earlier entry for the same id, so re-hydration stays idempotent. */
export function recordToolCallOutputs(entries: readonly ToolCallEntry[]): void {
  let changed = false
  const next = new Map(toolCallOutputsById.value)
  for (const entry of entries) {
    if (!entry.tool_use_id) continue
    next.set(entry.tool_use_id, entry)
    changed = true
  }
  if (changed) toolCallOutputsById.value = next
}

/** Look up the tool-call IO entry for a chat tool row by its entry id
 *  (`tool-<tool_use_id>`). Returns null until the tool-call hydration lands,
 *  or for rows whose call carried no provider id. Reads the signal value, so
 *  a component calling this during render subscribes to store updates. */
export function lookupToolCallOutput(toolEntryId: string): ToolCallEntry | null {
  const toolUseId = toolCallIdFromToolEntryId(toolEntryId) ?? toolEntryId
  return toolCallOutputsById.value.get(toolUseId) ?? null
}

/** Test/teardown helper: drop all recorded outputs. */
export function resetToolCallOutputs(): void {
  toolCallOutputsById.value = new Map()
  toolCallOutputHydrationByKeeper.value = {}
}
