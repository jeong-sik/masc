import { Schema } from 'effect'

import { get } from './core'

const failure = Schema.Struct({
  status: Schema.Literal('unavailable'),
  detail: Schema.String,
})
const snapshot = Schema.Struct({
  revision: Schema.Int.pipe(Schema.greaterThan(0)),
  updated_at: Schema.Finite,
  facts: Schema.Array(
    Schema.Struct({ claim: Schema.String }),
  ),
})
const store = Schema.Union(
  Schema.Struct({ status: Schema.Literal('missing') }),
  failure,
  Schema.Struct({ status: Schema.Literal('available'), snapshot }),
)
const context = Schema.Struct({
  schema: Schema.Literal('workspace.memory.context.v1'),
  generated_at: Schema.Finite,
  source_validation: Schema.Literal('stored_bindings_not_revalidated'),
  consistency: Schema.Literal('individual_store_snapshots'),
  discovery: Schema.Union(
    Schema.Struct({ status: Schema.Literal('available') }),
    failure,
  ),
  keepers: Schema.Array(
    Schema.Struct({ keeper_id: Schema.String, ordinary: store, source_bound: store }),
  ),
})
export type WorkspaceMemoryContext = Schema.Schema.Type<typeof context>
export type WorkspaceMemoryStore = Schema.Schema.Type<typeof store>

export async function fetchWorkspaceMemoryContext(signal?: AbortSignal): Promise<WorkspaceMemoryContext> {
  const raw = await get<unknown>('/api/v1/dashboard/workspace-memory-context', { signal })
  // The panel renders the stored snapshot verbatim in a details block, which
  // includes fields beyond this contract (fact origins, change notes). The
  // legacy Valibot parser preserved them; keep decoding permissive the same
  // way instead of dropping data the UI still shows.
  return Schema.decodeUnknownPromise(context, { onExcessProperty: 'preserve' })(raw)
}
