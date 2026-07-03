/**
 * Keeper catch-up digest schema — schema-at-boundary for
 * `GET /api/v1/keepers/:name/digest?since_unix=<float>`.
 *
 * Wire contract SSOT: docs/design/keeper-catchup-digest.md §"Wire contract (v1)".
 * The server assembles the digest deterministically (no LLM, no heuristics) by
 * scanning existing durable stores with a since-cursor. Every timestamp is a
 * unix-seconds float; `read_errors` surfaces per-source read failures instead
 * of dropping them silently (fail-visible).
 *
 * Unlike the tolerant per-row chat-history schema, this is a single object
 * decoded whole: `parseKeeperCatchupDigest` returns null on any shape drift and
 * the fetch layer throws, so a malformed digest never renders a wrong count.
 */

import {
  array,
  boolean,
  nullable,
  number,
  object,
  optional,
  picklist,
  safeParse,
  string,
  type InferOutput,
} from 'valibot'

const KeeperCatchupDigestChatSchema = object({
  new_messages: number(),
  // Null / absent when new_messages is 0 (no first row to anchor).
  first_new_ts: optional(nullable(number())),
  transport_failures: number(),
})

const KeeperCatchupDigestTurnsSchema = object({
  completed: number(),
  failed: number(),
  crashes: number(),
})

const KeeperCatchupDigestTaskItemSchema = object({
  task_id: string(),
  transition: string(),
  ts: number(),
})

const KeeperCatchupDigestTasksSchema = object({
  claimed: number(),
  done: number(),
  released: number(),
  cancelled: number(),
  // Capped to digest_items_cap (newest-first); the count fields above are the
  // uncapped totals.
  items: array(KeeperCatchupDigestTaskItemSchema),
})

const KeeperCatchupDigestBoardSchema = object({
  posted: number(),
  commented: number(),
  voted: number(),
})

const KeeperCatchupDigestLifecycleItemSchema = object({
  kind: string(),
  ts: number(),
})

const KeeperCatchupDigestLifecycleSchema = object({
  paused_now: boolean(),
  pause_events: number(),
  resume_events: number(),
  items: array(KeeperCatchupDigestLifecycleItemSchema),
})

const KeeperCatchupDigestCoverageCauseSchema = picklist([
  'chat_page_cap',
  'chat_retention_window',
  'jsonl_retention_window',
  'crash_scan_cap',
])

const KeeperCatchupDigestSourceCoverageSchema = object({
  lower_bound: boolean(),
  causes: optional(array(KeeperCatchupDigestCoverageCauseSchema)),
})

const KeeperCatchupDigestCoverageSchema = object({
  chat: KeeperCatchupDigestSourceCoverageSchema,
  turns: KeeperCatchupDigestSourceCoverageSchema,
  tasks: KeeperCatchupDigestSourceCoverageSchema,
  board: KeeperCatchupDigestSourceCoverageSchema,
  lifecycle: KeeperCatchupDigestSourceCoverageSchema,
})

export const KeeperCatchupDigestSchema = object({
  keeper: string(),
  since_unix: number(),
  generated_at_unix: number(),
  chat: KeeperCatchupDigestChatSchema,
  turns: KeeperCatchupDigestTurnsSchema,
  tasks: KeeperCatchupDigestTasksSchema,
  board: KeeperCatchupDigestBoardSchema,
  lifecycle: KeeperCatchupDigestLifecycleSchema,
  coverage: KeeperCatchupDigestCoverageSchema,
  read_errors: array(string()),
})

export type KeeperCatchupDigest = InferOutput<typeof KeeperCatchupDigestSchema>
export type KeeperCatchupDigestCoverageCause = InferOutput<typeof KeeperCatchupDigestCoverageCauseSchema>
export type KeeperCatchupDigestTaskItem = InferOutput<typeof KeeperCatchupDigestTaskItemSchema>
export type KeeperCatchupDigestLifecycleItem = InferOutput<typeof KeeperCatchupDigestLifecycleItemSchema>

export function parseKeeperCatchupDigest(data: unknown): KeeperCatchupDigest | null {
  const result = safeParse(KeeperCatchupDigestSchema, data)
  return result.success ? result.output : null
}
