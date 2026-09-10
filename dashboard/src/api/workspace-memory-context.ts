import * as v from 'valibot'
import { get } from './core'

const failure = v.object({ status: v.literal('unavailable'), detail: v.string() })
const snapshot = v.looseObject({
  revision: v.pipe(v.number(), v.integer(), v.minValue(1)),
  updated_at: v.pipe(v.number(), v.finite()),
  facts: v.array(v.looseObject({ claim: v.string() })),
})
const store = v.variant('status', [
  v.object({ status: v.literal('missing') }), failure,
  v.object({ status: v.literal('available'), snapshot }),
])
const context = v.object({
  schema: v.literal('workspace.memory.context.v1'),
  generated_at: v.pipe(v.number(), v.finite()),
  source_validation: v.literal('stored_bindings_not_revalidated'),
  consistency: v.literal('individual_store_snapshots'),
  discovery: v.variant('status', [v.object({ status: v.literal('available') }), failure]),
  keepers: v.array(v.object({ keeper_id: v.string(), ordinary: store, source_bound: store })),
})
export type WorkspaceMemoryContext = v.InferOutput<typeof context>
export type WorkspaceMemoryStore = v.InferOutput<typeof store>

export async function fetchWorkspaceMemoryContext(signal?: AbortSignal): Promise<WorkspaceMemoryContext> {
  return v.parse(context, await get<unknown>('/api/v1/dashboard/workspace-memory-context', { signal }))
}
