import { createContext, type ComponentChildren } from 'preact'
import { useContext, useMemo, useState } from 'preact/hooks'
import { html } from 'htm/preact'
import type { ArtifactPublicationOwner } from '../../lib/artifact-publication-outcomes'
import type { ArtifactDraftSnapshot } from './artifact-composer'

export type RetainedArtifactDraft = {
  readonly owner: ArtifactPublicationOwner;
  readonly snapshot: ArtifactDraftSnapshot;
  readonly detached: boolean;
}
export type ArtifactDraftSession = {
  readonly drafts: readonly RetainedArtifactDraft[];
  remember: (owner: ArtifactPublicationOwner, snapshot: ArtifactDraftSnapshot) => void;
  release: (owner: ArtifactPublicationOwner, identity: object) => void;
  forget: (owner: ArtifactPublicationOwner, identity: object) => void;
}
const DraftSession = createContext<ArtifactDraftSession | null>(null)

// This is the existing drafts SSOT, owned by the mounted app rather than an
// individual route. It grants no publication authority and is not durable.
export function ArtifactDraftSessionProvider({ children }: { children: ComponentChildren }) {
  const [drafts, setDrafts] = useState<readonly RetainedArtifactDraft[]>([])
  const session = useMemo<ArtifactDraftSession>(() => ({
    drafts,
    remember: (owner, snapshot) => setDrafts(previous => {
      const entry = { owner, snapshot, detached: false }
      return previous.some(item => item.owner === owner && item.snapshot.identity === snapshot.identity)
        ? previous.map(item => item.owner === owner && item.snapshot.identity === snapshot.identity ? entry : item)
        : [...previous, entry]
    }),
    release: (owner, identity) => setDrafts(previous => previous.map(item =>
      item.owner === owner && item.snapshot.identity === identity ? { ...item, detached: true } : item)),
    forget: (owner, identity) => setDrafts(previous => previous.filter(item =>
      item.owner !== owner || item.snapshot.identity !== identity)),
  }), [drafts])
  return html`<${DraftSession.Provider} value=${session}>${children}<//>`
}

export function useArtifactDraftSession(): ArtifactDraftSession {
  const session = useContext(DraftSession)
  if (session === null) throw new Error('Artifact drafts require the app session owner.')
  return session
}
