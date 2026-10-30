import { signal } from '@preact/signals'
import type { ArtifactWorkspace } from '../api/published-artifacts'
import { pendingShareIdentity, pendingShares, type PendingShare } from './artifact-share-recovery'

type ShareState = { readonly kind: 'ready' } | { readonly kind: 'pending'; readonly owner: object; readonly record?: PendingShare }
type ShareActivity = 'ready' | 'pending' | 'unconfirmed'
export type ShareObservation = { readonly id: string; readonly workspace: ArtifactWorkspace; readonly state: ShareState | undefined; readonly admitted: boolean }
export type ShareOutcome = {
  readonly id: string; readonly title: string; readonly revision: number; readonly requested: boolean
  readonly operationId: string; readonly expectedVersion: number
  readonly operation: PendingShare['operation']
  readonly workspace: { readonly basePath: string; readonly mascRoot: string }
} & (
  | { readonly kind: 'confirmed'; readonly outcome: 'applied' | 'conflict'; readonly shared: boolean; readonly current: boolean }
  | { readonly kind: 'unconfirmed'; readonly detail: string; readonly pending: PendingShare }
)

const resourceKey = (id: string, workspace: ArtifactWorkspace) => JSON.stringify([workspace.basePath, workspace.mascRoot, id])
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

  private hasPending(id: string, workspace: ArtifactWorkspace): boolean {
    const matches = (record: PendingShare) => record.operation.id === id && record.workspace.basePath === workspace.basePath
      && record.workspace.mascRoot === workspace.mascRoot && !this.confirmed(record)
    return [...this.unresolved.value.values()].some(matches) || pendingShares().some(matches)
  }

  activity(id: string, workspace: ArtifactWorkspace): ShareActivity {
    if (this.states.value.get(resourceKey(id, workspace))?.kind === 'pending') return 'pending'
    return this.hasPending(id, workspace) ? 'unconfirmed' : 'ready'
  }

  receipts(): readonly ShareOutcome[] { return this.outcomes.value }
  pendingInThisTab(): readonly PendingShare[] { return [...this.unresolved.value.values()] }
  confirmed(record: PendingShare): boolean {
    const identity = recordKey(record)
    return this.outcomes.value.some(outcome => outcome.kind === 'confirmed' && outcomeKey(outcome) === identity)
  }

  observe(id: string, workspace: ArtifactWorkspace): ShareObservation {
    const state = this.states.peek().get(resourceKey(id, workspace))
    return { id, workspace, state, admitted: (state === undefined || state.kind === 'ready') && !this.hasPending(id, workspace) }
  }

  admits(observation: ShareObservation): boolean {
    return observation.admitted && this.states.peek().get(resourceKey(observation.id, observation.workspace)) === observation.state
      && !this.hasPending(observation.id, observation.workspace)
  }

  begin(id: string, workspace: ArtifactWorkspace, observation: ShareObservation): object | null {
    if (observation.id !== id || resourceKey(id, observation.workspace) !== resourceKey(id, workspace) || !this.admits(observation)) return null
    const owner = {}, states = new Map(this.states.peek())
    states.set(resourceKey(id, workspace), { kind: 'pending', owner })
    this.states.value = states
    return owner
  }

  attachPending(id: string, workspace: ArtifactWorkspace, owner: object, record: PendingShare): void {
    const key = resourceKey(id, workspace), state = this.states.peek().get(key)
    if (state?.kind !== 'pending' || state.owner !== owner || record.operation.id !== id
      || resourceKey(id, record.workspace) !== key) return
    const states = new Map(this.states.peek()), unresolved = new Map(this.unresolved.peek())
    states.set(key, { kind: 'pending', owner, record })
    unresolved.set(recordKey(record), record)
    this.unresolved.value = unresolved
    this.states.value = states
  }

  beginRecovery(record: PendingShare): object | null {
    const key = resourceKey(record.operation.id, record.workspace)
    if (this.states.peek().get(key)?.kind === 'pending') return null
    const owner = {}, states = new Map(this.states.peek()), unresolved = new Map(this.unresolved.peek())
    states.set(key, { kind: 'pending', owner, record })
    unresolved.set(recordKey(record), record)
    this.unresolved.value = unresolved
    this.states.value = states
    return owner
  }

  finish(id: string, workspace: ArtifactWorkspace, owner: object, outcome: 'not-sent' | ShareOutcome): void {
    const key = resourceKey(id, workspace), state = this.states.peek().get(key)
    if (state?.kind !== 'pending' || state.owner !== owner) return
    if (outcome !== 'not-sent' && (outcome.id !== id || resourceKey(id, outcome.workspace) !== key
      || !state.record || recordKey(state.record) !== outcomeKey(outcome))) return
    const states = new Map(this.states.peek()), unresolved = new Map(this.unresolved.peek())
    const alreadyConfirmed = state.record !== undefined && this.confirmed(state.record)
    if (state.record && (outcome === 'not-sent' || outcome.kind === 'confirmed' || alreadyConfirmed)) unresolved.delete(recordKey(state.record))
    if (outcome !== 'not-sent' && outcome.kind === 'unconfirmed' && !alreadyConfirmed) unresolved.set(recordKey(outcome.pending), outcome.pending)
    states.set(key, { kind: 'ready' })
    this.unresolved.value = unresolved
    this.states.value = states
    if (outcome !== 'not-sent' && !(outcome.kind === 'unconfirmed' && alreadyConfirmed)) {
      const previous = this.outcomes.peek(), identity = outcomeKey(outcome)
      this.outcomes.value = [...previous.filter(item => outcomeKey(item) !== identity), outcome]
    }
  }
}

export const artifactExternalSharing = new ArtifactExternalSharing()
