import type { KeeperDiagnostic, KeeperTrustSummary, Message, MissionSignalTruth, MissionEvidenceSource } from './core'
import type { PendingConfirmEnvelope, PendingConfirmation, PendingConfirmSummary, OperatorActionDescriptor } from './gate'

export interface DashboardMissionSummary {
  workspace_health?: string
  cluster?: string
  project?: string
  paused?: boolean
  tempo_interval_s?: number
  active_agents?: number
  keeper_pressure?: number
  active_operations?: number
  pending_approvals?: number
  incident_count?: number
  recommended_action_count?: number
  top_attention?: OperatorAttentionItem | null
  top_action?: OperatorRecommendedAction | null
}

export interface DashboardMissionCommandFocus {
  health?: string
  active_operations?: number
  pending_approvals?: number
  top_attention?: OperatorAttentionItem | null
  top_action?: OperatorRecommendedAction | null
}

export interface DashboardMissionTargets {
  keepers: OperatorKeeperSnapshot[]
  pending_confirms: PendingConfirmation[]
  available_actions: OperatorActionDescriptor[]
}

export interface DashboardMissionAttentionQueueItem {
  id: string
  kind: string
  severity: string
  summary: string
  target_type: string
  target_id?: string | null
  top_action?: OperatorRecommendedAction | null
  related_session_ids: string[]
  related_agent_names: string[]
  evidence?: unknown
  evidence_preview: string[]
  grounded_verdict?: GroundedVerdict | null
  last_seen_at?: string | null
}

export interface GroundedVerdictEvidenceRef {
  path: string
  line?: number | null
  quote: string
}

export interface GroundedVerdict {
  verdict: string
  reason?: string | null
  evidence: GroundedVerdictEvidenceRef[]
}

export interface DashboardMissionSessionBrief {
  session_id: string
  goal: string
  created_by?: string | null
  origin_kind?: 'human' | 'system'
  namespace?: string | null
  status?: string
  health?: string
  member_names: string[]
  started_at?: string | null
  elapsed_sec?: number | null
  operation_id?: string | null
  blocker_summary?: string | null
  last_event_at?: string | null
  last_event_summary?: string | null
  communication_summary?: string | null
  active_count?: number
  seen_count?: number
  planned_count?: number
  required_count?: number
  counts_basis?: string | null
  related_attention_count: number
  top_attention?: OperatorAttentionItem | null
  top_recommendation?: OperatorRecommendedAction | null
}

export interface DashboardMissionParticipantPreview {
  agent_name: string
  display_name?: string | null
  is_live?: boolean
  status?: string
  current_work?: string | null
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_tool_names: string[]
  last_activity_at?: string | null
}

export interface DashboardMissionOperationBadge {
  operation_id: string
  status?: string
  stage?: string | null
  detachment_status?: string | null
  objective?: string | null
  updated_at?: string | null
}

export interface DashboardMissionKeeperRef {
  name: string
  agent_name?: string | null
  status?: string
  generation?: number
  context_ratio?: number | null
  last_turn_ago_s?: number | null
  current_work?: string | null
}

export interface DashboardMissionSessionCard extends DashboardMissionSessionBrief {
  member_previews: DashboardMissionParticipantPreview[]
  operation_badges: DashboardMissionOperationBadge[]
  keeper_refs: DashboardMissionKeeperRef[]
}

export interface DashboardMissionAgentBrief {
  agent_name: string
  display_name?: string | null
  is_live?: boolean
  archived_reason?: string | null
  status?: string
  where?: string | null
  with_whom: string[]
  current_work?: string | null
  related_session_id?: string | null
  related_attention_count: number
  last_activity_at?: string | null
  last_activity_age_sec?: number | null
  signal_truth?: MissionSignalTruth
  evidence_source?: MissionEvidenceSource
  recent_output_preview?: string | null
  recent_input_preview?: string | null
  recent_event?: string | null
  recent_tool_names: string[]
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
}

export interface DashboardMissionKeeperBrief {
  name: string
  agent_name?: string | null
  status?: string
  generation?: number
  context_ratio?: number | null
  last_turn_ago_s?: number | null
  current_work?: string | null
  last_autonomous_action_at?: string | null
  // Mission keeper briefs carry observed audit freshness, not authored policy.
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
}

export interface DashboardMissionInternalSignal {
  id: string
  signal_type: 'attention' | 'action'
  severity: string
  summary: string
  target_type: string
  target_id?: string | null
  attention?: OperatorAttentionItem | null
  action?: OperatorRecommendedAction | null
}

export interface DashboardMissionResponse {
  generated_at?: string
  summary: DashboardMissionSummary
  incidents: OperatorAttentionItem[]
  recommended_actions: OperatorRecommendedAction[]
  command_focus: DashboardMissionCommandFocus
  operator_targets: DashboardMissionTargets
  attention_queue: DashboardMissionAttentionQueueItem[]
  sessions: DashboardMissionSessionCard[]
  agent_briefs: DashboardMissionAgentBrief[]
  keeper_briefs: DashboardMissionKeeperBrief[]
  internal_signals: DashboardMissionInternalSignal[]
}

export interface DashboardMissionTimelineItem {
  id: string
  timestamp?: string | null
  event_type?: string
  actor?: string | null
  summary: string
}

export interface DashboardMissionWorkerReadiness {
  worker_name: string
  spawn_role?: string | null
  runtime_pool?: string | null
  routing_reason?: string | null
  has_meta?: boolean | null
  has_checkpoint?: boolean | null
  in_flight?: boolean | null
  delegate_ready?: boolean | null
  blocked_reason?: string | null
  guidance?: string | null
}

export interface DashboardMissionSessionWorkerRuns {
  requested_count?: number | null
  completed_success_count?: number | null
  completed_failed_count?: number | null
  in_flight_count?: number | null
  in_flight_run_ids: string[]
  in_flight_actor_names: string[]
  ready_worker_count?: number | null
  ready_worker_names: string[]
  delegate_ready_worker_names: string[]
  blocked_worker_names: string[]
  pending_worker_count?: number | null
  pending_worker_names: string[]
  worker_readiness: DashboardMissionWorkerReadiness[]
  recent_runs: DashboardProofWorkerRunEvidence[]
}

export interface DashboardMissionSessionDetailResponse {
  generated_at?: string
  session_id: string
  session?: DashboardMissionSessionCard | null
  timeline: DashboardMissionTimelineItem[]
  participants: DashboardMissionParticipantPreview[]
  operations: DashboardMissionOperationBadge[]
  keepers: DashboardMissionKeeperRef[]
  worker_runs?: DashboardMissionSessionWorkerRuns | null
  error?: string | null
}

export interface DashboardMissionBriefingSection {
  id: string
  label: string
  status: 'ok' | 'healthy' | 'aligned' | 'watch' | 'risk' | 'unclear'
  summary: string
  evidence: string[]
  signal_class?: 'operational_risk' | 'metadata_gap' | 'mixed'
  evidence_quality?: 'strong' | 'partial' | 'missing'
}

export interface DashboardMissionBriefingMetadataGap {
  kind: string
  summary: string
  scope_type: 'session' | 'keeper' | 'agent'
  scope_id?: string | null
  severity: 'info' | 'watch'
}

export interface DashboardMissionBriefingResponse {
  generated_at?: string
  cached?: boolean
  stale?: boolean
  refreshing?: boolean
  status?: 'ok' | 'pending' | 'unavailable' | 'error'
  summary?: string | null
  model?: string | null
  ttl_sec?: number
  criteria: string[]
  basis?: {
    namespace?: string | null
    crew_count?: number
    agent_count?: number
    keeper_count?: number
  }
  metadata_gap_count?: number
  metadata_gaps: DashboardMissionBriefingMetadataGap[]
  sections: DashboardMissionBriefingSection[]
  error?: string | null
  last_error?: string | null
}

export interface DashboardProofWorkerRunEvidence {
  worker_run_id: string
  session_id?: string | null
  operation_id?: string | null
  trace_ref?: Record<string, unknown> | null
  evidence_session_id?: string | null
  result_status?: string | null
  checkpoint_ref?: string | null
  tool_trace_refs?: string[]
  raw_evidence_refs?: string[]
  worker_name?: string | null
  status?: string | null
  mode?: string | null
  wait_mode?: string | null
  trace_capability?: string | null
  trace_evidence_status?: string | null
  trace_validated?: boolean | null
  validation_failures?: string[]
  success?: boolean | null
  requested_worker_class?: string | null
  requested_worker_size?: string | null
  requested_runtime?: string | null
  requested_model?: string | null
  tool_surface_status?: string | null
  tool_surface_source?: string | null
  tool_surface_names?: string[]
  tool_surface_masc_names?: string[]
  tool_surface_shell_names?: string[]
  tool_surface_count?: number | null
  resolved_runtime?: string | null
  resolved_model?: string | null
  routing_reason?: string | null
  tool_names?: string[]
  tool_call_count?: number | null
  output_preview?: string | null
  record_count?: number | null
  assistant_block_count?: number | null
  final_text?: string | null
  stop_reason?: string | null
  failure_reason?: string | null
  error?: string | null
  proof_evidence_status?: string | null
  evidence_refs?: string[]
  ts_iso?: string | null
}

export interface OperatorNamespaceSnapshot {
  project?: string
  cluster?: string
  paused?: boolean
  pause_reason?: string | null
  paused_by?: string | null
  paused_at?: string | null
}

export interface OperatorSessionSnapshot {
  session_id: string
  status?: string
  progress_pct?: number
  elapsed_sec?: number
  remaining_sec?: number
  done_delta_total?: number
  summary?: Record<string, unknown>
  team_health?: Record<string, unknown>
  communication_metrics?: Record<string, unknown>
  orchestration_state?: Record<string, unknown>
  runtime_metrics?: Record<string, unknown>
  report_paths?: Record<string, string>
  session?: Record<string, unknown>
  recent_events?: Record<string, unknown>[]
}

export interface OperatorKeeperSnapshot {
  name: string
  runtime_class?: 'keeper'
  phase?: string | null
  pipeline_stage?: string | null
  paused?: boolean | null
  registered?: boolean
  agent_name?: string
  status?: string
  context_ratio?: number
  generation?: number
  last_autonomous_action_at?: string | null
  last_turn_ago_s?: number
  model?: string
  turn_count?: number
  context_tokens?: number
  context_max?: number
  context_source?: string
  keepalive_running?: boolean
  autonomous_action_count?: number
  autonomous_turn_count?: number
  autonomous_text_turn_count?: number
  autonomous_tool_turn_count?: number
  last_model_used?: string
  last_model_used_label?: string | null
  active_model?: string
  active_model_label?: string | null
  diagnostic?: Record<string, unknown>
  runtime_trust?: KeeperTrustSummary | null
  recent_activity?: Record<string, unknown>[]
  needs_attention?: boolean | null
  attention_reason?: string | null
  next_human_action?: string | null
}


export interface OperatorAttentionItem {
  kind: string
  severity: string
  summary: string
  target_type: string
  target_id?: string | null
  actor?: string | null
  evidence?: unknown
}

export interface OperatorRecommendedAction {
  action_type: string
  target_type: string
  target_id?: string | null
  severity: string
  reason: string
  confirm_required?: boolean
  suggested_payload?: unknown
  preview?: unknown
}


export interface OperatorJudgeRuntime {
  enabled?: boolean
  judge_online?: boolean
  refreshing?: boolean
  generated_at?: string | null
  expires_at?: string | null
  model_used?: string | null
  keeper_name?: string | null
  last_error?: string | null
}

export interface OperatorGuidanceSummary {
  summary?: string | null
  confidence?: number | null
  provenance?: string | null
  authoritative?: boolean
  surface?: string | null
  fresh_until?: string | null
  keeper_name?: string | null
  fallback_used?: boolean
  disagreement_with_truth?: boolean
}

export interface OperatorJudgment {
  judgment_id?: string
  surface?: string | null
  target_type?: string | null
  target_id?: string | null
  status?: string | null
  summary?: string | null
  confidence?: number | null
  generated_at?: string | null
  fresh_until?: string | null
  keeper_name?: string | null
  model_name?: string | null
  runtime_name?: string | null
  evidence_refs: string[]
  recommended_action?: OperatorRecommendedAction | null
  supersedes: string[]
  fallback_used?: boolean
  disagreement_with_truth?: boolean
  provenance?: string | null
}

export interface OperatorReviewDecision {
  item_id: string
  fingerprint: string
  decision: 'resolved' | 'deferred'
  actor: string
  reason: string
  at: string
  target_type: string
  target_id?: string | null
  recommended_action_type?: string | null
}

export interface OperatorDigest {
  trace_id?: string
  target_type: 'root' | 'namespace' | 'workspace' | 'keeper'
  target_id?: string | null
  health?: string
  judgment_owner?: string | null
  authoritative_judgment_available?: boolean
  operator_judge_runtime?: OperatorJudgeRuntime | null
  judgment?: OperatorJudgment | null
  active_guidance_layer?: string | null
  active_summary?: OperatorGuidanceSummary | null
  active_recommended_actions?: OperatorRecommendedAction[]
  active_recommendation_source?: string | null
  active_recommendation_summary?: OperatorGuidanceSummary | null
  fallback_recommended_actions?: OperatorRecommendedAction[]
  recommendation_summary?: OperatorGuidanceSummary | null
  root?: OperatorNamespaceSnapshot
  attention_items: OperatorAttentionItem[]
  recommended_actions: OperatorRecommendedAction[]
  recent_reviews: OperatorReviewDecision[]
}

export interface KeeperProbeResult {
  status?: unknown
  diagnostic?: KeeperDiagnostic | null
}

export interface KeeperRecoverResult {
  recovered: boolean
  skipped_reason?: string | null
  before?: KeeperDiagnostic | null
  after?: KeeperDiagnostic | null
  down?: unknown
  up?: unknown
}

export interface InferenceInflightSnapshot {
  boundary_owner: 'oas_runtime'
  active: number
}

export interface OperatorSnapshot {
  root: OperatorNamespaceSnapshot
  sessions: OperatorSessionSnapshot[]
  keepers: OperatorKeeperSnapshot[]
  inference_inflight?: InferenceInflightSnapshot | null
  operator_judge_runtime?: OperatorJudgeRuntime | null
  persistent_agents?: OperatorKeeperSnapshot[]
  recent_messages: Message[]
  pending_confirms: PendingConfirmation[]
  pending_confirm_envelope?: PendingConfirmEnvelope | null
  pending_confirm_summary?: PendingConfirmSummary
  available_actions: OperatorActionDescriptor[]
}

type OperatorActionType = string

type OperatorTargetType = string

export interface OperatorActionRequest {
  actor: string
  action_type: OperatorActionType
  target_type: OperatorTargetType
  target_id?: string
  payload: Record<string, unknown>
}

export type { OperatorActionResult } from '../api/schemas/operator-action'

export interface OperatorActionLogEntry {
  id: number
  at: string
  actor: string
  action_type: string
  target_label: string
  outcome: 'preview' | 'executed' | 'confirmed' | 'error'
  message: string
  tool_name?: string
}
