// Real dashboard controls + HTTP serializers; isolated local response fixture.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
const root = resolve(process.argv[2])
const out = resolve(process.argv[3])
await mkdir(out, { recursive: true })
const require = createRequire(resolve(root, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
const statePath = '/src/components/flow-control/flow-control-state.ts'
const fixed = await readFile(resolve(root, '.' + statePath), 'utf8')
const main = await readFile(new URL('./main-flow-control-state.ts', import.meta.url), 'utf8')
const sourceHead = execFileSync('git', ['-C', resolve(root, '..'), 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim()
const receipts = []
const browser = await chromium.launch({ args: ['--no-sandbox'] })
try {
  for (const variant of ['main', 'fixed', 'fixed-readback-error', 'fixed-readback-mismatch']) {
    let paused = true
    let pending = null
    const events = []
    const vite = await createServer({ root, configFile: false, logLevel: 'error',
      cacheDir: resolve(out, 'vite-cache-' + variant), server: { host: '127.0.0.1', port: 0 },
      plugins: [{ name: 'isolated-namespace-fixture', enforce: 'pre',
        load(id) {
          if (id.endsWith(statePath)) return variant === 'main' ? main : fixed
          if (id.endsWith('/src/store.ts')) return `import {signal} from '@preact/signals';
            export const serverStatus=signal(null);
            export const shellAuthSummary=signal({effective_role:'admin',auth_error_code:null,auth_error_detail:null});`
          if (id.endsWith('/src/operator-store.ts')) return `import {signal} from '@preact/signals';
            export const operatorSnapshot=signal(null);
            export {runOperatorAction as dispatchOperatorAction,confirmOperatorAction as confirmOperatorPendingAction} from '/src/api/core.ts';`
          if (id.endsWith('/src/namespace-truth-store.ts')) return `import {signal} from '@preact/signals';
            import {fetchDashboardNamespaceTruth} from '/src/api/dashboard-hot.ts';
            export const namespaceTruth=signal({root:{status:{paused:true}}});
            export const namespaceTruthInitializing=signal(false),namespaceTruthError=signal(null);
            export async function refreshNamespaceTruth(){try{namespaceTruth.value=await fetchDashboardNamespaceTruth();namespaceTruthError.value=null}
              catch(e){namespaceTruth.value=null;namespaceTruthError.value=e.message}}`
          if (id.endsWith('/src/components/common/toast.ts')) return `
            export function showToast(message,tone){window.toasts.push({message,tone});document.getElementById('messages').textContent=message}
            export const showActionToast=showToast;`
        },
        configureServer(server) {
          server.middlewares.use(async (req, res, next) => {
            const path = new URL(req.url, 'http://fixture').pathname
            if (path === '/__probe') {
              res.setHeader('Content-Type', 'text/html')
              res.end(await server.transformIndexHtml(path, `<!doctype html><meta charset="utf-8"><title>Namespace Resume fixture</title>
                <style>body{margin:24px;background:#171c26;color:#eee;font:18px sans-serif}button{padding:12px;margin:8px;cursor:pointer}button:disabled{opacity:.4}h1{font-size:24px}[role=dialog]{border:2px solid #899;background:#242c3c;padding:24px}#messages{margin:16px}</style>
                <h1>Namespace Resume — ${variant}</h1><p>Isolated HTTP fixture; no deployed fleet is changed.</p><div id="root"></div><p id="messages"></p>
                <script type="module">
                  import {html} from 'htm/preact';import {render} from 'preact';
                  import {EmergencyStopControl} from '/src/components/emergency-stop-control.ts';
                  import {FlowControlPanel} from '/src/components/flow-control/flow-control-panel.ts';
                  import {ConfirmDialogOverlay} from '/src/components/common/confirm-dialog.ts';
                  import {setCanonicalDashboardActor} from '/src/lib/dashboard-session-actor.ts';
                  setCanonicalDashboardActor('fixture-operator');window.toasts=[];
                  render(html\`<\${EmergencyStopControl}/><\${FlowControlPanel}/><\${ConfirmDialogOverlay}/>\`,document.getElementById('root'));
                  window.ready=true;
                </script>`))
              return
            }
            if (!path.startsWith('/api/') && path !== '/mcp') return next()
            const chunks = []
            for await (const chunk of req) chunks.push(chunk)
            const raw = Buffer.concat(chunks).toString()
            const body = raw ? JSON.parse(raw) : null
            let response
            if (path === '/api/v1/operator/action') {
              assert.equal(body.actor, 'fixture-operator')
              assert.equal(body.target_type, 'workspace')
              assert.equal(body.action_type, 'namespace_resume')
              pending = body
              response = {status:'pending_confirm',confirm_required:true,confirm_token:'fixture-confirm'}
            } else if (path === '/api/v1/operator/confirm') {
              assert.ok(pending)
              assert.equal(body.actor, pending.actor)
              assert.equal(body.confirm_token, 'fixture-confirm')
              if (body.decision === 'confirm') paused = false
              pending = null
              response = {status: body.decision === 'confirm' ? 'ok' : 'denied'}
            } else if (path === '/api/v1/dashboard/project-snapshot') {
              response = {root:{status:{paused}}}
            } else if (path === '/mcp') {
              assert.equal(body.method, 'tools/call')
              if (body.params?.name === 'masc_pause_status') {
                assert.notEqual(variant, 'main')
                if (variant === 'fixed-readback-error') {
                  response = {jsonrpc:'2.0',id:body.id,error:{code:-32603,message:'Fixture pause status unavailable'}}
                } else {
                  // A new authoritative pause after resume can disagree.
                  if (variant === 'fixed-readback-mismatch') paused = true
                  const status = {ok:true,initializing:false,paused}
                  response = {jsonrpc:'2.0',id:body.id,result:{isError:false,
                    content:[{type:'text',text:JSON.stringify(status)}]}}
                }
              } else {
                assert.equal(variant, 'main')
                assert.equal(body.params?.name, 'masc_resume')
                response = {jsonrpc:'2.0',id:body.id,error:{code:-32601,message:'Unknown tool: masc_resume'}}
              }
            } else { response = {} }
            events.push({method:req.method,path,body,actorHeader:req.headers['x-masc-agent-name'],response})
            res.setHeader('Content-Type', 'application/json');res.end(JSON.stringify(response))
          })
        },
      }],
    })
    try {
      await vite.listen()
      const origin = 'http://127.0.0.1:' + vite.httpServer.address().port
      const page = await browser.newPage({ viewport: { width:1280,height:800 } })
      const errors=[];page.on('pageerror', e=>errors.push(e.message))
      await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort())
      await page.goto(origin + '/__probe?token=fixture-token&agent=fixture-operator')
      await page.waitForFunction(()=>window.ready)
      await page.getByRole('button',{name:'Resume',exact:true}).first().click()
      if (variant !== 'main') {
        await page.getByRole('dialog').waitFor()
        assert.equal(paused,true)
        await page.screenshot({path:resolve(out,variant+'-confirm.png')})
        await page.getByRole('dialog').getByRole('button',{name:'Resume',exact:true}).click()
        if (variant === 'fixed') {
          await page.waitForFunction(()=>window.toasts.some(t=>t.message==='Namespace resumed.' && t.tone==='success'))
          assert.equal(paused,false)
        } else if (variant === 'fixed-readback-error') {
          await page.waitForFunction(()=>window.toasts.some(t=>t.message==='Resume failed: Fixture pause status unavailable' && t.tone==='error'))
          assert.equal(paused,false)
        } else {
          await page.waitForFunction(()=>window.toasts.some(t=>t.message==='Resume sent; namespace state is paused.' && t.tone==='warning'))
          assert.equal(paused,true)
        }
        const toasts = await page.evaluate(()=>window.toasts)
        if (variant !== 'fixed') assert.ok(!toasts.some(t=>t.message==='Namespace resumed.' || t.tone==='success'))
        assert.deepEqual(events.map(e=>e.path),['/api/v1/operator/action','/api/v1/operator/confirm',
          '/api/v1/dashboard/project-snapshot','/mcp'])
        assert.equal(events.at(-1).body.params.name,'masc_pause_status')
      } else {
        await page.waitForFunction(()=>window.toasts.some(t=>t.tone==='error'))
        assert.equal(paused,true)
        assert.ok(events.some(e=>e.path==='/mcp' && e.body.params.name==='masc_resume'))
      }
      await page.screenshot({path:resolve(out,variant+'.png')})
      await page.setViewportSize({width:375,height:812})
      await page.screenshot({path:resolve(out,variant+'-375.png')})
      assert.deepEqual(errors,[])
      receipts.push({variant,paused,events,errors,toasts:await page.evaluate(()=>window.toasts)})
      await page.close()
    } finally { await vite.close() }
  }
} catch(e) { process.exitCode=1;receipts.push({error:e.stack}) }
finally {
  await browser.close()
  await writeFile(resolve(out,'receipt.json'), JSON.stringify({
    scope:'Actual controls and API serializers in Chromium; store projections and HTTP responses are fixtures. Not deployment evidence.',
    sourceHead,
    fixtureRole:'admin',
    fixtureSha256:createHash('sha256').update(await readFile(new URL('./browser.mjs', import.meta.url))).digest('hex'),
    originalSourceBase:'ae82a3b855cc5cb8c37a134ef01eebff35368bc3',
    mainSha256:createHash('sha256').update(main).digest('hex'),
    fixedSha256:createHash('sha256').update(fixed).digest('hex'),
    sourceUnchanged:fixed===await readFile(resolve(root,'.'+statePath),'utf8'),receipts,
  },null,2)+'\n')
}
console.log(JSON.stringify(receipts))
