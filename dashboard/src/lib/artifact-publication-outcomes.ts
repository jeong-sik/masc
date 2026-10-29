import { signal } from '@preact/signals'
import type { ArtifactPublicationOutcome } from '../components/published-artifacts/artifact-composer'

// A late response belongs to the owner that sent the request even when the
// workspace surface is unmounted. This is tab memory, not a durable receipt.
export type ArtifactPublicationOwner = { readonly authority: { readonly workspaceRoot: string } | null }
type Entry = { readonly owner: ArtifactPublicationOwner; readonly outcome: ArtifactPublicationOutcome }
export class ArtifactPublicationOutcomes {
  private readonly entries = signal<readonly Entry[]>([])

  records(): readonly Entry[] { return this.entries.value }

  record(owner: ArtifactPublicationOwner, outcome: ArtifactPublicationOutcome): void {
    const previous = this.entries.peek()
    const index = previous.findIndex(entry => entry.owner === owner && entry.outcome.identity === outcome.identity
      && entry.outcome.kind === outcome.kind
      && entry.outcome.workspace.basePath === outcome.workspace.basePath
      && entry.outcome.workspace.mascRoot === outcome.workspace.mascRoot)
    this.entries.value = index < 0 ? [...previous, { owner, outcome }]
      : previous.map((entry, position) => position === index ? { owner, outcome } : entry)
  }

  clear(): void { this.entries.value = [] }
}
export const artifactPublicationOutcomes = new ArtifactPublicationOutcomes()
