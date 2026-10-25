import { Schema } from 'effect'
import { ArtifactDiscussionRequestSchema, ArtifactDraftPositionSchema, ArtifactDraftTargetSchema } from '../api/artifact-drafts'
import type { ArtifactWorkspace } from '../api/published-artifacts'

export const DiscussionInputSchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('comment'), operationId: ArtifactDraftTargetSchema.fields.generation,
    source: Schema.Struct({ position: ArtifactDraftPositionSchema, quote: Schema.String, mode: Schema.Literal('source','html_text'), state: Schema.String }),
    body: Schema.String, proposing: Schema.Boolean, proposal: Schema.String }),
  Schema.Struct({ kind: Schema.Literal('reply'), operationId: ArtifactDraftTargetSchema.fields.generation,
    threadId: ArtifactDraftTargetSchema.fields.generation, body: Schema.String }))
const ValueSchema = Schema.Union(Schema.Struct({ kind: Schema.Literal('input'), input: DiscussionInputSchema }),
  Schema.Struct({ kind: Schema.Literal('request'), request: ArtifactDiscussionRequestSchema }))
const RecordSchema = Schema.Struct({ id: Schema.String, revision: Schema.String,
  workspace: Schema.Struct({ basePath: Schema.String, mascRoot: Schema.String }), target: ArtifactDraftTargetSchema,
  actor: Schema.String, value: ValueSchema, at: Schema.String })
export type DiscussionInput = typeof DiscussionInputSchema.Type
export type DiscussionLocalValue = typeof ValueSchema.Type
export type DiscussionLocalRecord = typeof RecordSchema.Type & { persisted: boolean; storedRevision: string | null }
const prefix = 'masc.artifact-discussion-local.v1:'
const memory = new Map<string, DiscussionLocalRecord>()
const storageKey = (record: Pick<DiscussionLocalRecord,'id'|'revision'>) => `${prefix}${record.id}:${record.revision}`
export function retainDiscussionLocal(id: string, workspace: ArtifactWorkspace, target: typeof ArtifactDraftTargetSchema.Type,
  actor: string, value: DiscussionLocalValue): DiscussionLocalRecord {
  const previous = memory.get(id)
  const data = structuredClone({ id, workspace, target, actor, value, revision: crypto.randomUUID(), at: new Date().toISOString() })
  const record: DiscussionLocalRecord = { ...data, persisted: false, storedRevision: previous?.storedRevision ?? null }
  try {
    // Every write gets its own key. An ACK in another tab can only remove the
    // exact version it read, even when that removal races this write.
    localStorage.setItem(storageKey(record),JSON.stringify(data))
    record.persisted = true; record.storedRevision = record.revision
  } catch { /* In-page recovery survives owner changes. */ }
  if(record.persisted && previous) {
    try {
      localStorage.removeItem(storageKey(previous))
      if(previous.storedRevision) localStorage.removeItem(storageKey({...previous,revision:previous.storedRevision}))
    } catch { /* Extra immutable copies can be offered again. */ }
  }
  memory.set(id,record); return record
}
// A late ACK or stale recovery view cannot delete a newer copy in another tab.
export function discardDiscussionLocal(record: DiscussionLocalRecord): void {
  const current = memory.get(record.id)
  if (current?.revision === record.revision) memory.delete(record.id)
  const protectedRevision = current && current.revision !== record.revision && !current.persisted ? current.storedRevision : null
  try {
    for(const revision of new Set([record.revision,record.storedRevision])) {
      if(revision && revision!==protectedRevision)localStorage.removeItem(storageKey({...record,revision}))
    }
  } catch { /* Remaining copies are only offered for explicit recovery. */ }
}
export function discussionLocals(workspace: ArtifactWorkspace, artifactId: string): DiscussionLocalRecord[] {
  const records = new Map([...memory.values()].map(record=>[record.revision,record]))
  try {
    for (let index=0;index<localStorage.length;index++) {
      const key=localStorage.key(index);if(!key?.startsWith(prefix))continue
      try {
        const data=Schema.decodeUnknownSync(RecordSchema)(JSON.parse(localStorage.getItem(key)??'null'))
        if(key!==storageKey(data))continue
        const cached=memory.get(data.id)
        if(cached?.revision===data.revision || (!cached?.persisted && cached?.storedRevision===data.revision))continue
        records.set(data.revision,{...data,persisted:true,storedRevision:data.revision})
      } catch { /* Ignore malformed local records. */ }
    }
  } catch { /* Memory remains available when browser storage is unavailable. */ }
  return [...records.values()].filter(record=>record.workspace.basePath===workspace.basePath&&record.workspace.mascRoot===workspace.mascRoot&&record.target.artifact_id===artifactId)
}
if(typeof window!=='undefined')window.addEventListener('beforeunload',event=>{
  if([...memory.values()].some(record=>!record.persisted)){event.preventDefault();event.returnValue=''}
})
