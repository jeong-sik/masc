import { parse, defaultTreeAdapter as tree, html, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { Schema } from 'effect'
import { resourceOrigins } from './artifact-app-resources'
import { isJson, isJsonObject, type JsonObject } from '../api/artifact-app-data'

const Value=Schema.Union(Schema.Struct({kind:Schema.Literal('value'),type:Schema.String,value:Schema.String}),
  Schema.Struct({kind:Schema.Literal('checked'),type:Schema.Literal('checkbox','radio'),value:Schema.String,checked:Schema.Boolean}),
  Schema.Struct({kind:Schema.Literal('select'),multiple:Schema.Boolean,options:Schema.Array(Schema.String),selected:Schema.Array(Schema.Boolean)}))
export const FrameInputsSchema=Schema.Struct({forms:Schema.Record({key:Schema.String,value:Value}),app:Schema.Unknown.pipe(Schema.filter(isJsonObject))})
export type FrameInputs=typeof FrameInputsSchema.Type
export type AppFrame={readonly token:string;readonly document:string}
export type AppFrameMessage=({kind:'ready'}|{kind:'initialized'}|{kind:'change';change:number;commit:boolean;data:FrameInputs}|{kind:'suspended';change:number;data:FrameInputs})&{instance:string}
export function artifactPreviewDocument(source:string):string {
  return '<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'none\'; style-src \'unsafe-inline\'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src \'none\'; frame-src \'none\'; object-src \'none\'; base-uri \'none\'; form-action \'none\'">'+source
}
export function frameInputs(data:JsonObject):FrameInputs {
  return Schema.decodeUnknownSync(FrameInputsSchema)({forms:Object.hasOwn(data,'forms')?data.forms:{},app:Object.hasOwn(data,'app')?data.app:{}})
}
export function appFrameMessage(frame:AppFrame,input:unknown):AppFrameMessage|null {
  if(!isJsonObject(input)||input.token!==frame.token||typeof input.instance!=='string'||input.instance==='')return null
  if(input.type==='masc.artifact.inputs.ready.v1')return {kind:'ready',instance:input.instance}
  if(input.type==='masc.artifact.inputs.initialized.v1')return {kind:'initialized',instance:input.instance}
  if(input.type==='masc.artifact.inputs.suspended.v1'&&typeof input.change==='number'&&Number.isSafeInteger(input.change)&&input.change>=1){
    try{return {kind:'suspended',instance:input.instance,change:input.change,data:Schema.decodeUnknownSync(FrameInputsSchema)(input.data)}}catch{return null}
  }
  if(input.type!=='masc.artifact.inputs.change.v1'||typeof input.change!=='number'||!Number.isSafeInteger(input.change)||input.change<1||typeof input.commit!=='boolean')return null
  try{return {kind:'change',instance:input.instance,change:input.change,commit:input.commit,data:Schema.decodeUnknownSync(FrameInputsSchema)(input.data)}}catch{return null}
}

// Stringified into the opaque frame. Keep every runtime dependency inside this
// function; neither credentials nor host API paths are included in its config.
function bootstrap(config:{token:string;marker:string},valid:typeof isJson):void {
  type Inputs=FrameInputs
  type Control=HTMLInputElement|HTMLTextAreaElement|HTMLSelectElement
  const instance=crypto.randomUUID()
  let initialized=false,formsReady=false,suspended=false,suspendRequested=false,change=0,current:Inputs={forms:{},app:{}}
  let defaults:Inputs['forms']={}
  let resolveReady!:()=>void
  const ready=new Promise<void>(resolve=>{resolveReady=resolve})
  let pending:{change:number;resolve:()=>void;reject:(error:Error)=>void}|null=null
  const send=(type:string,fields:object={})=>parent.postMessage({type,token:config.token,instance,...fields},'*')
  const controls=():Map<string,Control>=>{
    const result=new Map<string,Control>(),duplicates=new Set<string>()
    for(const node of document.querySelectorAll(`[${config.marker}]`)) {
      if(!(node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement||node instanceof HTMLSelectElement))continue
      if(node instanceof HTMLInputElement&&['password','file','button','submit','reset','image'].includes(node.type))continue
      const id=node.getAttribute(config.marker)!
      if(result.has(id))duplicates.add(id);else result.set(id,node)
    }
    for(const id of duplicates)result.delete(id)
    return result
  }
  const capture=():Inputs['forms']=>{
    const values:Record<string,Inputs['forms'][string]>={}
    for(const [id,node]of controls()) {
      if(node instanceof HTMLSelectElement)values[id]={kind:'select',multiple:node.multiple,
        options:Array.from(node.options,option=>option.value),selected:Array.from(node.options,option=>option.selected)}
      else if(node instanceof HTMLInputElement&&(node.type==='checkbox'||node.type==='radio'))values[id]={kind:'checked',type:node.type,value:node.value,checked:node.checked}
      else values[id]={kind:'value',type:node.type,value:node.value}
    }
    return values
  }
  const restore=()=>{
    if(!initialized||!formsReady)return
    for(const [id,node]of controls()) {
      const value=current.forms[id]??defaults[id];if(!value)continue
      if(value.kind==='select'&&node instanceof HTMLSelectElement&&value.multiple===node.multiple
        &&value.options.length===node.options.length&&value.selected.length===node.options.length
        &&value.options.every((option,index)=>option===node.options[index]!.value)) {
        Array.from(node.options).forEach((option,index)=>{option.selected=value.selected[index]!})
      }else if(value.kind==='checked'&&node instanceof HTMLInputElement&&node.type===value.type&&node.value===value.value)node.checked=value.checked
      else if(value.kind==='value'&&!(node instanceof HTMLSelectElement)&&node.type===value.type)node.value=value.value
    }
    send('masc.artifact.inputs.initialized.v1')
    if(suspendRequested)suspend()
  }
  const changed=(commit:boolean):number=>{
    if(!initialized||suspended)return change
    if(!Number.isSafeInteger(change+1))throw new Error('입력 변경 번호를 더 만들 수 없습니다.')
    change++
    if(formsReady)current={...current,forms:capture()}
    send('masc.artifact.inputs.change.v1',{change,commit,data:current})
    return change
  }
  const suspend=()=>{
    if(!initialized||!formsReady||suspended)return
    suspended=true;document.documentElement.inert=true
    if(!Number.isSafeInteger(change+1))throw new Error('입력 변경 번호를 더 만들 수 없습니다.')
    current={...current,forms:capture()};change++
    send('masc.artifact.inputs.suspended.v1',{change,data:current})
  }
  const sdk=Object.freeze({
    read:async()=>{await ready;return structuredClone(current.app)},
    write:async(data:JsonObject)=>{
      await ready
      if(suspendRequested)throw new Error('연결 설정을 적용하고 있습니다. 새 문서에서 다시 저장해 주세요.')
      if(pending)throw new Error('앞선 입력의 저장 결과를 기다려 주세요.')
      if(data===null||typeof data!=='object'||Array.isArray(data)||!valid(data))throw new Error('앱 입력은 JSON 객체여야 합니다.')
      const app=structuredClone(data)
      return new Promise<void>((resolve,reject)=>{
        current={...current,app}
        const operation=changed(true);pending={change:operation,resolve,reject}
      })
    },
  })
  Object.defineProperty(window,'MASC',{value:Object.freeze({inputs:sdk}),writable:false,configurable:false})
  window.addEventListener('message',event=>{
    if(event.source!==parent||event.data?.token!==config.token||event.data?.instance!==instance)return
    const message=event.data
    if(message.type==='masc.artifact.inputs.suspend.v1'){suspendRequested=true;suspend();return}
    if(message.type==='masc.artifact.inputs.init.v1'||message.type==='masc.artifact.inputs.restore.v1') {
      if(initialized&&message.type==='masc.artifact.inputs.init.v1')return
      current=message.data;initialized=true;restore();resolveReady()
      document.dispatchEvent(new CustomEvent('masc:inputs-ready',{detail:structuredClone(current.app)}))
    }else if(message.type==='masc.artifact.inputs.result.v1'&&pending) {
      if(message.status==='error'){pending.reject(new Error(message.message));pending=null}
      else if(message.status==='saved'&&message.change>=pending.change){pending.resolve();pending=null}
    }
  })
  for(const type of ['input','change','reset'])document.addEventListener(type,()=>queueMicrotask(()=>changed(type!=='input')),true)
  document.addEventListener('submit',event=>{event.preventDefault();queueMicrotask(()=>changed(true))},true)
  const parsed=()=>{defaults=capture();formsReady=true;restore()}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',parsed,{once:true});else parsed()
  send('masc.artifact.inputs.ready.v1')
}

export function artifactAppFrame(source:string,origins:readonly string[]=[]):AppFrame {
  const token=crypto.randomUUID(),marker='data-masc-input-'+crypto.randomUUID().replaceAll('-','')
  const document=parse(source,{sourceCodeLocationInfo:true}),insertions:{at:number;text:string}[]=[]
  const visit=(parent:Nodes.ParentNode):void=>{
    for(const node of parent.childNodes) {
      if(!tree.isElementNode(node)||node.namespaceURI!==html.NS.HTML)continue
      if(node.tagName==='template')continue
      const start=node.sourceCodeLocation?.startTag
      if(start&&['input','textarea','select'].includes(node.tagName)
        &&!(node.tagName==='input'&&['password','file','button','submit','reset','image'].includes(node.attrs.find(attr=>attr.name==='type')?.value.toLowerCase()??'text'))) {
        const at=start.startOffset+1+node.tagName.length
        insertions.push({at,text:` ${marker}="${start.startOffset.toString(36)}"`})
      }
      visit(node)
    }
  }
  visit(document)
  let marked=source
  for(const insertion of insertions.sort((a,b)=>b.at-a.at))marked=marked.slice(0,insertion.at)+insertion.text+marked.slice(insertion.at)
  const config=JSON.stringify({token,marker})
  const sources=resourceOrigins({resource_origins:[...origins]}).join(' ')
  const policy="default-src 'none'; script-src 'unsafe-inline' "+sources+"; style-src 'unsafe-inline' "+sources+"; img-src data: blob: "+sources+"; font-src data: "+sources+"; media-src data: blob: "+sources+"; connect-src "+(sources||"'none'")+"; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
  return {token,document:`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${policy}"><script>(${bootstrap.toString()})(${config},(${isJson.toString()}))</script>${marked}`}
}
