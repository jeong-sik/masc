import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import assert from 'node:assert/strict'

const [workspaceArg, outputArg] = process.argv.slice(2)
if (!workspaceArg || !outputArg) throw new Error('usage: scenario.mjs WORKSPACE OUTPUT')
const workspace = resolve(workspaceArg)
const dashboard = join(workspace, 'dashboard')
const outputDir = resolve(outputArg)
await mkdir(outputDir, { recursive: true })
const require = createRequire(join(dashboard, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
const git = (...args) => execFileSync('git', args, {cwd:workspace,encoding:'utf8'}).trim()
const sourceFiles = [
  'dashboard/src/components/candle-economy.ts',
  'dashboard/src/components/overview/overview.ts',
  'dashboard/src/components/keeper-detail-page.ts',
  'dashboard/src/components/keeper-detail-shell.ts',
  'dashboard/src/components/keeper-detail-lifecycle.ts',
  'dashboard/src/api/schemas/candle-observation.ts',
  'dashboard/src/api/dashboard-execution.ts',
  'dashboard/src/store.ts',
  'dashboard/src/keeper-store-normalize.ts',
  'dashboard/src/main.ts',
  'dashboard/vite.config.ts',
  'dashboard/pnpm-lock.yaml',
]
const hashes = async () => Object.fromEntries(await Promise.all(sourceFiles.map(async file => [file,sha(await readFile(join(workspace,file)))])))
const sourceHashes = await hashes()
const evidence = {
  scope:'Actual production Overview and KeeperDetailPage in Chromium via Vite dev. Currency is synthetic HTTP fixture JSON, not native ledger output or live server evidence. The actual execution fetch, decoder/store and production UI render every transition.',
  source_head:git('rev-parse','HEAD'), source_dirty:git('status','--porcelain') !== '',
  source_hashes:sourceHashes, requests:[], screenshots:[], browser_errors:[],
  console_diagnostics:[], blocked_external_requests:[], assertions:[],
}
evidence.harness_sha256=sha(await readFile(new URL(import.meta.url)))
const keeper = 'candle-browser-fixture'
const ready = {status:'ready',issued_milli:'18014398509481987',burned_milli:'9007199254740994',circulating_milli:'9007199254740993'}
assert.equal(BigInt(ready.issued_milli),BigInt(ready.burned_milli)+BigInt(ready.circulating_milli))
for (const amount of Object.values(ready).slice(1)) assert.ok(BigInt(amount)>BigInt(Number.MAX_SAFE_INTEGER))
const expected = {issued:'18014398509481.987 Candle',burned:'9007199254740.994 Candle',circulating:'9007199254740.993 Candle',balance:'잔액 9007199254740.993 Candle'}
let phase='ready'
let generation=0
const responseFor = () => {
  const candle = phase==='disabled' ? {status:'disabled',reason:'Controlled fixture: ledger unreadable'}
    : phase==='off' ? {status:'off'} : ready
  const balance = phase==='disabled'||phase==='off' ? null
    : phase==='malformed' ? 9007199254740992 : '9007199254740993'
  return {execution_publication_epoch:'candle-browser-evidence',execution_publication_generation:++generation,
    generated_at:new Date().toISOString(),candle,
    status:{status:'running',project:'isolated-candle-browser-fixture'},
    agents:[],tasks:[],messages:[],task_counts:{total:0},
    keepers:[{name:keeper,emoji:'◈',status:'active',health:'healthy',phase:'running',lifecycle_phase:'running',paused:false,keepalive_running:true,
      activation_mode:'autonomous',runtime_id:'fixture.model',pipeline_stage:'idle',runtime_blocker_summary:null,
      portrait:{state:'unavailable',reason:'Portrait PNG is outside this currency fixture'},candle_balance_milli:balance}],
  }
}
const entryPath='/__candle_economy_evidence.js'
const virtualId='\0candle-economy-evidence'
const mainSource=await readFile(join(dashboard,'src/main.ts'),'utf8')
// Keep the production entry's CSS order without mounting its App or starting
// unrelated global transports. No production module is mocked/replaced.
const cssImports=mainSource.split('\n').filter(line=>/^import .*\.css'/.test(line)||line.startsWith("import.meta.glob('./styles/"))
  .map(line=>line.replaceAll("'./styles/","'/src/styles/")).join('\n')
const entry=`
${cssImports}
import {h,render} from 'preact';
import {useState} from 'preact/hooks';
import {Overview} from '/src/components/overview/overview.ts';
import {KeeperDetailPage} from '/src/components/keeper-detail-page.ts';
import {route} from '/src/router.ts';
import {fetchDashboardExecution} from '/src/api/dashboard-execution.ts';
import {hydrateExecutionSnapshot,keepers,candleObservation} from '/src/store.ts';
import {setStoredToken} from '/src/api/core.ts';
setStoredToken('isolated-candle-evidence-token');
const keeper=${JSON.stringify(keeper)};
window.__currencyEvidence={reads:[],errors:[]};
async function refresh() {
 const raw=await fetchDashboardExecution({force:true});
 const accepted=hydrateExecutionSnapshot(raw);
 window.__currencyEvidence.reads.push({raw,accepted,reading:candleObservation.peek(),keeper:keepers.peek()[0]});
 if(!accepted)throw new Error('fixture publication was not admitted');
 return raw;
}
window.__currencyEvidence.refresh=refresh;
function Fixture(){
 const [surface,setSurface]=useState('overview');
 const go=next=>{route.value={tab:next==='overview'?'overview':'keepers',params:next==='overview'?{}:{keeper},postId:null};setSurface(next)};
 return h('div',{class:'v2-app', 'data-density':'comfortable'},[
   h('header',{class:'fixture-header'},[
     h('strong',{},'Candle · controlled API fixture'),
     h('span',{},'Synthetic amounts · actual production screens · no live server'),
     h('button',{'data-testid':'surface-overview',onClick:()=>go('overview')},'Overview'),
     h('button',{'data-testid':'surface-keeper',onClick:()=>go('keeper')},'Keeper detail'),
   ]),
   h('div',{class:'fixture-surface','data-testid':'fixture-surface','data-surface':surface},surface==='overview'?h(Overview):h(KeeperDetailPage)),
 ]);
}
refresh().then(()=>{render(h(Fixture),document.getElementById('app'));window.__fixtureReady=true}).catch(error=>{window.__currencyEvidence.errors.push(error.message);throw error});
`
const html=`<!doctype html><html lang="ko" data-skin="v2" data-volt="brass" data-tone="tempered"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Candle economy browser evidence</title><style>
.fixture-header{height:70px;padding:12px 20px;display:flex;gap:16px;align-items:center;border-bottom:1px solid #45413c;background:#181817;font:12px system-ui,sans-serif;color:#dedbd4;flex-shrink:0}.fixture-header span{flex:1;color:#aba69d}.fixture-header button{padding:7px 12px;border:1px solid #74694f;background:#26231d;border-radius:5px;color:#eee6d6}.fixture-surface{height:calc(100vh - 70px);min-height:0;overflow:auto}.fixture-surface>.kw-grid{height:100%}.fixture-surface>.ov{height:100%}#app>.v2-app{height:100vh;display:flex;flex-direction:column}
</style></head><body><div id="app"></div><script type="module" src="${entryPath}"></script></body></html>`
const plugin={name:'isolated-candle-economy-evidence',enforce:'pre',
 resolveId(id){if(id===entryPath)return virtualId},load(id){if(id===virtualId)return entry},
 configureServer(server){server.middlewares.use(async(req,res,next)=>{
  const url=new URL(req.url??'/','http://127.0.0.1')
  if(url.pathname==='/dashboard/__candle_economy_evidence.html'){
    try{res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(await server.transformIndexHtml(url.pathname,html))}catch(error){next(error)}return
  }
  if(url.pathname.startsWith('/api/')||['/health','/mcp','/sse','/ws','/yjs'].includes(url.pathname)){
    let status=200;let body
    if(url.pathname==='/api/v1/dashboard/execution'&&req.method==='GET')body=responseFor()
    else if(url.pathname==='/health')body={status:'ok',fixture_scope:'isolated UI only'}
    else if(url.pathname.endsWith('/transitions'))body={transitions:[]}
    else if(url.pathname.endsWith('/chat/history'))body=[]
    else if(url.pathname.endsWith('/chat/operations'))body={operations:[]}
    else if(url.pathname.endsWith('/tool-approvals'))body={approvals:[]}
    else {status=503;body={error:'Auxiliary surface is outside the controlled currency fixture'}}
    const encoded=JSON.stringify(body)
    evidence.requests.push({phase,method:req.method,url:req.url,status,body,body_sha256:sha(encoded),authorization_matches_fixture:req.headers.authorization==='Bearer isolated-candle-evidence-token'})
    res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(encoded);return
  }
  next()
 })},
}
process.env.MASC_DASHBOARD_PROXY_TARGET='http://127.0.0.1:1'
const server=await createServer({root:dashboard,configFile:join(dashboard,'vite.config.ts'),plugins:[plugin],server:{host:'127.0.0.1',port:0},logLevel:'warn'})
let browser,page
try{
 await server.listen()
 const port=server.httpServer.address().port
 browser=await chromium.launch({headless:true})
 evidence.browser={name:'Chromium',version:browser.version(),viewport:{width:1500,height:1050},device_scale_factor:1}
 page=await browser.newPage({viewport:evidence.browser.viewport,deviceScaleFactor:1})
 page.setDefaultTimeout(20000)
 page.on('pageerror',error=>evidence.browser_errors.push(error.message))
 page.on('console',message=>{if(['error','warning'].includes(message.type()))evidence.console_diagnostics.push({type:message.type(),text:message.text()})})
 await page.route('**/*',route=>{
   const url=new URL(route.request().url())
   if(['127.0.0.1','localhost'].includes(url.hostname)||['data:','blob:'].includes(url.protocol))return route.continue()
   evidence.blocked_external_requests.push(url.toString());return route.abort()
 })
 const shot=async name=>{
  const file=name+'.png';await page.screenshot({path:join(outputDir,file),fullPage:true})
  evidence.screenshots.push({name,file,sha256:sha(await readFile(join(outputDir,file)))})
 }
 const overview=async()=>{await page.getByTestId('surface-overview').click();await page.getByTestId('overview-surface').waitFor()}
 const detail=async()=>{
   await page.getByTestId('surface-keeper').click()
   await page.getByTestId('kw-chat-command-menu-toggle').click()
   await page.getByTestId('kw-chat-command-detail').click()
   await page.locator('#keeper-detail-title-'+keeper).waitFor()
   await page.getByRole('tab',{name:'대화',exact:true}).waitFor()
 }
 const control=async()=>{
   const shutdown=page.getByRole('button',{name:'종료하기',exact:true})
   assert.equal(await shutdown.isVisible(),true)
   assert.equal(await shutdown.isEnabled(),true)
   assert.equal(await page.locator('#keeper-detail-title-'+keeper).textContent(),keeper)
 }
 const refresh=async next=>{
   phase=next
   await page.evaluate(()=>window.__currencyEvidence.refresh())
   await page.waitForFunction(expected=>window.__currencyEvidence.reads.at(-1)?.raw.candle.status===expected, next==='disabled'?'disabled':next==='off'?'off':'ready')
 }
 await page.goto('http://127.0.0.1:'+port+'/dashboard/__candle_economy_evidence.html')
 await page.waitForFunction(()=>window.__fixtureReady===true)
 const summary=page.getByTestId('candle-summary')
 await summary.waitFor()
 for(const text of [expected.issued,expected.burned,expected.circulating])assert.ok((await summary.textContent()).includes(text))
 await shot('01-ready-overview')
 await detail();await control()
 assert.equal(await page.getByTestId('keeper-candle-balance').textContent(),expected.balance)
 await shot('02-ready-keeper')
 evidence.assertions.push('Actual Overview shows all three synthetic totals exactly; actual KeeperDetailPage shows >JS53 balance and enabled lifecycle control')
 await refresh('disabled');await control()
 await page.getByTestId('keeper-candle-balance').filter({hasText:'Controlled fixture: ledger unreadable'}).waitFor()
 assert.ok(!(await page.getByTestId('keeper-candle-balance').textContent()).includes('9007199254740.993'))
 await shot('03-disabled-keeper')
 await overview();assert.ok((await summary.textContent()).includes('사용 중지'));await shot('04-disabled-overview')
 await refresh('malformed');await summary.filter({hasText:'조회 불가'}).waitFor()
 assert.ok(!(await summary.textContent()).includes(expected.issued));await shot('05-malformed-overview')
 await detail();await control()
 assert.ok((await page.getByTestId('keeper-candle-balance').textContent()).includes('조회 불가'))
 await shot('06-malformed-keeper')
 evidence.assertions.push('Disabled and malformed execution observations withdraw amounts while the same Keeper remains present and its lifecycle control remains enabled')
 await refresh('off');await control()
 await page.getByTestId('keeper-candle-balance').waitFor({state:'detached'})
 await shot('07-off-keeper')
 await overview();assert.equal(await summary.count(),0);await shot('08-off-overview')
 evidence.assertions.push('Off hides currency panels while preserving the ordinary Keeper interface')
 evidence.observations=await page.evaluate(()=>({reads:window.__currencyEvidence.reads,errors:window.__currencyEvidence.errors}))
 assert.deepEqual(evidence.observations.errors,[])
 assert.deepEqual(evidence.browser_errors,[])
 assert.deepEqual(await hashes(),sourceHashes,'production modules changed during capture')
 evidence.production_module_requests=[...server.moduleGraph.idToModuleMap.values()].map(x=>x.file).filter(x=>x?.startsWith(join(dashboard,'src')))
 evidence.source_head_after=git('rev-parse','HEAD')
 evidence.status='passed'
 await writeFile(join(outputDir,'evidence.json'),JSON.stringify(evidence,null,2)+'\n')
 console.log(JSON.stringify({status:evidence.status,output_dir:outputDir,screenshots:evidence.screenshots.length,requests:evidence.requests.length,browser_errors:evidence.browser_errors},null,2))
}catch(error){
 evidence.status='failed';evidence.failure={message:error.message,stack:error.stack}
 if(page)await page.screenshot({path:join(outputDir,'failure.png'),fullPage:true}).catch(()=>{})
 await writeFile(join(outputDir,'evidence.json'),JSON.stringify(evidence,null,2)+'\n')
 throw error
}finally{if(browser)await browser.close();await server.close()}
