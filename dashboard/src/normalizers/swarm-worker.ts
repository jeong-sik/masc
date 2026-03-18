import { isRecord, asString, asNumber, asBoolean, asStringArray } from '../components/common/normalize'
import type {
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmChecklistItem,
  CommandPlaneSwarmMessage,
  CommandPlaneSwarmProvider,
  CommandPlaneSwarmProviderSample,
  CommandPlaneSwarmResponse,
  CommandPlaneSwarmWorker,
  CommandPlaneTraceEvent,
} from '../types'
import {
  normalizeOperationRecord,
  normalizeUnitRecord,
  normalizeDetachmentRecord,
  normalizeTrace,
} from '../command-normalizers'

function normalizeSwarmChecklistItem(raw: unknown): CommandPlaneSwarmChecklistItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const status = asString(raw.status) as CommandPlaneSwarmChecklistItem['status'] | undefined
  const detail = asString(raw.detail)
  const nextTool = asString(raw.next_tool)
  if (!id || !title || !status || !detail || !nextTool) return null
  return { id, title, status, detail, next_tool: nextTool }
}

function normalizeSwarmBlocker(raw: unknown): CommandPlaneSwarmBlocker | null {
  if (!isRecord(raw)) return null
  const code = asString(raw.code)
  const severity = asString(raw.severity) as CommandPlaneSwarmBlocker['severity'] | undefined
  const title = asString(raw.title)
  const detail = asString(raw.detail)
  const nextTool = asString(raw.next_tool)
  if (!code || !severity || !title || !detail || !nextTool) return null
  return { code, severity, title, detail, next_tool: nextTool }
}

function normalizeSwarmMessage(raw: unknown): CommandPlaneSwarmMessage | null {
  if (!isRecord(raw)) return null
  const from = asString(raw.from)
  const content = asString(raw.content)
  const timestamp = asString(raw.timestamp)
  const seq = asNumber(raw.seq)
  if (!from || !content || !timestamp || seq == null) return null
  return { seq, from, content, timestamp }
}

export function normalizeSwarmWorker(raw: unknown): CommandPlaneSwarmWorker | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  const role = asString(raw.role)
  const lane = asString(raw.lane)
  const status = asString(raw.status)
  const claimMarker = asString(raw.claim_marker)
  const doneMarker = asString(raw.done_marker)
  const finalMarker = asString(raw.final_marker)
  if (!name || !role || !lane || !status || !claimMarker || !doneMarker || !finalMarker) return null
  const lastMessage = (() => {
    if (!isRecord(raw.last_message)) return null
    const seq = asNumber(raw.last_message.seq)
    const content = asString(raw.last_message.content)
    const timestamp = asString(raw.last_message.timestamp)
    if (seq == null || !content || !timestamp) return null
    return { seq, content, timestamp }
  })()
  return {
    name,
    role,
    lane,
    joined: asBoolean(raw.joined) ?? false,
    live_presence: asBoolean(raw.live_presence) ?? false,
    completed: asBoolean(raw.completed) ?? false,
    status,
    current_task: asString(raw.current_task) ?? null,
    bound_task_id: asString(raw.bound_task_id) ?? null,
    bound_task_title: asString(raw.bound_task_title) ?? null,
    bound_task_status: asString(raw.bound_task_status) ?? null,
    current_task_matches_run: asBoolean(raw.current_task_matches_run) ?? false,
    squad_member: asBoolean(raw.squad_member) ?? false,
    detachment_member: asBoolean(raw.detachment_member) ?? false,
    last_seen: asString(raw.last_seen) ?? null,
    heartbeat_age_sec: asNumber(raw.heartbeat_age_sec) ?? null,
    heartbeat_fresh: asBoolean(raw.heartbeat_fresh) ?? false,
    claim_marker_seen: asBoolean(raw.claim_marker_seen) ?? false,
    done_marker_seen: asBoolean(raw.done_marker_seen) ?? false,
    final_marker_seen: asBoolean(raw.final_marker_seen) ?? false,
    claim_marker: claimMarker,
    done_marker: doneMarker,
    final_marker: finalMarker,
    last_message: lastMessage,
  }
}

function normalizeSwarmProvider(raw: unknown): CommandPlaneSwarmProvider | undefined {
  if (!isRecord(raw)) return undefined
  const timeline = Array.isArray(raw.timeline)
    ? raw.timeline
        .map(sample => {
          if (!isRecord(sample)) return null
          const timestamp = asString(sample.timestamp)
          const activeSlots = asNumber(sample.active_slots)
          if (!timestamp || activeSlots == null) return null
          const activeSlotIds = Array.isArray(sample.active_slot_ids)
            ? sample.active_slot_ids
                .map(value => (typeof value === 'number' && Number.isFinite(value) ? value : null))
                .filter((value): value is number => value != null)
            : []
          return { timestamp, active_slots: activeSlots, active_slot_ids: activeSlotIds }
        })
        .filter((sample): sample is CommandPlaneSwarmProviderSample => sample !== null)
    : []
  return {
    slot_url: asString(raw.slot_url) ?? null,
    provider_base_url: asString(raw.provider_base_url) ?? null,
    provider_reachable: asBoolean(raw.provider_reachable) ?? null,
    provider_status_code: asNumber(raw.provider_status_code) ?? null,
    provider_model_id: asString(raw.provider_model_id) ?? null,
    actual_model_id: asString(raw.actual_model_id) ?? null,
    expected_slots: asNumber(raw.expected_slots),
    actual_slots: asNumber(raw.actual_slots),
    expected_ctx: asNumber(raw.expected_ctx),
    actual_ctx: asNumber(raw.actual_ctx),
    configured_capacity: asNumber(raw.configured_capacity),
    slot_reachable: asBoolean(raw.slot_reachable) ?? null,
    slot_status_code: asNumber(raw.slot_status_code) ?? null,
    runtime_blocker: asString(raw.runtime_blocker) ?? null,
    detail: asString(raw.detail) ?? null,
    checked_at: asString(raw.checked_at) ?? null,
    total_slots: asNumber(raw.total_slots),
    ctx_per_slot: asNumber(raw.ctx_per_slot),
    active_slots_now: asNumber(raw.active_slots_now),
    peak_active_slots: asNumber(raw.peak_active_slots),
    sample_count: asNumber(raw.sample_count),
    last_sample_at: asString(raw.last_sample_at) ?? null,
    timeline,
  }
}

function normalizeRunResolution(raw: unknown): CommandPlaneSwarmResponse['run_resolution'] {
  if (!isRecord(raw)) return null
  const runId = asString(raw.run_id)
  const status = asString(raw.status) as 'continued' | 'rerun' | 'abandoned' | null
  const decidedBy = asString(raw.decided_by)
  const decidedAt = asString(raw.decided_at)
  const reason = asString(raw.reason)
  if (!runId || !status || !decidedBy || !decidedAt || !reason) return null
  const history: NonNullable<CommandPlaneSwarmResponse['run_resolution']>['history'] = []
  if (Array.isArray(raw.history)) {
    raw.history.forEach(entry => {
      if (!isRecord(entry)) return
      const itemStatus = asString(entry.status) as 'continued' | 'rerun' | 'abandoned' | null
      const itemActor = asString(entry.decided_by)
      const itemAt = asString(entry.decided_at)
      const itemReason = asString(entry.reason)
      if (!itemStatus || !itemActor || !itemAt || !itemReason) return
      history.push({
        status: itemStatus,
        decided_by: itemActor,
        decided_at: itemAt,
        reason: itemReason,
        operation_id: asString(entry.operation_id) ?? null,
        detachment_id: asString(entry.detachment_id) ?? null,
        note: asString(entry.note) ?? null,
      })
    })
  }
  return {
    run_id: runId,
    status,
    decided_by: decidedBy,
    decided_at: decidedAt,
    reason,
    operation_id: asString(raw.operation_id) ?? null,
    detachment_id: asString(raw.detachment_id) ?? null,
    note: asString(raw.note) ?? null,
    history,
  }
}

function normalizeRunResolutionRecommendation(
  raw: unknown,
): CommandPlaneSwarmResponse['resolution_recommendation'] {
  if (!isRecord(raw)) return null
  const runId = asString(raw.run_id)
  const recommendedKind = asString(raw.recommended_kind) as 'continue' | 'rerun' | 'abandon' | null
  const reason = asString(raw.reason)
  if (!runId || !recommendedKind || !reason) return null
  return {
    run_id: runId,
    recommended_kind: recommendedKind,
    continue_available: asBoolean(raw.continue_available) ?? false,
    rerun_available: asBoolean(raw.rerun_available) ?? false,
    abandon_available: asBoolean(raw.abandon_available) ?? false,
    reason,
    evidence: isRecord(raw.evidence)
      ? {
          operation_id: asString(raw.evidence.operation_id) ?? null,
          detachment_id: asString(raw.evidence.detachment_id) ?? null,
          joined_workers: asNumber(raw.evidence.joined_workers),
          current_task_bound: asNumber(raw.evidence.current_task_bound),
          fresh_heartbeats: asNumber(raw.evidence.fresh_heartbeats),
          trace_events: asNumber(raw.evidence.trace_events),
          message_events: asNumber(raw.evidence.message_events),
          runtime_blocker: asString(raw.evidence.runtime_blocker) ?? null,
        }
      : undefined,
    provenance: asString(raw.provenance),
    decision_engine: asString(raw.decision_engine),
    authoritative: asBoolean(raw.authoritative),
  }
}

export function normalizeSwarm(raw: unknown): CommandPlaneSwarmResponse {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    run_id: asString(root.run_id),
    room_id: asString(root.room_id),
    operation_id: asString(root.operation_id) ?? null,
    run_resolution: normalizeRunResolution(root.run_resolution),
    resolution_recommendation: normalizeRunResolutionRecommendation(root.resolution_recommendation),
    recommended_next_tool: asString(root.recommended_next_tool),
    summary: summary
      ? {
          expected_workers: asNumber(summary.expected_workers),
          joined_workers: asNumber(summary.joined_workers),
          live_workers: asNumber(summary.live_workers),
          squad_roster_size: asNumber(summary.squad_roster_size),
          detachment_roster_size: asNumber(summary.detachment_roster_size),
          current_task_bound: asNumber(summary.current_task_bound),
          fresh_heartbeats: asNumber(summary.fresh_heartbeats),
          claim_markers_seen: asNumber(summary.claim_markers_seen),
          done_markers_seen: asNumber(summary.done_markers_seen),
          final_markers_seen: asNumber(summary.final_markers_seen),
          completed_workers: asNumber(summary.completed_workers),
          peak_hot_slots: asNumber(summary.peak_hot_slots),
          hot_window_ok: asBoolean(summary.hot_window_ok),
          pass_hot_concurrency: asBoolean(summary.pass_hot_concurrency),
          pass_end_to_end: asBoolean(summary.pass_end_to_end),
          pending_decisions: asNumber(summary.pending_decisions),
          pass: asBoolean(summary.pass),
        }
      : undefined,
    provider: normalizeSwarmProvider(root.provider),
    operation: normalizeOperationRecord(root.operation),
    squad: normalizeUnitRecord(root.squad),
    detachment: normalizeDetachmentRecord(root.detachment),
    workers: Array.isArray(root.workers)
      ? root.workers
          .map(normalizeSwarmWorker)
          .filter((item): item is CommandPlaneSwarmWorker => item !== null)
      : [],
    checklist: Array.isArray(root.checklist)
      ? root.checklist
          .map(normalizeSwarmChecklistItem)
          .filter((item): item is CommandPlaneSwarmChecklistItem => item !== null)
      : [],
    blockers: Array.isArray(root.blockers)
      ? root.blockers
          .map(normalizeSwarmBlocker)
          .filter((item): item is CommandPlaneSwarmBlocker => item !== null)
      : [],
    recent_messages: Array.isArray(root.recent_messages)
      ? root.recent_messages
          .map(normalizeSwarmMessage)
          .filter((item): item is CommandPlaneSwarmMessage => item !== null)
      : [],
    recent_trace_events: Array.isArray(root.recent_trace_events)
      ? root.recent_trace_events
          .map(normalizeTrace)
          .filter((item): item is CommandPlaneTraceEvent => item !== null)
      : [],
    truth_notes: asStringArray(root.truth_notes),
  }
}
