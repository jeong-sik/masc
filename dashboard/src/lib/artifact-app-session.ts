import { appRequest, appRequestApplied, equalJson, readAppState, writeAppState, sameAppTarget,
  type AppState,type AppRequest,type JsonObject } from '../api/artifact-app-data'
import type { ArtifactWorkspace } from '../api/published-artifacts'
import { frameInputs,type FrameInputs } from './artifact-app-frame'
import { resourceOrigins } from './artifact-app-resources'
import { retainAppInput,discardAppInput,appInputRecoveries,type AppRecovery } from './artifact-app-recovery'

export type AppSessionMode='ready'|'saving'|'checking'|'unknown'|'retry'|'conflict'
export type AppSessionSnapshot={mode:AppSessionMode;server:AppState;data:JsonObject;pending:boolean;recovery:AppRecovery|null;copies:readonly AppRecovery[]}
type Options={initial:AppState;workspace:ArtifactWorkspace;current:()=>boolean;changed:(state:AppSessionSnapshot)=>void;
  result:(instance:string|null,change:number,status:'saved'|'error')=>void;restore:(inputs:FrameInputs)=>void}
type Operation={request:AppRequest;change:number;instance:string|null}
export class ArtifactAppSession {
  private readonly id=crypto.randomUUID()
  private active=true
  private mode:AppSessionMode='ready'
  private server:AppState
  private data:JsonObject
  private change=0
  private instance:string|null=null
  private wanted=false
  private frozen:Operation|null=null
  private recovery:AppRecovery|null=null
  private imported:AppRecovery[]=[]
  constructor(private readonly options:Options){this.server=options.initial;this.data=structuredClone(options.initial.data);frameInputs(this.data);resourceOrigins(this.data)}
  private current():boolean{return this.active&&this.options.current()}
  attachFrame(instance:string):void {
    if(!this.current()||instance===''||this.instance===instance)return
    this.instance=instance;this.change=0
  }
  snapshot():AppSessionSnapshot {
    return {mode:this.mode,server:this.server,data:this.data,pending:this.frozen!==null||!equalJson(this.data,this.server.data),recovery:this.recovery,
      copies:appInputRecoveries(this.options.workspace,this.server).filter(copy=>copy.id!==this.id)}
  }
  private emit():void{if(this.current())this.options.changed(this.snapshot())}
  refreshCopies():void{this.emit()}
  private retain():void{this.recovery=retainAppInput(this.id,this.options.workspace,this.server,this.data,this.frozen?.request??null)}
  input(inputs:FrameInputs,change:number,commit:boolean):boolean {
    if(!this.current()||this.instance===null||change<=this.change)return false
    this.change=change
    this.data=structuredClone({...this.data,forms:inputs.forms,app:inputs.app})
    if(this.frozen||!equalJson(this.data,this.server.data))this.retain()
    else if(this.mode==='ready'&&this.recovery){discardAppInput(this.recovery);this.recovery=null}
    if(commit){
      if(this.mode==='ready'||this.mode==='saving')this.wanted=true
      else this.options.result(this.instance,change,'error')
    }
    this.emit()
    if(commit&&this.mode==='ready')void this.save()
    return true
  }
  async setResources(origins:readonly string[]):Promise<void> {
    if(!this.current()||this.mode!=='ready'||this.frozen)return
    const resource_origins=[...resourceOrigins({resource_origins:[...origins]})]
    this.data=structuredClone({...this.data,resource_origins});this.retain();this.emit()
    await this.save()
  }
  async save():Promise<void> {
    if(!this.current()||this.mode!=='ready'||this.frozen)return
    if(equalJson(this.data,this.server.data)){this.wanted=false;this.options.result(this.instance,this.change,'saved');return}
    this.frozen={request:appRequest(this.server,this.data),instance:this.instance,change:this.change};this.wanted=false;this.retain()
    await this.send()
  }
  private async send():Promise<void> {
    const operation=this.frozen
    if(!this.current()||!operation||this.mode==='saving')return
    this.mode='saving';this.emit()
    try{
      const saved=await writeAppState(operation.request,this.options.workspace,this.server.actor)
      if(!this.current()||this.frozen!==operation)return
      this.acknowledge(saved,operation)
    }catch{
      if(!this.current()||this.frozen!==operation)return
      this.mode='unknown';this.wanted=false;this.retain();this.options.result(this.instance,this.change,'error');this.emit()
    }
  }
  private discardAppliedImports(state:AppState):void {
    const remaining=[]
    for(const copy of this.imported){
      const applied=equalJson(copy.data,state.data)
        &&(copy.request?appRequestApplied(state,copy.request):true)
      if(applied)discardAppInput(copy)
      else remaining.push(copy)
    }
    this.imported=remaining
  }
  private acknowledge(saved:AppState,operation:Operation):void {
    resourceOrigins(saved.data)
    this.server=saved;this.frozen=null;this.mode='ready'
    if(equalJson(this.data,saved.data)){
      if(this.recovery)discardAppInput(this.recovery)
      this.discardAppliedImports(saved);this.recovery=null
    }else this.retain()
    this.options.result(operation.instance,operation.change,'saved');this.emit()
    if(this.wanted)void this.save()
  }
  async check():Promise<void> {
    if(!this.current()||this.mode==='saving'||this.mode==='checking')return
    const operation=this.frozen
    this.mode='checking';this.emit()
    try{
      const current=await readAppState(this.server.target,this.options.workspace,this.server.actor)
      if(!this.current()||this.frozen!==operation)return
      if(this.frozen&&appRequestApplied(current,this.frozen.request)){this.acknowledge(current,this.frozen);return}
      resourceOrigins(current.data)
      this.server=current
      if(!this.frozen){
        const unchanged=equalJson(this.data,current.data)
        this.mode=unchanged?'ready':'conflict';this.wanted=false
        if(unchanged){
          if(this.recovery)discardAppInput(this.recovery)
          this.discardAppliedImports(current);this.recovery=null
        }else this.retain()
        this.emit();return
      }
      this.mode=current.version===this.frozen.request.expected_version
        &&!current.receipts.some(receipt=>receipt.id===this.frozen!.request.id)?'retry':'conflict'
      this.wanted=false;this.retain();this.emit()
    }catch{if(this.current()){this.mode='unknown';this.wanted=false;this.options.result(this.instance,this.change,'error');this.emit()}}
  }
  async retry():Promise<void>{if(this.current()&&this.mode==='retry')await this.send()}
  async overwrite():Promise<void>{
    if(!this.current()||this.mode!=='conflict')return
    this.frozen=null;this.mode='ready';await this.save()
  }
  useServer():void {
    if(!this.current()||this.mode!=='conflict')return
    frameInputs(this.server.data)
    this.data=structuredClone(this.server.data);this.frozen=null;this.mode='ready';this.wanted=false
    if(this.recovery)discardAppInput(this.recovery)
    this.recovery=null;this.imported=[]
    this.options.restore(frameInputs(this.data));this.emit()
  }
  restore(copy:AppRecovery):void {
    if(!this.current()||this.snapshot().pending||this.mode!=='ready'||!sameAppTarget(copy.target,this.server.target)||copy.actor!==this.server.actor
      ||copy.workspace.basePath!==this.options.workspace.basePath||copy.workspace.mascRoot!==this.options.workspace.mascRoot)return
    if(copy.request&&!sameAppTarget(copy.target,copy.request.target))return
    frameInputs(copy.data);resourceOrigins(copy.data)
    this.data=structuredClone(copy.data);this.imported.push(copy)
    this.frozen=copy.request?{request:structuredClone(copy.request),instance:null,change:this.change}:null
    this.mode=this.frozen?'unknown':'conflict';this.wanted=false;this.retain()
    this.options.restore(frameInputs(this.data));this.emit()
  }
  discard(copy:AppRecovery):void {
    if(!this.current()||copy.id===this.id)return
    discardAppInput(copy);this.emit()
  }
  stop():void {this.active=false}
}
