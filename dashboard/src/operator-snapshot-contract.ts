import { isObserverInstance } from './lib/observer-protocol'
import { isRecord } from './lib/type-guards'

/** The server's actual query echo, including defaults chosen after auth. */
export interface OperatorSnapshotQuery {
  readonly actor: string | null
  readonly view: string | null
  readonly effective_actor: string
  readonly effective_view: string
  readonly include_messages: boolean
  readonly include_keepers: boolean
  readonly lightweight_summary: boolean
  readonly default_summary_request: boolean
}

export function operatorSnapshotQuery(raw: unknown): OperatorSnapshotQuery | null {
  if (!isRecord(raw) || !isRecord(raw.query)) return null
  const q = raw.query
  if ((q.actor !== null && typeof q.actor !== 'string')
    || (q.view !== null && typeof q.view !== 'string')
    || typeof q.effective_actor !== 'string' || typeof q.effective_view !== 'string'
    || typeof q.include_messages !== 'boolean' || typeof q.include_keepers !== 'boolean'
    || typeof q.lightweight_summary !== 'boolean' || typeof q.default_summary_request !== 'boolean'
    || q.effective_actor !== (q.actor ?? 'dashboard')
    || q.effective_view !== (q.view ?? (q.default_summary_request ? 'summary' : 'full'))) return null
  return { actor: q.actor, view: q.view, effective_actor: q.effective_actor, effective_view: q.effective_view,
    include_messages: q.include_messages, include_keepers: q.include_keepers,
    lightweight_summary: q.lightweight_summary, default_summary_request: q.default_summary_request }
}

export function sameOperatorSnapshotQuery(a: OperatorSnapshotQuery, b: OperatorSnapshotQuery): boolean {
  return a.actor === b.actor && a.view === b.view && a.effective_actor === b.effective_actor
    && a.effective_view === b.effective_view && a.include_messages === b.include_messages
    && a.include_keepers === b.include_keepers && a.lightweight_summary === b.lightweight_summary
    && a.default_summary_request === b.default_summary_request
}

export interface OperatorSnapshotPublication {
  readonly instance: string
  readonly epoch: string
  readonly generation: number
  readonly computeSequence: number
  readonly terminalSequence: number
  readonly state: 'initializing' | 'invalidated' | 'ready' | 'error'
  readonly query: OperatorSnapshotQuery
}

const sequence = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
export function operatorSnapshotPublication(raw: unknown): OperatorSnapshotPublication | null {
  if (!isRecord(raw) || typeof raw.observer_instance_id !== 'string' || !isObserverInstance(raw.observer_instance_id)) return null
  const query = operatorSnapshotQuery(raw)
  const state = raw.snapshot_observation_state
  if (query === null || typeof raw.snapshot_epoch !== 'string' || !raw.snapshot_epoch
    || !sequence(raw.snapshot_generation) || !sequence(raw.snapshot_compute_sequence) || !sequence(raw.snapshot_terminal_sequence)
    || (state !== 'initializing' && state !== 'invalidated' && state !== 'ready' && state !== 'error')
    || (raw.snapshot_fresh_until_unix !== null && (typeof raw.snapshot_fresh_until_unix !== 'number'
      || !Number.isFinite(raw.snapshot_fresh_until_unix)))) return null
  return { instance: raw.observer_instance_id, epoch: raw.snapshot_epoch, generation: raw.snapshot_generation,
    computeSequence: raw.snapshot_compute_sequence, terminalSequence: raw.snapshot_terminal_sequence, state, query }
}

/** Private reads deliberately have none of the canonical ordering fields. */
export function hasOperatorSnapshotPublication(raw: Record<string, unknown>): boolean {
  return ['snapshot_epoch', 'snapshot_generation', 'snapshot_compute_sequence', 'snapshot_terminal_sequence',
    'snapshot_observation_state', 'snapshot_fresh_until_unix'].some(key => key in raw)
}
