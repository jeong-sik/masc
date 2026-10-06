import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const out=fileURLToPath(new URL('.',import.meta.url)), root=fileURLToPath(new URL('../..',import.meta.url))
const cacheDir=await mkdtemp(join(tmpdir(),'masc-lane-navigation-'))
process.env.MASC_DASHBOARD_PROXY_TARGET='http://127.0.0.1:1'
const server=await createServer({root,cacheDir,configFile:root+'vite.config.ts',server:{host:'127.0.0.1',port:0,watch:null}})
await server.listen()
const browser=await chromium.launch({headless:true}),context=await browser.newContext({viewport:{width:1440,height:1050}}),page=await context.newPage()
page.setDefaultTimeout(10000)
const reads=[],writes=[],errors=[],unexpected=[],checks=[]
page.on('pageerror',error=>errors.push(error.message))
const inventory=JSON.parse(await readFile(root+'src/api/fixtures/lane-inventory.json','utf8'))
const directory='/fixture/A/.masc/config/lane-addons', path=directory+'/한글 # package.toml'
const original='id = "pkg"\nrun_id = "run"\nmanifest_path = "../pkg/lane.toml"\n[binding]\nsources = []\n'
let source=original,revision='r1',incarnation='i1',failInventory=false
inventory.package_read.directory=directory
inventory.rows.push({id:'declaration/'+path,label:'Fixture package',purpose:'Declaration navigation',selection:{kind:'declaration',source_path:path},
 state:{kind:'package',declaration:{kind:'valid',enabled:true,installation_id:'pkg',run_id:'run',package_id:'fixture',title:'Fixture package',desired_revision:'semantic'},instances:[]}})
inventory.rows.push({id:'instance/worker',label:'Fixture manual worker',purpose:'Worker navigation',selection:{kind:'manual_instance',instance_id:'worker',incarnation:'i1'},
 state:{kind:'package',declaration:null,instances:[{instance_id:'worker',incarnation:'i1',run_id:'run',package_id:'fixture',title:'Fixture worker',package_revision:'v1',presence:'live',phase:{kind:'attached'},applied_revision:null}]}})
const snapshot=()=>({configuration:{directory,complete:true,issues:[],declarations:[{id:'pkg',source_path:path,enabled:true,desired_revision:'semantic',applied_revision:null,instance_id:null}]},
 instances:[{instance_id:'worker',run_id:'run',addon_id:'fixture',title:'Fixture worker',revision:'v1',incarnation,action_schema:null,binding:{},package:{binding_schema:null,presentation:{description:null,readings:[]},outputs:{}},configuration:null,phase:{kind:'attached'},observation_seq:0,rows_count:0}],rows:[],coverage:[]})
const runtimeSource='# retained runtime\nmachines = { msx = { enabled = true }, dos = { enabled = false } }\n[browser.live]\nenabled = true\n[browser.automation]\ngeckodriver = "/fixture/driver"\n[runtime]\n'
await page.context().route('**/api/**',async route=>{
 const request=route.request(),url=new URL(request.url()),p=url.pathname
 if(!p.startsWith('/api/'))return route.continue()
 const send=(body,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)})
 if(request.method()!=='GET'){writes.push({p,body:request.postData()});return send({error:'Navigation must not write'},500)}
 reads.push({p,query:url.search})
 if(p==='/api/v1/auth/dev-token'||p==='/api/v1/dashboard/dev-token')return send({token:'fixture-token',actor:'fixture',role:'admin'})
 if(p==='/api/v1/lanes')return send(inventory)
 if(p==='/api/v1/lane-addons'){
  if(failInventory){failInventory=false;return send({error:'Fixture inventory unavailable'},503)}
  return send(snapshot())
 }
 if(p==='/api/v1/lane-addons/declaration'){
  assert.equal(url.searchParams.get('source_path'),path)
  return send({file_name:'한글 # package.toml',source_path:path,source_text:source,source_revision:revision,desired_revision:'semantic',validation:{valid:true,messages:[]}})
 }
 if(p==='/api/v1/runtime/config/raw')return send({ok:true,path:'/fixture/A/.masc/config/runtime.toml',file_name:'runtime.toml',source_text:runtimeSource,source_revision:'a'.repeat(64),provider_protocols:[{protocol:'openai-compatible-http',transport:'endpoint',semantics:'http_provider',credential_policy:'optional',requires_non_interactive:false,provider_fields:[],required_provider_fields:[]}],reserved_provider_ids:['runtime','providers','models','machines','browser']})
 if(p==='/api/v1/runtime/params')return send({parameters:[]})
 if(p==='/api/v1/dashboard/standalone-lanes')return send(inventory.exact_snapshot)
 if(p==='/api/v1/runtime/resolved')return send({config_path:'/fixture/A/.masc/config/runtime.toml',default_runtime:null,runtimes:[],lanes:[],assignments:[]})
 if(p==='/api/v1/dashboard/exact-lane-runs')return send({runs:[],count:0,total:0,has_more:false,generated_at:'now'})
 if(p==='/api/v1/dashboard/verification-runs')return send({runs:[],count:0,generated_at:'now'})
 if(p==='/api/v1/dashboard/fusion-runs')return send({runs:[],count:0,generated_at:'now',replay:{status:'absent'},historical_evidence:[]})
 unexpected.push(p);return send({error:'Unexpected fixture route'},500)
})
const click=name=>page.getByRole('button',{name,exact:true}).click()
const hop=href=>page.evaluate(value=>{location.hash=value},href)
const focus=label=>page.waitForFunction(value=>document.activeElement?.getAttribute('aria-label')===value,label)
const sourceBox=()=>page.getByTestId('runtime-toml-source')
const selection=()=>sourceBox().evaluate(el=>el.value.slice(el.selectionStart,el.selectionEnd))
const selectedText=text=>page.waitForFunction(value=>{const el=document.querySelector('[data-testid="runtime-toml-source"]');return document.activeElement===el&&el.value.slice(el.selectionStart,el.selectionEnd).includes(value)},text)
const linkNames={exact:'Runtime settings · Lane candidates',browser:'Runtime settings · Browser paths',machine:'Runtime settings · Machine configuration',package:'Manage package declarations and retained observations'}
const hrefs={}
try {
 await page.goto(server.resolvedUrls.local[0]+'evidence/2026-10-05-web-lane-navigation/fixture.html')
 for(const [key,label,kind] of [['exact','Librarian','exact'],['live','Live browser','browser'],['automation','Browser automation','browser'],['msx','MSX','machine'],['dos','DOS','machine'],['package','Fixture package','package'],['worker','Fixture manual worker','package']]){
  await click('Inspect '+label)
  hrefs[key]=await page.getByRole('link',{name:linkNames[kind],exact:true}).getAttribute('href')
 }
 await click('Inspect Librarian');hrefs.diagnostics=await page.getByRole('link',{name:'Exact runs and diagnostics',exact:true}).getAttribute('href')
 await page.getByRole('link',{name:linkNames.exact,exact:true}).click();await focus('Lane configuration librarian_exact')
 checks.push('actual inventory link → real router → lazy Status Runtime editor focuses selected Exact Lane')
 await page.getByTestId('runtime-toml-nav-toml').click();const dirty=runtimeSource+'# unsaved runtime edit\n';await sourceBox().fill(dirty)
 await hop(hrefs.live);await selectedText('browser.live')
 assert.ok((await selection()).includes('browser.live'));assert.equal(await sourceBox().inputValue(),dirty)
 await hop(hrefs.exact);await focus('Lane configuration librarian_exact')
 checks.push('same Runtime surface Exact→Browser→same Exact restores focus and retains raw draft')
 await hop(hrefs.msx);await selectedText('msx');assert.ok((await selection()).startsWith('msx'))
 await hop(hrefs.dos);await selectedText('dos');assert.ok((await selection()).startsWith('dos'))
 assert.equal(await sourceBox().inputValue(),dirty);checks.push('MSX and DOS generated links select their actual inline TOML nodes without insertion')
 await hop(hrefs.automation);await selectedText('browser.automation')
 await page.screenshot({path:out+'runtime-target.png',fullPage:true})
 const missing=hrefs.automation.replace(encodeURIComponent('automation'),encodeURIComponent('stagehand'))
 await hop(missing);await page.getByText(/This target is not declared in the current draft/).waitFor();assert.equal(await sourceBox().inputValue(),dirty)
 checks.push('missing Browser config is explained without selecting another backend or inserting text')
 await hop(hrefs.package);const raw=page.getByLabel('TOML source',{exact:true});await raw.waitFor();await focus('Selected declaration settings')
 assert.equal(await raw.inputValue(),original);const rawDraft='# unsaved declaration\n'+original;await raw.fill(rawDraft)
 await click('Fixture All Lanes');await click('Inspect Fixture package');await page.getByRole('link',{name:linkNames.package,exact:true}).click();await raw.waitFor()
 assert.equal(await raw.inputValue(),rawDraft);assert.equal(await page.getByRole('button',{name:'Save TOML',exact:true}).isDisabled(),false)
 checks.push('declaration link preserves Unicode/space/hash path, focuses editor, rereads identity and retains dirty draft without spurious revision conflict')
 await click('Fixture All Lanes');source=original.replace('"pkg"','"replacement"');revision='r2';await hop(hrefs.package)
 await page.getByText('The file read belongs to a different installation. The replacement was not opened.',{exact:true}).waitFor()
 source=original;revision='r3';await click('Read target again');await raw.waitFor();assert.equal(await raw.inputValue(),rawDraft)
 assert.equal(await page.getByRole('button',{name:'Save TOML',exact:true}).isDisabled(),true)
 await page.getByRole('region',{name:'Current file comparison'}).waitFor();checks.push('changed file identity blocks replacement; Retry rereads restored identity and preserves draft/original CAS basis')
 const before=reads.length;await click('Fixture workspace B');await page.getByText(/This Lane link belongs to another workspace/).waitFor();assert.equal(reads.length,before)
 await click('Fixture workspace A');await raw.waitFor();assert.equal(await raw.inputValue(),rawDraft);checks.push('workspace A→B→A blocks target reads in B and restores the retained A draft after fresh read')
 await page.screenshot({path:out+'declaration-target.png',fullPage:true})
 await click('New TOML');assert.equal(new URLSearchParams(new URL(page.url()).hash.split('?')[1]).has('lane_target'),false)
 await page.getByLabel('Open drafts',{exact:true}).selectOption(path);assert.equal(await raw.inputValue(),rawDraft)
 checks.push('explicit New TOML releases the previous URL target while retaining the previous declaration draft')
 await hop(hrefs.worker);await focus('Worker worker · incarnation i1');assert.equal(await page.getByRole('radio').isChecked(),true)
 incarnation='i2';await click('Refresh');await page.getByText(/The selected worker is absent or its incarnation changed/).waitFor()
 assert.equal(await page.getByRole('button',{name:'Observe',exact:true}).count(),0)
 incarnation='i1';await click('Read target again');await focus('Worker worker · incarnation i1')
 checks.push('manual worker ID+incarnation is selected; replaced incarnation cannot inherit its controls and can be reread')
 await hop(hrefs.diagnostics);await focus('Lane observation librarian_exact')
 const filters=page.getByRole('group',{name:'Internal agent filters'});await filters.getByRole('button',{name:'Fusion 0',exact:true}).click()
 assert.equal(await filters.getByRole('button',{name:'Fusion 0',exact:true}).getAttribute('aria-pressed'),'true')
 assert.equal(new URLSearchParams(new URL(page.url()).hash.split('?')[1]).has('lane_target'),false)
 checks.push('diagnostics focuses selected Lane; choosing a different run filter clears target without resetting the chosen filter')
 await hop(hrefs.diagnostics);await focus('Lane observation librarian_exact');await click('Show all Lane runs')
 assert.equal(await filters.getByRole('button',{name:'All 0',exact:true}).getAttribute('aria-pressed'),'true')
 checks.push('Show all Lane runs clears the target and the previously selected filter together')
 await hop('#monitoring?section=runtime&view=config&lane_target=invalid');await page.getByText('The Lane link has an invalid or incomplete target.',{exact:true}).waitFor()
 checks.push('malformed direct target is reported explicitly')
 await hop(hrefs.live);await selectedText('browser.live');await page.setViewportSize({width:390,height:900});await sourceBox().waitFor();await page.screenshot({path:out+'target-mobile.png',fullPage:true})
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false)
 const reentry=await page.context().newPage();reentry.on('pageerror',error=>errors.push(error.message))
 failInventory=true
 await reentry.goto(server.resolvedUrls.local[0]+'evidence/2026-10-05-web-lane-navigation/fixture.html'+hrefs.package)
 await reentry.getByText(/Fixture inventory unavailable/).waitFor()
 await reentry.getByRole('button',{name:'Read target again',exact:true}).click()
 await reentry.getByLabel('TOML source',{exact:true}).waitFor()
 await reentry.waitForFunction(()=>document.activeElement?.getAttribute('aria-label')==='Selected declaration settings')
 assert.equal(await reentry.getByLabel('TOML source',{exact:true}).inputValue(),original)
 await reentry.close();checks.push('fresh page direct URL retains its target across initial inventory failure and Retry focuses the selected declaration')
 assert.deepEqual(writes,[]);assert.deepEqual(errors,[]);assert.deepEqual(unexpected,[])
 const result={passed:true,scope:'Actual styled Status + inventory links + router + receiver components/decoders with synthetic HTTP. No real backend, worker, native, deployment or full SPA bootstrap.',browser:browser.version(),checks,reads,writes,errors,unexpected,hrefs}
 await writeFile(out+'browser-result.json',JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({passed:true,checks,reads:reads.length,writes:0,errors,unexpected}))
} catch(error){await writeFile(out+'browser-failure.json',JSON.stringify({error:String(error),checks,reads,writes,errors,unexpected},null,2)+'\n');await page.screenshot({path:out+'browser-failure.png',fullPage:true});throw error}
finally {await browser.close();await server.close();await rm(cacheDir,{recursive:true,force:true})}
