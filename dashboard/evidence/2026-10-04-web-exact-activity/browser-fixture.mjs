import { chromium } from 'playwright'
import { createServer } from 'vite'
import { createHash } from 'node:crypto'
import assert from 'node:assert/strict'
import { readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { committedRuntimeTomlConfigFixture } from '../../src/lib/runtime-config-receipt.test-fixture.ts'
const out = fileURLToPath(new URL('.', import.meta.url))
const dashboardRoot = fileURLToPath(new URL('../..', import.meta.url))
const server = await createServer({ root: dashboardRoot, configFile: dashboardRoot + 'vite.config.ts',
 server: { host: '127.0.0.1', port: 0, watch: null } }); await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } }); page.setDefaultTimeout(10000)
const errors = [], unexpected = [], mutations = [], checks = []
const initial = '# operator notes\n[runtime.exact_output_lanes.librarian_exact]\nslots = ["first", "second"]\ncli_slots = ["client"]\nenabled = true # preserve comment\n'
let text = initial, publishedOff = false, applied = 0
let resumeGate = null
const path = '/fixture/runtime.toml'
const revision = source => createHash('sha256').update('runtime_config_source\0' + source).digest('hex')
const config = () => ({ ok: true, path, file_name: 'runtime.toml', source_text: text, source_revision: revision(text),
 provider_protocols:[{protocol:'openai-compatible-http',transport:'endpoint',semantics:'http_provider',credential_policy:'optional',requires_non_interactive:false,provider_fields:[],required_provider_fields:[]}],
 reserved_provider_ids:['providers','models','runtime'] })
const seed = JSON.parse(await readFile(new URL('../../src/api/fixtures/lane-inventory.json', import.meta.url), 'utf8'))
const label = seed.rows.find(row => row.id === 'exact/librarian_exact').label
function reading() {
 const result = structuredClone(seed), lane = result.exact_snapshot.lanes.find(row => row.lane_id === 'librarian_exact'), row = result.rows.find(row => row.id === 'exact/librarian_exact')
 Object.assign(lane, { configured:true, configuration_state:publishedOff?'off':'ready', status:publishedOff?'off':'idle', running_count:0,
   declared_slots:['first','second'], declared_cli_slots:['client'], admitted_slots:publishedOff?[]:['first','second'], cli_slots:publishedOff?[]:['client'], dropped_slots:[], admission_error:null })
 row.state.configuration = publishedOff ? { kind:'off', declared_slots:['first','second'], declared_cli_slots:['client'] }
   : { kind:'configured', ...Object.fromEntries(['declared_slots','declared_cli_slots','admitted_slots','cli_slots','dropped_slots','admission_error'].map(key=>[key,lane[key]])) }
 return result
}
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
 const req = route.request(), pathname = new URL(req.url()).pathname
 if (!pathname.startsWith('/api/')) return route.continue()
 const send = (body, status=200) => route.fulfill({ status, contentType:'application/json', body:JSON.stringify(body) })
 if (req.method() !== 'GET') mutations.push({ path:pathname, body:req.postDataJSON() })
 if (pathname === '/api/v1/dashboard/dev-token') return send({token:'synthetic-fixture-token',actor:'dashboard',role:'admin'})
 if (pathname === '/api/v1/runtime/config/raw/preview') return send({ok:true,can_save:true,validation:{valid:true,schema_version:1,current_schema_version:1,forward_schema:false,issues:[]}})
 if (pathname === '/api/v1/runtime/config/raw') {
  if (req.method()==='GET') return send(config())
  const body=req.postDataJSON()
  if (body.expected_source_revision!==revision(text)) return send({code:'revision_conflict',error:'file changed',current:{source_path:path,source_text:text,source_revision:revision(text)}},409)
  text=body.source_text;applied++
  const receipt=committedRuntimeTomlConfigFixture(config(), applied===2 ? { exactOutputRegistry:{status:'kept',requires_restart:false,next_boot_publishes:false,reason:'synthetic registry admission refused'} } : {})
  if (applied===1) publishedOff=true
  return send(JSON.parse(JSON.stringify(receipt).replaceAll('runtime-source-revision',revision(text))))
 }
 if (pathname === '/api/v1/lanes') return send(reading())
 if (pathname === '/api/v1/dashboard/standalone-lanes') return send(reading().exact_snapshot)
 if (pathname === '/api/v1/runtime/setup/resume') {
  if (resumeGate) { await resumeGate; publishedOff = true }
  return send({runtime_ready:true,exact_output_authority_available:true,model_setup:{status:'available'}})
 }
 if (pathname === '/api/v1/runtime/resolved') return send({config_path:path,default_runtime:null,runtimes:[],lanes:[],assignments:[]})
 if (pathname === '/api/v1/providers') return send({providers:[]})
 if (pathname === '/api/v1/runtime/params') return send({parameters:[]})
 if (pathname === '/api/v1/dashboard/shell') return send({})
 if (pathname === '/api/v1/dashboard/execution') return send(await page.evaluate(()=>window.fixtureExecution()))
 if (pathname === '/api/v1/dashboard/keepers/deletions') return send({operations:[],errors:[],configuration_removals:[],configuration_errors:[]})
 unexpected.push(pathname);return send({error:'unexpected fixture route'},500)
})
const click = name => page.getByRole('button',{name,exact:true}).click()
const activity = () => page.getByRole('region',{name:`${label} 활동 설정`})
const readback = () => page.waitForResponse(response=>response.url().endsWith('/api/v1/runtime/config/raw') && response.request().method()==='GET')
const open = async () => {
 const reading=readback()
 await click('Fixture All Lanes');await click(`Inspect ${label}`)
 const button=page.getByRole('button',{name:/활동 설정 열기/})
 if (await button.count()) await button.click()
 await reading
 await page.getByRole('switch').waitFor();await page.waitForFunction(()=>!document.querySelector('[role=switch]')?.disabled)
}
try {
 await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-web-exact-activity/fixture.html`)
 await page.getByTestId('runtime-toml-nav-toml').click()
 await page.waitForFunction(expected=>document.querySelector('[data-testid="runtime-toml-source"]')?.value===expected,initial)
 const rawDraft=initial+'# unsaved raw draft\n'
 await page.getByTestId('runtime-toml-source').fill(rawDraft)
 await open();await page.getByRole('switch').click()
 assert.equal(await page.getByRole('switch').getAttribute('aria-checked'),'false');assert.equal(mutations.length,0);checks.push('open and toggle are draft-only')
 await click('활동 설정 닫기 · 미저장 초안')
 const reopened=readback();await click('활동 설정 열기 · 미저장 초안');await reopened
 await page.waitForFunction(()=>!document.querySelector('[role=switch]')?.disabled)
 assert.equal(await page.getByRole('switch').getAttribute('aria-checked'),'false');checks.push('closed/reopened draft retained')
 text=initial+'# concurrent other writer\n';const concurrentRevision=revision(text)
 await click('활동 설정 저장');await click('활동 값만 다시 적용')
 assert.equal(text,initial+'# concurrent other writer\n');checks.push('conflict did not overwrite file')
 await click('활동 설정 저장');await activity().getByText(/파일 설정: 꺼짐/).waitFor()
 await activity().getByText(/관측 상태: off/).waitFor()
 assert.equal(text,initial.replace('enabled = true','enabled = false')+'# concurrent other writer\n')
 assert.equal(mutations.filter(x=>x.path==='/api/v1/runtime/config/raw').at(-1).body.expected_source_revision,concurrentRevision)
 checks.push('reapply preserved candidates, comment and concurrent edit with current CAS')
 await page.screenshot({path:out+'activity-off-saved.png',fullPage:true})
 await click('Fixture Runtime');await page.getByTestId('runtime-toml-source').waitFor()
 assert.equal(await page.getByTestId('runtime-toml-source').inputValue(),rawDraft)
 assert.equal(await page.getByTestId('runtime-toml-save').isDisabled(),true);checks.push('raw editor draft retained and old save basis invalidated')
 const runtimeReading=readback();await page.getByTestId('runtime-toml-nav-lanes').click()
 const runtimeLane=page.getByTestId('exact-lane-librarian_exact')
 await runtimeReading
 await runtimeLane.getByText(/관측 상태: off/).waitFor()
 await page.waitForFunction(()=>!document.querySelector('[data-testid="exact-lane-librarian_exact"] [role=switch]')?.disabled)
 assert.equal(await runtimeLane.getByRole('switch').getAttribute('aria-checked'),'false');checks.push('Runtime Lane candidate screen shares activity control and fresh observation despite a retained raw draft')
 await open();await page.getByRole('switch').click();await click('활동 설정 저장')
 await activity().getByText(/파일 설정: 켜짐/).waitFor();await activity().getByText(/synthetic registry admission refused/).waitFor()
 assert.equal(await activity().getByText(/관측 상태: off/).count(),1);checks.push('stored On, live Off and kept receipt remain distinct')
 await page.screenshot({path:out+'activity-on-registry-kept.png',fullPage:true})
 await page.setViewportSize({width:390,height:844})
 await activity().scrollIntoViewIfNeeded();await page.screenshot({path:out+'activity-mobile.png'})
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);checks.push('mobile no horizontal overflow')
 await page.setViewportSize({width:1440,height:1000})
 // A setup resume can publish the registry after the file receipt and after
 // both observation consumers have been replaced by navigation.
 publishedOff=false
 let releaseResume
 resumeGate=new Promise(resolve=>{releaseResume=resolve})
 const runtimeReopen=readback();await click('Fixture Runtime');await runtimeReopen
 await runtimeLane.getByText(/관측 상태: idle/).waitFor()
 await page.waitForFunction(()=>!document.querySelector('[data-testid="exact-lane-librarian_exact"] [role=switch]')?.disabled)
 await runtimeLane.getByRole('switch').click()
 const resuming=page.waitForRequest(request=>request.url().endsWith('/api/v1/runtime/setup/resume'))
 await runtimeLane.getByRole('button',{name:'활동 설정 저장',exact:true}).click();await resuming
 await runtimeLane.getByRole('button',{name:'활동 설정 저장 중…',exact:true}).waitFor()
 await runtimeLane.getByText(/Exact registry 적용됨/).waitFor()
 checks.push('Runtime direct save keeps the open activity and receipt during delayed resume')
 await click('Fixture All Lanes');await click(`Inspect ${label}`)
 await activity().getByText(/관측 상태: idle/).waitFor()
 await click('Fixture Runtime');await runtimeLane.getByText(/관측 상태: idle/).waitFor()
 await runtimeLane.getByRole('button',{name:'활동 설정 저장 중…',exact:true}).waitFor()
 checks.push('Runtime remount retains the pending activity save and receipt')
 await click('Fixture All Lanes');await click(`Inspect ${label}`)
 await activity().getByText(/관측 상태: idle/).waitFor()
 releaseResume();await activity().getByText(/관측 상태: off/).waitFor()
 await activity().getByText(/파일 설정: 꺼짐/).waitFor()
 const finalRuntimeRead=readback();await click('Fixture Runtime');await finalRuntimeRead
 await runtimeLane.getByText(/관측 상태: off/).waitFor();await runtimeLane.getByText(/Exact registry 적용됨/).waitFor()
 checks.push('both remounted consumers show the post-resume observation with the activity still open')
 await runtimeLane.scrollIntoViewIfNeeded();await page.screenshot({path:out+'activity-runtime-resumed.png'})
 assert.equal(mutations.filter(x=>x.path==='/api/v1/runtime/config/raw').length,4)
 assert.equal(mutations.filter(x=>x.path==='/api/v1/runtime/config/raw/preview').length,4)
 assert.equal(mutations.filter(x=>x.path==='/api/v1/runtime/setup/resume').length,3)
 assert.deepEqual(errors,[]);assert.deepEqual(unexpected,[]);checks.push('only 4 explicit save attempts, 3 resume calls; no page errors or unexpected routes')
 await writeFile(out+'browser-result.json',JSON.stringify({passed:true,browser:browser.version(),scope:'Actual Status/Lane activity/Runtime raw editor/router/API with synthetic HTTP. No backend, native TUI, model, CI or deployment.',checks,mutations,errors,unexpected},null,2)+'\n')
 console.log(`PASS: ${checks.length} Web activity browser checks`)
} catch(error) {
 await writeFile(out+'browser-failure.json',JSON.stringify({error:String(error),errors,unexpected,mutations,body:await page.locator('body').innerText()},null,2)+'\n');throw error
} finally {await browser.close();await server.close()}
