import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
const out=fileURLToPath(new URL('.',import.meta.url)), root=fileURLToPath(new URL('../..',import.meta.url))
const cacheDir=await mkdtemp(join(tmpdir(),'masc-package-web-'))
process.env.MASC_DASHBOARD_PROXY_TARGET = 'http://127.0.0.1:1' // all fixture API requests are intercepted below
const server=await createServer({root,cacheDir,configFile:root+'vite.config.ts',server:{host:'127.0.0.1',port:0,watch:null}})
await server.listen()
const browser=await chromium.launch({headless:true}), page=await browser.newPage({viewport:{width:1440,height:1000}})
page.setDefaultTimeout(10000)
const errors=[], unexpected=[], mutations=[], checks=[], reads=[]
page.on('pageerror',e=>errors.push(e.message))
const object=(properties,required=Object.keys(properties))=>({type:'object',properties,required,additionalProperties:false})
const schema=object({sources:{type:'array',minItems:1,items:object({source_id:{type:'string',minLength:1},kind:{type:'string',const:'lane_output'},installation_id:{type:'string'},selection:{type:'string',const:'latest_completed'},output_id:{type:'string'}},['source_id','kind','installation_id','selection'])},count:{type:'integer',minimum:0},enabled:{type:'boolean'}})
const documents=new Map()
const directory=workspace=>`${workspace}/.masc/config/lane-addons`
const snapshot=workspace=>({configuration:{directory:directory(workspace),complete:true,issues:[],declarations:[
 {id:'producer',source_path:directory(workspace)+'/producer.toml',enabled:true,desired_revision:'applied',applied_revision:'applied',instance_id:'producer'},
 ...[...documents.values()].filter(doc=>doc.source_path.startsWith(directory(workspace)+'/')).map(doc=>({id:'new-report',source_path:doc.source_path,enabled:true,desired_revision:'desired',applied_revision:null,instance_id:null}))]},
 instances:[{instance_id:'producer',run_id:'run',addon_id:'fixture',title:'Observed producer',revision:'p1',incarnation:'inc-producer',action_schema:null,binding:{},
 package:{binding_schema:null,presentation:{description:null,readings:[]},outputs:{results:{all_lanes:true}}},
 configuration:{id:'producer',source_path:directory(workspace)+'/producer.toml',revision:'applied'},phase:{kind:'attached'},observation_seq:0,rows_count:0}],rows:[],coverage:[]})
await page.route('**/api/**',async route=>{
 const req=route.request(), url=new URL(req.url()), path=url.pathname
 if(!path.startsWith('/api/'))return route.continue()
 const send=(body,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)})
 if(path==='/api/v1/dashboard/dev-token')return send({token:'package-fixture-token',actor:'dashboard',role:'admin'})
 const workspace=await page.evaluate(()=>window.fixtureExecution().status.workspace_root)
 if(req.method()==='GET')reads.push({path,query:url.search,workspace});else mutations.push({path,body:req.postDataJSON(),workspace})
 if(path==='/api/v1/lane-addons')return send(snapshot(workspace))
 if(path==='/api/v1/lane-addons/package-catalog' && !url.searchParams.has('directory'))return send({directory:workspace,parent:null,entries:[{kind:'folder',path:workspace+'/packages'}]})
 if(path==='/api/v1/lane-addons/package-catalog')return send({directory:workspace+'/packages',parent:workspace,entries:[
  {kind:'package',manifest_path:workspace+'/packages/report/lane.toml',title:'Listed package',revision:'old-1',description:'Select a package and connect an observed input'},
  {kind:'issue',path:workspace+'/packages/bad/lane.toml',message:'Invalid manifest'}]})
 if(path==='/api/v1/lane-addons/package-preview')return send({manifest_path:url.searchParams.get('manifest_path'),
  package:{title:'Report package',revision:'fresh-2',image:'fixture-image:2',binding_schema:schema},image:{state:'unverified',detail:'Fixture does not inspect Docker'}})
 if(path==='/api/v1/lane-addons/declaration'){
  const body=req.postDataJSON(), source_path=directory(workspace)+'/'+body.file_name
  const document={file_name:body.file_name,source_path,source_text:body.source_text,source_revision:createHash('sha256').update(body.source_text).digest('hex'),desired_revision:'desired',validation:{valid:true,messages:[]}}
  documents.set(source_path,document)
  return send({document,write:{state:'created',durability:'durable',detail:null},application:'pending_reconciliation'})
 }
 unexpected.push(path);return send({error:'unexpected fixture route'},500)
})
const click=name=>page.getByRole('button',{name,exact:true}).click()
try{
 await page.goto(server.resolvedUrls.local[0]+'evidence/2026-10-05-web-package-installation/fixture.html')
 await click('New TOML');await page.getByLabel('File name',{exact:true}).fill('older.toml');await page.getByLabel('TOML source',{exact:true}).fill('# preserve raw draft')
 await click('Install package');await click('Open /workspace/packages');await click('Choose Listed package')
 const wizard=page.getByRole('region',{name:'Package installer',exact:true})
 await wizard.getByText('Configure Report package · fresh-2',{exact:true}).waitFor()
 await wizard.getByText(/Invalid manifest/).waitFor();checks.push('folder navigation, catalog metadata/issues and fresh preview through actual API decoders')
 await wizard.getByLabel('Installation ID',{exact:true}).fill('new-report');await wizard.getByLabel('Run ID',{exact:true}).fill('run')
 await click('Add binding.sources item');await wizard.getByLabel('binding.sources[1].source_id *',{exact:true}).fill('upstream')
 await wizard.getByLabel(/^Use a current output/).selectOption('1')
 await wizard.getByLabel('binding.count *',{exact:true}).fill('1e');await wizard.getByLabel('binding.enabled *',{exact:true}).selectOption('false')
 await click('Prepare TOML draft');await wizard.getByRole('alert').filter({hasText:/complete finite number/}).waitFor();assert.equal(mutations.length,0)
 await wizard.getByLabel('binding.count *',{exact:true}).fill('0');checks.push('nested source selection; incomplete numeric text refuses drafting with no write')
 await click('Fixture hide/show');await page.getByText('Other fixture page',{exact:true}).waitFor();await click('Fixture hide/show')
 await wizard.getByLabel('Installation ID',{exact:true}).waitFor();assert.equal(await wizard.getByLabel('Installation ID',{exact:true}).inputValue(),'new-report');checks.push('input owner survives actual component unmount/remount')
 await click('Workspace B');await wizard.waitFor({state:'hidden'});await click('Workspace A')
 await wizard.getByText(/A fresh package preview is required/).waitFor();await click('Prepare TOML draft');await wizard.getByRole('alert').filter({hasText:/Recheck this package/}).waitFor()
 await click('Recheck package');await wizard.getByText(/A fresh package preview is required/).waitFor({state:'hidden'});checks.push('workspace return preserves inputs but requires fresh preview before drafting')
 await wizard.scrollIntoViewIfNeeded();await page.screenshot({path:out+'form-desktop.png',fullPage:true})
 await page.setViewportSize({width:390,height:844});await wizard.getByLabel('Installation ID',{exact:true}).scrollIntoViewIfNeeded()
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true)
 await page.screenshot({path:out+'form-mobile.png',fullPage:true});checks.push('actual styled nested form at mobile width without horizontal overflow')
 await page.setViewportSize({width:1440,height:1000});await click('Prepare TOML draft');await wizard.waitFor({state:'hidden'})
 const editor=page.getByRole('region',{name:'Lane TOML editor',exact:true}), source=editor.getByLabel('TOML source',{exact:true})
 const expected={enabled:true,id:'new-report',run_id:'run',manifest_path:'/workspace/packages/report/lane.toml',binding:{sources:[{source_id:'upstream',kind:'lane_output',installation_id:'producer',selection:'latest_completed',output_id:'results'}],count:0,enabled:false}}
 assert.deepEqual(getStaticTOMLValue(parseTOML(await source.inputValue())),expected);assert.equal(mutations.length,0)
 const prepared=await editor.getByLabel('Open drafts',{exact:true}).inputValue()
 await editor.getByLabel('Open drafts',{exact:true}).selectOption({label:'older.toml'});assert.equal(await source.inputValue(),'# preserve raw draft')
 await editor.getByLabel('Open drafts',{exact:true}).selectOption(prepared);checks.push('prepared TOML preserves false/zero/named output and independent pre-existing raw draft')
 await click('Save TOML');await editor.getByRole('status').filter({hasText:/File created/}).waitFor()
 assert.equal(mutations.length,1);assert.equal(mutations[0].path,'/api/v1/lane-addons/declaration');assert.equal(mutations[0].body.mode,'create')
 assert.deepEqual(getStaticTOMLValue(parseTOML(mutations[0].body.source_text)),expected)
 checks.push('only explicit Save TOML dispatches one create; receipt remains pending reconciliation')
 await editor.scrollIntoViewIfNeeded();await page.screenshot({path:out+'draft-saved-desktop.png'})
 assert.deepEqual(errors,[]);assert.deepEqual(unexpected,[])
 await writeFile(out+'browser-result.json',JSON.stringify({passed:true,scope:'Actual panel/form/session/API in Chromium with synthetic HTTP. No real backend/worker or full SPA validation.',browser:browser.version(),checks,reads,mutations,errors,unexpected},null,2)+'\n')
 console.log(JSON.stringify({passed:true,checks,reads:reads.length,writes:mutations.length,errors,unexpected}))
}catch(error){await writeFile(out+'browser-failure.json',JSON.stringify({error:String(error),checks,reads,mutations,errors,unexpected},null,2)+'\n');await page.screenshot({path:out+'browser-failure.png',fullPage:true});throw error}
finally{await browser.close();await server.close();await rm(cacheDir,{recursive:true,force:true})}
