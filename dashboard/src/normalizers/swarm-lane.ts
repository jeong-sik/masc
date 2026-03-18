import { isRecord, asString, asNumber, asBoolean, asStringArray } from '../components/common/normalize'
import type {
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmStatus,
  CommandPlaneSwarmTimelineEvent,
} from '../types'

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
