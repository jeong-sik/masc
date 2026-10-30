import { Schema } from 'effect'
import { v7, validate, version } from 'uuid'
import { getWithResponse, post } from './core'
import { artifactWorkspaceBody, artifactWorkspaceHeaders, artifactWorkspaceQuery, requireArtifactWorkspaceRead, PublishedArtifactSchema, type ArtifactWorkspace } from './published-artifacts'

export type Json = null | boolean | number | string | readonly Json[] | { readonly [key: string]: Json }
export type JsonObject = { readonly [key: string]: Json }
export function isJson(value: unknown, ancestors = new Set<object>()): value is Json {
  function scalarString(value:string):boolean {
    for(const scalar of value){const point=scalar.codePointAt(0)!;if(point>=0xd800&&point<=0xdfff)return false}
    return true
  }
  if(value===null||typeof value==='boolean')return true
  if(typeof value==='string')return scalarString(value)
  if(typeof value==='number')return Number.isFinite(value)&&(!Number.isInteger(value)||Number.isSafeInteger(value))
  if(typeof value!=='object'||ancestors.has(value))return false
  if(!Array.isArray(value)&&Object.getPrototypeOf(value)!==Object.prototype&&Object.getPrototypeOf(value)!==null)return false
  if(Array.isArray(value)&&(Object.keys(value).length!==value.length||Array.from(value,(_,index)=>Object.hasOwn(value,index)).some(present=>!present)))return false
  const next=new Set(ancestors);next.add(value)
  return Object.keys(value).every(scalarString)&&Object.values(value).every(child=>isJson(child,next))
}
export function isJsonObject(value: unknown): value is JsonObject { return value!==null&&typeof value==='object'&&!Array.isArray(value)&&isJson(value) }
const Integer=Schema.Int.pipe(Schema.nonNegative(),Schema.lessThanOrEqualTo(Number.MAX_SAFE_INTEGER))
const Id=Schema.String.pipe(Schema.filter(value=>validate(value)&&version(value)===7&&value===value.toLowerCase()))
export const AppTargetSchema=Schema.Struct({artifact_id:PublishedArtifactSchema.fields.id,revision:Integer.pipe(Schema.positive())})
const ReceiptSchema=Schema.Struct({id:Id,expected_version:Integer,data_sha256:PublishedArtifactSchema.fields.body.fields._blob.fields.sha256,at:Schema.String.pipe(Schema.nonEmptyString())})
export const AppStateSchema=Schema.Struct({schema:Schema.Literal('masc.artifact_app_data.v1'),target:AppTargetSchema,
  actor:Schema.String.pipe(Schema.nonEmptyString()),version:Integer,data:Schema.Unknown.pipe(Schema.filter(isJsonObject)),receipts:Schema.Array(ReceiptSchema)})
export const AppRequestSchema=Schema.Struct({target:AppTargetSchema,id:Id,expected_version:Integer,data:Schema.Unknown.pipe(Schema.filter(isJsonObject))})
export type AppTarget=typeof AppTargetSchema.Type
export type AppState=typeof AppStateSchema.Type
export type AppRequest=typeof AppRequestSchema.Type
export const sameAppTarget=(a:AppTarget,b:AppTarget)=>a.artifact_id===b.artifact_id&&a.revision===b.revision
export function appRequest(state:AppState,data:JsonObject):AppRequest {
  if(!isJsonObject(data))throw new Error('앱 입력은 JSON 객체여야 합니다.')
  return structuredClone({target:state.target,id:v7(),expected_version:state.version,data})
}
export function decodeAppState(input:unknown,target:AppTarget,actor?:string):AppState {
  const state=Schema.decodeUnknownSync(AppStateSchema)(input)
  if(!sameAppTarget(state.target,target)||(actor!==undefined&&state.actor!==actor)
    ||state.receipts.length!==state.version||new Set(state.receipts.map(r=>r.id)).size!==state.version
    ||state.receipts.some((r,index)=>r.expected_version!==index))throw new Error('저장된 앱 입력의 사용자·문서·버전이 요청과 다릅니다.')
  return state
}
export function equalJson(a:Json,b:Json):boolean {
  if(a===b)return true
  if(a===null||b===null||typeof a!=='object'||typeof b!=='object'||Array.isArray(a)!==Array.isArray(b))return false
  const keys=Object.keys(a),other=Object.keys(b)
  return keys.length===other.length&&keys.every(key=>Object.hasOwn(b,key)&&equalJson((a as JsonObject)[key]!, (b as JsonObject)[key]!))
}
export function appRequestApplied(state:AppState,request:AppRequest):boolean {
  return state.version===request.expected_version+1&&equalJson(state.data,request.data)
    &&state.receipts.some(r=>r.id===request.id&&r.expected_version===request.expected_version)
}
const path='/api/v1/artifact-app-data'
export async function readAppState(target:AppTarget,workspace:ArtifactWorkspace,actor?:string):Promise<AppState> {
  const query=artifactWorkspaceQuery(workspace);query.set('revision',String(target.revision))
  const response=await getWithResponse<unknown>(`${path}/${encodeURIComponent(target.artifact_id)}?${query}`,{extraHeaders:artifactWorkspaceHeaders(workspace)})
  requireArtifactWorkspaceRead(response.headers)
  return decodeAppState(response.data,target,actor)
}
export async function writeAppState(request:AppRequest,workspace:ArtifactWorkspace,actor:string):Promise<AppState> {
  const state=decodeAppState(await post<unknown>(path,{...request,expected_workspace:artifactWorkspaceBody(workspace)},artifactWorkspaceHeaders(workspace)),request.target,actor)
  if(!appRequestApplied(state,request))throw new Error('앱 입력 저장 응답이 보낸 요청과 다릅니다. 저장 상태를 확인해 주세요.')
  return state
}
