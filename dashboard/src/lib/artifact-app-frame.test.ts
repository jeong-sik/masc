import { Window } from 'happy-dom'
import { parse,defaultTreeAdapter as tree,type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import { afterEach,expect,it,vi } from 'vitest'
import { artifactAppFrame,appFrameMessage,frameInputs,type FrameInputs } from './artifact-app-frame'
const windows:Window[]=[]
afterEach(async()=>{for(const child of windows.splice(0))await child.happyDOM.close()})
async function open(source:string,data:FrameInputs={forms:{},app:{}}){
  const frame=artifactAppFrame(source),child=new Window({settings:{enableJavaScriptEvaluation:true}})
  windows.push(child)
  // HappyDOM's VM omits this browser global. These fixtures carry JSON only;
  // the production bridge continues to use the browser's native clone.
  child.eval('globalThis.structuredClone = value => JSON.parse(JSON.stringify(value))')
  const messages:Record<string,unknown>[]=[]
  vi.spyOn(child,'postMessage').mockImplementation(message=>{messages.push(structuredClone(message) as Record<string,unknown>)})
  // document.write starts interactive in HappyDOM. Model a real srcdoc
  // parser: its head bootstrap runs while loading, before the body exists.
  vi.spyOn(child.document,'readyState','get').mockReturnValue('loading' as typeof child.document.readyState)
  child.document.write(frame.document)
  child.document.dispatchEvent(new child.Event('DOMContentLoaded'))
  await child.happyDOM.whenAsyncComplete()
  const instance=messages.find(message=>message.type==='masc.artifact.inputs.ready.v1')?.instance
  expect(typeof instance).toBe('string')
  const send=(fields:object)=>child.dispatchEvent(new child.MessageEvent('message',{source:child.eval('parent') as Window,data:{token:frame.token,instance,...fields}}))
  send({type:'masc.artifact.inputs.init.v1',data})
  await child.happyDOM.whenAsyncComplete()
  return {frame,child,messages,send}
}
it('runs the generated bridge and SDK, restoring Korean inputs without exposing host authority',async()=>{
  const {child,messages,send,frame}=await open('<textarea id="memo">기본 메모</textarea><input type="password"><input type="file"><select multiple><option value="a">A</option><option value="b">B</option></select>')
  const area=child.document.querySelector('textarea')!,marker=area.getAttributeNames().find(name=>name.startsWith('data-masc-input-'))!,id=area.getAttribute(marker)!
  expect(child.document.querySelector('input[type=password]')!.hasAttribute(marker)).toBe(false)
  expect(child.document.querySelector('input[type=file]')!.hasAttribute(marker)).toBe(false)
  send({type:'masc.artifact.inputs.restore.v1',data:{forms:{[id]:{kind:'value',type:'textarea',value:'저장한 메모 😀\r\n'}},app:{counter:3}}})
  expect(area.value).toBe('저장한 메모 😀\r\n')
  expect(await child.eval('window.MASC.inputs.read()')).toEqual({counter:3})
  area.value='새 메모';area.dispatchEvent(new child.Event('input',{bubbles:true}))
  await child.happyDOM.whenAsyncComplete()
  const editing=messages.at(-1)!
  expect(appFrameMessage(frame,editing)).toMatchObject({kind:'change',commit:false,data:{forms:{[id]:{value:'새 메모'}}}})
  area.dispatchEvent(new child.Event('change',{bubbles:true}));await child.happyDOM.whenAsyncComplete()
  expect(messages.at(-1)?.commit).toBe(true)
  const saved=child.eval('window.MASC.inputs.write({counter:4,note:"앱 입력"})') as Promise<void>
  await child.happyDOM.whenAsyncComplete()
  const change=messages.at(-1)!
  expect(change.data).toMatchObject({app:{counter:4,note:'앱 입력'}})
  send({type:'masc.artifact.inputs.result.v1',change:change.change,status:'saved'})
  await expect(saved).resolves.toBeUndefined()
  expect(frame.document).toContain("connect-src 'none'")
  expect(frame.document).not.toContain('Bearer ')
  expect(frame.document).not.toContain('/api/v1/')
  send({type:'masc.artifact.inputs.restore.v1',data:{forms:{},app:{}}})
  expect(area.value).toBe('기본 메모')
})
it('preserves unquoted slash attributes, scripts and duplicate controls while binding by original source positions',async()=>{
  const source='\uFEFF<input id=a value=one/><input id=b value=two/><template><input></template><script>window.appMarker="original"</script>'
  const {child,frame,messages}=await open(source)
  const values=(source:string)=>{
    const result:string[]=[]
    const visit=(node:Nodes.ParentNode)=>{for(const child of node.childNodes)if(tree.isElementNode(child)){if(child.tagName==='input')result.push(child.attrs.find(attr=>attr.name==='value')?.value??'');visit(child)}}
    visit(parse(source));return result
  }
  // HappyDOM treats the slash in an unquoted attribute differently; use the
  // HTML parser for this source-preservation assertion, not its DOM repair.
  expect(values(frame.document)).toEqual(values(source))
  expect(values(frame.document)).toEqual(['one/','two/'])
  expect(child.eval('window.appMarker')).toBe('original')
  const input=child.document.querySelector('#a')!,marker=input.getAttributeNames().find(name=>name.startsWith('data-masc-input-'))!
  expect(input.getAttribute(marker)).toBe(source.indexOf('<input').toString(36))
  input.after(input.cloneNode(true))
  input.dispatchEvent(new child.Event('change',{bubbles:true}));await child.happyDOM.whenAsyncComplete()
  const message=appFrameMessage(frame,messages.at(-1))
  expect(message?.kind).toBe('change')
  if(message?.kind==='change')expect(message.data.forms).not.toHaveProperty(input.getAttribute(marker)!)
})
it('rejects invalid SDK values and forged capabilities, and keeps reading a detached copy',async()=>{
  const {child,frame}=await open('<input>')
  for(const expression of ['null','[]','{x:NaN}','{x:undefined}','{x:new Date()}','{x:"\\ud800"}'])await expect(child.eval(`window.MASC.inputs.write(${expression})`)).rejects.toThrow()
  expect(appFrameMessage(frame,{type:'masc.artifact.inputs.change.v1',token:'wrong',change:1,commit:true,data:{forms:{},app:{}}})).toBeNull()
  expect(appFrameMessage(frame,{type:'masc.artifact.inputs.change.v1',token:frame.token,change:1,commit:true,data:{forms:{},app:[]}})).toBeNull()
  expect(()=>frameInputs({forms:3})).toThrow()
  expect(()=>frameInputs({forms:null})).toThrow()
  await child.eval('window.MASC.inputs.read().then(value=>{value.changed=true})')
  expect(await child.eval('window.MASC.inputs.read()')).toEqual({})
})
it('limits network resources to explicit canonical origins and rejects CSP injection',()=>{
  const frame=artifactAppFrame('<script src="https://cdn.example.com/app.js"></script>',['https://api.example.com','http://[::1]:9876'])
  const document=parse(frame.document)
  const head=document.childNodes.find(tree.isElementNode)!.childNodes.find(node=>tree.isElementNode(node)&&node.tagName==='head')! as Nodes.Element
  const policy=(head.childNodes.find(node=>tree.isElementNode(node)&&node.tagName==='meta'&&node.attrs.some(attr=>attr.name==='http-equiv')) as Nodes.Element).attrs.find(attr=>attr.name==='content')!.value
  expect(policy).toContain('connect-src https://api.example.com http://[::1]:9876;')
  expect(policy).toContain("script-src 'unsafe-inline' https://api.example.com http://[::1]:9876;")
  expect(policy).toContain("frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'")
  for(const origin of ['https://*.example.com','https://x;connect-src','https://x\"foo','https://x\'foo','https://x/path','https://a@x','data:text/plain,hello','https://x/#y','https://x/?y','https://API.example.com'])expect(()=>artifactAppFrame('hello',[origin])).toThrow()
})

it('suspends user and SDK editing only after capturing the final unsent form value',async()=>{
  const {child,messages,send,frame}=await open('<textarea>기본</textarea>')
  const area=child.document.querySelector('textarea')!
  area.value='마지막으로 입력한 값'
  area.dispatchEvent(new child.Event('input',{bubbles:true}))
  send({type:'masc.artifact.inputs.suspend.v1'})
  await child.happyDOM.whenAsyncComplete()
  expect(child.document.documentElement.inert).toBe(true)
  const suspended=appFrameMessage(frame,messages.at(-1))
  expect(suspended).toMatchObject({kind:'suspended',change:1,data:{app:{}}})
  if(suspended?.kind==='suspended')expect(Object.values(suspended.data.forms)[0]).toMatchObject({value:'마지막으로 입력한 값'})
  await expect(child.eval('window.MASC.inputs.write({memo:"late"})')).rejects.toThrow()
  const count=messages.length
  area.dispatchEvent(new child.Event('change',{bubbles:true}))
  expect(messages).toHaveLength(count)
})
