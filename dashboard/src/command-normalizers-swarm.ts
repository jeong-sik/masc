import { isRecord, asString, asNumber, asBoolean, asStringArray } from './components/common/normalize'
import type {
  ChainHistoryEventSummary,
  ChainRuntimeStatus,
  CommandPlaneChainConnection,
  CommandPlaneChainOverlay,
  CommandPlaneChainRun,
  CommandPlaneChainRunNode,
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
  CommandPlaneHelpConcept,
  CommandPlaneHelpDocLink,
  CommandPlaneHelpExample,
  CommandPlaneHelpPath,
  CommandPlaneHelpPitfall,
  CommandPlaneHelpResponse,
  CommandPlaneHelpStep,
  CommandPlaneHelpToolGroup,
  CommandPlaneOrchestraEdge,
  CommandPlaneOrchestraFact,
  CommandPlaneOrchestraFocus,
  CommandPlaneOrchestraNode,
  CommandPlaneOrchestraResponse,
  CommandPlaneOrchestraSignal,
  CommandPlaneSnapshot,
  CommandPlaneSummarySnapshot,
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmChecklistItem,
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmMessage,
  CommandPlaneSwarmProof,
  CommandPlaneSwarmProvider,
  CommandPlaneSwarmProviderSample,
  CommandPlaneSwarmResponse,
  CommandPlaneSwarmStatus,
  CommandPlaneSwarmTimelineEvent,
  CommandPlaneSwarmWorker,
  CommandPlaneTraceEvent,
} from './types'
import {
  normalizeTopology,
  normalizeOperations,
  normalizeDetachments,
  normalizeAlerts,
  normalizeDecisions,
  normalizeCapacity,
  normalizeTraces,
  normalizeOperationRecord,
  normalizeUnitRecord,
  normalizeDetachmentRecord,
  normalizeTrace,
} from './command-normalizers'

export function normalizeSwarmFlag(raw: unknown): CommandPlaneSwarmFlag | null {
  if (!isRecord(raw)) return null
  const code = asString(raw.code)
  const severity = asString(raw.severity)
  const summary = asString(raw.summary)
  if (!code || !severity || !summary) return null
  return { code, severity, summary }
}

export function normalizeSwarmLane(raw: unknown): CommandPlaneSwarmLane | null {
  if (!isRecord(raw)) return null
  const laneId = asString(raw.lane_id)
  const label = asString(raw.label)
  const kind = asString(raw.kind)
  const phase = asString(raw.phase)
  const motionState = asString(raw.motion_state)
  const sourceOfTruth = asString(raw.source_of_truth)
  const movementReason = asString(raw.movement_reason)
  const currentStep = asString(raw.current_step)
  if (!laneId || !label || !kind || !phase || !motionState || !sourceOfTruth || !movementReason || !currentStep) {
    return null
  }
  const counts = isRecord(raw.counts) ? raw.counts : {}
  return {
    lane_id: laneId,
    label,
    kind,
    present: asBoolean(raw.present) ?? false,
    phase,
    motion_state: motionState,
    source_of_truth: sourceOfTruth,
    last_movement_at: asString(raw.last_movement_at) ?? null,
    movement_reason: movementReason,
    current_step: currentStep,
    blockers: asStringArray(raw.blockers),
    counts: {
      operations: asNumber(counts.operations),
      detachments: asNumber(counts.detachments),
      workers: asNumber(counts.workers),
      approvals: asNumber(counts.approvals),
      alerts: asNumber(counts.alerts),
    },
    hard_flags: Array.isArray(raw.hard_flags)
      ? raw.hard_flags
          .map(normalizeSwarmFlag)
          .filter((item): item is CommandPlaneSwarmFlag => item !== null)
      : [],
  }
}

export function normalizeSwarmTimelineEvent(raw: unknown): CommandPlaneSwarmTimelineEvent | null {
  if (!isRecord(raw)) return null
  const eventId = asString(raw.event_id)
  const laneId = asString(raw.lane_id)
  const kind = asString(raw.kind)
  const timestamp = asString(raw.timestamp)
  const title = asString(raw.title)
  const detail = asString(raw.detail)
  const tone = asString(raw.tone)
  const source = asString(raw.source)
  if (!eventId || !laneId || !kind || !timestamp || !title || !detail || !tone || !source) return null
  return { event_id: eventId, lane_id: laneId, kind, timestamp, title, detail, tone, source }
}

export function normalizeSwarmGap(raw: unknown): CommandPlaneSwarmGap | null {
  if (!isRecord(raw)) return null
  const code = asString(raw.code)
  const severity = asString(raw.severity)
  const summary = asString(raw.summary)
  if (!code || !severity || !summary) return null
  return {
    code,
    severity,
    summary,
    why_it_matters: asString(raw.why_it_matters) ?? undefined,
    next_tool: asString(raw.next_tool) ?? undefined,
    next_step: asString(raw.next_step) ?? undefined,
    lane_ids: asStringArray(raw.lane_ids),
    count: asNumber(raw.count) ?? 0,
  }
}

export function normalizeSwarmStatus(raw: unknown): CommandPlaneSwarmStatus | undefined {
  if (!isRecord(raw)) return undefined
  const overview = isRecord(raw.overview) ? raw.overview : {}
  const gaps = isRecord(raw.gaps) ? raw.gaps : {}
  const narrative = isRecord(raw.narrative) ? raw.narrative : {}
  const recommendation = isRecord(raw.recommended_next_action) ? raw.recommended_next_action : undefined
  return {
    generated_at: asString(raw.generated_at),
    narrative: {
      state: asString(narrative.state) ?? undefined,
      started: asString(narrative.started) ?? undefined,
      active_work: asString(narrative.active_work) ?? undefined,
      completion: asString(narrative.completion) ?? undefined,
      lane_id: asString(narrative.lane_id) ?? null,
    },
    overview: {
      active_lanes: asNumber(overview.active_lanes),
      moving_lanes: asNumber(overview.moving_lanes),
      stalled_lanes: asNumber(overview.stalled_lanes),
      projected_lanes: asNumber(overview.projected_lanes),
      last_movement_at: asString(overview.last_movement_at) ?? null,
    },
    lanes: Array.isArray(raw.lanes)
      ? raw.lanes
          .map(normalizeSwarmLane)
          .filter((item): item is CommandPlaneSwarmLane => item !== null)
      : [],
    timeline: Array.isArray(raw.timeline)
      ? raw.timeline
          .map(normalizeSwarmTimelineEvent)
          .filter((item): item is CommandPlaneSwarmTimelineEvent => item !== null)
      : [],
    gaps: {
      count: asNumber(gaps.count),
      items: Array.isArray(gaps.items)
        ? gaps.items
            .map(normalizeSwarmGap)
            .filter((item): item is CommandPlaneSwarmGap => item !== null)
        : [],
    },
    recommended_next_action: recommendation
      ? {
          tool: asString(recommendation.tool) ?? 'masc_operator_snapshot',
          label: asString(recommendation.label) ?? 'Observe operator state',
          reason: asString(recommendation.reason) ?? '',
          lane_id: asString(recommendation.lane_id) ?? null,
        }
      : undefined,
  }
}

export function normalizeSwarmProof(raw: unknown): CommandPlaneSwarmProof | undefined {
  if (!isRecord(raw)) return undefined
  const workers = isRecord(raw.workers) ? raw.workers : {}
  const pass = asBoolean(raw.pass)
  return {
    status: asString(raw.status) ?? 'missing',
    source: asString(raw.source) ?? 'none',
    reason_code: asString(raw.reason_code) ?? null,
    status_summary: asString(raw.status_summary) ?? null,
    run_id: asString(raw.run_id) ?? null,
    captured_at: asString(raw.captured_at) ?? null,
    ...(pass !== undefined ? { pass } : {}),
    ...(asNumber(raw.peak_hot_slots) != null ? { peak_hot_slots: asNumber(raw.peak_hot_slots) } : {}),
    ...(asNumber(raw.ctx_per_slot) != null ? { ctx_per_slot: asNumber(raw.ctx_per_slot) } : {}),
    workers: {
      expected: asNumber(workers.expected),
      joined: asNumber(workers.joined),
      current_task_bound: asNumber(workers.current_task_bound),
      fresh_heartbeats: asNumber(workers.fresh_heartbeats),
      done: asNumber(workers.done),
      final: asNumber(workers.final),
    },
    expected_artifact_dir: asString(raw.expected_artifact_dir) ?? null,
    artifact_ref: asString(raw.artifact_ref) ?? null,
    missing_reason: asString(raw.missing_reason) ?? null,
  }
}

export function normalizeSnapshot(raw: unknown): CommandPlaneSnapshot {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    topology: normalizeTopology(root.topology),
    operations: normalizeOperations(root.operations),
    detachments: normalizeDetachments(root.detachments),
    alerts: normalizeAlerts(root.alerts),
    decisions: normalizeDecisions(root.decisions),
    capacity: normalizeCapacity(root.capacity),
    traces: normalizeTraces(root.traces),
    swarm_status: normalizeSwarmStatus(root.swarm_status),
  }
}

export function normalizeSummarySnapshot(raw: unknown): CommandPlaneSummarySnapshot {
  const root = isRecord(raw) ? raw : {}
  const topology = normalizeTopology(root.topology)
  const operations = normalizeOperations(root.operations)
  const detachments = normalizeDetachments(root.detachments)
  const alerts = normalizeAlerts(root.alerts)
  const decisions = normalizeDecisions(root.decisions)
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    topology: {
      version: topology.version,
      generated_at: topology.generated_at,
      source: topology.source,
      summary: topology.summary,
    },
    operations: {
      version: operations.version,
      generated_at: operations.generated_at,
      summary: operations.summary,
      microarch: operations.microarch,
    },
    detachments: {
      version: detachments.version,
      generated_at: detachments.generated_at,
      summary: detachments.summary,
    },
    alerts: {
      version: alerts.version,
      generated_at: alerts.generated_at,
      summary: alerts.summary,
    },
    decisions: {
      version: decisions.version,
      generated_at: decisions.generated_at,
      summary: decisions.summary,
    },
    swarm_status: normalizeSwarmStatus(root.swarm_status),
    swarm_proof: normalizeSwarmProof(root.swarm_proof),
  }
}

function normalizeChainRuntime(raw: unknown): ChainRuntimeStatus | null {
  if (!isRecord(raw)) return null
  return {
    chain_id: asString(raw.chain_id) ?? null,
    started_at: asNumber(raw.started_at) ?? null,
    progress: asNumber(raw.progress) ?? null,
    elapsed_sec: asNumber(raw.elapsed_sec) ?? null,
  }
}

function normalizeChainHistoryEvent(raw: unknown): ChainHistoryEventSummary | null {
  if (!isRecord(raw)) return null
  const event = asString(raw.event)
  if (!event) return null
  return {
    event,
    chain_id: asString(raw.chain_id) ?? null,
    timestamp: asString(raw.timestamp) ?? null,
    duration_ms: asNumber(raw.duration_ms) ?? null,
    message: asString(raw.message) ?? null,
    tokens: asNumber(raw.tokens) ?? null,
  }
}

export function normalizeChainRun(raw: unknown): CommandPlaneChainRun | null {
  if (!isRecord(raw)) return null
  const runId = asString(raw.run_id)
  const chainId = asString(raw.chain_id)
  if (!chainId) return null
  return {
    run_id: runId ?? null,
    chain_id: chainId,
    duration_ms: asNumber(raw.duration_ms),
    success: asBoolean(raw.success),
    mermaid: asString(raw.mermaid),
    nodes: Array.isArray(raw.nodes)
      ? raw.nodes
          .map(normalizeChainRunNode)
          .filter((item): item is CommandPlaneChainRunNode => item !== null)
      : [],
  }
}

function normalizeChainOverlay(raw: unknown): CommandPlaneChainOverlay | null {
  if (!isRecord(raw)) return null
  const operation = normalizeOperationRecord(raw.operation)
  if (!operation) return null
  return {
    operation,
    runtime: normalizeChainRuntime(raw.runtime),
    history: normalizeChainHistoryEvent(raw.history),
    mermaid: asString(raw.mermaid) ?? null,
    preview_run: normalizeChainRun(raw.preview_run),
  }
}

function normalizeChainConnection(raw: unknown): CommandPlaneChainConnection {
  const root = isRecord(raw) ? raw : {}
  return {
    status: asString(root.status) ?? 'disconnected',
    base_url: asString(root.base_url) ?? null,
    message: asString(root.message) ?? null,
  }
}

export function normalizeChainSummary(raw: unknown): CommandPlaneChainSummary {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    connection: normalizeChainConnection(root.connection),
    summary: summary
      ? {
          linked_operations: asNumber(summary.linked_operations),
          active_chains: asNumber(summary.active_chains),
          running_operations: asNumber(summary.running_operations),
          recent_failures: asNumber(summary.recent_failures),
          last_history_event_at: asString(summary.last_history_event_at) ?? null,
        }
      : undefined,
    operations: Array.isArray(root.operations)
      ? root.operations
          .map(normalizeChainOverlay)
          .filter((item): item is CommandPlaneChainOverlay => item !== null)
      : [],
    recent_history: Array.isArray(root.recent_history)
      ? root.recent_history
          .map(normalizeChainHistoryEvent)
          .filter((item): item is ChainHistoryEventSummary => item !== null)
      : [],
  }
}

function normalizeChainRunNode(raw: unknown): CommandPlaneChainRunNode | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  if (!id) return null
  return {
    id,
    type: asString(raw.type),
    status: asString(raw.status),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    error: asString(raw.error) ?? null,
  }
}

export function normalizeChainRunResponse(raw: unknown): CommandPlaneChainRunResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    run: normalizeChainRun(root.run),
  }
}

function normalizeHelpDoc(raw: unknown): CommandPlaneHelpDocLink | null {
  if (!isRecord(raw)) return null
  const title = asString(raw.title)
  const path = asString(raw.path)
  if (!title || !path) return null
  return { title, path }
}

function normalizeHelpConcept(raw: unknown): CommandPlaneHelpConcept | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  if (!id || !title || !summary) return null
  return { id, title, summary }
}

function normalizeHelpStep(raw: unknown): CommandPlaneHelpStep | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const tool = asString(raw.tool)
  const summary = asString(raw.summary)
  if (!id || !title || !tool || !summary) return null
  return {
    id,
    title,
    tool,
    summary,
    success_signals: asStringArray(raw.success_signals),
    pitfalls: asStringArray(raw.pitfalls),
  }
}

function normalizeHelpPath(raw: unknown): CommandPlaneHelpPath | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const whenToUse = asString(raw.when_to_use)
  if (!id || !title || !summary || !whenToUse) return null
  return {
    id,
    title,
    summary,
    when_to_use: whenToUse,
    steps: Array.isArray(raw.steps)
      ? raw.steps
          .map(normalizeHelpStep)
          .filter((item): item is CommandPlaneHelpStep => item !== null)
      : [],
  }
}

function normalizeHelpToolGroup(raw: unknown): CommandPlaneHelpToolGroup | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const description = asString(raw.description)
  if (!id || !title || !description) return null
  return {
    id,
    title,
    description,
    tools: asStringArray(raw.tools),
  }
}

function normalizeHelpPitfall(raw: unknown): CommandPlaneHelpPitfall | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const symptom = asString(raw.symptom)
  const why = asString(raw.why)
  const fixTool = asString(raw.fix_tool)
  const fixSummary = asString(raw.fix_summary)
  if (!id || !title || !symptom || !why || !fixTool || !fixSummary) return null
  return {
    id,
    title,
    symptom,
    why,
    fix_tool: fixTool,
    fix_summary: fixSummary,
  }
}

function normalizeHelpExample(raw: unknown): CommandPlaneHelpExample | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const pathId = asString(raw.path_id)
  const transport = asString(raw.transport)
  if (!id || !title || !pathId || !transport) return null
  return {
    id,
    title,
    path_id: pathId,
    transport,
    request: raw.request,
    response: raw.response,
    notes: asStringArray(raw.notes),
  }
}

export function normalizeHelp(raw: unknown): CommandPlaneHelpResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    docs: Array.isArray(root.docs)
      ? root.docs
          .map(normalizeHelpDoc)
          .filter((item): item is CommandPlaneHelpDocLink => item !== null)
      : [],
    concepts: Array.isArray(root.concepts)
      ? root.concepts
          .map(normalizeHelpConcept)
          .filter((item): item is CommandPlaneHelpConcept => item !== null)
      : [],
    golden_paths: Array.isArray(root.golden_paths)
      ? root.golden_paths
          .map(normalizeHelpPath)
          .filter((item): item is CommandPlaneHelpPath => item !== null)
      : [],
    tool_groups: Array.isArray(root.tool_groups)
      ? root.tool_groups
          .map(normalizeHelpToolGroup)
          .filter((item): item is CommandPlaneHelpToolGroup => item !== null)
      : [],
    pitfalls: Array.isArray(root.pitfalls)
      ? root.pitfalls
          .map(normalizeHelpPitfall)
          .filter((item): item is CommandPlaneHelpPitfall => item !== null)
      : [],
    examples: Array.isArray(root.examples)
      ? root.examples
          .map(normalizeHelpExample)
          .filter((item): item is CommandPlaneHelpExample => item !== null)
      : [],
  }
}

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

function normalizeSwarmWorker(raw: unknown): CommandPlaneSwarmWorker | null {
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

function normalizeOrchestraFact(raw: unknown): CommandPlaneOrchestraFact | null {
  if (!isRecord(raw)) return null
  const label = asString(raw.label)
  const value = asString(raw.value)
  if (!label || !value) return null
  return { label, value }
}

function normalizeOrchestraNode(raw: unknown): CommandPlaneOrchestraNode | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const kind = asString(raw.kind)
  const label = asString(raw.label)
  const tone = asString(raw.tone)
  const provenance = asString(raw.provenance)
  if (!id || !kind || !label || !tone || !provenance) return null
  return {
    id,
    kind,
    label,
    subtitle: asString(raw.subtitle) ?? null,
    status: asString(raw.status) ?? null,
    tone,
    pulse: asString(raw.pulse) ?? null,
    provenance,
    visual_class: asString(raw.visual_class) ?? undefined,
    glyph: asString(raw.glyph) ?? undefined,
    parent_id: asString(raw.parent_id) ?? null,
    lane_id: asString(raw.lane_id) ?? null,
    link_tab: asString(raw.link_tab) ?? null,
    link_surface: asString(raw.link_surface) ?? null,
    link_params: isRecord(raw.link_params)
      ? Object.fromEntries(
          Object.entries(raw.link_params)
            .map(([key, value]) => {
              const text = asString(value)
              return text ? [key, text] : null
            })
            .filter((entry): entry is [string, string] => entry !== null),
        )
      : {},
    facts: Array.isArray(raw.facts)
      ? raw.facts
          .map(normalizeOrchestraFact)
          .filter((item): item is CommandPlaneOrchestraFact => item !== null)
      : [],
  }
}

function normalizeOrchestraEdge(raw: unknown): CommandPlaneOrchestraEdge | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const source = asString(raw.source)
  const target = asString(raw.target)
  const kind = asString(raw.kind)
  const tone = asString(raw.tone)
  const provenance = asString(raw.provenance)
  if (!id || !source || !target || !kind || !tone || !provenance) return null
  return {
    id,
    source,
    target,
    kind,
    label: asString(raw.label) ?? null,
    tone,
    provenance,
    animated: asBoolean(raw.animated),
  }
}

function normalizeOrchestraSignal(raw: unknown): CommandPlaneOrchestraSignal | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const kind = asString(raw.kind)
  const label = asString(raw.label)
  const tone = asString(raw.tone)
  const provenance = asString(raw.provenance)
  if (!id || !kind || !label || !tone || !provenance) return null
  return {
    id,
    kind,
    label,
    detail: asString(raw.detail) ?? null,
    tone,
    provenance,
    source_id: asString(raw.source_id) ?? null,
    target_id: asString(raw.target_id) ?? null,
    suggested_surface: asString(raw.suggested_surface) ?? null,
    suggested_params: isRecord(raw.suggested_params)
      ? Object.fromEntries(
          Object.entries(raw.suggested_params)
            .map(([key, value]) => {
              const text = asString(value)
              return text ? [key, text] : null
            })
            .filter((entry): entry is [string, string] => entry !== null),
        )
      : {},
  }
}

function normalizeOrchestraFocus(raw: unknown): CommandPlaneOrchestraFocus | null {
  if (!isRecord(raw)) return null
  const targetKind = asString(raw.target_kind)
  const targetId = asString(raw.target_id)
  const label = asString(raw.label)
  const reason = asString(raw.reason)
  if (!targetKind || !targetId || !label || !reason) return null
  return {
    target_kind: targetKind,
    target_id: targetId,
    label,
    reason,
    suggested_surface: asString(raw.suggested_surface) ?? null,
    suggested_params: isRecord(raw.suggested_params)
      ? Object.fromEntries(
          Object.entries(raw.suggested_params)
            .map(([key, value]) => {
              const text = asString(value)
              return text ? [key, text] : null
            })
            .filter((entry): entry is [string, string] => entry !== null),
        )
      : {},
  }
}

export function normalizeOrchestra(raw: unknown): CommandPlaneOrchestraResponse {
  const root = isRecord(raw) ? raw : {}
  const room = isRecord(root.room) ? root.room : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    room: {
      room_id: asString(room.room_id),
      project: asString(room.project),
      cluster: asString(room.cluster),
      paused: asBoolean(room.paused),
      pause_reason: asString(room.pause_reason) ?? null,
      agent_count: asNumber(room.agent_count),
      task_count: asNumber(room.task_count),
      message_count: asNumber(room.message_count),
    },
    summary: summary
      ? {
          session_count: asNumber(summary.session_count),
          operation_count: asNumber(summary.operation_count),
          detachment_count: asNumber(summary.detachment_count),
          lane_count: asNumber(summary.lane_count),
          worker_count: asNumber(summary.worker_count),
          keeper_count: asNumber(summary.keeper_count),
          signal_count: asNumber(summary.signal_count),
          alert_count: asNumber(summary.alert_count),
        }
      : undefined,
    nodes: Array.isArray(root.nodes)
      ? root.nodes
          .map(normalizeOrchestraNode)
          .filter((item): item is CommandPlaneOrchestraNode => item !== null)
      : [],
    edges: Array.isArray(root.edges)
      ? root.edges
          .map(normalizeOrchestraEdge)
          .filter((item): item is CommandPlaneOrchestraEdge => item !== null)
      : [],
    signals: Array.isArray(root.signals)
      ? root.signals
          .map(normalizeOrchestraSignal)
          .filter((item): item is CommandPlaneOrchestraSignal => item !== null)
      : [],
    focus: normalizeOrchestraFocus(root.focus),
    swarm_status: normalizeSwarmStatus(root.swarm_status),
    swarm_proof: normalizeSwarmProof(root.swarm_proof),
    truth_notes: asStringArray(root.truth_notes),
  }
}
