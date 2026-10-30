// Source component in Chromium, synthetic API only; no live MASC mutations.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
const [rootArg, outputArg] = process.argv.slice(2)
const root = resolve(rootArg), output = resolve(outputArg)
await mkdir(output)
const require = createRequire(resolve(root, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
const revision = char => ({ manifest: { state: 'sha256', value: char.repeat(64) }, runtime_assignment: { state: 'runtime_config_missing' } })
let config = {
  name: 'save-probe', config_revision: revision('a'),
  activation_mode: 'autonomous', input_policy: 'small', max_context_override: null,
  sandbox_profile: 'docker', network_mode: 'inherit', remote_endpoint: null,
  voice_always_allow: false, sandbox_roots: ['/synthetic'],
  prompt: { instructions: 'Original instructions', system_prompt_blocks: { system: { key: 'keeper', source: 'file', text: 'Synthetic shared system' } }, system_prompt: { state: 'available', effective: 'Synthetic prompt', assembled: 'Synthetic prompt' } },
  skills: { names: ['base-skill'] },
  execution: { models: ['fixture'], selected_runtime_id: 'tier-group.keeper_unified', runtime_options: ['tier-group.keeper_unified'] },
  runtime: { paused: false, registered: true, keepalive_running: true, fiber_health: 'healthy' },
  workspace: { mention_targets: ['fixture-peer'], board_interests: [], bound_workspace_ids: [] },
  sources: { live_meta_path: '/synthetic/live.json', default_source_kind: 'toml' },
}
let pending = null
const posts = [], errors = [], snapshots = []
let vite, browser
const send = (res, data) => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(data)) }
const receipt = { scope: 'Real KeeperConfigPanel source in Chromium with isolated synthetic API; not installed server acceptance.', passed: false }
try {
  vite = await createServer({ configFile: false, root, cacheDir: resolve(output, 'vite-cache'),
    server: { host: '127.0.0.1', port: 0 }, logLevel: 'error',
    plugins: [{ name: 'save-probe', configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url, 'http://localhost')
        if (url.pathname === '/__save_probe') {
          res.setHeader('Content-Type', 'text/html')
          res.end(await server.transformIndexHtml('/__save_probe', `<!doctype html><html lang="ko" data-skin="v2"><meta charset="utf-8"><title>Save response draft preservation — synthetic API</title>
          <style>body{background:#161a22;color:#eee;font:15px sans-serif}textarea{min-height:80px}.probe-note{position:fixed;bottom:8px;left:12px;z-index:10000;background:#202631;padding:8px}</style>
          <div id="fixture"></div><div class="probe-note">#31173 · 실제 소스 패널 · 격리 API</div>
          <script type="module">
          import {html} from 'htm/preact'; import {render} from 'preact';
          import {KeeperConfigPanel} from '/src/components/keeper-config-panel.ts';
          import {runtimeCatalogState} from '/src/lib/runtime-catalog-resource.ts';
          import '/src/styles/variables.css'; import '/src/styles/skin-v2.css'; import '/src/styles/keeper-v2/keeper-config.css';
          runtimeCatalogState.value={status:'loaded',data:[]};
          render(html\`<\${KeeperConfigPanel} keeperName="save-probe" />\`, document.getElementById('fixture'));
          </script></html>`))
        } else if (url.pathname === '/api/v1/keepers/save-probe/config') {
          if (req.method === 'POST') {
            let body = ''; for await (const chunk of req) body += chunk
            const payload = JSON.parse(body); posts.push(payload)
            pending = { res, payload }
          } else send(res, config)
        } else if (url.pathname === '/api/v1/dashboard/dev-token') send(res, { token: 'isolated-browser-fixture-token', actor: 'dashboard', role: 'admin' })
        else if (url.pathname.startsWith('/api/')) { res.statusCode = 404; send(res, { error: 'Outside the isolated config fixture' }) }
        else next()
      })
    } }],
  })
  await vite.listen()
  const origin = `http://127.0.0.1:${vite.httpServer.address().port}`
  browser = await chromium.launch({ args: ['--no-sandbox'] })
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } })
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort())
  const settle = async () => {
    assert.ok(pending)
    const {res,payload} = pending; pending = null
    config = { ...config, config_revision: revision(posts.length === 1 ? 'b' : posts.length === 2 ? 'c' : posts.length === 3 ? 'd' : 'e'), runtime_sync: 'lane_restarted' }
    if (payload.skills) config.skills = payload.skills
    if (payload.instructions !== undefined) config.prompt = { ...config.prompt, instructions: payload.instructions }
    if (payload.board_interests) config.workspace = { ...config.workspace, board_interests: payload.board_interests }
    send(res, config)
  }
  // Wait on observed HTTP arrival without making a wall-clock sleep the oracle.
  const waitArrival = async count => { for (let i = 0; posts.length < count && i < 200; i++) await new Promise(r => setTimeout(r, 10)); assert.equal(posts.length, count) }
  const capture = async name => { snapshots.push({ name, text: await page.locator('.kcf').innerText() }); await page.screenshot({ path: resolve(output, name + '.png') }) }
  await page.goto(origin + '/__save_probe')
  await page.getByRole('tab', { name: /실행 정책/ }).click()
  const skills = page.getByRole('textbox', { name: 'Skill 이름', exact: true })
  await skills.fill('first-skill')
  const runtimeSave = page.getByRole('button', { name: /Keeper 설정 저장/ })
  await runtimeSave.click(); await waitArrival(1)
  await skills.fill('second-skill')
  await capture('skills-pending')
  await settle(); await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(b => b.textContent.includes('Keeper 설정 저장') && !b.disabled))
  assert.equal(await skills.inputValue(), 'second-skill')
  await capture('skills-preserved')
  await runtimeSave.click(); await waitArrival(2)
  assert.deepEqual(posts[1].skills, { names: ['second-skill'] })
  assert.deepEqual(posts[1].expected_config_revision, revision('b'))
  await settle(); await page.waitForFunction(() => !Array.from(document.querySelectorAll('button')).some(b => b.textContent.includes('Keeper 설정 저장') && b.textContent.includes('중')))
  await page.getByRole('tab', { name: /권한·샌드박스/ }).click()
  await page.getByRole('textbox', { name: 'board_interests', exact: true }).fill('unsaved-interest')
  await page.getByRole('tab', { name: /프롬프트/ }).click()
  await page.getByRole('button', { name: '편집하기', exact: true }).click()
  const prompt = page.getByRole('textbox', { name: '지시사항', exact: true })
  await prompt.fill('First instructions'); await prompt.blur()
  await page.waitForFunction(() => document.querySelector('.kcf').textContent.includes('수정됨'))
  await page.getByRole('button', { name: '저장', exact: true }).click(); await waitArrival(3)
  await prompt.fill('Later instructions')
  assert.equal(await prompt.evaluate(el => document.activeElement === el), true)
  await settle(); await page.getByRole('button', { name: '저장', exact: true }).waitFor()
  await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(b => b.textContent === '저장' && !b.disabled))
  assert.equal(await prompt.inputValue(), 'Later instructions')
  await capture('prompt-preserved')
  await page.getByRole('button', { name: '저장', exact: true }).click(); await waitArrival(4)
  assert.equal(posts[3].instructions, 'Later instructions')
  assert.deepEqual(posts[3].expected_config_revision, revision('d'))
  await settle(); await page.getByRole('button', { name: '편집하기', exact: true }).waitFor()
  await page.getByRole('tab', { name: /권한·샌드박스/ }).click()
  assert.equal(await page.getByRole('textbox', { name: 'board_interests', exact: true }).inputValue(), 'unsaved-interest')
  await capture('runtime-unsaved-preserved')
  assert.deepEqual(errors, [])
  receipt.passed = true
} catch(error) { receipt.error = error.stack ?? String(error); process.exitCode = 1 }
finally {
  if (pending) pending.res.end('{}')
  await browser?.close(); await vite?.close()
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ ...receipt, posts, snapshots, errors }, null, 2) + '\n')
}
console.log(JSON.stringify(receipt))
