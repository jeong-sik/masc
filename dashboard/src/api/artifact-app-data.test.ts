import { beforeEach,expect,it,vi } from 'vitest'
import { get,post } from './core'
import { appRequest,decodeAppState,equalJson,isJson,readAppState,writeAppState } from './artifact-app-data'
vi.mock('./core',()=>({get:vi.fn(),post:vi.fn()}))
const target={artifact_id:`artifact-${'a'.repeat(32)}`,revision:1},workspace={basePath:'/work',mascRoot:'/work/.masc'}
const initial={schema:'masc.artifact_app_data.v1' as const,target,actor:'human',version:0,data:{},receipts:[]}
beforeEach(()=>{vi.mocked(get).mockReset();vi.mocked(post).mockReset()})
it('uses captured roots and sends a stable frozen request only once when a response is lost',async()=>{
  vi.mocked(get).mockResolvedValue(initial)
  await readAppState(target,workspace)
  expect(get).toHaveBeenCalledWith(`/api/v1/artifact-app-data/${target.artifact_id}?revision=1`,{extraHeaders:{'x-masc-expected-base-path':'/work','x-masc-expected-masc-root':'/work/.masc'}})
  const request=appRequest(initial,{memo:'한글 😀\r\n'})
  vi.mocked(post).mockRejectedValue(new Error('lost ACK'))
  await expect(writeAppState(request,workspace,'human')).rejects.toThrow('lost ACK')
  expect(post).toHaveBeenCalledTimes(1)
  expect(post).toHaveBeenCalledWith('/api/v1/artifact-app-data',request,{'x-masc-expected-base-path':'/work','x-masc-expected-masc-root':'/work/.masc'})
})
it.each(['target','actor','history','duplicate','receipt'] as const)('refuses mismatched %s without reporting a save',async kind=>{
  const request=appRequest(initial,{memo:'saved'}),receipt={id:request.id,expected_version:0,data_sha256:'a'.repeat(64),at:'now'}
  const saved={...initial,version:1,data:request.data,receipts:[receipt]}
  const input=kind==='target'?{...saved,target:{...target,revision:2}}:kind==='actor'?{...saved,actor:'other'}
    :kind==='history'?{...saved,receipts:[]}:kind==='duplicate'?{...saved,version:2,receipts:[receipt,receipt]}:{...saved,receipts:[{...receipt,id:appRequest(initial,{}).id}]}
  vi.mocked(post).mockResolvedValue(input)
  await expect(writeAppState(request,workspace,'human')).rejects.toThrow()
})
it('compares JSON objects without relying on property order and validates scalar Unicode',()=>{
  expect(equalJson({app:{x:1,y:[true,null]}},{app:{y:[true,null],x:1}})).toBe(true)
  expect(equalJson([1,2],[2,1])).toBe(false)
  for(const invalid of [{x:NaN},{x:Infinity},{x:undefined},{x:1n},{x:new Date()},{x:Number.MAX_SAFE_INTEGER+1},{x:'\ud800'},{['\udfff']:1},{x:Array(2)}])expect(isJson(invalid)).toBe(false)
  const cyclic:{self?:unknown}={};cyclic.self=cyclic;expect(isJson(cyclic)).toBe(false)
  expect(isJson({text:'\uFEFF한글 😀\r\n',n:0.125})).toBe(true)
  expect(()=>decodeAppState({...initial,schema:'old'},target)).toThrow()
})
