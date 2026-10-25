import { Schema } from 'effect'
import { ArtifactDraftPositionSchema, ArtifactDraftTargetSchema, type ArtifactDraftTarget } from '../api/artifact-drafts'
import type { ArtifactWorkspace } from '../api/published-artifacts'
import type { SharedSelection } from './artifact-shared-document'

export type ArtifactSentenceInput = { expected: string; original: string; input: string; selection: SharedSelection; state: string }
export type ArtifactSentenceRecovery = ArtifactSentenceInput & {
  id: string; workspace: ArtifactWorkspace; target: ArtifactDraftTarget; at: string; persisted: boolean;
}
const RecordSchema = Schema.Struct({ id: Schema.String, workspace: Schema.Struct({ basePath: Schema.String, mascRoot: Schema.String }),
  target: ArtifactDraftTargetSchema, expected: Schema.String, original: Schema.String, input: Schema.String,
  selection: ArtifactDraftPositionSchema, state: Schema.String, at: Schema.String })
const prefix = 'masc.artifact-sentence-recovery.v1:'
const memory = new Map<string, ArtifactSentenceRecovery>()

// An unapplied sentence stays separate from CRDT updates: recovering it never
// skips the original expected-text guard or writes to a different workspace.
export function retainArtifactSentence(id: string, workspace: ArtifactWorkspace, target: ArtifactDraftTarget, input: ArtifactSentenceInput): ArtifactSentenceRecovery {
  const record = { id, workspace: { ...workspace }, target: { ...target }, expected: input.expected, original: input.original, input: input.input, state: input.state,
    selection: { anchor: [...input.selection.anchor], head: [...input.selection.head] }, at: new Date().toISOString(), persisted: false }
  try { localStorage.setItem(prefix + id, JSON.stringify(record)); record.persisted = true } catch { /* In-page copy survives an owner remount. */ }
  memory.set(id, record); return record
}
export function discardArtifactSentence(id: string): void {
  memory.delete(id)
  try { localStorage.removeItem(prefix + id) } catch { /* A remaining copy is offered explicitly, never applied automatically. */ }
}
export function artifactSentenceRecoveries(workspace: ArtifactWorkspace, artifactId: string): ArtifactSentenceRecovery[] {
  try {
    for (let index = 0; index < localStorage.length; index++) {
      const key = localStorage.key(index)
      if (!key?.startsWith(prefix)) continue
      try {
        const record = Schema.decodeUnknownSync(RecordSchema)(JSON.parse(localStorage.getItem(key) ?? 'null'))
        if (key !== prefix + record.id || memory.has(record.id)) continue
        memory.set(record.id, { ...record, selection: { anchor: [...record.selection.anchor], head: [...record.selection.head] }, persisted: true })
      } catch { /* Ignore malformed local copies. */ }
    }
  } catch { /* In-page copies remain available when browser storage is disabled. */ }
  return [...memory.values()].filter(record => record.workspace.basePath === workspace.basePath
    && record.workspace.mascRoot === workspace.mascRoot && record.target.artifact_id === artifactId)
}
if (typeof window !== 'undefined') window.addEventListener('beforeunload', event => {
  if ([...memory.values()].some(record => !record.persisted)) { event.preventDefault(); event.returnValue = '' }
})
