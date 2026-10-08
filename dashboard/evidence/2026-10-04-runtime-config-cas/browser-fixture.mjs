import { chromium } from 'playwright'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const out = fileURLToPath(new URL('.', import.meta.url))
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1200 } })
const pageErrors = [], consoleErrors = [], requests = [], unhandled = []
page.on('pageerror', error => pageErrors.push(error.message))
page.on('console', entry => { if (entry.type() === 'error') consoleErrors.push(entry.text()) })
const revisions = ['a', 'b', 'c', 'd'].map(x => x.repeat(64))
const path = '/synthetic/runtime.toml'
const source = '[runtime]\n# initial source\n'
let current = { source_path: path, source_text: source, source_revision: revisions[0] }
const config = () => ({ ok: true, path, file_name: 'runtime.toml', ...current,
  provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider',
    credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }],
  reserved_provider_ids: ['providers', 'models', 'runtime', 'voice', 'board', 'turn'],
})
const laneIds = ['board_attention_exact','hitl_auto_judge','librarian_exact','verifier_exact','workspace_curator_exact','browser_stagehand_exact','candle_appraiser']
const lanes = { schema: 'masc.standalone_llm_lanes.v2', generated_at:'2026-10-04T00:00:00Z', observed_at_unix:20,
  observation_only:true, exact_run_projection_count:0, exact_run_source_total:0, exact_run_projection_truncated:false,
  lanes:laneIds.map(lane_id=>({lane_id,label:lane_id,purpose:lane_id,required:false,observation_only:true,configured:true,
    configuration_state:'ready',admitted_slots:[],cli_slots:[],dropped_slots:[],declared_slots:[],declared_cli_slots:[],admission_error:null,
    status:'no_retained_observation',retained_run_count:0,running_count:0,succeeded_count:0,failed_count:0,cancelled_count:0,
    last_started_at:null,last_terminal_at:null,last_outcome:null,p50_elapsed_s:null,selected_slots:[],
    ...(lane_id==='board_attention_exact'?{jev:{state:'off'}}:{})})) }
let saveCount = 0
await page.route('**/api/**', async route => {
  const request = route.request(), pathname = new URL(request.url()).pathname
  if (!pathname.startsWith('/api/')) return route.continue()
  const send = (body,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)})
  if(pathname==='/api/v1/dashboard/dev-token') return send({token:'synthetic-fixture-token',actor:'dashboard',role:'admin'})
  if(pathname==='/api/v1/runtime/config/raw' && request.method()==='GET') return send(config())
  if(pathname==='/api/v1/runtime/config/raw' && request.method()==='POST') {
    requests.push(request.postDataJSON()); saveCount++
    if(saveCount===1) current={source_path:path,source_text:source+'# another writer B\n',source_revision:revisions[1]}
    if(saveCount===2) current={source_path:path,source_text:source+'# concurrent writer C\n',source_revision:revisions[2]}
    if(saveCount<=2) return send({error:'runtime.toml changed since the editor read it',code:'revision_conflict',current},409)
    return send({error:'synthetic storage result unavailable'},500)
  }
  if(pathname==='/api/v1/dashboard/standalone-lanes') return send(lanes)
  if(pathname==='/api/v1/runtime/resolved') return send({config_path:path,default_runtime:null,runtimes:[],lanes:[],assignments:[]})
  unhandled.push(pathname); return send({error:'unexpected fixture route'},500)
})
const testId = id => page.getByTestId(id)
try {
  await page.goto(process.env.CAS_FIXTURE_URL ?? 'http://127.0.0.1:5196/dashboard/evidence/2026-10-04-runtime-config-cas/fixture.html')
  await testId('runtime-toml-nav-toml').click()
  const editor=testId('runtime-toml-source'), draft=source+'# my unsaved draft\n'
  await editor.fill(draft)
  await testId('runtime-toml-save').click()
  await testId('runtime-toml-conflict').waitFor()
  assert.equal(await editor.inputValue(),draft)
  assert.equal(await testId('runtime-toml-save').isDisabled(),true)
  assert.deepEqual(requests,[{source_text:draft,expected_source_revision:revisions[0]}])
  await page.screenshot({path:out+'conflict.png',fullPage:true})
  await testId('runtime-toml-adopt-revision').click()
  assert.equal(await editor.inputValue(),draft)
  assert.equal(requests.length,1)
  await testId('runtime-toml-save').click()
  await testId('runtime-toml-conflict').waitFor()
  assert.equal(requests[1].expected_source_revision,revisions[1])
  assert.equal(await editor.inputValue(),draft)
  await testId('runtime-toml-replace-draft').click()
  assert.equal(await editor.inputValue(),current.source_text)
  assert.equal(await testId('runtime-toml-save').isDisabled(),true)
  const thirdDraft=current.source_text+'# keep after unknown result\n'
  await editor.fill(thirdDraft)
  current={...current,source_revision:revisions[3],source_text:source+'# server D\n'}
  await testId('runtime-toml-read-current').click()
  await testId('runtime-toml-conflict').waitFor()
  assert.equal(await editor.inputValue(),thirdDraft)
  assert.equal(requests.length,2)
  await testId('runtime-toml-adopt-revision').click()
  await testId('runtime-toml-save').click()
  await page.getByText(/파일 변경 여부를 확인하지 못했습니다/).waitFor()
  assert.equal(await editor.inputValue(),thirdDraft)
  assert.equal(requests[2].expected_source_revision,revisions[3])
  await page.screenshot({path:out+'unknown-result.png',fullPage:true})
  assert.deepEqual(pageErrors,[]); assert.deepEqual(unhandled,[])
  await writeFile(out+'browser-result.json',JSON.stringify({passed:true,browser:await browser.version(),scope:'Actual RuntimeTomlEditor and HTTP client with intercepted synthetic responses; no backend/native/deployment proof',requests,pageErrors,consoleErrors,unhandled,assertions:['409 preserves draft and disables unresolved save','first POST uses original revision','adoption does not POST or replace draft','explicit adoption uses shown revision; a subsequent writer conflicts again','separate replace changes draft and save baseline','read-current preserves draft','unknown result keeps draft and explains file uncertainty']},null,2)+'\n')
  console.log('PASS: actual Chromium component/API fixture, 7 assertions, 3 POSTs; expected HTTP 409/409/500')
} catch (error) {
  await writeFile(out+'browser-failure.json',JSON.stringify({message:String(error),pageErrors,consoleErrors,unhandled,url:page.url(),html:await page.content()},null,2)+'\n')
  throw error
} finally { await browser.close() }
