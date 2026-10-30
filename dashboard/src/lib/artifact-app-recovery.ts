import { Schema } from 'effect'
import { AppTargetSchema, AppRequestSchema, sameAppTarget, isJsonObject, type AppRequest, type AppState, type JsonObject } from '../api/artifact-app-data'
import type { ArtifactWorkspace } from '../api/published-artifacts'

const ObjectSchema=Schema.Unknown.pipe(Schema.filter(isJsonObject))
const RecordSchema=Schema.Struct({id:Schema.String,revision:Schema.String,at:Schema.String,
  workspace:Schema.Struct({basePath:Schema.String,mascRoot:Schema.String}),target:AppTargetSchema,actor:Schema.String,
  data:ObjectSchema,request:Schema.NullOr(AppRequestSchema)})
export type AppRecovery=typeof RecordSchema.Type&{persisted:boolean;storedRevision:string|null}
const prefix='masc.artifact-app-recovery.v1:',memory=new Map<string,AppRecovery>()
const key=(record:Pick<AppRecovery,'id'|'revision'>)=>`${prefix}${record.id}:${record.revision}`
export function retainAppInput(id:string,workspace:ArtifactWorkspace,state:AppState,data:JsonObject,request:AppRequest|null):AppRecovery {
  const previous=memory.get(id),value=structuredClone({id,revision:crypto.randomUUID(),at:new Date().toISOString(),workspace,target:state.target,actor:state.actor,data,request})
  const record:AppRecovery={...value,persisted:false,storedRevision:previous?.storedRevision??null}
  try{localStorage.setItem(key(record),JSON.stringify(value));record.persisted=true;record.storedRevision=record.revision}catch{/* Preserve the in-page copy and its durable predecessor. */}
  if(record.persisted&&previous)try{
    localStorage.removeItem(key(previous))
    if(previous.storedRevision)localStorage.removeItem(key({...previous,revision:previous.storedRevision}))
  }catch{/* Extra immutable copies remain recoverable. */}
  memory.set(id,record);return record
}
export function discardAppInput(record:AppRecovery):void {
  const current=memory.get(record.id)
  if(current?.revision===record.revision)memory.delete(record.id)
  const protectedRevision=current&&current.revision!==record.revision&&!current.persisted?current.storedRevision:null
  try{for(const revision of new Set([record.revision,record.storedRevision]))if(revision&&revision!==protectedRevision)localStorage.removeItem(key({...record,revision}))}catch{/* A failed deletion cannot discard a later immutable copy. */}
}
export function appInputRecoveries(workspace:ArtifactWorkspace,state:AppState):AppRecovery[] {
  const records=new Map([...memory.values()].map(record=>[record.revision,record]))
  try{for(let index=0;index<localStorage.length;index++){
    const storageKey=localStorage.key(index);if(!storageKey?.startsWith(prefix))continue
    try{
      const record=Schema.decodeUnknownSync(RecordSchema)(JSON.parse(localStorage.getItem(storageKey)??'null'))
      if(key(record)!==storageKey||(record.request&&!sameAppTarget(record.target,record.request.target)))continue
      const cached=memory.get(record.id)
      if(cached?.revision===record.revision||(!cached?.persisted&&cached?.storedRevision===record.revision))continue
      records.set(record.revision,{...record,persisted:true,storedRevision:record.revision})
    }catch{/* Malformed local data never becomes a save request. */}
  }}catch{/* In-page copies remain available without browser storage. */}
  return [...records.values()].filter(record=>record.actor===state.actor&&record.target.artifact_id===state.target.artifact_id&&record.target.revision===state.target.revision
    &&record.workspace.basePath===workspace.basePath&&record.workspace.mascRoot===workspace.mascRoot)
}
if(typeof window!=='undefined')window.addEventListener('beforeunload',event=>{
  if([...memory.values()].some(record=>!record.persisted)){event.preventDefault();event.returnValue=''}
})
