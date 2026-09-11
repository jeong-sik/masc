import * as v from 'valibot'
import { get, post } from './core'

const text = v.pipe(v.string(), v.nonEmpty())
const count = v.pipe(v.number(), v.integer(), v.minValue(0))
const nullableText = v.nullable(text)
export const laneAddonRowSchema = v.object({
  id: text, lane_id: text, kind: v.picklist(['event', 'value', 'relation']),
  title: text, observed_at: v.pipe(v.number(), v.finite()), subject_id: text,
  clock: v.nullable(v.object({ domain: text, value: text })),
  actor: nullableText, fields: v.record(v.string(), v.unknown()),
  evidence: v.array(v.object({ uri: text, sha256: nullableText })),
  related_ids: v.array(text),
})
const coverageSchema = v.object({
  source_id: text, incarnation: text, cursor: nullableText,
  complete: v.boolean(), detail: nullableText,
})
const instanceSchema = v.object({
  instance_id: text, run_id: text, addon_id: text, title: text, revision: text,
  phase: v.object({
    kind: v.picklist(['attached', 'observing', 'failed', 'detaching', 'detached']),
    message: v.optional(v.string()),
  }),
  observation_seq: count, rows_count: count, error: v.optional(v.nullable(v.string())),
})
const snapshotSchema = v.object({
  instances: v.array(instanceSchema), rows: v.array(laneAddonRowSchema),
  coverage: v.array(coverageSchema),
})
const sliceSchema = v.object({
  rows: v.array(laneAddonRowSchema), coverage: v.array(coverageSchema), complete: v.boolean(),
})
export type LaneAddonRow = v.InferOutput<typeof laneAddonRowSchema>
export type LaneAddonSnapshot = v.InferOutput<typeof snapshotSchema>
export type LaneAddonSlice = v.InferOutput<typeof sliceSchema>
export type LaneAddonQuery = { run_id?: string; lane_id?: string; since?: number; until?: number }
export const parseLaneAddonSnapshot = (value: unknown) => v.parse(snapshotSchema, value)
export const parseLaneAddonSlice = (value: unknown) => v.parse(sliceSchema, value)

export async function fetchLaneAddons(signal?: AbortSignal): Promise<LaneAddonSnapshot> {
  return parseLaneAddonSnapshot(await get<unknown>('/api/v1/lane-addons', { signal }))
}
export async function fetchLaneAddonSlice(query: LaneAddonQuery, signal?: AbortSignal): Promise<LaneAddonSlice> {
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== '') params.set(key, String(value))
  }
  return parseLaneAddonSlice(await get<unknown>(`/api/v1/lane-addons/slice?${params}`, { signal }))
}
export function attachLaneAddon(manifest_path: string, run_id: string, binding: Record<string, unknown>) {
  return post<unknown>('/api/v1/lane-addons/attach', { manifest_path, run_id, binding })
}
export function observeLaneAddon(instance_id: string) {
  return post<unknown>('/api/v1/lane-addons/observe', { instance_id })
}
export function detachLaneAddon(instance_id: string) {
  return post<unknown>('/api/v1/lane-addons/detach', { instance_id })
}
export function preserveLaneAddonEvidence(instance_id: string, row_ids: string[], keeper_name?: string) {
  return post<unknown>('/api/v1/lane-addons/evidence', { instance_id, row_ids, ...(keeper_name ? { keeper_name } : {}) })
}
