import { Schema } from 'effect'
import { get } from './core'

const text = Schema.NonEmptyString
const sha = Schema.String
const fact = Schema.Struct({
  keeper_id: text,
  store: Schema.Literal('ordinary', 'source_bound'),
  path: Schema.optional(text),
  claim_sha256: sha,
  disposition: Schema.Union(
    Schema.Struct({ kind: Schema.Literal('claim'), claim_id: text }),
    Schema.Struct({ kind: Schema.Literal('conflict'), conflict_id: text }),
    Schema.Struct({ kind: Schema.Literal('excluded'), reason: text }),
  ),
  current_claim: Schema.NullOr(text),
  source_state: Schema.Literal('present', 'absent', 'unavailable'),
})
const ledger = Schema.Struct({
  schema: Schema.Literal('workspace.memory.ledger.v1'),
  claims: Schema.Array(Schema.Struct({ claim_id: text, claim: text })),
  conflicts: Schema.Array(Schema.Struct({ conflict_id: text, description: text })),
  facts: Schema.Array(fact),
})
const response = Schema.Union(
  Schema.Struct({ status: Schema.Literal('missing') }),
  Schema.Struct({ status: Schema.Literal('available'), semantic_verification: Schema.Literal('not_performed'),
    ledger_sha256: sha, source_resolution: Schema.Union(
      Schema.Struct({ status: Schema.Literal('available') }),
      Schema.Struct({ status: Schema.Literal('unavailable'), detail: Schema.String }),
    ), ledger }),
)

export type WorkspaceMemoryLedger = Schema.Schema.Type<typeof response>

export async function fetchWorkspaceMemoryLedger(signal?: AbortSignal): Promise<WorkspaceMemoryLedger> {
  const parsed = Schema.decodeUnknownSync(response)(await get<unknown>('/api/v1/dashboard/workspace-memory-ledger', { signal }))
  if (parsed.status === 'missing') return parsed
  const isSha = (value: string) => /^[a-f0-9]{64}$/.test(value)
  if (!isSha(parsed.ledger_sha256) || parsed.ledger.facts.some(row => !isSha(row.claim_sha256))) {
    throw new Error('Invalid workspace ledger digest')
  }
  const claims = new Set(parsed.ledger.claims.map(row => row.claim_id))
  const conflicts = new Set(parsed.ledger.conflicts.map(row => row.conflict_id))
  if (claims.size !== parsed.ledger.claims.length || conflicts.size !== parsed.ledger.conflicts.length
    || parsed.ledger.facts.some(row => row.disposition.kind === 'claim' && !claims.has(row.disposition.claim_id)
      || row.disposition.kind === 'conflict' && !conflicts.has(row.disposition.conflict_id))) {
    throw new Error('Invalid workspace ledger references')
  }
  return parsed
}
