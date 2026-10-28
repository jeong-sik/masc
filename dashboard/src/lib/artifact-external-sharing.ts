import { signal } from '@preact/signals'
import { pendingShareIdentity, pendingShares, type PendingShare } from './artifact-share-recovery'

type ShareState = { readonly kind: 'ready' } | { readonly kind: 'pending'; readonly owner: object; readonly record?: PendingShare }
type ShareActivity = 'ready' | 'pending' | 'unconfirmed'
export type ShareObservation = { readonly id: string; readonly basePath: string; readonly state: ShareState | undefined; readonly admitted: boolean }
export type ShareOutcome = {
  readonly id: string; readonly title: string; readonly revision: number; readonly requested: boolean
  readonly operationId: string; readonly expectedVersion: number
  readonly operation: PendingShare['operation']
  readonly workspace: { readonly basePath: string; readonly mascRoot: string }
} & (
  | { readonly kind: 'confirmed'; readonly outcome: 'applied' | 'conflict'; readonly shared: boolean; readonly current: boolean }
  | { readonly kind: 'unconfirmed'; readonly detail: string; readonly pending: PendingShare }
)

const resourceKey = (id: string, basePath: string) => JSON.stringify([basePath, id])
const recordKey = pendingShareIdentity
const outcomeKey = (outcome: ShareOutcome) => pendingShareIdentity({ workspace: outcome.workspace, operation: outcome.operation,
  title: outcome.title, revision: outcome.revision })

// A visit owns only its workspace and artifact. Each uncertain operation stays
// in memory until that exact request is reconciled, even if another tab removes
// its durable copy. Different operations on the same artifact remain separate.
export class ArtifactExternalSharing {
  private readonly states = signal<ReadonlyMap<string, ShareState>>(new Map())
  private readonly unresolved = signal<ReadonlyMap<string, PendingShare>>(new Map())
  private readonly outcomes = signal<readonly ShareOutcome[]>([])

  private hasPending(id: string, basePath: string): boolean {
    const matches = (record: PendingShare) => record.operation.id === id && record.workspace.basePath === basePath
    return [...this.unresolved.value.values()].some(matches) || pendingShares().some(matches)
  }

  activity(id: string, basePath: string): ShareActivity {
    if (this.states.value.get(resourceKey(id, basePath))?.kind === 'pending') return 'pending'
    return this.hasPending(id, basePath) ? 'unconfirmed' : 'ready'
  }

  receipts(): readonly ShareOutcome[] { return this.outcomes.value }
  pendingInThisTab(): readonly PendingShare[] { return [...this.unresolved.value.values()] }

  observe(id: string, basePath: string): ShareObservation {
    const state = this.states.peek().get(resourceKey(id, basePath))
    return { id, basePath, state, admitted: (state === undefined || state.kind === 'ready') && !this.hasPending(id, basePath) }
  }

  admits(observation: ShareObservation): boolean {
    return observation.admitted && this.states.peek().get(resourceKey(observation.id, observation.basePath)) === observation.state
      && !this.hasPending(observation.id, observation.basePath)
  }

  begin(id: string, basePath: string, observation: ShareObservation): object | null {
    if (observation.id !== id || observation.basePath !== basePath || !this.admits(observation)) return null
    const owner = {}, states = new Map(this.states.peek())
    states.set(resourceKey(id, basePath), { kind: 'pending', owner })
    this.states.value = states
    return owner
  }

  attachPending(id: string, basePath: string, owner: object, record: PendingShare): void {
    const key = resourceKey(id, basePath), state = this.states.peek().get(key)
    if (state?.kind !== 'pending' || state.owner !== owner || record.operation.id !== id || record.workspace.basePath !== basePath) return
    const states = new Map(this.states.peek()), unresolved = new Map(this.unresolved.peek())
    states.set(key, { kind: 'pending', owner, record })
    unresolved.set(recordKey(record), record)
    this.unresolved.value = unresolved
    this.states.value = states
  }

  beginRecovery(record: PendingShare): object | null {
    const key = resourceKey(record.operation.id, record.workspace.basePath)
    if (this.states.peek().get(key)?.kind === 'pending') return null
    const owner = {}, states = new Map(this.states.peek()), unresolved = new Map(this.unresolved.peek())
    states.set(key, { kind: 'pending', owner, record })
    unresolved.set(recordKey(record), record)
    this.unresolved.value = unresolved
    this.states.value = states
    return owner
  }

  finish(id: string, basePath: string, owner: object, outcome: 'not-sent' | ShareOutcome): void {
    const key = resourceKey(id, basePath), state = this.states.peek().get(key)
    if (state?.kind !== 'pending' || state.owner !== owner) return
    if (outcome !== 'not-sent' && (outcome.id !== id || outcome.workspace.basePath !== basePath
      || !state.record || recordKey(state.record) !== outcomeKey(outcome))) return
    const states = new Map(this.states.peek()), unresolved = new Map(this.unresolved.peek())
    if (state.record && (outcome === 'not-sent' || outcome.kind === 'confirmed')) unresolved.delete(recordKey(state.record))
    if (outcome !== 'not-sent' && outcome.kind === 'unconfirmed') unresolved.set(recordKey(outcome.pending), outcome.pending)
    states.set(key, { kind: 'ready' })
    this.unresolved.value = unresolved
    this.states.value = states
    if (outcome !== 'not-sent') {
      const previous = this.outcomes.peek(), identity = outcomeKey(outcome)
      this.outcomes.value = [...previous.filter(item => outcomeKey(item) !== identity), outcome]
    }
  }
}

export const artifactExternalSharing = new ArtifactExternalSharing()
