import * as v from 'valibot'
import { get } from './core'

const text = v.pipe(v.string(), v.minLength(1))
const sha = v.pipe(v.string(), v.regex(/^[a-f0-9]{64}$/))
const store = v.picklist(['ordinary', 'source_bound'])
const source = v.union([
  v.looseObject({ source_id: text, snapshot_id: text, keeper_id: text, store,
    revision: v.pipe(v.number(), v.integer(), v.minValue(1)), snapshot_sha256: sha,
    fact_index: v.pipe(v.number(), v.integer(), v.minValue(0)), fact: v.looseObject({ claim: text }) }),
  v.looseObject({ source_id: text, snapshot_id: text,
    evidence_path: v.pipe(v.array(v.union([text, v.pipe(v.number(), v.integer(), v.minValue(0))])), v.minLength(1)) }),
])
const snapshot = v.looseObject({ snapshot_id: text, keeper_id: text, store,
  snapshot_sha256: sha, metadata: v.record(v.string(), v.unknown()) })
const refs = v.pipe(v.array(text), v.minLength(1))
const envelope = v.object({
  status: v.literal('model_proposed'), context_sha256: sha,
  sources: v.array(source), snapshots: v.array(snapshot),
  gaps: v.array(v.object({ keeper_id: text, store, observation: v.variant('status', [
    v.object({ status: v.literal('missing') }),
    v.object({ status: v.literal('unavailable'), detail: v.string() }),
  ]) })),
  proposal: v.object({
    shared_claims: v.array(v.object({ claim: text, source_ids: refs })),
    conflicts: v.array(v.object({ description: text, source_ids: refs })),
    excluded: v.array(v.object({ source_id: text, reason: text })),
  }),
})
const response = v.object({
  semantic_verification: v.literal('not_performed'),
  proposals: v.array(v.object({ id: text, proposal: envelope, semantic_verification: v.literal('not_performed') })),
})
export type WorkspaceMemoryProposal = v.InferOutput<typeof envelope>
export type WorkspaceMemoryProposals = v.InferOutput<typeof response>

export async function fetchWorkspaceMemoryProposals(signal?: AbortSignal): Promise<WorkspaceMemoryProposals> {
  const parsed = v.parse(response, await get<unknown>('/api/v1/dashboard/workspace-memory-proposals', { signal }))
  if (new Set(parsed.proposals.map(row => row.id)).size !== parsed.proposals.length) throw new Error('Duplicate proposal identity')
  for (const { proposal: item } of parsed.proposals) {
    const snapshots = new Set(item.snapshots.map(row => row.snapshot_id))
    const sources = new Set(item.sources.map(row => row.source_id))
    if (snapshots.size !== item.snapshots.length || sources.size !== item.sources.length
      || item.sources.some(row => !snapshots.has(row.snapshot_id))) throw new Error('Invalid proposal source identity')
    const used = new Set([...item.proposal.shared_claims, ...item.proposal.conflicts].flatMap(row => row.source_ids))
    const excluded = item.proposal.excluded.map(row => row.source_id)
    const all = new Set([...used, ...excluded])
    if (excluded.length !== new Set(excluded).size || excluded.some(id => used.has(id))
      || all.size !== sources.size || [...all].some(id => !sources.has(id))) throw new Error('Invalid proposal source coverage')
  }
  return parsed
}
