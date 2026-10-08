import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseTOML, getStaticTOMLValue } from 'toml-eslint-parser'
const out=fileURLToPath(new URL('.',import.meta.url)), root=fileURLToPath(new URL('../..',import.meta.url))
const cacheDir=await mkdtemp(join(tmpdir(),'masc-package-activity-'))
process.env.MASC_DASHBOARD_PROXY_TARGET='http://127.0.0.1:1'
const server=await createServer({root,cacheDir,configFile:root+'vite.config.ts',server:{host:'127.0.0.1',port:0,watch:null}})
await server.listen()
const browser=await chromium.launch({headless:true}),page=await browser.newPage({viewport:{width:1440,height:1050}})
page.setDefaultTimeout(10000)
const reads=[],mutations=[],errors=[],unexpected=[],checks=[]
page.on('pageerror',error=>errors.push(error.message))
const original='# retained package comment\nid = "pkg"\nrun_id = "run"\nmanifest_path = "../pkg/lane.toml"\n[binding]\nsources = []\n'
const path='/workspace/.masc/config/lane-addons/pkg.toml',directory=path.slice(0,path.lastIndexOf('/'))
let source=original,revision='r1',loseNextSave=false,valid=true
const document=()=>({file_name:'pkg.toml',source_path:path,source_text:source,source_revision:revision,desired_revision:'semantic',validation:{valid,messages:valid?[]:['Fixture invalid binding']}})
const enabled=()=>getStaticTOMLValue(parseTOML(source)).enabled!==false
const snapshot=()=>({configuration:{directory,complete:true,issues:[],declarations:[{id:'pkg',source_path:path,enabled:enabled(),desired_revision:'semantic',applied_revision:'semantic',instance_id:'worker'}]},
 instances:[{instance_id:'worker',run_id:'run',addon_id:'fixture',title:'Observed worker',revision:'v1',incarnation:'i1',action_schema:null,binding:{},package:{binding_schema:null,presentation:{description:null,readings:[]},outputs:{}},configuration:{id:'pkg',source_path:path,revision:'semantic'},phase:{kind:'attached'},observation_seq:0,rows_count:0}],rows:[],coverage:[]})
await page.route('**/api/**',async route=>{
 const request=route.request(),url=new URL(request.url()),p=url.pathname
 if(!p.startsWith('/api/'))return route.continue()
 const send=(body,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)})
 if(p==='/api/v1/auth/dev-token')return send({token:'fixture-token',actor:'fixture',role:'admin'})
 if(p==='/api/v1/lane-addons'&&request.method()==='GET'){reads.push({p});return send(snapshot())}
 if(p==='/api/v1/lane-addons/declaration'&&request.method()==='GET'){reads.push({p,source_path:url.searchParams.get('source_path')});return send(document())}
 if(p==='/api/v1/lane-addons/declaration'&&request.method()==='POST'){
  const body=request.postDataJSON();mutations.push(body)
  if(body.mode!=='save'||body.expected_source_revision!==revision)return send({code:'revision_conflict',error:'Fixture CAS conflict',current:document()},409)
  source=body.source_text;revision='saved-'+mutations.length
  if(loseNextSave){loseNextSave=false;return route.abort('failed')}
  return send({document:document(),write:{state:'saved',durability:'durable',detail:null},application:'pending_reconciliation'})
 }
 unexpected.push({p,method:request.method()});return send({error:'Unexpected fixture route'},500)
})
const click=name=>page.getByRole('button',{name,exact:true}).click()
const activity=page.getByRole('region',{name:'Package activity pkg',exact:true})
const switcher=()=>activity.getByRole('switch',{name:'Activity draft for pkg',exact:true})
const labelText=async text=>{await activity.getByText(text,{exact:true}).waitFor()}
try {
 await page.goto(server.resolvedUrls.local[0]+'evidence/2026-10-05-web-package-activity/fixture.html')
 await click('Edit TOML '+path)
 const raw=page.getByLabel('TOML source',{exact:true});await raw.fill('# independent raw edit\n'+original)
 await click('Configure activity for pkg');await labelText('File activity (last read): On')
 assert.equal(await page.evaluate(()=>document.activeElement?.textContent),'Package on/off · pkg')
 assert.equal(mutations.length,0);checks.push('activity opens from declaration row with keyboard focus and actual file API read')
 await switcher().click();assert.equal(await switcher().getAttribute('aria-checked'),'false');assert.equal(mutations.length,0)
 await click('Fixture hide/show');await page.getByText('Other fixture page',{exact:true}).waitFor();await click('Fixture hide/show')
 await labelText('File activity (last read): On');assert.equal(await switcher().getAttribute('aria-checked'),'false')
 assert.equal(await raw.inputValue(),'# independent raw edit\n'+original);checks.push('unsaved activity and independent raw draft survive actual component remount without writes')
 source=original+'newer = "preserved external binding"\n';revision='external'
 await click('Save activity');await activity.getByText(/nothing was saved by this request/).waitFor()
 assert.equal(await activity.getByRole('button',{name:'Save activity',exact:true}).isDisabled(),true)
 await click('Reapply activity only');await click('Save activity');await activity.getByText(/Activity configuration saved/).waitFor()
 assert.equal(mutations.length,2);assert.equal(mutations[1].expected_source_revision,'external')
 assert.equal(source,'enabled = false\n'+original+'newer = "preserved external binding"\n')
 assert.equal(await raw.inputValue(),'# independent raw edit\n'+original)
 await activity.getByText('Observed configuration: Off requested · worker cleanup not yet confirmed',{exact:true}).waitFor()
 checks.push('CAS conflict retains intent; explicit reapply preserves newer binding; save stays distinct from worker cleanup')
 await page.screenshot({path:out+'off-desktop.png',fullPage:true})
 await click('Workspace B');await activity.waitFor({state:'hidden'});await click('Workspace A')
 await labelText('File activity (last read): Off');assert.equal(await switcher().getAttribute('aria-checked'),'false')
 checks.push('workspace return rereads the current file and keeps Off state isolated')
 await switcher().click();await click('Save activity');await labelText('File activity (last read): On')
 assert.equal(mutations.length,3);assert.equal(enabled(),true);assert.equal(await raw.inputValue(),'# independent raw edit\n'+original)
 checks.push('Off can be saved back On with the same declaration and binding, without detach or remove requests')
 loseNextSave=true;await switcher().click();await click('Save activity')
 await activity.getByText('The previous save outcome is uncertain. Read the current file before another save.',{exact:true}).waitFor()
 assert.equal(mutations.length,4);assert.equal(await activity.getByRole('button',{name:'Save activity',exact:true}).isDisabled(),true)
 await click('Read current activity');await labelText('File activity (last read): Off')
 await click('Reapply activity only');assert.equal(await activity.getByRole('button',{name:'Save activity',exact:true}).isDisabled(),true)
 assert.equal(mutations.length,4);checks.push('lost save response forces reread; matching observed Off is resolved without a duplicate save')
 await page.setViewportSize({width:390,height:900});await activity.scrollIntoViewIfNeeded()
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false)
 await page.screenshot({path:out+'activity-mobile.png',fullPage:true});checks.push('actual styled mobile activity controls render without page horizontal overflow')
 valid=false;await click('Read current activity');await activity.getByText(/The declaration is invalid/).waitFor()
 assert.equal(await switcher().isDisabled(),true);assert.equal(await activity.getByRole('button',{name:'Save activity',exact:true}).isDisabled(),true)
 assert.equal(mutations.length,4);checks.push('invalid current declaration disables activity mutation and exposes original TOML repair')
 assert.deepEqual(errors,[]);assert.deepEqual(unexpected,[])
 const result={passed:true,scope:'Actual styled Add-ons panel/activity owner/declaration API with synthetic HTTP; not real backend/worker or full SPA.',browser:browser.version(),checks,reads,mutations,errors,unexpected}
 await writeFile(out+'browser-result.json',JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({passed:true,checks,reads:reads.length,writes:mutations.length,errors,unexpected}))
} catch(error){await writeFile(out+'browser-failure.json',JSON.stringify({error:String(error),checks,reads,mutations,errors,unexpected},null,2)+'\n');await page.screenshot({path:out+'browser-failure.png',fullPage:true});throw error}
finally {await browser.close();await server.close();await rm(cacheDir,{recursive:true,force:true})}
