import { signal } from '@preact/signals'
import { pendingShares } from './artifact-share-recovery'

type ShareState =
  | { readonly kind: 'ready' }
  | { readonly kind: 'pending'; readonly owner: object }
  | { readonly kind: 'unconfirmed' }

export type ShareObservation = {
  readonly id: string
  readonly state: ShareState | undefined
  readonly admitted: boolean
}

export type ShareOutcome = {
  readonly id: string
  readonly title: string
  readonly revision: number
  readonly requested: boolean
  readonly workspace: { readonly basePath: string; readonly mascRoot: string }
} & (
  | { readonly kind: 'confirmed'; readonly outcome: 'applied' | 'conflict'; readonly shared: boolean; readonly current: boolean }
  | { readonly kind: 'unconfirmed'; readonly detail: string }
)

// The per-tab owner guards a visit. The persisted operation guards reloads and
// is also observed across tabs; the server makes the final version decision.
export class ArtifactExternalSharing {
  private readonly states = signal<ReadonlyMap<string, ShareState>>(new Map())
  private readonly outcomes = signal<readonly ShareOutcome[]>([])

  activity(id: string): ShareState['kind'] {
    const state = this.states.value.get(id)
    if (state?.kind === 'pending') return 'pending'
    if (pendingShares().some(record => record.operation.id === id)) return 'unconfirmed'
    return state?.kind ?? 'ready'
  }

  receipts(): readonly ShareOutcome[] {
    return this.outcomes.value
  }

  observe(id: string): ShareObservation {
    const state = this.states.peek().get(id)
    return { id, state, admitted: (state === undefined || state.kind === 'ready')
      && !pendingShares().some(record => record.operation.id === id) }
  }

  admits(observation: ShareObservation): boolean {
    return observation.admitted && this.states.peek().get(observation.id) === observation.state
      && !pendingShares().some(record => record.operation.id === observation.id)
  }

  begin(id: string, observation: ShareObservation): object | null {
    if (observation.id !== id || !this.admits(observation)) return null
    const owner = {}
    const states = new Map(this.states.peek())
    states.set(id, { kind: 'pending', owner })
    this.states.value = states
    return owner
  }

  beginRecovery(id: string): object | null {
    if (this.states.peek().get(id)?.kind === 'pending') return null
    const owner = {}
    const states = new Map(this.states.peek())
    states.set(id, { kind: 'pending', owner })
    this.states.value = states
    return owner
  }

  finish(id: string, owner: object, outcome: 'not-sent' | ShareOutcome): void {
    const state = this.states.peek().get(id)
    if (state?.kind !== 'pending' || state.owner !== owner) return
    if (outcome !== 'not-sent' && outcome.id !== id) return
    const states = new Map(this.states.peek())
    // A new object also invalidates reads that began before or during the write.
    states.set(id, outcome !== 'not-sent' && outcome.kind === 'unconfirmed' ? { kind: 'unconfirmed' } : { kind: 'ready' })
    this.states.value = states
    if (outcome !== 'not-sent') this.outcomes.value = [...this.outcomes.peek(), outcome]
  }

}

export const artifactExternalSharing = new ArtifactExternalSharing()
