/**
 * Keeper chat history schema — schema-at-boundary for
 * `GET /api/v1/keepers/:name/chat/history`.
 *
 * Contract (see dashboard/docs/API_CONTRACT.md):
 * - Types derived via `InferOutput`; no hand-typed interface remains.
 * - The endpoint returns a list whose individual items may drift; the
 *   existing caller silently drops garbage entries so operators keep
 *   seeing a clean transcript. We preserve that behaviour here with a
 *   per-item `safeParse` helper — no drift error class is needed since
 *   individual failures are non-fatal.
 * - `role` is left as open `string()` because the backend can introduce
 *   a new role (e.g. a new tool role) ahead of the dashboard; a strict
 *   enum would silently drop valid messages during the deploy window.
 *
 * Rolled out as part of #7441 (P2 rollout) following pilot #7439.
 */

import {
  number,
  object,
  safeParse,
  string,
  type InferOutput,
} from 'valibot'

export const KeeperChatHistoryMessageSchema = object({
  role: string(),
  content: string(),
  ts: number(),
})

export type KeeperChatHistoryMessage = InferOutput<typeof KeeperChatHistoryMessageSchema>

export function safeParseKeeperChatHistoryMessage(
  data: unknown,
): KeeperChatHistoryMessage | null {
  const result = safeParse(KeeperChatHistoryMessageSchema, data)
  return result.success ? result.output : null
}
