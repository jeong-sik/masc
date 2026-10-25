import { Schema } from 'effect'
import { ArtifactDraftTargetSchema, type ArtifactDraftTarget } from '../api/artifact-drafts'
import type { ArtifactWorkspace } from '../api/published-artifacts'

const RecordSchema = Schema.Struct({ id: Schema.String, revision: Schema.String,
  workspace: Schema.Struct({ basePath: Schema.String, mascRoot: Schema.String }), target: ArtifactDraftTargetSchema,
  state: Schema.String, at: Schema.String })
export type ArtifactDraftRecovery = typeof RecordSchema.Type & { persisted: boolean; storedRevision: string | null }
const prefix = 'masc.artifact-draft-recovery.v1:'
const memory = new Map<string, ArtifactDraftRecovery>()
const storageKey = (record: Pick<ArtifactDraftRecovery,'id'|'revision'>) => `${prefix}${record.id}:${record.revision}`
// Records are per editor, so one session never acknowledges another's pending
// work. They are recovery copies, never an authority or automatic write source.
export function retainArtifactDraft(id: string, workspace: ArtifactWorkspace, target: ArtifactDraftTarget, state: string): ArtifactDraftRecovery {
  const previous = memory.get(id)
  const data = structuredClone({ id, workspace, target, state, revision: crypto.randomUUID(), at: new Date().toISOString() })
  const record: ArtifactDraftRecovery = { ...data, persisted: false, storedRevision: previous?.storedRevision ?? null }
  try {
    localStorage.setItem(storageKey(record), JSON.stringify(data))
    record.persisted = true; record.storedRevision = record.revision
  } catch { /* Keep the new in-page snapshot and its prior durable fallback. */ }
  if(record.persisted && previous) {
    try {
      localStorage.removeItem(storageKey(previous))
      if(previous.storedRevision)localStorage.removeItem(storageKey({...previous,revision:previous.storedRevision}))
    } catch { /* Extra immutable copies can be offered again. */ }
  }
  memory.set(id, record)
  return record
}
export function discardArtifactDraftRecovery(record: ArtifactDraftRecovery): void {
  const current = memory.get(record.id)
  if(current?.revision===record.revision)memory.delete(record.id)
  const protectedRevision = current && current.revision!==record.revision && !current.persisted ? current.storedRevision : null
  try {
    for(const revision of new Set([record.revision,record.storedRevision])) {
      if(revision && revision!==protectedRevision)localStorage.removeItem(storageKey({...record,revision}))
    }
  } catch { /* Remaining copies are only offered for explicit recovery. */ }
}
export function artifactDraftRecoveries(workspace: ArtifactWorkspace, artifactId: string): ArtifactDraftRecovery[] {
  const records = new Map([...memory.values()].map(record=>[record.revision,record]))
  try {
    for (let index = 0; index < localStorage.length; index++) {
      const key = localStorage.key(index)
      if (!key?.startsWith(prefix)) continue
      try {
        const data = Schema.decodeUnknownSync(RecordSchema)(JSON.parse(localStorage.getItem(key) ?? 'null'))
        if(key!==storageKey(data))continue
        const cached=memory.get(data.id)
        if(cached?.revision===data.revision || (!cached?.persisted && cached?.storedRevision===data.revision))continue
        records.set(data.revision,{...data,persisted:true,storedRevision:data.revision})
      } catch { /* Ignore malformed local records. */ }
    }
  } catch { /* In-page recovery remains usable when local storage is disabled. */ }
  return [...records.values()].filter(record => record.workspace.basePath === workspace.basePath
    && record.workspace.mascRoot === workspace.mascRoot && record.target.artifact_id === artifactId)
}

if (typeof window !== 'undefined') window.addEventListener('beforeunload', event => {
  if ([...memory.values()].some(record => !record.persisted)) { event.preventDefault(); event.returnValue = '' }
})
