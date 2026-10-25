import { Schema } from 'effect'
import { ArtifactDraftPositionSchema, ArtifactDraftTargetSchema, type ArtifactDraftTarget } from '../api/artifact-drafts'
import type { ArtifactWorkspace } from '../api/published-artifacts'
import type { SharedSelection } from './artifact-shared-document'

export type ArtifactSentenceInput = { format:'html'|'markdown'; expected: string; original: string; input: string; selection: SharedSelection; state: string }
const RecordSchema = Schema.Struct({ id: Schema.String, revision: Schema.String, workspace: Schema.Struct({ basePath: Schema.String, mascRoot: Schema.String }),
  target: ArtifactDraftTargetSchema, format:Schema.Literal('html','markdown'), expected: Schema.String, original: Schema.String, input: Schema.String,
  selection: ArtifactDraftPositionSchema, state: Schema.String, at: Schema.String })
export type ArtifactSentenceRecovery = typeof RecordSchema.Type & { persisted: boolean; storedRevision: string | null }
const prefix = 'masc.artifact-sentence-recovery.v1:'
const memory = new Map<string, ArtifactSentenceRecovery>()
const storageKey = (record: Pick<ArtifactSentenceRecovery,'id'|'revision'>) => `${prefix}${record.id}:${record.revision}`

// An unapplied sentence stays separate from CRDT updates: recovering it never
// skips the original expected-text guard or writes to a different workspace.
export function retainArtifactSentence(id: string, workspace: ArtifactWorkspace, target: ArtifactDraftTarget, input: ArtifactSentenceInput): ArtifactSentenceRecovery {
  const previous=memory.get(id)
  const data=structuredClone({id,workspace,target,format:input.format,expected:input.expected,original:input.original,input:input.input,state:input.state,
    selection:input.selection,revision:crypto.randomUUID(),at:new Date().toISOString()})
  const record:ArtifactSentenceRecovery={...data,persisted:false,storedRevision:previous?.storedRevision??null}
  try {
    localStorage.setItem(storageKey(record),JSON.stringify(data));record.persisted=true;record.storedRevision=record.revision
  } catch { /* In-page copy survives an owner remount; keep its durable fallback. */ }
  if(record.persisted&&previous) {
    try {
      localStorage.removeItem(storageKey(previous))
      if(previous.storedRevision)localStorage.removeItem(storageKey({...previous,revision:previous.storedRevision}))
    } catch { /* Extra immutable copies can be offered again. */ }
  }
  memory.set(id, record); return record
}
export function discardArtifactSentence(record:ArtifactSentenceRecovery): void {
  const current=memory.get(record.id)
  if(current?.revision===record.revision)memory.delete(record.id)
  const protectedRevision=current&&current.revision!==record.revision&&!current.persisted?current.storedRevision:null
  try {
    for(const revision of new Set([record.revision,record.storedRevision])) {
      if(revision&&revision!==protectedRevision)localStorage.removeItem(storageKey({...record,revision}))
    }
  } catch { /* A remaining copy is offered explicitly, never applied automatically. */ }
}
export function artifactSentenceRecoveries(workspace: ArtifactWorkspace, artifactId: string): ArtifactSentenceRecovery[] {
  const records=new Map([...memory.values()].map(record=>[record.revision,record]))
  try {
    for (let index = 0; index < localStorage.length; index++) {
      const key = localStorage.key(index)
      if (!key?.startsWith(prefix)) continue
      try {
        const record = Schema.decodeUnknownSync(RecordSchema)(JSON.parse(localStorage.getItem(key) ?? 'null'))
        if (key !== storageKey(record)) continue
        const cached=memory.get(record.id)
        if(cached?.revision===record.revision||(!cached?.persisted&&cached?.storedRevision===record.revision))continue
        records.set(record.revision,{...record,persisted:true,storedRevision:record.revision})
      } catch { /* Ignore malformed local copies. */ }
    }
  } catch { /* In-page copies remain available when browser storage is disabled. */ }
  return [...records.values()].filter(record => record.workspace.basePath === workspace.basePath
    && record.workspace.mascRoot === workspace.mascRoot && record.target.artifact_id === artifactId)
}
if (typeof window !== 'undefined') window.addEventListener('beforeunload', event => {
  if ([...memory.values()].some(record => !record.persisted)) { event.preventDefault(); event.returnValue = '' }
})
