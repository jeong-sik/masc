import { chromium } from 'playwright'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL(process.env.BROWSER_EVIDENCE_DIRECTORY ?? './integrated-browser/', import.meta.url))
const browser = await chromium.launch({ headless:true })
const page = await browser.newPage({viewport:{width:1380,height:1200}})
page.setDefaultTimeout(10000)
const errors=[], consoleErrors=[], unhandled=[], writes=[], reads=[]
page.on('pageerror',e=>errors.push(e.message))
page.on('console',e=>{if(e.type()==='error')consoleErrors.push(e.text())})
const directory='/fixture/shared-config/lane-addons', path=directory+'/custom.toml'
const source='# server A\nid = "custom"\nrun_id = "fixture"\nmanifest_path = "./lane.toml"\n[binding]\nsources = []\n'
const document=(file_name,text,revision)=>({file_name,source_path:directory+'/'+file_name,source_text:text,source_revision:revision,
  desired_revision:'synthetic-semantic',validation:{valid:true,messages:[]}})
const sourceA=document('custom.toml',source,'synthetic-source-a'), sourceB=document('custom.toml',source.replace('server A','server B'),'synthetic-source-b')
let active='A', created=null, releaseCreate
await page.route('**/api/**',async route=>{
  const req=route.request(),url=new URL(req.url())
  if(!url.pathname.startsWith('/api/'))return route.continue()
  const reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)})
  if(url.pathname==='/api/v1/lane-addons')return reply({configuration:{directory,complete:true,issues:[],
    declarations:[sourceA,...(created?[created]:[])].map(d=>({id:d.file_name,source_path:d.source_path,desired_revision:d.desired_revision,applied_revision:null,instance_id:null}))},instances:[],rows:[],coverage:[]})
  if(url.pathname==='/api/v1/lane-addons/declaration' && req.method()==='GET'){
    reads.push({workspace:active,path:url.searchParams.get('source_path')})
    return reply(active==='A'?sourceA:sourceB)
  }
  if(url.pathname==='/api/v1/lane-addons/declaration' && req.method()==='POST'){
    const request=req.postDataJSON();writes.push(request)
    await new Promise(resolve=>{releaseCreate=resolve})
    created=document(request.file_name,request.source_text,'synthetic-created-source')
    return reply({document:created,write:{state:'created',durability:'durable',detail:null},application:'pending_reconciliation'})
  }
  if(url.pathname==='/api/v1/skills')return reply({schema:'masc.skill-snapshot/v1',state:'uninitialized'})
  if(url.pathname==='/api/v1/async-requests')return reply({schema:'masc.async-request-observation/v1',status:'ready',
    summary:{active:0,runtime_owned:0,ownership_unknown:0,record_errors:0},requests:[],record_errors:[],startup_recovery:null})
  unhandled.push(url.pathname);return reply({error:'unexpected fixture route'},500)
})
const click=name=>page.getByRole('button',{name,exact:true}).click()
const editor=()=>page.getByLabel('TOML source',{exact:true})
const waitText=async text=>{await editor().waitFor();await editor().evaluate((element,expected)=>new Promise((resolve,reject)=>{const end=Date.now()+10000;const check=()=>{if(element.value===expected)resolve(true);else if(Date.now()>end)reject(new Error('TOML text did not match'));else setTimeout(check,20)};check()}),text)}
try{
  await page.goto(process.env.LANE_DRAFT_FIXTURE_URL??'http://127.0.0.1:5198/dashboard/evidence/2026-10-04-lane-declaration-drafts/fixture.html')
  await click('Edit TOML '+path)
  await waitText(source)
  const draftA='# retained A draft\n'+source
  await editor().fill(draftA)
  await click('Fixture leave to Skills')
  await editor().waitFor({state:'detached'})
  const guard=await page.evaluate(()=>{const event=new Event('beforeunload',{cancelable:true});window.dispatchEvent(event);return event.defaultPrevented})
  assert.equal(guard,true)
  await click('Fixture return to Lanes')
  await waitText(draftA)
  assert.equal(reads.length,1)
  await click('New TOML')
  await page.getByLabel('File name',{exact:true}).fill('travel.toml')
  await editor().fill(source)
  await click('Save TOML')
  await page.getByRole('button',{name:'Saving TOML…',exact:true}).waitFor()
  const duringCreate='# typed during create\n'+source
  await editor().fill(duringCreate)
  await click('Fixture leave to Skills')
  await editor().waitFor({state:'detached'})
  assert.equal(writes.length,1)
  const createdResponse=page.waitForResponse(r=>r.url().endsWith('/api/v1/lane-addons/declaration')&&r.request().method()==='POST')
  releaseCreate()
  await createdResponse
  await click('Fixture return to Lanes')
  await waitText(duringCreate)
  assert.equal(await page.getByLabel('File name',{exact:true}).isDisabled(),true)
  assert.match(await page.locator('body').innerText(),/Your newer draft edits are not saved/)
  await page.screenshot({path:out+'late-create-restored.png',fullPage:true})
  await click('New TOML')
  assert.equal(await page.getByLabel('File name',{exact:true}).inputValue(),'')
  await click('Edit TOML '+path)
  await waitText(draftA)
  active='B';await click('Fixture workspace B')
  await editor().waitFor({state:'detached'})
  await click('Edit TOML '+path)
  await waitText(sourceB.source_text)
  const draftB='# isolated B draft\n'+sourceB.source_text
  await editor().fill(draftB)
  active='A';await click('Fixture workspace A')
  await waitText(draftA)
  await page.screenshot({path:out+'workspace-a-restored.png',fullPage:true})
  active='B';await click('Fixture workspace B')
  await waitText(draftB)
  assert.equal(writes.length,1)
  assert.deepEqual(errors,[]);assert.deepEqual(unhandled,[]);assert.deepEqual(consoleErrors,[])
  const result={passed:true,browser:await browser.version(),scope:'actual Status/router/editor with synthetic HTTP and accepted execution authority; no backend or deployment',
    assertions:['actual Status unmount removes editor DOM','dirty beforeunload guard remains on Skills','return restores same file draft without refetch','late create after unmount migrates to file identity','edits typed during create remain unsaved','new-file key rotates after late creation','previous file draft survives new-file flow','identical configured directory does not join workspace A/B drafts','return to each workspace restores its own draft','only one explicit create POST'],writes,reads,pageErrors:errors,consoleErrors,unhandled}
  await writeFile(out+'browser-result.json',JSON.stringify(result,null,2)+'\n')
  console.log('PASS: 10 actual routed browser assertions; one explicit POST; no browser errors')
}catch(error){await writeFile(out+'browser-failure.json',JSON.stringify({message:String(error),pageErrors:errors,consoleErrors,unhandled},null,2)+'\n');throw error}
finally{await browser.close()}
