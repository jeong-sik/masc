import { isRecord, asString, asNumber, asBoolean, asStringArray } from '../components/common/normalize'
import type {
  CommandPlaneOrchestraEdge,
  CommandPlaneOrchestraFact,
  CommandPlaneOrchestraFocus,
  CommandPlaneOrchestraNode,
  CommandPlaneOrchestraResponse,
  CommandPlaneOrchestraSignal,
} from '../types'
import { normalizeSwarmStatus } from './swarm-lane'
import { normalizeSwarmProof } from './swarm-proof'

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
  const namespace = isRecord(root.namespace) ? root.namespace : (isRecord(root.room) ? root.room : {})
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    namespace: {
      namespace_id: asString(namespace.namespace_id) ?? asString(namespace.room_id),
      namespace: asString(namespace.namespace),
      project: asString(namespace.project),
      cluster: asString(namespace.cluster),
      paused: asBoolean(namespace.paused),
      pause_reason: asString(namespace.pause_reason) ?? null,
      agent_count: asNumber(namespace.agent_count),
      task_count: asNumber(namespace.task_count),
      message_count: asNumber(namespace.message_count),
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
