import { isRecord } from './lib/type-guards'
import { isObserverInstance } from './lib/observer-protocol'

export interface OperatorDigestQuery {
  readonly actor: string
  readonly targetId: string | null
  readonly includeWorkers: boolean | null
}

export function operatorDigestQuery(raw: unknown): OperatorDigestQuery | null {
  if (!isRecord(raw) || !isRecord(raw.query)) return null
  const query = raw.query
  if (query.effective_target_type !== 'workspace'
    || (query.actor !== null && typeof query.actor !== 'string')
    || (query.target_id !== null && typeof query.target_id !== 'string')
    || (query.include_workers !== null && typeof query.include_workers !== 'boolean')) return null
  return { actor: query.actor ?? 'dashboard', targetId: query.target_id, includeWorkers: query.include_workers }
}

export function sameOperatorDigestQuery(left: OperatorDigestQuery, right: OperatorDigestQuery): boolean {
  return left.actor === right.actor && left.targetId === right.targetId && left.includeWorkers === right.includeWorkers
}

export interface OperatorDigestPublication {
  readonly instance: string
  readonly generation: number
  readonly sequence: number
  readonly state: 'initializing' | 'ready' | 'error'
  readonly query: OperatorDigestQuery
}

export function operatorDigestPublication(raw: unknown): OperatorDigestPublication | null {
  if (!isRecord(raw) || typeof raw.observer_instance_id !== 'string'
    || !isObserverInstance(raw.observer_instance_id)) return null
  const query = operatorDigestQuery(raw)
  const generation = raw.digest_publication_generation
  const sequence = raw.digest_publication_sequence
  const state = raw.digest_observation_state
  if (query === null || typeof generation !== 'number' || !Number.isSafeInteger(generation) || generation < 0
    || typeof sequence !== 'number' || !Number.isSafeInteger(sequence) || sequence < 0
    || (state !== 'initializing' && state !== 'ready' && state !== 'error')) return null
  return { instance: raw.observer_instance_id, generation, sequence, state, query }
}
