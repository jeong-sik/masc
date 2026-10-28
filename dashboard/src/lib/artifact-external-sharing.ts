import { signal } from '@preact/signals'

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
  | { readonly kind: 'confirmed'; readonly shared: boolean }
  | { readonly kind: 'unconfirmed'; readonly detail: string }
)

// A per-tab owner guards reads and writes for an artifact ID even if its
// reader unmounts or the workspace changes. It cannot settle a request across
// a page reload or another client; the server needs a durable receipt for that.
export class ArtifactExternalSharing {
  private readonly states = signal<ReadonlyMap<string, ShareState>>(new Map())
  private readonly outcomes = signal<readonly ShareOutcome[]>([])

  activity(id: string): ShareState['kind'] {
    return this.states.value.get(id)?.kind ?? 'ready'
  }

  receipts(): readonly ShareOutcome[] {
    return this.outcomes.value
  }

  observe(id: string): ShareObservation {
    const state = this.states.peek().get(id)
    return { id, state, admitted: state === undefined || state.kind === 'ready' }
  }

  admits(observation: ShareObservation): boolean {
    return observation.admitted && this.states.peek().get(observation.id) === observation.state
  }

  begin(id: string, observation: ShareObservation): object | null {
    if (observation.id !== id || !this.admits(observation)) return null
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
