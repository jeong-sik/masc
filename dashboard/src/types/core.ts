// MASC Dashboard — Core entity types (Agent, Task, Message, Board, Keeper)

import type { KeeperChatDeliveryProvenance } from '../keeper-delivery-provenance'

// --- Shared options ---

export interface RefreshOptions {
  force?: boolean
  immediate?: boolean
  light?: boolean
}

// --- Shared signal / evidence primitives (SSOT) ---
// Mission and execution domains extend these with domain-specific values.

/** Core signal truth values shared across mission and execution domains. */
export type SignalTruthCore = 'live' | 'stale'
/** Mission-domain signal truth (extends core with archived, unknown). */
export type MissionSignalTruth = SignalTruthCore | 'archived' | 'unknown'
/** Execution-domain signal truth (extends core with absent). */
export type ExecutionSignalTruth = SignalTruthCore | 'absent'

/** Core evidence source values shared across domains. */
export type EvidenceSourceCore = 'message' | 'presence' | 'none'
/** Mission-domain evidence source (extends core with session). */
export type MissionEvidenceSource = EvidenceSourceCore | 'session'

// --- Core entities ---

export interface Agent {
  name: string
  agent_type?: string
  keeper_name?: string | null
  keeper_id?: string | null
  status?: 'active' | 'busy' | 'listening' | 'idle' | 'inactive' | 'offline'
  current_task: string | null
  context_ratio?: number
  session_bound_at?: string
  last_seen?: string
  capabilities?: string[]
  emoji?: string
  koreanName?: string
  model?: string
  preferredHours?: number[]
  peakHour?: number
  synthetic?: boolean
}

export interface Task {
  id: string
  title: string
  goal_id?: string | null
  status?: 'todo' | 'in_progress' | 'claimed' | 'awaiting_verification' | 'done' | 'cancelled' | 'blocked' | 'paused' | 'unknown'
  status_raw?: string | null
  priority?: number
  assignee?: string
  description?: string
  created_at?: string
  updated_at?: string
  completed_at?: string
  /** Present only for status=cancelled; the API flattens it out of the task
   *  status. `assignee` is null on a cancelled task because the status no
   *  longer carries one, so this is the only actor the row can name. */
  cancelled_by?: string | null
  /** Stated reason for a terminal transition, flattened out of the task status
   *  alongside `cancelled_by`. Distinct from `handoff_context.reason`, which is
   *  a working note the assignee left and is usually absent on a plain cancel. */
  reason?: string | null
  predecessor_task_id?: string | null
  contract?: TaskContract | null
  handoff_context?: TaskHandoffContext | null
  execution_links?: TaskExecutionLinks | null
}

interface TaskExecutionLinks {
  operation_id?: string | null
  session_id?: string | null
}

interface TaskContract {
  strict?: boolean
  completion_contract?: string[]
  required_evidence?: string[]
  inspect_gate_evidence?: string[]
  verify_gate_evidence?: string[]
}

interface TaskHandoffContext {
  summary: string
  reason?: string | null
  next_step?: string | null
  failure_mode?: string | null
  evidence_refs?: string[]
  updated_at?: string | null
  updated_by?: string | null
}

// SSOT for mention-delivery status values. Consumers that decode this field
// from the wire (api/dashboard-workspace.ts, store-normalizers.ts) derive
// their guard from this array instead of repeating the literal set.
export const MENTION_DELIVERY_STATUSES = ['passive', 'pending', 'accepted', 'rejected'] as const
export type MentionDeliveryStatus = (typeof MENTION_DELIVERY_STATUSES)[number]

export interface Message {
  id?: string
  requestId?: string
  seq?: number
  from?: string
  content: string
  timestamp?: string
  type?: string
  workspace?: string
  mentionDelivery?: MentionDeliveryStatus
  mentions?: string[]
}

// --- Board ---

type BoardPostMeta = Record<string, unknown> & {
  source?: string | null
  classification_reason?: string | null
  judgment?: unknown
}

/**
 * RFC-0000 §3.1 board attachment carrier — the wire shape of one entry in
 * `meta.attachments` (OCaml `Board_attachment_meta`). `kind` is a closed set.
 */
export type BoardAttachmentKind = 'image' | 'video' | 'youtube' | 'external_link'

export interface BoardAttachment {
  id: string
  kind: BoardAttachmentKind
  origin_url: string
  origin_name: string
  origin_size_bytes: number
  mime_type: string
  width: number | null
  height: number | null
  created_at: number
}

/**
 * Decode result for one raw `meta.attachments` entry. Entries that fail the
 * typed wire contract are kept as `{ ok: false }` so surfaces render an
 * explicit failure card instead of silently skipping them.
 */
export type BoardAttachmentDecode =
  | { ok: true; attachment: BoardAttachment }
  | { ok: false; raw: unknown }

export type BoardVoteDirection = 'up' | 'down'

export interface BoardActorIdentity {
  kind: 'keeper' | 'agent'
  id: string
  key: string
  display_name: string
  raw: string
  source?: 'keeper_registry_name' | 'raw_agent'
}

/**
 * RFC-0233 §7: originating-turn provenance of a board post. `turn_ref` is the
 * join key "<trace_id>#<absolute_turn>" identical to the chat row the same turn
 * produced (board post -> exact chat turn navigation). `fusion_run_id` is the
 * distinct fusion run correlation id. All optional: legacy/system posts have no
 * origin.
 */
export interface BoardPostOrigin {
  turn_ref?: string | null
  source?: string | null
  fusion_run_id?: string | null
}

export interface BoardPost {
  id: string
  author: string
  author_identity?: BoardActorIdentity | null
  post_kind?: 'direct' | 'automation' | 'system'
  pinned?: boolean
  classification_reason?: string | null
  title: string
  body: string
  meta?: BoardPostMeta | null
  attachments?: BoardAttachmentDecode[]
  tags: string[]
  votes: number
  vote_balance?: number
  current_vote?: BoardVoteDirection | null
  has_voted?: boolean
  comment_count: number
  created_at: string
  updated_at: string
  flair?: string
  hearth?: string | null
  visibility?: string
  expires_at?: string | null
  hearth_count?: number
  reactions?: BoardReactionSummary[]
  supported_reaction_emojis?: string[]
  origin?: BoardPostOrigin | null
}

export interface BoardComment {
  id: string
  post_id: string
  parent_id?: string | null
  author: string
  author_identity?: BoardActorIdentity | null
  content: string
  created_at: string
  votes?: number
  vote_balance?: number
  votes_up?: number
  votes_down?: number
  current_vote?: BoardVoteDirection | null
  has_voted?: boolean
  reactions?: BoardReactionSummary[]
  supported_reaction_emojis?: string[]
}

export type BoardReactionTargetType = 'post' | 'comment'

export interface BoardReactionSummary {
  emoji: string
  count: number
  reacted: boolean
  has_reacted: boolean
  recent_user_ids: string[]
}

export interface BoardReactionToggleResult {
  target_type: BoardReactionTargetType
  target_id: string
  user_id: string
  emoji: string
  reacted: boolean
  summary: BoardReactionSummary[]
}

export interface BoardReactionState {
  summaries: BoardReactionSummary[]
  supportedEmojis: string[]
}

export interface BoardCurationSnapshot {
  id: string
  generated_at: string
  submitted_by: string
  model?: string | null
  summary?: string | null
  ordering: string[]
  highlights: string[]
  tag_suggestions: BoardCurationTagSuggestion[]
  answer_matches: BoardCurationAnswerMatch[]
  health_score?: number | null
  health_components: BoardCurationHealthComponent[]
  rationale: string
  provenance?: unknown
}

export interface BoardCurationTagSuggestion {
  post_id: string
  tags: string[]
  rationale: string
}

export interface BoardCurationAnswerMatch {
  question_post_id: string
  answer_post_id: string
  score: number
  rationale: string
}

export interface BoardCurationHealthComponent {
  name: string
  score: number
  weight: number
  rationale: string
}

export interface BoardKarmaLedgerEvent {
  recipient: string
  voter: string
  target_kind: 'post' | 'comment'
  target_id: string
  delta: number
  ts: number
  ts_iso: string
}

export interface BoardKarmaTotal {
  agent: string
  karma: number
}

export interface BoardKarmaLedger {
  events: BoardKarmaLedgerEvent[]
  count: number
  scoring_rule: string
  totals: BoardKarmaTotal[]
}

// --- SubBoard ---

export type SubBoardAccess = 'open' | 'members_only' | 'owner_only'

export interface SubBoard {
  id: string
  slug: string
  name: string
  description: string
  owner: string
  members: string[]
  access: SubBoardAccess
  created_at: string
  post_count: number
}
// --- Keeper Metrics ---

export interface InferenceTelemetry {
  system_fingerprint: string | null
  timings: {
    prompt_n: number | null
    prompt_ms: number | null
    prompt_per_second: number | null
    predicted_n: number | null
    predicted_ms: number | null
    predicted_per_second: number | null
    cache_n: number | null
  } | null
  reasoning_tokens: number | null
  peak_memory_gb: number | null
  request_latency_ms: number | null
  ttfrc_ms: number | null
  prefill_ms: number | null
}

export interface PromptSegmentTelemetry {
  bytes: number
  fingerprint: string | null
}

export interface PromptTelemetry {
  fingerprint: string | null
  total_bytes: number | null
  cacheable_bytes: number | null
  segments: Record<string, PromptSegmentTelemetry>
}

export interface CtxCompositionTelemetry {
  actual_input_tokens: number | null
  attributed_bytes: number
  segments: Record<string, PromptSegmentTelemetry>
}

export interface KeeperMetricPoint {
  ts: number
  context_ratio: number | null
  context_tokens: number | null
  context_max: number | null
  latency_ms: number | null
  generation: number
  channel: string
  is_handoff: boolean
  cost_usd: number
  handoff_new_generation: number | null
  prompt_fingerprint: string | null
  prompt_metrics: PromptTelemetry | null
  ctx_composition: CtxCompositionTelemetry | null
  input_tokens: number | null
  output_tokens: number | null
  total_tokens: number | null
  wall_tokens_per_second: number | null
  inference_telemetry: InferenceTelemetry | null
  runtime_id?: string | null
  runtime_outcome?: string | null
  runtime_attempt_count?: number | null
}

export interface ProviderHealth {
  provider: string
  model: string
  status: 'healthy' | 'degraded' | 'unhealthy'
  ttfrc_ms_ewma: number
  timeout_count_5m: number
  prefill_ms_ewma: number
  last_updated: number
}

export const KEEPER_RUNTIME_BLOCKER_CLASSES = [
  'runtime_exhausted',
  'provider_runtime_error',
  'fiber_unresolved',
  'stale_termination_storm',
  'heartbeat_failures',
  'turn_failures',
  'exception',
  'agent_core_context_window_exceeded',
  'agent_core_unrecognized_stop_reason',
  'agent_core_guardrail_violation',
  'agent_core_tripwire_violation',
  // Emitted by `blocker_class_to_string` in lib/keeper/keeper_meta_contract.ml
  // and previously discarded here: `asKeeperRuntimeBlockerClass` answers null
  // for anything absent, so eleven real classes arrived and were dropped.
  // `test_blocker_class_mirror` fails if the server gains another one.
  'agent_core_input_required',
  'capacity_backpressure',
  'gate_replay_repair_required',
  'incomplete_tool_transcript',
  'internal_bridge_exception',
  'internal_contract_rejected',
  'internal_unhandled_exception',
  'provider_attempt_effect_fenced',
  'receipt_persistence_failed',
  'terminal_effect_failed',
  'tool_correction_lost',
] as const

export type KeeperRuntimeBlockerClass = (typeof KEEPER_RUNTIME_BLOCKER_CLASSES)[number]

export type KeeperLiveActivitySource =
  | 'keeper_meta'
  | 'tool_call'
  | 'approval_pending'

export interface KeeperLiveActivity {
  source?: KeeperLiveActivitySource | null
  at?: string | null
  age_s?: number | null
  tool?: string | null
  turn?: number | null
  keeper_turn_id?: number | null
}

export interface KeeperCurrentGate {
  kind?: 'approval_required' | string | null
  source?: string | null
  id?: string | null
  tool?: string | null
  turn_id?: number | null
  at?: string | null
  age_s?: number | null
  disposition?: string | null
  disposition_reason?: string | null
}

// Wire emit: `lib/keeper/keeper_status_bridge.ml:720` —
//   `pause_state = if meta.paused then "paused" else "active"`.
// Closed 2-arm; the previous `| string` catch-all hid the fact that
// the wire vocabulary is exhaustive and let unmapped values flow
// silently through narrowing.
export type KeeperPauseState = 'active' | 'paused'

export type KeeperRuntimeBlockerState = 'clear' | 'blocked'

export type StopCauseSource =
  | 'runtime_blocker_class'
  | 'terminal_reason_code'
  | 'stop_reason'
  | 'error_kind'
  | 'attention_reason'

export interface StopCause {
  code: string
  source: StopCauseSource
  label: string
  summary?: string | null
  severity?: string | null
  next_action?: string | null
}

export interface KeeperTrustLatestEvent {
  kind: string
  ts: string
  ts_unix?: number | null
  keeper_turn_id?: number | null
  task_id?: string | null
  goal_ids?: string[]
  title: string
  summary: string
  severity: 'ok' | 'warn' | 'bad'
  next_human_action?: string | null
  // Trace id for deep-linking the causal event to its distributed trace.
  trace_id?: string | null
}

export interface KeeperTrustApprovalPendingFirst {
  id?: string | null
  tool_name?: string | null
  task_id?: string | null
  blocker_class?: string | null
}

export interface KeeperTrustApprovalState {
  state?: string | null
  summary?: string | null
  pending_count?: number | null
  pending_first?: KeeperTrustApprovalPendingFirst | null
  // ISO8601 timestamp of the last approval-audit event.
  latest_event_at?: string | null
}

export interface KeeperTrustExecutionSummary {
  provider_attempt_count?: number | null
  provider_fallback_applied?: boolean | null
  provider_selected_model?: string | null
  runtime_outcome?: string | null
  sandbox_summary?: string | null
  sandbox_root?: string | null
  completion_observation_summary?: string | null
  latest_receipt_at?: string | null
}

export interface KeeperTrustTerminalReason {
  code?: string | null
  source?: string | null
  severity?: 'ok' | 'warn' | 'bad' | null
  summary?: string | null
  next_action?: string | null
}

export interface KeeperTrustSummary {
  disposition?: string | null
  disposition_reason?: string | null
  operator_disposition?: string | null
  operator_disposition_reason?: string | null
  needs_attention?: boolean | null
  attention_reason?: string | null
  next_human_action?: string | null
  latest_terminal_reason?: KeeperTrustTerminalReason | null
  latest_next_action?: string | null
  approval_state?: KeeperTrustApprovalState | null
  execution_summary?: KeeperTrustExecutionSummary | null
  latest_causal_event?: KeeperTrustLatestEvent | null
}

// Dashboard rendering union returned by `deriveLifecycleState`
// (keeper-store-normalize.ts). This is a display union, not the backend
// keeper FSM. Offline-detail rendering may surface terminal sub-states
// from `keeperDisplayStatus`; keep the accepted set explicit instead
// of trusting arbitrary wire strings.
export type KeeperLifecycleState =
  | 'active'
  | 'preparing'
  | 'handoff-imminent'
  | 'idle'
  | 'offline'
  | 'unbooted'
  | 'stopped'
  // Offline-detail sub-states emitted by keeperDisplayStatus.
  | 'paused'
  | 'crashed'
  | 'unknown'

export interface Goal {
  id: string
  title: string
  metric?: string | null
  target_value?: string | null
  due_date?: string | null
  priority: number
  phase: string
  last_review_note?: string | null
  last_review_at?: string | null
  created_at: string
  updated_at: string
}

// --- Keeper ---

type KeeperHealthState = 'healthy' | 'idle' | 'stale' | 'degraded' | 'offline'

// Exactly what Keeper_status_runtime.keeper_quiet_reason serializes.
type KeeperQuietReason =
  | 'disabled'
  | 'not_running'
  | 'startup'
  | 'never_started'

// Exactly what Keeper_status_runtime.keeper_next_action_path serializes.
type KeeperNextActionPath =
  | 'auto_restart'
  | 'recover'
  | 'probe'
  | 'direct_message'

type KeeperReplyStatus =
  | 'never'
  | 'awaiting_reply'
  | 'delivered'
  | 'fresh'
  | 'stale'
  | 'error'
  | 'unknown'

type KeeperContinuityState =
  | 'not_running'
  | 'recovering'
  | 'healthy'
  | 'disabled'
  | 'offline'

export interface KeeperDiagnostic {
  health_state: KeeperHealthState
  quiet_reason?: KeeperQuietReason | null
  next_action_path: KeeperNextActionPath
  last_reply_status: KeeperReplyStatus
  last_reply_at?: string | null
  last_reply_preview?: string | null
  last_error?: string | null
  recoverable?: boolean
  summary?: string
  keepalive_running?: boolean
  continuity_state?: KeeperContinuityState | null
}

export type KeeperConversationRole = 'user' | 'assistant' | 'system' | 'tool' | 'other'

/** Canonical actor name for system-originated entries (backend convention).
 *  Used when an actor field is null/missing and the entry came from a
 *  system source rather than a real user/agent. */
export const SYSTEM_ACTOR_NAME = 'system' as const

export type KeeperConversationSource =
  | 'direct_user'
  | 'direct_assistant'
  | 'world_state_prompt'
  | 'internal_assistant'
  // A keeper turn that ran without anyone addressing the keeper. Its ordinary
  // User/Assistant/Tool exchange is durable in the Agent Core checkpoint; these
  // dashboard-only rows avoid duplicating that conversation in the chat store
  // and are projected by Keeper_autonomous_turn_source. Visible by default but
  // folded into one collapsed group, because a keeper may wake once a minute.
  | 'autonomous_turn'
  | 'tool_result'
  | 'system'
  | 'unknown'

export type KeeperConversationDelivery =
  | 'history'
  | 'queued'
  | 'sending'
  | 'streaming'
  | 'delivered'
  | 'no_reply'
  | 'timeout'
  | 'cancelled'
  | 'error'
  // Durable keeper_chat_store row written when a request failed before the
  // keeper produced an utterance. Unlike generic client/tool errors, this
  // writer-declared state is watermark-neutral.
  | 'transport_failure'
  // Stream ended without a terminal RUN_FINISHED / RUN_ERROR event —
  // the transport was cut mid-response, so the text may be incomplete.
  | 'interrupted'

interface KeeperConversationUsage {
  inputTokens?: number | null
  outputTokens?: number | null
  totalTokens?: number | null
  cacheCreationInputTokens?: number | null
  cacheReadInputTokens?: number | null
  costUsd?: number | null
}

// A tool call the keeper is holding for an operator decision. The stream
// event KEEPER_TOOL_APPROVAL_REQUESTED mints it; KEEPER_TOOL_APPROVAL_SETTLED
// (or a timeout-driven settle on the server) retires it. Without this row the
// dashboard drew nothing while the call waited and the answer, when it came,
// was only the 180-second timeout read as a denial nobody chose.
export interface KeeperToolApprovalPending {
  toolCallId: string
  toolName: string
  args: string
  question: string
  // Policy-owned reason the call was held. Empty for an older emitter that
  // predates the field; the card omits the reason row in that case.
  because: string
  askedAtMs: number | null
  // Server-stated seconds until the wait retires itself. Null when unknown;
  // the view derives the remaining time from its own clock.
  timeoutSec: number | null
  // Client-side answer state: 'answering' while the POST is in flight so the
  // buttons cannot be double-clicked into two answers for one call.
  answering: boolean
  answeredDecision: 'approve' | 'deny' | null
  answeredOutcome: string | null
  settled: boolean
}

// RFC-0232 P2: producer-typed turn outcome carried in the reply payload
// (`turn_outcome`). `continuation_checkpoint` marks a resume-next-cycle
// boundary, `external_effect_pending` marks a durable control wait,
// `external_effect_completed` marks a reply delivered by an external
// connector (e.g. Slack/Discord), and `no_visible_reply` marks a completed
// runtime turn with no assistant text.
export type KeeperTurnOutcome =
  | 'visible_reply'
  | 'continuation_checkpoint'
  | 'external_effect_completed'
  | 'external_effect_pending'
  | 'no_visible_reply'

// Where an `external_effect_completed` turn actually delivered its reply
// (`external_effect_target` on the reply payload / the
// KEEPER_EXTERNAL_EFFECT_COMPLETED event value). Present exactly on those
// turns; other outcomes carry no target and the card keeps generic copy.
export type KeeperExternalEffectTarget =
  | { kind: 'dashboard' }
  | { kind: 'discord'; channelId: string }
  | { kind: 'slack'; channelId: string; threadTs: string | null }

export interface KeeperConversationDetails {
  traceId?: string | null
  turnRef?: string | null
  providerMessageId?: string | null
  generation?: number | null
  modelUsed?: string | null
  stopReason?: string | null
  latencyMs?: number | null
  costUsd?: number | null
  usage?: KeeperConversationUsage | null
  replyText?: string | null
  turnOutcome?: KeeperTurnOutcome | null
  externalEffectTarget?: KeeperExternalEffectTarget | null
  rawPayload?: unknown
}

export interface KeeperConversationAttachment {
  id: string
  type: 'image' | 'file'
  name: string
  size: number
  mimeType: string
  data: string
  /** Optional image dimensions (e.g. "1920×1080") computed for composer blocks. */
  dims?: string
}

export type KeeperUserInputMediaKind = 'image' | 'document' | 'audio'

export type KeeperUserInputBlock =
  | { type: 'text'; text: string }
  | {
      type: KeeperUserInputMediaKind
      attachmentId: string
      name: string
      mimeType: string
      size: number
    }

// RFC-0235 P1: synthesized voice clip attached to an assistant chat row.
// `audioUrl` is the absolute/relative URL the dashboard uses for playback;
// `token` is the capability in `/api/v1/voice/audio/<token>` used as a
// fallback when the backend did not emit a full URL.
export interface KeeperConversationAudioClip {
  token: string
  audioUrl?: string | null
  mime: string
  durationSec?: number | null
  messageText: string
  deviceId?: string | null
  expired?: boolean | null
}

// --- Keeper v2 rich chat blocks (optional; when present the bubble renderer
// uses them instead of plain markdown text). See ChatMessageBubble in
// src/components/chat/primitives.ts.

export type ChatTextBlock = { t: 'p'; html: string }
export type ChatHeadingBlock = { t: 'h4'; html: string }
export type ChatListBlock = { t: 'ul'; items: string[] }

export type ChatCalloutSeverity = 'info' | 'warn' | 'bad'
export type ChatCalloutBlock = { t: 'callout'; severity?: ChatCalloutSeverity; html: string }

export type ChatTableCellValue = string | { v: string; num?: boolean; muted?: boolean }
export type ChatTableBlock = { t: 'table'; head: ChatTableCellValue[]; rows: ChatTableCellValue[][] }

export type ChatCodeBlock = { t: 'code'; cap?: string; html: string; source?: string }

export type ChatShellLine = { t?: 'cmd' | 'out' | 'err'; v: string }
export type ChatShellBlock = { t: 'shell'; title?: string; lines: ChatShellLine[]; exit?: number; dur?: string }

export type ChatArtifactBlock = { t: 'artifact'; kind?: string; name: string; size?: string; note?: string; data?: string; mimeType?: string }

export type ChatChartSeries = { label: string; color?: string; values: number[] }
export type ChatChartBlock = { t: 'chart'; title: string; series: ChatChartSeries[]; labels?: string[]; xLabel?: string; yMax?: number }

export type ChatSuggestionItem = { icon?: string; label: string; action?: string }
export type ChatSuggestionsBlock = { t: 'suggestions'; items: ChatSuggestionItem[] }

export type ChatIssueBlock = { t: 'issue'; repo: string; number: number; title: string; status: 'open' | 'closed'; url?: string; meta?: string }

export type ChatAttachBlock = {
  t: 'attach'
  name: string
  dims?: string
  src?: string
  svg?: string
  ph?: string
  via?: string
  size?: string
  /** Optional source data carried so the parent can forward attachments to the API. */
  data?: string
  mimeType?: string
  sizeBytes?: number
  id?: string
  kind?: string
}

export type ChatVoiceBlock = { t: 'voice'; secs?: number; wave?: number[]; via?: string; size?: string; transcript?: string; src?: string }

export type ChatImageBlock = { t: 'image'; src?: string; ph?: string; cap?: string }
export type ChatSvgBlock = { t: 'svg'; svg: string; cap?: string }
export type ChatMermaidBlock = { t: 'mermaid'; source: string; caption?: string }

// `ts` (ISO-8601) records when the trace event arrived. Live streams preserve
// think/tool order structurally in this array; persisted legacy rows may omit
// timestamps and still render in stored order.
// `contentWithheld` marks a step the server admitted without carrying its
// reasoning (RFC-0358 §2 public autonomous projection). `text` is '' in that
// case and the label shown for it is this client's to choose. Distinct from
// ChatThinkingBlock's `redacted`, which means the provider itself sent only a
// signature.
export type ChatTraceThinkStep = {
  kind: 'think'
  text: string
  contentWithheld?: boolean
  ts?: string
  agentCoreBlockIndex?: number
}
export type ChatTraceReasonStep = { kind: 'reason'; text: string; detail?: string; ts?: string }
export type ChatTraceProgressStep = { kind: 'progress'; text: string; ts?: string; agentCoreBlockIndex?: number }
export type ChatTraceToolStep = {
  kind: 'tool'
  name: string
  toolCallId?: string
  executionId?: string
  /** Live-only delivery occurrence. Provider IDs are not row identity. */
  toolOccurrenceId?: string
  status?: 'pending' | 'ok' | 'err'
  dur?: string
  args?: string
  result?: string
  ts?: string
  agentCoreBlockIndex?: number
}
export type ChatTraceStep = ChatTraceThinkStep | ChatTraceReasonStep | ChatTraceProgressStep | ChatTraceToolStep
// `omitted` counts steps this surface did not carry (absent or 0 when whole).
// A shorter `trace` with no count would read as a shorter turn, which is a
// different fact from a turn whose trace was abridged for transport.
export type ChatTraceBlock = { t: 'trace'; trace: ChatTraceStep[]; omitted?: number }
export type ChatThinkingBlock = { t: 'thinking'; content: string; redacted: boolean }

export type ChatLinkBlock = { t: 'link'; url: string; title: string; desc?: string; meta?: string; fav?: string; kind?: string }

export type ChatBroadcastAck = 'acked' | 'read' | 'delivered' | string
export type ChatBroadcastRecipient = { id: string; ack: ChatBroadcastAck; at?: string }
export type ChatBroadcastBlock = { t: 'broadcast'; scope: string; via?: string; note: string; recipients: ChatBroadcastRecipient[] }
// RFC-0252: a reference from a keeper chat message to a fusion deliberation's
// board post. Carries only ids (snake_case to match the backend wire shape in
// keeper_chat_blocks.ml); ChatFusionCard lazy-fetches the board post by
// board_post_id and renders its meta_json (panel answers + judge synthesis).
export type ChatFusionBlock = { t: 'fusion'; board_post_id: string; run_id?: string }
export type ChatStatusBlock = {
  t: 'status'
  kind: 'continuation_checkpoint' | 'external_effect_pending'
}

export type ChatBlock =
  | ChatTextBlock
  | ChatHeadingBlock
  | ChatListBlock
  | ChatCalloutBlock
  | ChatTableBlock
  | ChatCodeBlock
  | ChatShellBlock
  | ChatArtifactBlock
  | ChatChartBlock
  | ChatSuggestionsBlock
  | ChatIssueBlock
  | ChatAttachBlock
  | ChatVoiceBlock
  | ChatImageBlock
  | ChatSvgBlock
  | ChatMermaidBlock
  | ChatTraceBlock
  | ChatThinkingBlock
  | ChatLinkBlock
  | ChatBroadcastBlock
  | ChatFusionBlock
  | ChatStatusBlock
export type KeeperConversationStreamState =
  | 'opening'
  | 'thinking'
  | 'streaming'
  | 'finalizing'
  | null

export type KeeperConversationStreamContractSource =
  | 'keeper_chat_store'
  | 'backend_stream_lifecycle'
  | 'backend_turn_trace'
  | 'rest_history'
  | 'sse_event'
  | 'client_operation_store'
  | 'client_operation_lookup'
  | 'client_local_send'
  | 'client_stream_failure'

export type KeeperConversationStreamContractStatus =
  | 'backend_stream_event'
  | 'backend_terminal_event'
  | 'backend_lifecycle_replay'
  | 'backend_trace_join'
  | 'history_without_turn_ref'
  | 'history_without_stream_events'
  | 'client_operation_terminal'
  | 'client_placeholder'
  | 'client_reconciled_history'
  | 'contract_gap'

export interface KeeperConversationStreamContract {
  source: KeeperConversationStreamContractSource
  status: KeeperConversationStreamContractStatus
  eventName?: string | null
  requestId?: string | null
  turnRef?: string | null
  traceEventCount?: number | null
  lifecycleEvents?: string[] | null
  reason?: string | null
}

// Mirrors the closed variant vocabulary in lib/keeper/surface_ref.ml —
// same seven kinds, no open string escape. keeper-state.ts owns the one
// closed parse (normalizeSurfaceRef); an unknown wire kind drops the
// surface, never the row, matching keeper_chat_store.load's policy.
export type SurfaceRefKind =
  | 'dashboard'
  | 'discord'
  | 'slack'
  | 'webhook'
  | 'agent'
  | 'broadcast'
  | 'gate'

export interface SurfaceRef {
  kind: SurfaceRefKind
  session_id?: string
  guild_id?: string
  channel_id?: string
  parent_channel_id?: string
  thread_id?: string
  team_id?: string
  thread_ts?: string
  source?: string
  event_id?: string
  label?: string
  address?: Record<string, string>
}

export interface KeeperConversationEntry {
  id: string
  role: KeeperConversationRole
  source: KeeperConversationSource
  label: string
  text: string
  rawText?: string | null
  timestamp?: string | null
  // RFC-0233 §7: MASC-minted "<trace_id>#<absolute_turn>" correlation key.
  // Carries the originating turn for trace attachment; it is not row identity.
  turnRef?: string | null
  // Exact append-once identity for history reconciliation. This preserves the
  // backend SSOT pair instead of flattening it into a role-qualified request id.
  deliveryProvenance?: KeeperChatDeliveryProvenance | null
  // Canonical physical tool execution. Provider tool-call identity remains
  // optional correlation data; neither conversation row identity nor output
  // hydration substitutes one for the other.
  executionId?: string | null
  // Provider correlation is explicit data, never encoded in [id].
  toolCallId?: string | null
  // Live lifecycle state for selecting the current provider occurrence.
  toolCallEnded?: boolean
  delivery: KeeperConversationDelivery
  streamState?: KeeperConversationStreamState
  streamContract?: KeeperConversationStreamContract | null
  attachments?: KeeperConversationAttachment[]
  /** Exact ordered multimodal input sent to the Keeper. Kept on optimistic and
   * pending rows so editing never reconstructs model input from display text. */
  userBlocks?: KeeperUserInputBlock[]
  blocks?: ChatBlock[]
  traceSteps?: ChatTraceStep[]
  details?: KeeperConversationDetails | null
  error?: string | null
  surface?: SurfaceRef | null
  conversationId?: string | null
  externalMessageId?: string | null
  speakerId?: string | null
  speakerName?: string | null
  speakerAuthority?: string | null
  audio?: KeeperConversationAudioClip | null
}

export interface KeeperStatusDetail {
  name: string
  diagnostic?: KeeperDiagnostic | null
  history: KeeperConversationEntry[]
  rawText: string
  rawStatus?: unknown
  loadedAt: string
}

// Backend SSOT: `Keeper_status_runtime.pipeline_stage_of_phase`
// (lib/keeper/keeper_status_runtime.ml:537) deterministic mapping from
// the KeeperPhase lifecycle. Emits the closed set below;
// values; `unknown` is a dashboard-side marker for missing data
// (`asString(row.pipeline_stage) ?? 'unknown'`). Removed legacy
// `thinking` / `tool_use` (= trajectory content_type, never
// pipeline_stage) and `scheduled_autonomous` (= turn channel, never
// pipeline_stage).
export type PipelineStage =
  | 'idle'
  | 'offline'
  | 'failing'
  | 'draining'
  | 'paused'
  | 'crashed'
  | 'restarting'
  | 'unknown'

// Aggregated metrics computed by the backend over a sliding window.
// Fields mirror dashboard_http_keeper_detail.ml summary output.
interface MetricsWindowTopItem {
  tool?: string
  kind?: string
  model?: string
  reason?: string
  trigger?: string
  count?: number
  [key: string]: unknown
}

export interface MetricsWindow {
  // -- Sample metadata --
  sample_points?: number
  window_sample_points?: number
  turn_points?: number
  window_turn_points?: number
  heartbeat_points?: number
  window_heartbeat_points?: number
  proactive_points?: number
  window_proactive_points?: number
  window_interactions?: number
  window_turns?: number
  window_series_max_lines?: number

  // -- Handoff --
  handoff_count?: number

  // -- Intervention --
  intervention_share?: number
  intervention_per_turn?: number

  // -- Tool --
  tool_call_count?: number

  // -- Top-N lists --
  top_work_kinds?: MetricsWindowTopItem[]
  top_tools?: MetricsWindowTopItem[]
  generation_equipment?: MetricsWindowTopItem[]

  // Catch-all for future fields
  [key: string]: unknown
}

export type KeeperPhase =
  | 'Offline'
  | 'Running'
  | 'Failing'
  | 'Draining'
  | 'Paused'
  | 'Stopped'
  | 'Crashed'
  | 'Restarting'

export const KEEPER_AUTOBOOT_EXCLUSION_REASONS = [
  'declarative_autoboot_disabled',
  'paused',
  'autoboot_disabled',
] as const

export type KeeperAutobootExclusionReason =
  typeof KEEPER_AUTOBOOT_EXCLUSION_REASONS[number]

export type KeeperProfileConfigErrorKind =
  | 'read_error'
  | 'parse_error'
  | 'profile_error'
  | 'invalid_name'
  | 'unknown'

export interface KeeperProfileConfigError {
  keeper: string
  keeper_path: string
  failing_path: string
  kind: KeeperProfileConfigErrorKind
  reported_kind?: string | null
  detail: string
  terminal_reason: 'config_invalid'
  blocking: true
  operator_action_required: true
  next_action: 'fix_keeper_toml_config'
}

export interface KeeperLastTurnUsage {
  input_tokens: number
  output_tokens: number
  total_tokens: number
  observed_at: string | null
  source: 'keeper_runtime_usage'
}

// Mirrors the closed reason set in
// lib/keeper/keeper_context_observation_projection.ml — extend both together.
export const KEEPER_CONTEXT_NOT_OBSERVED_REASONS = [
  'context_measurement_missing',
  'turn_record_undecodable',
  'turn_record_read_failed',
  'turn_record_without_usage',
  'turn_record_trace_mismatch',
] as const

export type KeeperContextNotObservedReason =
  (typeof KEEPER_CONTEXT_NOT_OBSERVED_REASONS)[number]

export type KeeperContextMetricsUnavailable =
  | {
      kind: 'not_observed'
      reason: KeeperContextNotObservedReason
    }
  | {
      kind: 'invalid_payload'
      reported_kind: string | null
      reported_reason: string | null
    }

export interface Keeper {
  name: string
  keeper_id?: string | null
  pipeline_stage?: PipelineStage
  pipeline_stage_detail?: string | null
  lifecycle_phase?: KeeperPhase | null
  phase?: KeeperPhase | null
  runtime_class?: 'keeper'
  paused?: boolean
  /** Autoboot exclusion reason mirrored from `Keeper_runtime`.
   *  null when bootable. Surfaced from execution `keepers` and briefing
   *  `keeper_briefs`. */
  exclusion_reason?: KeeperAutobootExclusionReason | null
  registered?: boolean
  emoji?: string
  koreanName?: string
  trace_id?: string
  model?: string
  primary_model?: string
  active_model?: string
  active_model_label?: string | null
  last_model_used?: string
  last_model_used_label?: string | null
  next_model_hint?: string | null
  runtime_id?: string | null
  runtime_ref?: RuntimeRef | null
  runtime_canonical?: string | null
  selected_runtime_canonical?: string | null
  status: string
  keepalive_running?: boolean
  keeper_keepalive_interval_s?: number | null
  heartbeat_stale_after_s?: number | null
  diagnostic?: KeeperDiagnostic | null
  registry_state?: string | null
  proactive_enabled?: boolean
  pause_state?: KeeperPauseState | null
  runtime_blocker_state?: KeeperRuntimeBlockerState | null
  runtime_blocker_class?: KeeperRuntimeBlockerClass | null
  runtime_blocker_summary?: string | null
  stop_cause?: StopCause | null
  needs_attention?: boolean | null
  attention_reason?: string | null
  next_human_action?: string | null
  config_error?: KeeperProfileConfigError | null
  sandbox_profile?: 'local' | 'docker' | 'microvm' | null
  sandbox_target?: string | null
  keeper_last_error?: string | null
  blocked_task_count?: number | null
  goal_progress?: {
    linked_task_count?: number
    done_task_count?: number
    open_task_count?: number
    blocked_task_count?: number
    convergence?: number | null
  } | null
  created_at?: string
  updated_at?: string
  last_heartbeat?: string
  /** Non-null when the heartbeat ledger could not be read — the operator
      surface shows the error instead of substituting a stale timestamp. */
  heartbeat_observation_error?: string | null
  keeper_age_s?: number
  last_turn_ago_s?: number
  last_handoff_ago_s?: number
  last_proactive_ago_s?: number
  last_proactive_reason?: string | null
  last_proactive_preview?: string | null
  last_drift_reason?: string | null
  drift_count_total?: number
  runtime_warning_ctx_ratio?: number | null
  trust?: KeeperTrustSummary | null
  turn_count?: number
  total_turns?: number
  total_tokens?: number
  last_latency_ms?: number
  last_activity_ago_s?: number
  last_activity_at?: string | null
  last_activity_source?: KeeperLiveActivitySource | null
  live_activity?: KeeperLiveActivity | null
  current_gate?: KeeperCurrentGate | null
  context_ratio?: number | null
  context_tokens?: number | null
  context_max?: number | null
  context_source?: string | null
  context_metrics_unavailable?: KeeperContextMetricsUnavailable | null
  last_turn_usage?: KeeperLastTurnUsage | null
  context?: {
    source?: string | null
    context_ratio?: number | null
    context_tokens?: number | null
    context_max?: number | null
    // Provenance of a turn_record-sourced measurement (RFC-0233): which
    // completed turn produced the numbers and its serialized request size.
    observed_at?: string | null
    turn_ref?: string | null
    absolute_turn?: number | null
    request_body_bytes?: number | null
    message_count?: number
    has_checkpoint?: boolean
  }
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_tool_names?: string[]
  // Observed audit fallback from the shell summary; not authored tool policy.
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
  conversation_tail_count?: number
  k2k_count?: number
  k2k_mentions?: Array<{ keeper: string; count: number }>
  handoff_count_total?: number
  metrics_window?: MetricsWindow
  // Metrics time-series (from backend metrics_series)
  metrics_series?: KeeperMetricPoint[]
  inventory?: string[]
  relationships?: Record<string, string>
  supervisor_diagnostics?: KeeperSupervisorDiagnostics
  provider_health?: ProviderHealth | null
  outcomes?: KeeperOutcomes
  conditions?: KeeperConditions
}

/** Outcomes rollup — aggregated successes / failures / validation
 *  for the last 50-entry transition ring. Backed by
 *  [Dashboard_http_keeper.compute_outcomes_rollup]. See
 *  [specs/keeper-state-machine/KeeperOutcomesConservation.tla] for the
 *  conservation invariant:
 *    successes.substantive_turns + failures.turn_failed = observed_turns
 */
export interface KeeperOutcomes {
  window: string
  observed_turns: number
  successes: {
    substantive_turns: number
    handoffs_ok: number
  }
  failures: {
    turn_failed: number
    handoff_failed: number
    crashes: number
    restarts: number
    consecutive_fail_current: number
  }
  validation: {
    agent_core_verdicts: {
      pass: number
      fail: number
      unknown: number
      top_failure_reasons: string[]
    }
    last_verdict_at: number | null
  }
}

/** Observable conditions that drive the keeper FSM.
 *  Serialized by [Keeper_state_machine.conditions_to_json]. */
export interface KeeperConditions {
  launch_pending: boolean
  fiber_alive: boolean
  heartbeat_healthy: boolean
  turn_healthy: boolean
  context_handoff_needed: boolean
  handoff_active: boolean
  operator_paused: boolean
  stop_requested: boolean
  drain_complete: boolean
}

export interface KeeperSupervisorCrashLogEntry {
  ts?: number
  reason?: string
}

interface KeeperSupervisorDiagnostics {
  restart_count?: number
  crash_log?: KeeperSupervisorCrashLogEntry[]
  last_failure_reason?: string | null
}

// --- Keeper Config (structured read-only view) ---

interface KeeperConfigPrompt {
  instructions: string
  // The server emits exactly one shared block. keeper.constitution,
  // keeper.world and keeper.capabilities were folded into keeper by
  // #26823; decoding them produced three empty blocks and the panel rendered
  // nothing for the shared prompt.
  system_prompt_blocks: {
    system: {
      key: string
      source: string
      text: string
    }
  }
  effective_system_prompt: string
  assembled_system_prompt: string
  unified_user_message_preview: string
}

interface KeeperConfigExecution {
  models: string[]
  active_model: string
  active_model_label?: string | null
  last_model_used_label?: string | null
  verify: boolean
  selected_runtime_id: string
  selected_runtime_canonical: string
  runtime_options: string[]
  runtime_ref?: RuntimeRef | null
}

interface KeeperConfigProactive {
  enabled: boolean
}

export interface KeeperConfigSkills {
  /** null inherits every published Skill; [] explicitly selects none. */
  names: string[] | null
}

export type KeeperManifestRevision =
  | { state: 'missing' }
  | { state: 'sha256'; value: string }

export type KeeperRuntimeAssignmentState =
  | { state: 'missing' }
  | { state: 'assigned'; runtime_id: string }

export type KeeperRuntimeAssignmentRevision =
  | { state: 'runtime_config_missing' }
  | {
      state: 'runtime_config_present'
      source_revision: string
      assignment: KeeperRuntimeAssignmentState
    }

export interface KeeperConfigRevision {
  manifest: KeeperManifestRevision
  runtime_assignment: KeeperRuntimeAssignmentRevision
}

/** The server's answer when it could not read the revision at all —
 * dashboard_http_keeper_snapshot emits `{state:"unavailable", detail}` in
 * place of the manifest/runtime_assignment pair. Carried as its own arm so
 * the panel can show `detail` and a save cannot post it as a CAS expected
 * value. */
export interface KeeperConfigRevisionUnavailable {
  state: 'unavailable'
  detail: string
}

export type KeeperConfigRevisionState =
  | KeeperConfigRevision
  | KeeperConfigRevisionUnavailable

export interface RuntimeRef {
  group: string
  item: string | null
}

export interface KeeperConfigRuntimeTrust {
  disposition?: string | null
  disposition_reason?: string | null
  needs_attention?: boolean | null
  attention_reason?: string | null
  next_human_action?: string | null
  approval?: unknown
  execution?: unknown
  latest_causal_event?: unknown
}

interface KeeperConfigRuntime {
  paused: boolean
  registered: boolean
  keepalive_running: boolean
  registry_state?: string | null
  fiber_health: string
  runtime_blocker_class?: KeeperRuntimeBlockerClass | null
  active_model_label?: string | null
  last_model_used_label?: string | null
  runtime_blocker_summary?: string | null
}

interface KeeperConfigWorkspace {
  mention_targets: string[]
  bound_workspace_ids: string[]
}

export interface KeeperConfigOverrideFieldSource {
  field: string
  source: string | null
  live_source: string | null
  default_source: string | null
  default_source_kind: 'toml' | null
  default_manifest_path: string | null
  default_manifest_exists: boolean | null
  default_missing: boolean | null
  default_value: unknown
  live_value: unknown
}

interface KeeperConfigSources {
  live_meta_path: string
  default_manifest_path: string | null
  default_source_kind: 'toml' | null
  precedence: string[]
  has_live_override: boolean
  override_fields: string[]
  override_field_sources: KeeperConfigOverrideFieldSource[]
}

interface KeeperConfigMetrics {
  generation: number
  total_turns: number
  total_input_tokens: number
  total_output_tokens: number
  total_tokens: number
  total_cost_usd: number
  last_model_used: string
  last_input_tokens: number
  last_output_tokens: number
  last_total_tokens: number
  last_latency_ms: number | null
  last_total_tokens_per_sec: number | null
  last_output_tokens_per_sec: number | null
}

export interface KeeperConfigFieldPresence {
  schema: string
  producer: string
  present_paths: string[]
}

export interface KeeperManifestWarning {
  code: string
  detail: string
}

export interface KeeperConfigWriteReceipt {
  revision: KeeperConfigRevision
  applied: boolean
  warnings: KeeperManifestWarning[]
}

export interface KeeperHookSlot {
  active: boolean
  source: string
  gates?: string[]
  effects?: string[]
  features?: string[]
}

interface KeeperHookIntrospection {
  scope: string | null
  slots: Record<string, KeeperHookSlot>
}

export interface KeeperConfig {
  name: string
  config_revision: KeeperConfigRevisionState
  config_write?: KeeperConfigWriteReceipt
  config_transaction_warnings?: KeeperManifestWarning[]
  autoboot_enabled: boolean
  max_context_override: number | null
  sandbox_profile?: 'local' | 'docker' | 'microvm' | string
  network_mode?: 'none' | 'inherit' | string
  keeper_last_error?: string | null
  sandbox_roots: string[]
  prompt: KeeperConfigPrompt
  execution: KeeperConfigExecution
  proactive: KeeperConfigProactive
  skills: KeeperConfigSkills
  hooks?: KeeperHookIntrospection
  runtime: KeeperConfigRuntime
  runtime_trust?: KeeperConfigRuntimeTrust | null
  workspace: KeeperConfigWorkspace
  sources: KeeperConfigSources
  metrics: KeeperConfigMetrics
  field_presence?: KeeperConfigFieldPresence
}
