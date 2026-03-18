import { isRecord, asString, asNumber, asBoolean } from '../components/common/normalize'
import type { CommandPlaneSwarmProof } from '../types'

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
