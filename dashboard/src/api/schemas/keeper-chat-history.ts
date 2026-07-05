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
  array,
  boolean,
  literal,
  number,
  object,
  optional,
  record,
  safeParse,
  string,
  union,
  unknown,
  type InferOutput,
} from 'valibot'

// Attachment row shape persisted by keeper_chat_store.ml (to_json_array
// :848-861): snake_case mime_type and an open `type` string. Normalized to
// the camelCase KeeperConversationAttachment at the consume boundary.
export const KeeperChatHistoryAttachmentSchema = object({
  id: string(),
  type: string(),
  name: string(),
  size: number(),
  mime_type: string(),
  data: string(),
})

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
  expired: optional(boolean()),
})

export type KeeperChatHistoryAudioClip = InferOutput<typeof KeeperChatHistoryAudioClipSchema>

const KeeperChatTableCellSchema = union([
  string(),
  object({
    v: string(),
    num: optional(boolean()),
    muted: optional(boolean()),
  }),
])

const KeeperChatTraceStepSchema = union([
  object({
    kind: literal('think'),
    text: string(),
    ts: optional(string()),
    oas_block_index: optional(number()),
    oasBlockIndex: optional(number()),
  }),
  object({
    kind: literal('reason'),
    text: string(),
    detail: optional(string()),
    ts: optional(string()),
  }),
  object({
    kind: literal('tool'),
    name: string(),
    tool_call_id: optional(string()),
    toolCallId: optional(string()),
    status: optional(union([literal('pending'), literal('ok'), literal('err')])),
    dur: optional(string()),
    args: optional(unknown()),
    result: optional(unknown()),
    ts: optional(string()),
    oas_block_index: optional(number()),
    oasBlockIndex: optional(number()),
  }),
])

// RFC-0235 P3: server-parsed rich chat blocks carried on persisted history
// rows. Keep this aligned with keeper_chat_blocks.ml and the dashboard
// renderer's ChatBlock union; malformed block arrays cause the whole row to be
// dropped by safeParseKeeperChatHistoryMessage so the transcript stays clean.
export const KeeperChatBlockSchema = union([
  object({
    t: literal('p'),
    html: string(),
  }),
  object({
    t: literal('h4'),
    html: string(),
  }),
  object({
    t: literal('ul'),
    items: array(string()),
  }),
  object({
    t: literal('callout'),
    severity: optional(union([literal('info'), literal('warn'), literal('bad')])),
    html: string(),
  }),
  object({
    t: literal('table'),
    head: array(KeeperChatTableCellSchema),
    rows: array(array(KeeperChatTableCellSchema)),
  }),
  object({
    t: literal('code'),
    cap: optional(string()),
    html: string(),
    source: optional(string()),
  }),
  object({
    t: literal('mermaid'),
    source: string(),
    caption: optional(string()),
  }),
  object({
    t: literal('svg'),
    svg: string(),
    cap: optional(string()),
  }),
  object({
    t: literal('voice'),
    secs: optional(number()),
    wave: optional(array(number())),
    via: optional(string()),
    size: optional(string()),
    transcript: optional(string()),
    src: optional(string()),
  }),
  object({
    t: literal('attach'),
    name: string(),
    dims: optional(string()),
    src: optional(string()),
    svg: optional(string()),
    ph: optional(string()),
    via: optional(string()),
    size: optional(string()),
    data: optional(string()),
    mimeType: optional(string()),
    sizeBytes: optional(number()),
    kind: optional(string()),
  }),
  object({
    t: literal('image'),
    src: string(),
    cap: optional(string()),
  }),
  object({
    t: literal('link'),
    url: string(),
    title: string(),
    desc: optional(string()),
    meta: optional(string()),
  }),
  // RFC-0252: fusion deliberation card. Must be accepted here or a message
  // carrying a fusion block (the keeper conclusion) is dropped wholesale.
  object({
    t: literal('fusion'),
    board_post_id: string(),
    run_id: optional(string()),
  }),
  object({
    t: literal('trace'),
    trace: array(KeeperChatTraceStepSchema),
  }),
  object({
    t: literal('thinking'),
    content: string(),
    redacted: optional(boolean()),
  }),
])

export type KeeperChatBlock = InferOutput<typeof KeeperChatBlockSchema>

export const KeeperChatHistoryStreamContractSchema = object({
  source: string(),
  status: string(),
  event_name: optional(string()),
  eventName: optional(string()),
  request_id: optional(string()),
  requestId: optional(string()),
  turn_ref: optional(string()),
  turnRef: optional(string()),
  trace_event_count: optional(number()),
  traceEventCount: optional(number()),
  reason: optional(string()),
})

export type KeeperChatHistoryStreamContract = InferOutput<typeof KeeperChatHistoryStreamContractSchema>

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
  // RFC-0233 §7: turn join key "<trace_id>#<absolute_turn>" the keeper minted
  // onto every row of the turn (keeper_chat_store.ml to_json_array emits it).
  // Read-only here; the board post that the same turn produced carries the
  // identical string in its origin, so a board post can anchor to the exact
  // chat turn. Optional for the deploy window and legacy rows (absent ->
  // undefined, never drops the message). Consumed for navigation in a
  // follow-up (KeeperConversationEntry.turnRef).
  turn_ref: optional(string()),
  // RFC-0235 P1/P3: audio clip field. The wire object is accepted as
  // `unknown` at the boundary so malformed clips do not cause the whole
  // message to be dropped; `normalizeAudioClip` validates before use.
  audio: optional(unknown()),
  // Persisted file/image uploads (keeper_chat_store.ml to_json_array
  // :848-861). Without decoding these, a user's upload appears live but
  // vanishes on reload even though it is on disk.
  attachments: optional(array(KeeperChatHistoryAttachmentSchema)),
  // RFC-0235 P3: server-parsed rich chat blocks. Carried on history rows so
  // reloads preserve the structured render instead of re-parsing plain text.
  blocks: optional(array(KeeperChatBlockSchema)),
  // Row kind (keeper_chat_store.ml :838-841). `transport_failure` is minted
  // so a reload can tell a failed request apart from a real keeper reply;
  // open string() per the same deploy-window rationale as `role`.
  kind: optional(string()),
  // K1e read model: backend-owned provenance for what a history row can prove
  // about the stream/turn lifecycle. Kept optional for deploy windows and
  // legacy endpoints; consumers fall back to explicit "history without stream
  // events" instead of inventing a lifecycle.
  stream_contract: optional(KeeperChatHistoryStreamContractSchema),
})

export type KeeperChatHistoryMessage = InferOutput<typeof KeeperChatHistoryMessageSchema>

export function safeParseKeeperChatHistoryMessage(
  data: unknown,
): KeeperChatHistoryMessage | null {
  const result = safeParse(KeeperChatHistoryMessageSchema, data)
  return result.success ? result.output : null
}
