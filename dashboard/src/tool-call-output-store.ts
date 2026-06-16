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
const TOOL_ENTRY_ID_PREFIX = 'tool-'

// Global join table: tool_use_id → the tool-call IO entry (input + output).
// Replaced (not mutated) on each merge so signal subscribers re-render.
export const toolCallOutputsById = signal<Map<string, ToolCallEntry>>(new Map())

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
  const toolUseId = toolEntryId.startsWith(TOOL_ENTRY_ID_PREFIX)
    ? toolEntryId.slice(TOOL_ENTRY_ID_PREFIX.length)
    : toolEntryId
  return toolCallOutputsById.value.get(toolUseId) ?? null
}

/** Test/teardown helper: drop all recorded outputs. */
export function resetToolCallOutputs(): void {
  toolCallOutputsById.value = new Map()
}
