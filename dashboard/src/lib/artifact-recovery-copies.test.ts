import { afterEach, describe, expect, it, vi } from 'vitest'
import { artifactDraftRecoveries, discardArtifactDraftRecovery, retainArtifactDraft } from './artifact-draft-recovery'
import { artifactSentenceRecoveries, discardArtifactSentence, retainArtifactSentence, type ArtifactSentenceInput } from './artifact-sentence-recovery'
const workspace={basePath:'/immutable-recovery-test',mascRoot:'/separate-runtime'}
const target={artifact_id:`artifact-${'f'.repeat(32)}`,generation:'019f0000-0000-7000-8000-000000000000'}
const sentence:ArtifactSentenceInput={format:'html',expected:'alpha',original:'alpha',input:'',selection:{anchor:[1],head:[2]},state:'snapshot'}
const stores=[{
  name:'source',prefix:'masc.artifact-draft-recovery.v1:',field:'state',
  save(id:string,value:string){const r=retainArtifactDraft(id,workspace,target,value);return {...r,value:r.state,discard:()=>discardArtifactDraftRecovery(r)}},
  read(){return artifactDraftRecoveries(workspace,target.artifact_id).map(r=>({...r,value:r.state,discard:()=>discardArtifactDraftRecovery(r)}))},
},{
  name:'sentence',prefix:'masc.artifact-sentence-recovery.v1:',field:'input',
  save(id:string,value:string){const r=retainArtifactSentence(id,workspace,target,{...sentence,input:value});return {...r,value:r.input,discard:()=>discardArtifactSentence(r)}},
  read(){return artifactSentenceRecoveries(workspace,target.artifact_id).map(r=>({...r,value:r.input,discard:()=>discardArtifactSentence(r)}))},
}]
afterEach(()=>{vi.unstubAllGlobals();vi.restoreAllMocks();stores.forEach(store=>store.read().forEach(r=>r.discard()));localStorage.clear()})
describe.each(stores)('$name recovery copies',store=>{
  const key=(record:{id:string;revision:string})=>`${store.prefix}${record.id}:${record.revision}`
  it('preserves a newer in-page edit when an old snapshot is acknowledged',()=>{
    const old=store.save('same-owner','old input'),newer=store.save('same-owner','new input')
    old.discard()
    expect(store.read().map(r=>r.value)).toEqual(['new input'])
    expect(localStorage.getItem(key(newer))).not.toBeNull()
  })
  it('discovers distinct other-tab copies and removes only the acknowledged immutable snapshot',()=>{
    const old=store.save('two-tabs','old input')
    const external={...JSON.parse(localStorage.getItem(key(old))!),revision:crypto.randomUUID(),[store.field]:'other tab input'}
    localStorage.setItem(key(external),JSON.stringify(external))
    expect(store.read().map(r=>r.value)).toEqual(['old input','other tab input'])
    old.discard()
    expect(store.read().map(r=>r.value)).toEqual(['other tab input'])
  })
  it('preserves another tab write that races the actual deletion, without a storage lock',()=>{
    const old=store.save('delete-race','old input'),storage=localStorage
    const external={...JSON.parse(storage.getItem(key(old))!),revision:crypto.randomUUID(),[store.field]:'interleaved input'}
    vi.stubGlobal('localStorage',{get length(){return storage.length},key:storage.key.bind(storage),getItem:storage.getItem.bind(storage),setItem:storage.setItem.bind(storage),removeItem(storageKey:string){
      if(storageKey===key(old))storage.setItem(key(external),JSON.stringify(external))
      storage.removeItem(storageKey)
    }})
    old.discard()
    expect(JSON.parse(storage.getItem(key(external))!)[store.field]).toBe('interleaved input')
    expect(store.read().map(r=>r.value)).toEqual(['interleaved input'])
  })
  it('keeps the prior durable fallback when quota blocks newer input, including an older acknowledgement',()=>{
    const old=store.save('quota','durable input'),storage=localStorage
    vi.stubGlobal('localStorage',{get length(){return storage.length},key:storage.key.bind(storage),getItem:storage.getItem.bind(storage),removeItem:storage.removeItem.bind(storage),setItem(){throw new DOMException('full','QuotaExceededError')}})
    const newer=store.save('quota','memory-only input')
    expect(newer.persisted).toBe(false);old.discard()
    expect(JSON.parse(storage.getItem(key(old))!)[store.field]).toBe('durable input')
    expect(store.read().map(r=>r.value)).toEqual(['memory-only input'])
    const unload=new Event('beforeunload',{cancelable:true});window.dispatchEvent(unload);expect(unload.defaultPrevented).toBe(true)
    newer.discard()
    expect(storage.getItem(key(old))).toBeNull();expect(store.read()).toEqual([])
  })
})
it('snapshots mutable caller identity and sentence ranges rather than retaining their references',()=>{
  const owner={...workspace},document={...target},input={...sentence,selection:{anchor:[1],head:[2]}}
  const draft=retainArtifactDraft('identity',owner,document,'original')
  const text=retainArtifactSentence('identity',owner,document,input)
  owner.mascRoot='/replacement';document.generation='019f0000-0000-7000-8000-000000000001';input.selection.anchor[0]=7
  expect(draft.workspace).toEqual(workspace);expect(draft.target).toEqual(target)
  expect(text.workspace).toEqual(workspace);expect(text.target).toEqual(target);expect(text.selection.anchor).toEqual([1])
})
it('loads sentence copies after a cold module reload without auto applying or losing their original generation',async()=>{
  retainArtifactSentence('cold',workspace,target,{...sentence,input:'durable sentence'})
  vi.resetModules()
  const fresh=await import('./artifact-sentence-recovery')
  const record=fresh.artifactSentenceRecoveries(workspace,target.artifact_id)[0]!
  expect(record.input).toBe('durable sentence');expect(record.target).toEqual(target);expect(record.persisted).toBe(true)
  fresh.discardArtifactSentence(record)
})
