import type { DiscordReplyOrigin } from './discord-reply'
/**
 * Keepers Workspace wire types (#36).
 */

import type { EQUIPMENT_IDS, KeeperEquipment } from '../../lib/keeper-portrait'
import type { KeeperChatDeliveryProvenance } from '../../keeper-delivery-provenance'

export type RosterMode = 'companies' | 'attention' | 'wall24h'

export type DebugCompanionTab = 'trace' | 'context' | 'memory' | 'config-diff'

export interface KeeperRosterTurnSlot {
  readonly starts_at: number
  readonly ok: number
  readonly rested: number
  readonly failed: number
}

export interface KeeperActiveTurnPreview {
  readonly status_text: string
  readonly activity: 'preparing' | 'waiting' | 'streaming' | 'tool' | 'failed' | string
  readonly text_tail: string
  readonly last_tool: string | null
  readonly updated_at_unix: number
  readonly revision: number | null
}

export interface KeeperActiveTurn {
  readonly lane: string
  readonly turn_ref?: string | null
  readonly started_at_unix: number
  readonly phase?: string | null
  readonly tool_in_flight: string | null
  readonly elapsed_ms?: number | null
  readonly preview?: KeeperActiveTurnPreview | null
}

export interface KeeperWaitingRow {
  readonly keeper_name: string | null
  readonly source: string
  readonly waiting_on: string
  readonly what: string
  readonly wake_producer: string
  readonly since: number | null
  readonly due_at: number | null
  readonly next_action: string
}

export interface KeeperWaitingInventoryData {
  readonly schema: string
  readonly keeper_count: number
  readonly waiting_keeper_count: number
  readonly row_count: number
  readonly total_row_count: number
  readonly oldest_age_seconds: number | null
  readonly rows: readonly KeeperWaitingRow[]
}

export interface KeeperPathRest {
  readonly status: 'serving' | 'resting'
  readonly runtime_id: string | null
  readonly release_at: string | null
  readonly release_basis: string | null
}

export interface KeeperLaneFailure {
  readonly runtime_id: string | null
  readonly summary: string
  readonly fault_kind: string | null
  readonly attempt?: number | null
  readonly dispatch?: string | null
  readonly failure_kind?: string | null
  readonly failure_detail?: string | null
  readonly provider?: string | null
  readonly network_kind?: string | null
}

export interface KeeperTurnBreakdown {
  readonly ok: number
  readonly rested: number
  readonly failed: number
}

export interface KeeperWaitingSummary {
  readonly count: number
  readonly primary_reason: string | null
  readonly due_at: string | null
}
export interface KeeperRosterItem {
  readonly name: string
  readonly status: string
  readonly phase: string
  readonly health: string
  readonly paused: boolean
  readonly keepalive_running: boolean
  readonly activation_mode: string
  readonly runtime_id: string
  readonly sandbox_profile: string | null
  readonly company: string
  readonly context_ratio: number | null
  readonly context_tokens: number | null
  readonly context_max: number | null
  readonly context_provenance?: 'measured' | 'estimated' | 'unavailable' | null
  readonly estimated_context_ratio?: number | null
  readonly context_unavailable_reason: string | null
  readonly runtime_blocker_summary: string | null
  readonly runtime_blocker_signature?: string | null
  readonly runtime_blocker_class?: string | null
  readonly runtime_path_rest?: KeeperPathRest | null
  readonly operator_disposition?: string | null
  readonly operator_disposition_reason?: string | null
  readonly failing_since?: number | null
  readonly next_action?: string | null
  readonly runtime_lane_failures?: readonly KeeperLaneFailure[]
  readonly last_failure: { readonly cause: string; readonly at_unix: number | null } | null
  readonly directory_issue: string | null
  readonly turns_24h: number | null
  readonly turns_24h_breakdown?: KeeperTurnBreakdown | null
  readonly candle_balance_milli: string | number | null
  readonly portrait_equipment: KeeperEquipment | null
  readonly chat_control_token: string | null
  readonly waiting_summary?: KeeperWaitingSummary | null
  readonly active_turn: KeeperActiveTurn | null
}

// ── Chat Delivery & Transcript ────────────────────────────────────────────

export type ChatDeliveryState =
  | 'Queued'
  | 'Sending'
  | 'Pending_processing'
  | 'Confirming_delivery'
  | 'Streaming'
  | 'Delivered'
  | 'Cut_recovered'
  | 'Failed'

export interface ChatAttachmentDraft {
  readonly id: string
  readonly type: 'image' | 'file'
  readonly name: string
  readonly size: number
  readonly mimeType: string
  readonly data: string
}

export interface ChatToolBlock {
  readonly id?: string
  readonly streamKey?: string
  readonly executionId?: string
  readonly name: string
  readonly args?: string
  readonly result?: string
  readonly status?: string
  readonly progressLabel?: string
  readonly duration?: string
}

export type KeeperToolResultResponse =
  | { readonly state: 'pending'; readonly executionId: string }
  | { readonly state: 'unavailable'; readonly executionId: string; readonly reason: string }
  | {
      readonly state: 'page'
      readonly executionId: string
      readonly sourceId?: string
      readonly bodySha256?: string
      readonly offset: number
      readonly nextOffset: number
      readonly encoding: string
      readonly content: string
      readonly isError: boolean
      readonly recordedBytes: number
      readonly totalBytes: number
      readonly eof: boolean
    }

export type ChatEntryKind =
  | 'chat'
  | 'tool_call'
  | 'tool_result'
  | 'memory_recall'
  | 'autonomous'
  | 'system_internal'

export type ChatSpeakerAuthority = 'owner' | 'keeper' | 'external'

export interface KeeperToolApprovalModesData {
  readonly defaultMode: string
  readonly overrides: Readonly<Record<string, string>>
  readonly restoreError: string | null
}

export interface RetainedChatImage {
  readonly path: string
  readonly caption?: string
  readonly workspaceEpoch: number
}

export interface ChatTranscriptEntry {
  readonly id: string
  readonly role: 'user' | 'assistant' | 'system' | 'tool' | 'request_failure'
  readonly speakerLabel?: string
  readonly content: string
  readonly retainedImages?: readonly RetainedChatImage[]
  readonly thinking?: string
  readonly ts: number
  readonly operationId?: string
  readonly replyOperationId?: string
  readonly deliveryProvenance?: KeeperChatDeliveryProvenance
  readonly turnRef?: string
  readonly executionId?: string
  readonly toolName?: string
  readonly kind?: ChatEntryKind
  readonly toolCalls?: readonly ChatToolBlock[]
  readonly memoryItems?: readonly string[]
  readonly autonomousTurn?: boolean
  readonly deliveryState?: ChatDeliveryState
  readonly cutStream?: boolean
  readonly errorDetail?: string
  readonly speakerAuthority?: ChatSpeakerAuthority | null
  readonly speakerName?: string | null
  readonly speakerId?: string | null
  readonly surface?: string | null
  readonly discordReplyOrigin?: DiscordReplyOrigin | null
}

export interface ChatHistoryPage {
  readonly messages: readonly ChatTranscriptEntry[]
  readonly hasMore: boolean
  readonly nextCursor: string | null
}

export interface ChatJournalCursor {
  readonly lastSeq: number
  readonly nextOffset: number
}

export interface ChatJournalTextOwner {
  readonly kind: 'observed_response' | 'unobserved_scope'
  readonly contentGeneration?: number
  readonly streamScope?: number | null
}

export type ChatJournalEvent =
  | { readonly kind: 'run_started' }
  | { readonly kind: 'batch_bound'; readonly executionId: string }
  | { readonly kind: 'runtime_attempt_started' }
  | { readonly kind: 'text_delta'; readonly text: string; readonly owner: ChatJournalTextOwner }
  | { readonly kind: 'run_finished' }
  | { readonly kind: 'error'; readonly detail: string }
  | { readonly kind: 'other' }

export interface ChatJournalPage {
  readonly operationId: string
  readonly events: readonly ChatJournalEvent[]
  readonly next: ChatJournalCursor | null
}

export interface QueuedChatOperation {
  readonly operationId: string
  readonly sequence: string
  readonly createdAt: number
  readonly message: string
  readonly state: string
}

export interface BtwQueryState {
  readonly status: 'idle' | 'streaming' | 'done' | 'error'
  readonly prompt: string
  readonly reply: string
  readonly error: string | null
}

// ── Turn Records, Tool Calls, Prompt & Provider Input (#36) ──────────────

export interface TurnRecordPromptBlock {
  readonly block: string
  readonly bytes: number
  readonly digest: string
}

export interface TurnRecordItem {
  readonly trace_id: string
  readonly absolute_turn: number
  readonly turn_ref: string
  readonly turn_kind: 'autonomous' | 'direct'
  readonly runtime_profile: string
  readonly selected_model?: string
  readonly finish_reason?: string
  readonly context_window?: number
  readonly provider_context_window?: number
  readonly request_latency_ms?: number
  readonly ttfrc_ms?: number
  readonly input_tokens?: number
  readonly cache_creation_input_tokens?: number
  readonly cache_read_input_tokens?: number
  readonly output_tokens?: number
  readonly ts: number
  readonly blocks: readonly TurnRecordPromptBlock[]
  readonly raw_trace_run_ref: {
    readonly worker_run_id: string
    readonly path: string
    readonly start_seq: number
    readonly end_seq: number
  } | null
}

export interface KeeperTurnRecordsData {
  readonly keeper: string
  readonly count: number
  readonly live_turn_in_progress: boolean
  readonly health: string
  readonly entries: readonly {
    readonly record: TurnRecordItem
    readonly diff_vs_prev: {
      readonly added: readonly TurnRecordPromptBlock[]
      readonly removed: readonly TurnRecordPromptBlock[]
      readonly changed: readonly { readonly prev: TurnRecordPromptBlock; readonly next: TurnRecordPromptBlock }[]
    } | null
  }[]
}

export interface KeeperToolCallEntry {
  readonly ts: number
  readonly record_kind: 'tool_call' | 'composition_run' | 'lifecycle_event'
  readonly keeper: string
  readonly tool: string
  readonly duration_ms: number
  readonly wire_outcome: string
  readonly disposition?: 'completed' | 'deferred' | 'failed'
  readonly failure_class?: string
  readonly execution_id?: string
  readonly trace_id?: string
  readonly turn?: number
  readonly task_id?: string
  readonly model?: string
  readonly result_bytes?: number
  readonly truncated_to?: number
  readonly input: unknown
  readonly output: unknown
}

export interface KeeperToolCallsData {
  readonly keeper: string
  readonly count: number
  readonly health: string
  readonly entries: readonly KeeperToolCallEntry[]
}

export interface KeeperToolStatsData {
  readonly keeper: string
  readonly window_hours: number
  readonly total_entries: number
  readonly tools: readonly {
    readonly name: string
    readonly call_count: number
    readonly success_count: number
    readonly failure_count: number
    readonly avg_duration_ms: number
    readonly p95_duration_ms: number
  }[]
}

export interface KeeperLastPromptData {
  readonly keeper: string
  readonly captured_at: number
  readonly trace_id: string
  readonly absolute_turn: number
  readonly assembled: string | null
  readonly assembled_bytes: number
  readonly system_prompt: string | null
  readonly blocks: readonly { readonly id: string; readonly bytes: number; readonly text: string }[]
}

export interface ProviderInputPartSummary {
  readonly index: number
  readonly kind: 'system_prompt' | 'message' | 'tool_schema'
  readonly role?: string
  readonly name?: string
  readonly bytes: number
  readonly sha256: string
}

export interface ProviderInputData {
  readonly keeper: string
  readonly turn_ref: string
  readonly runtime_profile: string
  readonly wire: {
    readonly provider: string
    readonly model: string
    readonly http_codec: string
    readonly body_bytes: number
  }
  readonly parts: readonly ProviderInputPartSummary[]
}

export interface RawTraceTurnItem {
  readonly file: string
  readonly trace_id: string | null
  readonly bytes: number
  readonly records: number | null
  readonly modified_at: number
}

export interface CheckpointInventoryData {
  readonly keeper: string
  readonly trace_id: string
  readonly current_status: 'available' | 'missing' | 'unavailable'
  readonly current: {
    readonly snapshot_id: string
    readonly message_count: number
    readonly created_at: number
    readonly latest_preview: string | null
  } | null
  readonly history: readonly {
    readonly snapshot_id: string
    readonly message_count: number
    readonly created_at: number
    readonly latest_preview: string | null
  }[]
}

// ── Memory OS (3-way discriminated per #36) ───────────────────────────────

export interface OrdinaryMemoryFact {
  readonly memory_id: string
  readonly claim: string
  readonly category: string
  readonly first_seen: number
  readonly last_seen: number
}

export interface OrdinarySupportInvalidation {
  readonly memory_id: string
  readonly claim: string
  readonly missing_premise_ids: readonly string[]
}

export type OrdinaryMemoryBranch =
  | { readonly state: 'absent' }
  | { readonly state: 'read_error'; readonly read_error: string }
  | {
      readonly state: 'present'
      readonly revision: number
      readonly snapshot_sha256: string
      readonly updated_at: number
      readonly facts: readonly OrdinaryMemoryFact[]
      readonly support_invalidations: readonly OrdinarySupportInvalidation[]
    }

export interface SourceBoundMemoryFact {
  readonly claim: string
  readonly first_seen: number
  readonly path: string
  readonly sha256: string
}

export interface SourceBoundInvalidation {
  readonly source_path: string
  readonly invalidated_at: number
  readonly reason: 'source_changed' | 'source_unavailable' | string
}

export type SourceBoundMemoryBranch =
  | { readonly state: 'absent' }
  | { readonly state: 'read_error'; readonly read_error: string }
  | {
      readonly state: 'present'
      readonly revision: number
      readonly updated_at: number
      readonly facts: readonly SourceBoundMemoryFact[]
      readonly invalidations: readonly SourceBoundInvalidation[]
    }

export interface KeeperMemoryFactsData {
  readonly keeper: string
  readonly ordinary: OrdinaryMemoryBranch
  readonly source_bound: SourceBoundMemoryBranch
  readonly events_unreadable_lines: number
  readonly events_read_error: string | null
}

export interface KeeperMemoryOsInternalsData {
  readonly keeper: string
  readonly compaction: {
    readonly present: boolean
    readonly epoch_count: number
    readonly archived_turns_count: number
    readonly anchor_bytes: number
    readonly latest_epoch_id: number | null
    readonly verified_facts_count: number
    readonly decisions_count: number
    readonly open_threads_count: number
    readonly read_error: string | null
  }
  readonly canonical_turns: {
    readonly present: boolean
    readonly turn_count: number
    readonly latest_turn_id: string | null
    readonly compaction_watermark_seq: number | null
    readonly compaction_watermark_epoch: number | null
    readonly history_resets_count: number
    readonly read_error: string | null
  }
  readonly memory_digest: {
    readonly present: boolean
    readonly revision: number | null
    readonly digest_sha256: string | null
    readonly bytes: number
    readonly fact_count: number
    readonly derived_count: number
  }
  readonly librarian_molt: {
    readonly writer_kind: string
    readonly writer_state: unknown
    readonly pending_molt: unknown
    readonly available_acts: readonly string[]
  }
}

export interface KeeperMemoryJournalEntry {
  readonly structural_id: string
  readonly ok: boolean
  readonly error?: string
  readonly recorded_at?: number
  readonly revision?: number
  readonly source_kind?: string
  readonly added?: number
  readonly removed?: number
  readonly retained?: number
  readonly invalidated?: number
}

export interface KeeperMemoryActivityEvent {
  readonly identity: string
  readonly recorded_at: number
  readonly revision: number
  readonly kind: string
  readonly reason: string | null
}

export interface KeeperMemoryJournalData {
  readonly keeper: string
  readonly returned: number
  readonly undecodable_lines: number
  readonly entries: readonly KeeperMemoryJournalEntry[]
  readonly activity: {
    readonly events: readonly KeeperMemoryActivityEvent[]
    readonly notes: readonly string[]
  } | null
}

export type MemoryActPayload =
  | { readonly action: 'resume' }
  | { readonly action: 'adopt'; readonly observed: string }
  | { readonly action: 'restart_reading'; readonly observed: string }
  | { readonly action: 'skip_line'; readonly offset: number }
  | {
      readonly action: 'skip_item'
      readonly target:
        | { readonly kind: 'unreadable_unit'; readonly turn_log: string; readonly line: number }
        | { readonly kind: 'head_item'; readonly turn_log: string; readonly line: number; readonly store: string; readonly at: number }
    }

// ── Portrait & Candle (#36) ───────────────────────────────────────────────

export type PortraitSlot = keyof typeof EQUIPMENT_IDS

export interface CandleBalanceRow {
  readonly keeper: string
  readonly balance_milli: number
  readonly decayed_milli: string
  readonly last_event_unix: number | null
  readonly owned_items: readonly string[]
  readonly equipped: Readonly<Record<PortraitSlot, string | null>>
}

export interface CandleLedgerEventRow {
  readonly seq: number
  readonly at_unix: number
  readonly at_rfc3339: string
  readonly kind: string
  readonly summary: string
}

export interface KeeperCandleLedgerData {
  readonly ledger_state: 'missing' | 'present'
  readonly total_events: number
  readonly policy_configuration: 'off' | 'disabled' | 'enabled'
  readonly disabled_reason: string | null
  readonly pricing_mode: string
  readonly half_life_hours: number | null
  readonly supply: {
    readonly issued_milli: string
    readonly burned_milli: string
    readonly circulating_milli: string
  }
  readonly balance: CandleBalanceRow | null
  readonly recent_events: readonly CandleLedgerEventRow[]
}

export interface KeeperCatalogItem {
  readonly id: string
  readonly slot: PortraitSlot
  readonly price_status: 'priced' | 'unpriced'
  readonly price_milli: string | null
}

export interface KeeperItemsData {
  readonly status: 'off' | 'disabled' | 'ready'
  readonly reason?: string
  readonly account_revision: string | null
  readonly balance_milli: string | null
  readonly owned_items: readonly string[]
  readonly catalog: readonly KeeperCatalogItem[]
}

// ── Work & Sandbox ────────────────────────────────────────────────────────

export interface KeeperLinkedTask {
  readonly id: string
  readonly title: string
  readonly status: string
  readonly priority: number
  readonly goal_id: string | null
  readonly updated_at: string | null
}

export interface KeeperOperatorNoteData {
  readonly keeper: string
  readonly pending: boolean
  readonly text: string
  readonly created_by: string
  readonly created_at: number
  readonly consumed_turn: number | null
}

export interface KeeperSandboxData {
  readonly keeper: string
  readonly probe_kind: string
  readonly backend: string
  readonly summary: Readonly<Record<string, unknown>>
}

// ── Schema Config CAS & OAuth/Secrets (#36) ───────────────────────────────

export interface KeeperAttachedProvider {
  readonly provider: string
  readonly provider_label: string
  readonly attached: boolean
  readonly enabled?: boolean
  readonly tools?: readonly string[]
  readonly problem?: string
  readonly switch_problem?: string
}
