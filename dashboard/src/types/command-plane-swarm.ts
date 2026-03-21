import type {
  CommandPlaneOperationRecord,
  CommandPlaneTraceEvent,
  CommandPlaneUnitRecord,
  CommandPlaneDetachmentRecord,
} from './command-plane-core'

export interface CommandPlaneSwarmFlag {
  code: string
  severity: string
  summary: string
}

export interface CommandPlaneSwarmLane {
  lane_id: string
  label: string
  kind: 'managed' | 'projected' | 'supervised' | string
  present: boolean
  phase: string
  motion_state: 'moving' | 'waiting' | 'stalled' | 'terminal' | string
  source_of_truth: string
  last_movement_at?: string | null
  movement_reason: string
  current_step: string
  blockers: string[]
  counts: {
    operations?: number
    detachments?: number
    workers?: number
    approvals?: number
    alerts?: number
  }
  hard_flags: CommandPlaneSwarmFlag[]
}

export interface CommandPlaneSwarmTimelineEvent {
  event_id: string
  lane_id: string
  kind: string
  timestamp: string
  title: string
  detail: string
  tone: string
  source: string
}

export interface CommandPlaneSwarmGap {
  code: string
  severity: string
  summary: string
  why_it_matters?: string
  next_tool?: string
  next_step?: string
  lane_ids: string[]
  count: number
}

export interface CommandPlaneSwarmRecommendation {
  tool: string
  label: string
  reason: string
  lane_id?: string | null
}

export interface CommandPlaneSwarmStatus {
  generated_at?: string
  narrative?: {
    state?: string
    started?: string
    active_work?: string
    completion?: string
    lane_id?: string | null
  }
  overview: {
    active_lanes?: number
    moving_lanes?: number
    stalled_lanes?: number
    projected_lanes?: number
    last_movement_at?: string | null
  }
  lanes: CommandPlaneSwarmLane[]
  timeline: CommandPlaneSwarmTimelineEvent[]
  gaps: {
    count?: number
    items: CommandPlaneSwarmGap[]
  }
  recommended_next_action?: CommandPlaneSwarmRecommendation
}

export interface CommandPlaneSwarmProof {
  status: 'present' | 'fallback' | 'missing' | string
  source: 'artifact' | 'slot_samples' | 'none' | string
  reason_code?: string | null
  status_summary?: string | null
  run_id?: string | null
  captured_at?: string | null
  pass?: boolean
  peak_hot_slots?: number
  ctx_per_slot?: number
  workers: {
    expected?: number
    joined?: number
    current_task_bound?: number
    fresh_heartbeats?: number
    done?: number
    final?: number
  }
  expected_artifact_dir?: string | null
  artifact_ref?: string | null
  missing_reason?: string | null
}

export interface CommandPlaneSwarmChecklistItem {
  id: string
  title: string
  status: 'pass' | 'fail' | 'warn'
  detail: string
  next_tool: string
}

export interface CommandPlaneSwarmBlocker {
  code: string
  severity: 'bad' | 'warn' | 'ok'
  title: string
  detail: string
  next_tool: string
}

export interface CommandPlaneSwarmMessage {
  seq: number
  from: string
  content: string
  timestamp: string
}

export interface CommandPlaneSwarmWorker {
  name: string
  role: string
  lane: string
  joined: boolean
  live_presence: boolean
  completed: boolean
  status: string
  current_task: string | null
  bound_task_id: string | null
  bound_task_title: string | null
  bound_task_status: string | null
  current_task_matches_run: boolean
  squad_member: boolean
  detachment_member: boolean
  last_seen: string | null
  heartbeat_age_sec: number | null
  heartbeat_fresh: boolean
  claim_marker_seen: boolean
  done_marker_seen: boolean
  final_marker_seen: boolean
  claim_marker: string
  done_marker: string
  final_marker: string
  last_message: {
    seq: number
    content: string
    timestamp: string
  } | null
}

export interface CommandPlaneSwarmProviderSample {
  timestamp: string
  active_slots: number
  active_slot_ids: number[]
}

export interface CommandPlaneSwarmProvider {
  slot_url?: string | null
  provider_base_url?: string | null
  provider_reachable?: boolean | null
  provider_status_code?: number | null
  provider_model_id?: string | null
  actual_model_id?: string | null
  expected_slots?: number
  actual_slots?: number
  expected_ctx?: number
  actual_ctx?: number
  configured_capacity?: number
  slot_reachable?: boolean | null
  slot_status_code?: number | null
  runtime_blocker?: string | null
  detail?: string | null
  checked_at?: string | null
  total_slots?: number
  ctx_per_slot?: number
  active_slots_now?: number
  peak_active_slots?: number
  sample_count?: number
  last_sample_at?: string | null
  timeline: CommandPlaneSwarmProviderSample[]
}

export interface CommandPlaneRunResolutionHistoryEntry {
  status: 'continued' | 'rerun' | 'abandoned'
  decided_by: string
  decided_at: string
  reason: string
  operation_id?: string | null
  detachment_id?: string | null
  note?: string | null
}

export interface CommandPlaneRunResolutionState {
  run_id: string
  status: 'continued' | 'rerun' | 'abandoned'
  decided_by: string
  decided_at: string
  reason: string
  operation_id?: string | null
  detachment_id?: string | null
  note?: string | null
  history: CommandPlaneRunResolutionHistoryEntry[]
}

export interface CommandPlaneRunResolutionRecommendation {
  run_id: string
  recommended_kind: 'continue' | 'rerun' | 'abandon'
  continue_available: boolean
  rerun_available: boolean
  abandon_available: boolean
  reason: string
  evidence?: {
    operation_id?: string | null
    detachment_id?: string | null
    joined_workers?: number
    current_task_bound?: number
    fresh_heartbeats?: number
    trace_events?: number
    message_events?: number
    runtime_blocker?: string | null
  }
  provenance?: string
  decision_engine?: string
  authoritative?: boolean
}

export interface CommandPlaneSwarmResponse {
  version?: string
  generated_at?: string
  run_id?: string
  room_id?: string
  operation_id?: string | null
  run_resolution?: CommandPlaneRunResolutionState | null
  resolution_recommendation?: CommandPlaneRunResolutionRecommendation | null
  recommended_next_tool?: string
  summary?: {
    expected_workers?: number
    joined_workers?: number
    live_workers?: number
    squad_roster_size?: number
    detachment_roster_size?: number
    current_task_bound?: number
    fresh_heartbeats?: number
    claim_markers_seen?: number
    done_markers_seen?: number
    final_markers_seen?: number
    completed_workers?: number
    peak_hot_slots?: number
    hot_window_ok?: boolean
    pass_hot_concurrency?: boolean
    pass_end_to_end?: boolean
    pending_decisions?: number
    pass?: boolean
  }
  provider?: CommandPlaneSwarmProvider
  operation?: CommandPlaneOperationRecord | null
  squad?: CommandPlaneUnitRecord | null
  detachment?: CommandPlaneDetachmentRecord | null
  workers: CommandPlaneSwarmWorker[]
  checklist: CommandPlaneSwarmChecklistItem[]
  blockers: CommandPlaneSwarmBlocker[]
  recent_messages: CommandPlaneSwarmMessage[]
  recent_trace_events: CommandPlaneTraceEvent[]
  truth_notes: string[]
}
