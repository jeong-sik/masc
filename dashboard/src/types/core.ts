// MASC Dashboard — Core entity types (Agent, Task, Message, Board, Keeper)

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
  joined_at?: string
  last_seen?: string
  capabilities?: string[]
  emoji?: string
  koreanName?: string
  model?: string
  traits?: string[]
  interests?: string[]
  activityLevel?: number
  preferredHours?: number[]
  peakHour?: number
  primaryValue?: string
  personalityHint?: string
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
  assignee_kind?: string | null
  description?: string
  created_at?: string
  updated_at?: string
  completed_at?: string
  predecessor_task_id?: string | null
  contract?: TaskContract | null
  handoff_context?: TaskHandoffContext | null
  gate?: TaskGateSnapshot | null
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
  links?: TaskExecutionLinks | null
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

interface TaskGateCheck {
  evidence: string
  outcome: 'satisfied' | 'missing' | 'failed' | 'unsupported'
  detail: string
}

export interface TaskGateEvaluation {
  status: 'ready' | 'blocked' | 'inconclusive' | 'unknown'
  status_raw?: string | null
  checks?: TaskGateCheck[]
  reasons?: string[]
}

interface TaskGateSnapshot {
  strict?: boolean
  completion_contract?: string[]
  unmet_completion_contract?: string[]
  done?: TaskGateEvaluation
  inspect_to_implement?: TaskGateEvaluation | null
  verify_to_review?: TaskGateEvaluation | null
}

export interface Message {
  id?: string
  seq?: number
  from?: string
  content: string
  timestamp?: string
  type?: string
  workspace?: string
}

// --- Board ---

type BoardPostMeta = Record<string, unknown> & {
  source?: string | null
  classification_reason?: string | null
  judgment?: unknown
}

export type BoardVoteDirection = 'up' | 'down'
export type BoardModerationStatus = 'none' | 'flagged' | 'approved' | 'removed' | 'hidden' | 'warned'

export interface BoardContributorQuality {
  source?: string
  completion_rate?: number
  response_rate?: number
  board_posts?: number
  board_comments?: number
  thompson_confidence?: number
  evidence_state?: 'default' | 'measured'
}

export interface BoardActorIdentity {
  kind: 'keeper' | 'agent'
  id: string
  key: string
  display_name: string
  raw: string
  source?: 'keeper_registry_agent_name' | 'keeper_registry_name' | 'keeper_alias_contract' | 'raw_agent'
  runtime_agent_name?: string
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
  content: string
  meta?: BoardPostMeta | null
  tags: string[]
  votes: number | null
  vote_balance?: number | null
  vote_blind?: boolean
  vote_blind_reason?: string
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
  report_count?: number
  moderation_status?: BoardModerationStatus
  contributor_quality?: BoardContributorQuality | null
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
  votes?: number | null
  vote_balance?: number | null
  votes_up?: number | null
  votes_down?: number | null
  vote_blind?: boolean
  vote_blind_reason?: string
  current_vote?: BoardVoteDirection | null
  has_voted?: boolean
  report_count?: number
  moderation_status?: BoardModerationStatus
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
  estimated_tokens: number
  fingerprint: string | null
}

export interface PromptTelemetry {
  fingerprint: string | null
  estimated_total_tokens: number | null
  estimated_cacheable_tokens: number | null
  segments: Record<string, PromptSegmentTelemetry>
}

// Compatibility telemetry for historical OAS timeout-budget payloads.
// New keeper surfaces must keep the immutable root cause owner-specific
// (provider timeout, admission/capacity pressure, or turn deadline) instead of
// reclassifying those causes back into a timeout-budget state.
export interface TimeoutBudgetTelemetry {
  oas_timeout_sec: number | null
  adaptive_timeout_sec: number | null
  keeper_turn_timeout_sec: number | null
  remaining_turn_budget_sec: number | null
  estimated_input_tokens: number | null
  source: string | null
}

export interface CtxCompositionTelemetry {
  actual_input_tokens: number | null
  display_total_tokens: number
  estimated_known_tokens: number
  segments: Record<string, PromptSegmentTelemetry>
}

export interface KeeperMetricPoint {
  ts: number
  context_ratio: number
  context_tokens: number
  context_max: number
  latency_ms: number | null
  generation: number
  channel: string
  is_handoff: boolean
  is_compaction: boolean
  compaction_saved_tokens: number
  compaction_trigger: string | null
  model_used: string
  cost_usd: number
  handoff_to_model: string | null
  handoff_new_generation: number | null
  prompt_fingerprint: string | null
  prompt_metrics: PromptTelemetry | null
  provider_timeout_plan: TimeoutBudgetTelemetry | null
  ctx_composition: CtxCompositionTelemetry | null
  input_tokens: number | null
  output_tokens: number | null
  total_tokens: number | null
  wall_tokens_per_second: number | null
  inference_telemetry: InferenceTelemetry | null
  runtime_id?: string | null
  runtime_outcome?: string | null
  runtime_selected_model?: string | null
  runtime_attempt_count?: number | null
  runtime_strategy?: string | null
  fallback_applied: boolean
  fallback_hops: number
  fallback_from: string | null
  fallback_to: string | null
  fallback_reason: string | null
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
  'turn_timeout',
  'runtime_exhausted',
  'provider_runtime_error',
  'fiber_unresolved',
  'stale_turn_timeout',
  'stale_termination_storm',
  'heartbeat_failures',
  'turn_failures',
  'exception',
  'stale_fleet_batch',
  'awaiting_operator',
  'awaiting_sandbox_egress',
  'supervisor_paused',
  'synthetic_stall',
  'self_imposed_idle',
  'sdk_max_turns_exceeded',
  'sdk_token_budget_exceeded',
  'sdk_cost_budget_exceeded',
  'sdk_unrecognized_stop_reason',
  'sdk_idle_detected',
  'sdk_guardrail_violation',
  'sdk_tripwire_violation',
  'sdk_exit_condition_met',
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
  | 'compacting'
  | 'preparing'
  | 'handoff-imminent'
  | 'idle'
  | 'offline'
  | 'unbooted'
  | 'stopped'
  // Offline-detail sub-states emitted by keeperDisplayStatus.
  | 'paused'
  | 'crashed'
  | 'dead'
  | 'unknown'

export interface Goal {
  id: string
  title: string
  metric?: string | null
  target_value?: string | null
  due_date?: string | null
  priority: number
  status: string
  phase: string
  parent_goal_id?: string | null
  last_review_note?: string | null
  last_review_at?: string | null
  created_at: string
  updated_at: string
}

// --- Keeper ---

type KeeperHealthState = 'healthy' | 'idle' | 'stale' | 'degraded' | 'offline'

type KeeperQuietReason =
  | 'quiet_hours'
  | 'min_gap'
  | 'no_recent_activity'
  | 'disabled'
  | 'startup'
  | 'model_error'
  | 'graphql_error'
  | 'never_started'
  | 'unknown'

type KeeperNextActionPath =
  | 'direct_message'
  | 'manual_social_sweep'
  | 'probe'
  | 'recover'

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
  next_eligible_at_s?: number | null
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

// RFC-0232 P2: producer-typed turn outcome carried in the reply payload
// (`turn_outcome`). `continuation_checkpoint` marks the synthetic
// resume-next-cycle notice; `no_visible_reply` marks a completed runtime
// turn with no assistant text for the chat surface.
export type KeeperTurnOutcome =
  | 'visible_reply'
  | 'continuation_checkpoint'
  | 'no_visible_reply'

export type KeeperQueueReceiptLifecycle =
  | 'pending'
  | 'inflight'
  | 'delivered'
  | 'failed'

export type KeeperQueueReceiptFailureKind =
  | 'turn_failed'
  | 'timed_out'
  | 'no_visible_reply'
  | 'transcript_persist_failed'
  | 'connector_unavailable'
  | 'delivery_failed'
  | 'cancelled'
  | 'internal_error'

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
  /** Durable server receipt for a busy chat message accepted into the Keeper
   * queue. This is distinct from the browser-local draft queue. */
  queueReceiptId?: string | null
  /** Shutdown fence that caused this message to be deferred, when present. */
  queueShutdownOperationId?: string | null
  queueRevision?: number | null
  queuePendingCount?: number | null
  queueInflightCount?: number | null
  queueState?: KeeperQueueReceiptLifecycle | null
  queueFailureKind?: KeeperQueueReceiptFailureKind | null
  queueCorrelationError?: 'missing_outcome_ref' | null
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
export type ChatTraceThinkStep = { kind: 'think'; text: string; ts?: string; oasBlockIndex?: number }
export type ChatTraceReasonStep = { kind: 'reason'; text: string; detail?: string; ts?: string }
export type ChatTraceProgressStep = { kind: 'progress'; text: string; ts?: string; oasBlockIndex?: number }
export type ChatTraceToolStep = {
  kind: 'tool'
  name: string
  toolCallId?: string
  status?: 'pending' | 'ok' | 'err'
  dur?: string
  args?: string
  result?: string
  ts?: string
  oasBlockIndex?: number
}
export type ChatTraceStep = ChatTraceThinkStep | ChatTraceReasonStep | ChatTraceProgressStep | ChatTraceToolStep
export type ChatTraceBlock = { t: 'trace'; trace: ChatTraceStep[] }

export type ChatLinkBlock = { t: 'link'; url: string; title: string; desc?: string; meta?: string; fav?: string; kind?: string }

export type ChatBroadcastAck = 'acked' | 'read' | 'delivered' | string
export type ChatBroadcastRecipient = { id: string; ack: ChatBroadcastAck; at?: string }
export type ChatBroadcastBlock = { t: 'broadcast'; scope: string; via?: string; note: string; recipients: ChatBroadcastRecipient[] }
// RFC-0252: a reference from a keeper chat message to a fusion deliberation's
// board post. Carries only ids (snake_case to match the backend wire shape in
// keeper_chat_blocks.ml); ChatFusionCard lazy-fetches the board post by
// board_post_id and renders its meta_json (panel answers + judge synthesis).
export type ChatFusionBlock = { t: 'fusion'; board_post_id: string; run_id?: string }

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
  | ChatLinkBlock
  | ChatBroadcastBlock
  | ChatFusionBlock
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
  | 'queue_event'
  | 'queue_poll'
  | 'pending_request_store'
  | 'client_local_send'
  | 'client_reconciliation'

export type KeeperConversationStreamContractStatus =
  | 'backend_stream_event'
  | 'backend_terminal_event'
  | 'backend_lifecycle_replay'
  | 'backend_trace_join'
  | 'history_without_turn_ref'
  | 'history_without_stream_events'
  | 'queue_request_event'
  | 'queue_poll_result'
  | 'client_placeholder'
  | 'client_reconciled_history'
  | 'contract_gap'

export type KeeperConversationStreamDeliveryReceipt =
  | 'client_observed_sse_event'
  | 'server_durable_receipt'
  | 'server_lifecycle_replay_only'
  | 'no_delivery_receipt'

export interface KeeperConversationStreamContract {
  source: KeeperConversationStreamContractSource
  status: KeeperConversationStreamContractStatus
  eventName?: string | null
  requestId?: string | null
  turnRef?: string | null
  traceEventCount?: number | null
  lifecycleEvents?: string[] | null
  deliveryReceipt?: KeeperConversationStreamDeliveryReceipt | null
  reason?: string | null
}

export interface SurfaceRef {
  kind: 'dashboard' | 'discord' | 'slack' | 'webhook' | 'agent' | 'gate' | string
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
  // RFC-0233 §7: MASC-minted "<trace_id>#<absolute_turn>" join key. Carries the
  // chat message's originating turn so turn consumers can prefer exact matching
  // over timestamp-window fallback.
  turnRef?: string | null
  delivery: KeeperConversationDelivery
  streamState?: KeeperConversationStreamState
  streamContract?: KeeperConversationStreamContract | null
  queueSeq?: number | null
  queueClientActionId?: string | null
  attachments?: KeeperConversationAttachment[]
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
// the 13-state KeeperPhase, post-RFC-0046 (#14707). Emits 10 distinct
// values; `unknown` is a dashboard-side marker for missing data
// (`asString(row.pipeline_stage) ?? 'unknown'`). Removed legacy
// `thinking` / `tool_use` (= trajectory content_type, never
// pipeline_stage) and `scheduled_autonomous` (= turn channel, never
// pipeline_stage). Added `overflowed` which the backend emits but
// the type previously rejected.
export type PipelineStage =
  | 'idle'
  | 'compacting'
  | 'handoff'
  | 'offline'
  | 'failing'
  | 'overflowed'
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
  window_series_max_bytes?: number
  primary_model?: string

  // -- Handoff / Compaction counts --
  handoff_count?: number
  compaction_events?: number
  compaction_before_tokens?: number
  compaction_saved_tokens?: number
  compaction_saved_ratio?: number
  avg_compaction_saved_tokens?: number

  // -- Fallback rates --
  fallback_count?: number
  fallback_rate?: number
  model_fallback_count?: number
  model_fallback_rate?: number
  model_fallback_numerator?: number
  model_fallback_denominator?: number
  proactive_fallback_count?: number
  proactive_fallback_rate?: number
  proactive_template_fallback_count?: number
  proactive_template_fallback_rate?: number
  proactive_template_fallback_numerator?: number
  proactive_template_fallback_denominator?: number

  // -- Intervention --
  intervention_share?: number
  intervention_per_turn?: number

  // -- Drift --
  drift_applied_count?: number
  drift_applied_rate?: number

  // -- Tool --
  tool_call_count?: number

  // -- Memory --
  memory_checks?: number
  memory_passed?: number
  memory_failed?: number
  memory_pass_rate?: number
  memory_avg_score?: number
  memory_threshold?: number
  memory_corrections?: number
  memory_correction_success?: number
  memory_notes_added?: number

  // -- Memory compaction --
  memory_compaction_events?: number
  memory_compaction_before_notes?: number
  memory_compaction_dropped_notes?: number
  memory_compaction_invalid_dropped?: number
  memory_compaction_drop_ratio?: number
  memory_compaction_drop_avg?: number

  // -- Memory weather --
  memory_weather_checks?: number
  memory_weather_passed?: number
  memory_weather_pass_rate?: number

  // -- Top-N lists --
  top_work_kinds?: MetricsWindowTopItem[]
  top_models?: MetricsWindowTopItem[]
  top_tools?: MetricsWindowTopItem[]
  top_memory_kinds?: MetricsWindowTopItem[]
  top_drift_reasons?: MetricsWindowTopItem[]
  top_compaction_triggers?: MetricsWindowTopItem[]
  generation_equipment?: MetricsWindowTopItem[]

  // Catch-all for future fields
  [key: string]: unknown
}

export type KeeperPhase =
  | 'Offline'
  | 'Running'
  | 'Failing'
  | 'Overflowed'
  | 'Compacting'
  | 'HandingOff'
  | 'Draining'
  | 'Paused'
  | 'Stopped'
  | 'Crashed'
  | 'Restarting'
  | 'Dead'

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
  reconcile_status?: string | null
  emoji?: string
  koreanName?: string
  agent_name?: string
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
  active_goal_ids?: string[]
  goal?: string | null
  sandbox_profile?: 'local' | 'docker' | null
  sandbox_target?: string | null
  sandbox_last_error?: string | null
  blocked_task_count?: number | null
  goal_progress?: {
    active_goal_count?: number
    linked_task_count?: number
    done_task_count?: number
    open_task_count?: number
    blocked_task_count?: number
    convergence?: number | null
  } | null
  last_autonomous_action_at?: string | null
  autonomous_action_count?: number
  autonomous_turn_count?: number
  autonomous_text_turn_count?: number
  autonomous_tool_turn_count?: number
  board_reactive_turn_count?: number
  mention_reactive_turn_count?: number
  noop_turn_count?: number
  created_at?: string
  updated_at?: string
  last_heartbeat?: string
  keeper_age_s?: number
  last_turn_ago_s?: number
  last_handoff_ago_s?: number
  last_compaction_ago_s?: number
  last_proactive_ago_s?: number
  last_proactive_reason?: string | null
  last_proactive_preview?: string | null
  last_blocker?: string | null
  last_drift_reason?: string | null
  drift_count_total?: number
  runtime_warning_ctx_ratio?: number | null
  trust?: KeeperTrustSummary | null
  generation?: number
  turn_count?: number
  total_turns?: number
  total_tokens?: number
  last_latency_ms?: number
  last_activity_ago_s?: number
  last_activity_at?: string | null
  last_activity_source?: KeeperLiveActivitySource | null
  live_activity?: KeeperLiveActivity | null
  current_gate?: KeeperCurrentGate | null
  context_ratio?: number
  context_tokens?: number
  context_max?: number
  context_source?: string
  context?: {
    source?: string
    context_ratio?: number
    context_tokens?: number
    context_max?: number
    message_count?: number
    has_checkpoint?: boolean
  }
  compaction_profile?: string | null
  compaction_ratio_gate?: number | null
  compaction_message_gate?: number | null
  compaction_token_gate?: number | null
  traits?: string[]
  interests?: string[]
  primaryValue?: string
  activityLevel?: number
  memory_recent_note?: string | null
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_tool_names?: string[]
  // Observed audit fallback from the shell summary; not authored tool policy.
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
  turn_budget?: {
    reactive: {
      value: number
      source: 'override' | 'env' | 'override_invalid'
      env_default: number
      env_var: string
      raw_override: number | null
    }
    scheduled_autonomous: {
      value: number
      source: 'override' | 'env' | 'override_invalid'
      env_default: number
      env_var: string
      raw_override: number | null
    }
    manifest_path: string | null
    clamp_min: number
    clamp_max: number
  } | null
  conversation_tail_count?: number
  k2k_count?: number
  k2k_mentions?: Array<{ keeper: string; count: number }>
  handoff_count_total?: number
  compaction_count?: number
  last_compaction_saved_tokens?: number
  metrics_window?: MetricsWindow
  agent?: {
    name?: string
    exists?: boolean
    error?: string
    agent_type?: string
    status?: string
    current_task?: string | null
    joined_at?: string
    last_seen?: string
    last_seen_ago_s?: number
    capabilities?: string[]
    is_zombie?: boolean
    [key: string]: unknown
  }
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
    compactions_ok: number
    handoffs_ok: number
  }
  failures: {
    turn_failed: number
    compaction_failed: number
    handoff_failed: number
    crashes: number
    restarts: number
    consecutive_fail_current: number
  }
  validation: {
    oas_verdicts: {
      pass: number
      fail: number
      unknown: number
      top_failure_reasons: string[]
    }
    /** null until the contract-verdict gate (#7531) lands. */
    cdal_gate: null | {
      pass: number
      reject: number
      pending_verification: number
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
  context_within_budget: boolean
  context_handoff_needed: boolean
  compaction_active: boolean
  handoff_active: boolean
  operator_paused: boolean
  stop_requested: boolean
  dead_tombstone_latched: boolean
  drain_complete: boolean
  context_overflow: boolean
}

export interface KeeperSupervisorCrashLogEntry {
  ts?: number
  reason?: string
}

interface KeeperSupervisorDiagnostics {
  restart_count?: number
  crash_log?: KeeperSupervisorCrashLogEntry[]
  last_failure_reason?: string | null
  dead_since?: number | null
}

// --- Keeper Config (structured read-only view) ---

interface KeeperConfigPrompt {
  goal: string
  instructions: string
  system_prompt_blocks: {
    constitution: {
      key: string
      source: string
      text: string
    }
    world: {
      key: string
      source: string
      text: string
    }
    capabilities: {
      key: string
      source: string
      text: string
    }
  }
  effective_system_prompt: string
  unified_system_prompt: string
  unified_user_message_preview: string
}

interface KeeperConfigExecution {
  models: string[]
  active_model: string
  active_model_label?: string | null
  last_model_used_label?: string | null
  per_provider_timeout_sec?: number | null
  per_provider_timeout_mode: 'override' | 'turn_budget_default'
  verify: boolean
  selected_runtime_id: string
  selected_runtime_canonical: string
  runtime_options: string[]
  runtime_ref?: RuntimeRef | null
}

interface KeeperConfigCompaction {
  profile: string
  ratio_gate: number
  message_gate: number
  token_gate: number
  cooldown_sec: number
}

interface KeeperConfigProactive {
  enabled: boolean
}

export interface RuntimeRef {
  group: string
  item: string | null
}

export type KeeperFeatureStatus = 'wired' | 'source_only' | 'unwired'

interface KeeperConfigDrift {
  status: KeeperFeatureStatus
  enabled: boolean | null
  min_turn_gap: number | null
  count_total: number | null
  last_reason: string | null
}

interface KeeperConfigHandoff {
  auto: boolean
  threshold: number
  cooldown_sec: number
}

export interface KeeperConfigActiveGoal {
  id: string
  title: string
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
  active_goal_ids: string[]
  active_goals: KeeperConfigActiveGoal[]
  active_goal_count: number
  missing_active_goal_ids: string[]
}

interface KeeperConfigSources {
  live_meta_path: string
  default_manifest_path: string | null
  default_source_kind: 'toml' | 'persona' | null
  precedence: string[]
  has_live_override: boolean
  override_fields: string[]
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
  compaction_count: number
}

interface KeeperConfigLimits {
  min_context_override_tokens: number | null
  max_context_override_tokens: number | null
}

export interface KeeperConfigFieldPresence {
  schema: string
  producer: string
  present_paths: string[]
}

export interface KeeperHookSlot {
  active: boolean
  source: string
  gates?: string[]
  effects?: string[]
  features?: string[]
}

interface KeeperHookIntrospection {
  slots: Record<string, KeeperHookSlot>
  deny_list: string[]
  // deny_list_count dropped: it is pure derived state (deny_list.length).
  // Consumers compute the count from the array directly.
  cost_budget: { max_cost_usd?: number | null; active: boolean }
}

export interface KeeperConfig {
  name: string
  active_goal_ids: string[]
  autoboot_enabled: boolean
  max_context_override: number | null
  limits: KeeperConfigLimits
  sandbox_profile?: 'local' | 'docker' | string
  network_mode?: 'none' | 'inherit' | string
  sandbox_last_error?: string | null
  allowed_paths: string[]
  effective_allowed_paths: string[]
  prompt: KeeperConfigPrompt
  execution: KeeperConfigExecution
  compaction: KeeperConfigCompaction
  proactive: KeeperConfigProactive
  drift: KeeperConfigDrift
  handoff: KeeperConfigHandoff
  hooks?: KeeperHookIntrospection
  runtime: KeeperConfigRuntime
  runtime_trust?: KeeperConfigRuntimeTrust | null
  workspace: KeeperConfigWorkspace
  sources: KeeperConfigSources
  metrics: KeeperConfigMetrics
  field_presence?: KeeperConfigFieldPresence
}
