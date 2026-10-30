import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import assert from 'node:assert/strict'

const [workspaceArg, nativeArg, outputArg, nativeRun, nativeHead] = process.argv.slice(2)
if (!workspaceArg || !nativeArg || !outputArg || !nativeRun || !nativeHead) {
  throw new Error('usage: scenario.mjs WORKSPACE NATIVE_ARTIFACT OUTPUT CI_RUN CI_HEAD')
}
const workspace = resolve(workspaceArg)
const dashboard = join(workspace, 'dashboard')
const nativeDir = resolve(nativeArg)
const outputDir = resolve(outputArg)
await mkdir(outputDir, { recursive: true })
const require = createRequire(join(dashboard, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
const manifest = JSON.parse(await readFile(join(nativeDir, 'manifest.json'), 'utf8'))
assert.equal(manifest.build?.binary_commit, nativeHead, 'native PNG fixture must identify its embedded binary commit')
const before = await readFile(join(nativeDir, 'before.png'))
const equipped = await readFile(join(nativeDir, 'equipped.png'))
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
assert.notEqual(sha(before), sha(equipped), 'native before/equipped PNGs must differ')
assert.notEqual(manifest.before_etag, manifest.equipped_etag, 'native ETags must differ')
const pngDimensions = bytes => {
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a')
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) }
}
const dimensions = pngDimensions(before)
assert.deepEqual(pngDimensions(equipped), dimensions)
assert.equal(dimensions.width, dimensions.height)
assert.equal(dimensions.width % 2, 0)
if (manifest.pixel_size !== undefined) assert.equal(dimensions.width, manifest.pixel_size)
const sizePx = dimensions.width / 2
const sourceHead = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: workspace, encoding: 'utf8' }).trim()
const nativeRunMetadata = JSON.parse(execFileSync('gh', ['run', 'view', nativeRun, '--json', 'headSha,status,conclusion,url'], { cwd: workspace, encoding: 'utf8' }))
assert.equal(nativeRunMetadata.headSha, nativeHead, 'native artifact run must name the requested source head')
const sourceFiles = [
  'dashboard/src/components/keeper-portrait.ts',
  'dashboard/src/api/schemas/keeper-portrait.ts',
  'dashboard/src/api/core.ts',
]
const sourceHashes = Object.fromEntries(await Promise.all(sourceFiles.map(async file => [file, sha(await readFile(join(workspace, file)))])))
const nativeComponentHashes = Object.fromEntries(sourceFiles.map(file => [file, sha(execFileSync('git', ['show', nativeHead+':'+file], {cwd:workspace}))]))
assert.deepEqual(sourceHashes, nativeComponentHashes, 'replayed component code must match the native fixture source')
const nativeLog = await readFile(join(nativeDir, 'native-fixture.log'), 'utf8')
const beforeRoster = JSON.parse(await readFile(join(nativeDir, 'before-roster.json'), 'utf8'))
const equippedRoster = JSON.parse(await readFile(join(nativeDir, 'equipped-roster.json'), 'utf8'))
const nativeReading = roster => {
  const row = roster.keepers.find(row=>row.name===manifest.keeper)
  assert.ok(row, 'native roster contains the same Keeper identity')
  assert.equal(row.portrait.state, 'ready')
  return row.portrait
}
const beforeReading = nativeReading(beforeRoster)
const equippedReading = nativeReading(equippedRoster)
assert.deepEqual(beforeReading.equipment,manifest.before)
assert.deepEqual(equippedReading.equipment,manifest.equipped)
const fixtureToken = 'isolated-portrait-fixture-token'
const evidence = {
  scope: 'Real browser executing the actual dashboard KeeperPortrait component; API fixture serves unchanged native HTTP-router CI PNGs. Not a live deployment or full dashboard navigation test.',
  source_head: sourceHead,
  source_dirty: execFileSync('git', ['status', '--porcelain'], {cwd:workspace,encoding:'utf8'}).trim() !== '',
  source_hashes: sourceHashes,
  native_component_hashes: nativeComponentHashes,
  harness_sha256: sha(await readFile(new URL(import.meta.url))),
  native_ci_run: nativeRun,
  native_ci_head: nativeHead,
  native_ci_metadata: nativeRunMetadata,
  native_manifest: manifest,
  native_fixture_log: nativeLog,
  native_roster_readings: {before:beforeReading, equipped:equippedReading},
  native_pngs: { before: { sha256: sha(before), ...dimensions }, equipped: { sha256: sha(equipped), ...dimensions } },
  browser: null,
  requests: [],
  browser_errors: [],
  screenshots: [],
  assertions: [],
}
let phase = 'before'
let releaseRecovery = null
let recoveryStartedResolve
const recoveryStarted = new Promise(resolve => { recoveryStartedResolve = resolve })
const entryPath = '/__candle_equipped_evidence.js'
const virtualId = '\0candle-equipped-portrait-evidence'
const fixtureData = JSON.stringify({ keeper: manifest.keeper, before: beforeReading, equipped: equippedReading, sizePx, token: fixtureToken })
const entry = `
import { h, render } from 'preact';
import { useState } from 'preact/hooks';
import { KeeperPortrait } from '/src/components/keeper-portrait.ts';
import { readKeeperPortrait } from '/src/api/schemas/keeper-portrait.ts';
import { setStoredToken } from '/src/api/core.ts';
const data = ${fixtureData};
setStoredToken(data.token);
const snapshots = {before: readKeeperPortrait(data.before), equipped: readKeeperPortrait(data.equipped), unavailable: readKeeperPortrait({state:'unavailable', reason:'Native ledger observation unavailable (controlled browser fixture)'})};
if (snapshots.before.state !== 'ready' || snapshots.equipped.state !== 'ready') throw new Error('native equipment manifest rejected by real dashboard decoder');
function Fixture() {
  const [state, setState] = useState('before');
  const reading = state === 'recovery' ? snapshots.equipped : snapshots[state];
  return h('main', {class:'evidence'}, [
    h('p', {class:'eyebrow'}, 'MASC · native HTTP payload / browser component fixture'),
    h('h1', {}, 'Equipped Keeper portrait'),
    h('p', {class:'scope'}, 'Real KeeperPortrait component; native CI PNG bytes. Isolated fixture — no live server.'),
    h('section', {class:'card'}, [
      h('div', {class:'portrait-cell'}, h(KeeperPortrait, {name:data.keeper, reading, sizePx:data.sizePx, fallback:h('span', {'data-testid':'portrait-fallback', class:'fallback'}, 'P')})),
      h('div', {class:'details'}, [h('h2', {}, data.keeper), h('p', {'data-testid':'fixture-phase'}, state), h('p', {'data-testid':'equipment-reading'}, reading.state === 'ready' ? Object.entries(reading.equipment).map(([slot,item]) => slot+': '+item).join(' · ') : reading.reason)]),
    ]),
    h('nav', {class:'controls', 'aria-label':'Fixture observation controls'}, ['before','equipped','unavailable','recovery'].map(name => h('button', {'data-testid':'show-'+name, onClick:() => setState(name), 'aria-pressed':state===name}, name))),
    h('p', {class:'note'}, 'Recovery reuses the equipped snapshot and holds the image response until the loading state is captured.'),
  ]);
}
render(h(Fixture), document.getElementById('app'));
window.__fixtureReady = true;
`
const html = `<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Equipped portrait evidence</title><style>
*{box-sizing:border-box}body{margin:0;background:#0d1420;color:#edf3fa;font-family:system-ui,sans-serif}.evidence{max-width:980px;margin:0 auto;padding:44px 36px}.eyebrow{text-transform:uppercase;font-size:11px;letter-spacing:.08em;color:#8fa7c4}h1{font-size:30px;margin:14px 0}.scope,.note{color:#a3b4c9;line-height:1.6;font-size:14px}.card{margin:32px 0 24px;background:#172333;border:1px solid #32465f;border-radius:16px;min-height:208px;display:flex;align-items:center;gap:32px;padding:24px}.portrait-cell{width:176px;height:152px;display:flex;align-items:center;justify-content:center;background:#0b1420;border-radius:12px;flex-shrink:0}.portrait-cell>*{transform:scale(2);transform-origin:center}.portrait-cell img{display:block}.details h2{font-size:20px;margin:0 0 12px}.details p{line-height:1.7;font-size:13px;color:#b3c9e2;overflow-wrap:anywhere}.details [data-testid=fixture-phase]{font-size:16px;color:#7edbbe;font-weight:700;text-transform:uppercase}.fallback{font-size:26px;display:grid;place-items:center;width:${sizePx}px;height:${sizePx}px;background:#294664;color:#cee6ff;border-radius:50%}.controls{display:flex;gap:10px;flex-wrap:wrap}button{border:1px solid #38516c;border-radius:8px;background:#172333;color:#dceafb;padding:10px 16px;font-size:13px;cursor:pointer}button[aria-pressed=true]{background:#215448;border-color:#3f9c84;color:#ecfff8}.block{display:block}.shrink-0{flex-shrink:0}.rounded-full{border-radius:9999px}[data-testid=keeper-portrait-loading]{background:#1e334c;border:1px dashed #6083a9}
</style></head><body><div id="app"></div><script type="module" src="${entryPath}"></script></body></html>`
const plugin = {
  name: 'isolated-candle-portrait-evidence',
  enforce: 'pre',
  resolveId(id) { if (id === entryPath) return virtualId },
  load(id) { if (id === virtualId) return entry },
  configureServer(server) {
    server.middlewares.use(async (req, res, next) => {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      if (url.pathname === '/dashboard/__candle_equipped_evidence.html') {
        try {
          const transformed = await server.transformIndexHtml(url.pathname, html)
          res.writeHead(200, {'Content-Type':'text/html; charset=utf-8'})
          res.end(transformed)
        } catch (error) { next(error) }
        return
      }
      if (url.pathname.startsWith('/api/')) {
        const expected = '/api/v1/keepers/' + encodeURIComponent(manifest.keeper) + '/portrait.png'
        if (url.pathname !== expected || url.searchParams.get('size') !== String(dimensions.width)) {
          res.writeHead(400); res.end('unexpected fixture API path'); return
        }
        const record = {index:evidence.requests.length, phase, url:req.url, authorization_matches_fixture:req.headers.authorization === 'Bearer '+fixtureToken, cache_control:req.headers['cache-control'] ?? null, pragma:req.headers.pragma ?? null, if_none_match:req.headers['if-none-match']??null, served:false}
        evidence.requests.push(record)
        const bytes = phase === 'before' ? before : equipped
        const respond = () => {
          record.served = true
          record.body_sha256 = sha(bytes)
          res.writeHead(200, {'Content-Type':'image/png', 'Cache-Control':'no-cache', ETag:phase==='before'?manifest.before_etag:manifest.equipped_etag})
          res.end(bytes)
        }
        if (phase === 'recovery') { releaseRecovery=respond; recoveryStartedResolve() }
        else respond()
        return
      }
      next()
    })
  },
}
process.env.MASC_DASHBOARD_PROXY_TARGET = 'http://127.0.0.1:1'
const server = await createServer({root:dashboard, configFile:join(dashboard,'vite.config.ts'), plugins:[plugin], server:{host:'127.0.0.1',port:0,strictPort:false}, logLevel:'warn'})
let browser
let page
try {
  await server.listen()
  const address = server.httpServer.address()
  assert.equal(typeof address, 'object')
  browser = await chromium.launch({headless:true})
  evidence.browser = {name:'Chromium', version:browser.version(), viewport:{width:1000,height:650}, device_scale_factor:2}
  page = await browser.newPage({viewport:evidence.browser.viewport, deviceScaleFactor:2})
  page.setDefaultTimeout(20000)
  page.on('pageerror', error => evidence.browser_errors.push(error.message))
  await page.addInitScript(() => {
    window.__portraitUrls = {created:[],revoked:[]}
    window.__portraitFetches = []
    const fetchActual = window.fetch.bind(window)
    window.fetch = (input, init) => {
      window.__portraitFetches.push({url:String(input), cache:init?.cache ?? null})
      return fetchActual(input, init)
    }
    const create = URL.createObjectURL.bind(URL)
    const revoke = URL.revokeObjectURL.bind(URL)
    URL.createObjectURL = blob => {
      const url = create(blob)
      const record={url,size:blob.size,type:blob.type,sha256:null}
      window.__portraitUrls.created.push(record)
      blob.arrayBuffer().then(buffer=>crypto.subtle.digest('SHA-256',buffer)).then(digest=>{record.sha256=Array.from(new Uint8Array(digest)).map(x=>x.toString(16).padStart(2,'0')).join('')})
      return url
    }
    URL.revokeObjectURL = url => {window.__portraitUrls.revoked.push(url); return revoke(url)}
  })
  const screenshot = async name => {
    const file = name+'.png'
    await page.screenshot({path:join(outputDir,file),fullPage:true})
    evidence.screenshots.push({name,file,sha256:sha(await readFile(join(outputDir,file)))})
  }
  const loaded = async (count, hash) => {
    await page.waitForFunction(({count,hash})=>{
      const img=document.querySelector('img[data-testid="keeper-portrait"]')
      const urls=window.__portraitUrls
      return img instanceof HTMLImageElement && img.complete && img.naturalWidth>0 && urls.created.length===count && urls.created[count-1].sha256===hash && img.src===urls.created[count-1].url
    },{count,hash})
  }
  await page.goto('http://127.0.0.1:'+address.port+'/dashboard/__candle_equipped_evidence.html')
  await page.waitForFunction(()=>window.__fixtureReady===true)
  await loaded(1,sha(before))
  await screenshot('01-before')
  evidence.assertions.push('initial rendered image blob equals the native before PNG')
  phase='equipped'
  await page.getByTestId('show-equipped').click()
  await loaded(2,sha(equipped))
  await page.waitForFunction(()=>window.__portraitUrls.revoked.length===1)
  await screenshot('02-equipped')
  evidence.assertions.push('same Keeper equipment change requests fresh bytes and revokes the old blob')
  phase='unavailable'
  await page.getByTestId('show-unavailable').click()
  await page.getByTestId('keeper-portrait-unavailable').waitFor()
  await page.waitForFunction(()=>window.__portraitUrls.revoked.length===2)
  assert.equal(await page.getByTestId('keeper-portrait').count(),0)
  assert.equal(evidence.requests.length,2)
  await screenshot('03-unavailable')
  evidence.assertions.push('Unavailable removes the prior picture, revokes its URL, and performs no PNG request')
  phase='recovery'
  await page.getByTestId('show-recovery').click()
  await page.getByTestId('keeper-portrait-loading').waitFor()
  let recoveryGuard
  try {
    await Promise.race([recoveryStarted, new Promise((_, reject) => {
      recoveryGuard = setTimeout(() => reject(new Error('recovery did not request native PNG within the browser test deadline')), 20000)
    })])
  } finally { clearTimeout(recoveryGuard) }
  assert.equal(await page.getByTestId('keeper-portrait').count(),0)
  assert.equal(evidence.requests.length,3)
  assert.equal(evidence.requests[2].served,false)
  await screenshot('04-recovery-loading')
  evidence.assertions.push('same-equipment recovery shows loading without a stale revoked image while response is held')
  releaseRecovery()
  await loaded(3,sha(equipped))
  await screenshot('05-recovered')
  evidence.assertions.push('recovered blob contains exactly the same native equipped PNG bytes')
  const urls=await page.evaluate(()=>window.__portraitUrls)
  assert.deepEqual(urls.revoked,urls.created.slice(0,2).map(x=>x.url))
  assert.equal(new Set(urls.created.map(x=>x.url)).size,3)
  assert.equal(evidence.requests.every(x=>x.authorization_matches_fixture),true)
  const fetches=await page.evaluate(()=>window.__portraitFetches)
  assert.equal(fetches.length,3)
  assert.equal(fetches.every(x=>x.cache==='no-cache'),true)
  evidence.fetch_options=fetches
  assert.equal(new Set(evidence.requests.map(x=>x.url)).size,1)
  assert.deepEqual(evidence.browser_errors,[])
  evidence.object_urls=urls
  evidence.assertions.push('all three requests retain auth/no-cache, use the same Keeper URL, and all blobs have distinct object URLs')
  const sourceHashesAfter = Object.fromEntries(await Promise.all(sourceFiles.map(async file => [file,sha(await readFile(join(workspace,file)))])))
  assert.deepEqual(sourceHashesAfter,sourceHashes,'component source changed during browser capture')
  evidence.status='passed'
  await writeFile(join(outputDir,'evidence.json'),JSON.stringify(evidence,null,2)+'\n')
  console.log(JSON.stringify({status:evidence.status,output_dir:outputDir,requests:evidence.requests.length,screenshots:evidence.screenshots.length,source_head:sourceHead,native_ci_head:nativeHead},null,2))
} catch (error) {
  evidence.status='failed'
  evidence.failure={message:error.message,stack:error.stack}
  if (page) await page.screenshot({path:join(outputDir,'failure.png'),fullPage:true}).catch(()=>{})
  await writeFile(join(outputDir,'evidence.json'),JSON.stringify(evidence,null,2)+'\n')
  throw error
} finally {
  if (browser) await browser.close()
  await server.close()
}
