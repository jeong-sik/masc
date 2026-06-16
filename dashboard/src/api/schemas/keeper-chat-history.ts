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
  optional,
  record,
  safeParse,
  string,
  unknown,
  type InferOutput,
} from 'valibot'

export const SurfaceRefSchema = object({
  kind: string(),
  session_id: optional(string()),
  guild_id: optional(string()),
  channel_id: optional(string()),
  parent_channel_id: optional(string()),
  thread_id: optional(string()),
  team_id: optional(string()),
  thread_ts: optional(string()),
  repo: optional(string()),
  notification_id: optional(string()),
  source: optional(string()),
  event_id: optional(string()),
  label: optional(string()),
  address: optional(record(string(), string())),
})

// RFC-0235 P1/P3: synthesized voice clip. Backend uses snake_case in
// history rows (lib/keeper/keeper_chat_store.ml) and camelCase in SSE
// payloads (lib/keeper/keeper_chat_broadcast.ml). We accept both at the
// boundary and let normalizers canonicalize to camelCase.
export const KeeperChatHistoryAudioClipSchema = object({
  token: string(),
  audio_url: optional(string()),
  audioUrl: optional(string()),
  mime: string(),
  duration_sec: optional(number()),
  durationSec: optional(number()),
  message_text: optional(string()),
  messageText: optional(string()),
  device_id: optional(string()),
  deviceId: optional(string()),
})

export type KeeperChatHistoryAudioClip = InferOutput<typeof KeeperChatHistoryAudioClipSchema>

export const KeeperChatHistoryMessageSchema = object({
  // R3: producer-assigned stable message id (keeper_chat_store.ml mints it
  // at append and the read boundary stamps legacy rows, so the backend now
  // emits it on every row). Left optional for the deploy window — a
  // dashboard deployed ahead of the backend would otherwise drop every
  // message; the consumer falls back to a stable content-derived id when
  // it is absent.
  id: optional(string()),
  role: string(),
  content: string(),
  ts: number(),
  // Tool-call rows (role === 'tool') persisted by keeper_chat_store.ml
  // carry the executed tool's id/name; `content` holds the accumulated
  // argument JSON. `source` names the originating connector
  // ('dashboard' | 'discord' | 'slack' | 'agent') on every row of a
  // turn. Connector rows may also carry opaque conversation/message
  // coordinates so UI surfaces can group platform channels/threads.
  // These fields are absent on legacy rows.
  tool_call_id: optional(string()),
  tool_call_name: optional(string()),
  source: optional(string()),
  surface: optional(SurfaceRefSchema),
  conversation_id: optional(string()),
  external_message_id: optional(string()),
  // RFC-0223 P1 speaker identity, present on user rows written since
  // then. `speaker_authority` is 'owner' (authenticated dashboard
  // operator) or 'external' (arbitrary person on a connector channel);
  // left as open string() per the same deploy-window rationale as
  // `role` above. id/name are absent when the route supplies none
  // (dashboard rows carry authority only).
  speaker_id: optional(string()),
  speaker_name: optional(string()),
  speaker_authority: optional(string()),
  // RFC-0235 P1/P3: audio clip field. The wire object is accepted as
  // `unknown` at the boundary so malformed clips do not cause the whole
  // message to be dropped; `normalizeAudioClip` validates before use.
  audio: optional(unknown()),
})

export type KeeperChatHistoryMessage = InferOutput<typeof KeeperChatHistoryMessageSchema>

export function safeParseKeeperChatHistoryMessage(
  data: unknown,
): KeeperChatHistoryMessage | null {
  const result = safeParse(KeeperChatHistoryMessageSchema, data)
  return result.success ? result.output : null
}
