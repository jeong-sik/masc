import { Schema } from 'effect'
import { get, post } from './core'

const text = Schema.NonEmptyString
const count = Schema.Int.pipe(Schema.nonNegative())
const nullableText = Schema.NullOr(text)
const jsonObject = Schema.Record({ key: Schema.String, value: Schema.Unknown })
export const laneAddonRowSchema = Schema.Struct({
  id: text, lane_id: text, kind: Schema.Literal('event', 'value', 'relation'),
  title: text, observed_at: Schema.Number.pipe(Schema.finite()), subject_id: text,
  clock: Schema.NullOr(Schema.Struct({ domain: text, value: text })),
  actor: nullableText, fields: Schema.Record({ key: Schema.String, value: Schema.Unknown }),
  evidence: Schema.Array(Schema.Struct({ uri: text, sha256: nullableText })),
  related_ids: Schema.Array(text),
})
const coverageSchema = Schema.Struct({
  source_id: text, incarnation: text, cursor: nullableText,
  complete: Schema.Boolean, detail: nullableText,
})
const instanceConfigurationSchema = Schema.Struct({
  id: text, source_path: text, revision: text,
})
const configurationSchema = Schema.Struct({
  directory: text, complete: Schema.Boolean,
  issues: Schema.Array(Schema.Struct({ source_path: text, id: nullableText, message: text })),
  declarations: Schema.Array(Schema.Struct({
    id: text, source_path: text, desired_revision: text,
    applied_revision: nullableText, instance_id: nullableText,
  })),
})
const outputSelectionSchema = Schema.Union(
  Schema.Struct({ lanes: Schema.NonEmptyArray(text), all_lanes: Schema.optional(Schema.Never) }),
  Schema.Struct({ all_lanes: Schema.Literal(true), lanes: Schema.optional(Schema.Never) }),
)
const instanceSchema = Schema.Struct({
  instance_id: text, run_id: text, addon_id: text, title: text, revision: text,
  incarnation: text, action_schema: Schema.NullOr(jsonObject),
  package: Schema.Struct({ outputs: Schema.Record({ key: text, value: outputSelectionSchema }) }),
  configuration: Schema.NullOr(instanceConfigurationSchema),
  phase: Schema.Struct({
    kind: Schema.Literal('attached', 'observing', 'failed', 'detaching', 'detached'),
    message: Schema.optional(Schema.String),
  }),
  observation_seq: count, rows_count: count, error: Schema.optional(Schema.NullOr(Schema.String)),
})
const snapshotSchema = Schema.Struct({
  configuration: Schema.NullOr(configurationSchema),
  instances: Schema.Array(instanceSchema), rows: Schema.Array(laneAddonRowSchema),
  coverage: Schema.Array(coverageSchema),
})
const sliceSchema = Schema.Struct({
  rows: Schema.Array(laneAddonRowSchema), coverage: Schema.Array(coverageSchema), complete: Schema.Boolean,
})
const actionReceiptSchema = Schema.Struct({
  instance_id: text, incarnation: text, request_id: text, requester: text,
  executor: nullableText, input_sha256: text, action: jsonObject,
  state: Schema.Literal('queued', 'running', 'confirmed', 'failed_before_effect', 'outcome_unknown'),
  result: Schema.NullOr(jsonObject), detail: Schema.NullOr(Schema.String),
})
export type LaneAddonRow = Schema.Schema.Type<typeof laneAddonRowSchema>
export type LaneAddonInstance = Schema.Schema.Type<typeof instanceSchema>
export type LaneAddonSnapshot = Schema.Schema.Type<typeof snapshotSchema>
export type LaneAddonSlice = Schema.Schema.Type<typeof sliceSchema>
export type LaneAddonActionReceipt = Schema.Schema.Type<typeof actionReceiptSchema>
export type LaneAddonActionRequest = {
  instance_id: string; expected_incarnation: string; request_id: string; action: Record<string, unknown>
}
export type LaneAddonQuery = { run_id?: string; lane_id?: string; since?: number; until?: number }
export const parseLaneAddonSnapshot = Schema.decodeUnknownSync(snapshotSchema)
export const parseLaneAddonSlice = Schema.decodeUnknownSync(sliceSchema)
export const parseLaneAddonActionReceipt = Schema.decodeUnknownSync(actionReceiptSchema)

function matchingActionReceipt(value: unknown, request: LaneAddonActionRequest): LaneAddonActionReceipt {
  const receipt = parseLaneAddonActionReceipt(value)
  if (receipt.instance_id !== request.instance_id || receipt.incarnation !== request.expected_incarnation
    || receipt.request_id !== request.request_id) {
    throw new Error('Action receipt does not match the requested instance, incarnation, and request ID.')
  }
  return receipt
}

export async function requestLaneAddonAction(request: LaneAddonActionRequest): Promise<LaneAddonActionReceipt> {
  return matchingActionReceipt(await post<unknown>('/api/v1/lane-addons/actions', request), request)
}

export async function fetchLaneAddonAction(request: LaneAddonActionRequest, signal?: AbortSignal): Promise<LaneAddonActionReceipt> {
  const params = new URLSearchParams({ instance_id: request.instance_id, request_id: request.request_id })
  return matchingActionReceipt(await get<unknown>(`/api/v1/lane-addons/actions?${params}`, { signal }), request)
}

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
