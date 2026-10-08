// Real source component, synthetic HTTP only. No backend or product build.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
const [dashboardArg, outputArg] = process.argv.slice(2)
assert.ok(dashboardArg && outputArg, 'DASHBOARD FRESH_OUTPUT_DIR required')
const dashboard = resolve(dashboardArg), output = resolve(outputArg)
await mkdir(output)
const require = createRequire(resolve(dashboard, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: tailwindcss } = await import(pathToFileURL(require.resolve('@tailwindcss/vite')).href)
const { chromium } = require('playwright')
const calls = [], errors = [], frames = []
let phase = 'paused', resume_phase = 'verifying', vite, browser
const actions = () => phase === 'paused' ? ['drop', 'reopen', 'resume', 'block']
  : phase === 'blocked' ? ['drop', 'reopen', 'pause', 'unblock'] : ['drop', 'reopen', 'pause', 'block']
const goal = () => ({
  id: 'goal-suspension-fixture', title: 'Goal 검증을 중단하고 이어서 진행',
  phase, resume_phase, criterion_revision: 'fixture-revision', priority: 2,
  metric: '성공한 검증 시나리오', target_value: '1', due_date: null,
  phase_color: '#eab308', measurement: { state: 'not_recorded' },
  goal_fsm: { state: phase, source: 'goal.phase', next_actions: actions(), activity_observation: 'goal_metadata' },
  tasks: [], children: [], task_count: 0, task_done_count: 0, child_count: 0,
  last_activity_at: '2026-10-04T00:00:00Z', stagnation_seconds: 0, linked_keeper_names: [], pending_approval_count: 0,
  created_at: '2026-10-04T00:00:00Z', updated_at: '2026-10-04T00:00:00Z',
})
const receipt = { scope: 'Production source GoalTree in Chromium with synthetic HTTP. Native backend evidence is separate. No live mutations.', passed: false }
try {
  vite = await createServer({ root: dashboard, configFile: false, server: { host: '127.0.0.1', port: 0 },
    plugins: [tailwindcss(), { name: 'goal-suspension-fixture', configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url, 'http://localhost')
        const send = data => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(data)) }
        if (url.pathname === '/__goal_suspension') {
          res.setHeader('Content-Type', 'text/html')
          res.end(await server.transformIndexHtml(url.pathname, '<!doctype html><html lang="ko" data-skin="v2"><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Goal suspension source fixture</title><style>body{padding:16px}main{max-width:1100px;margin:auto}</style><div id="fixture"></div><script type="module" src="/scripts/goal-suspension-browser-fixture.ts"></script></html>'))
        } else if (url.pathname === '/api/v1/dashboard/goals') {
          send({ approval_queue_state: { state: 'ready' }, tree: [goal()], summary: {
            total_goals: 1, active_goals: 0, phase_counts: { [phase]: 1 }, total_tasks: 0, done_tasks: 0, pending_approvals: 0,
          } })
        } else if (url.pathname === '/api/v1/dashboard/goals/detail') {
          send({ approval_queue_state: { state: 'ready' }, goal: goal(), linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] })
        } else if (url.pathname === '/mcp' && req.method === 'POST') {
          let raw = ''; for await (const chunk of req) raw += chunk
          const call = JSON.parse(raw)
          assert.equal(call.method, 'tools/call'); assert.equal(call.params.name, 'masc_goal_transition')
          const args = call.params.arguments; assert.equal(args.goal_id, 'goal-suspension-fixture'); assert.ok(actions().includes(args.action))
          calls.push(args)
          if (args.action === 'pause' || args.action === 'block') { resume_phase = resume_phase ?? phase; phase = args.action === 'pause' ? 'paused' : 'blocked' }
          else if (args.action === 'resume' || args.action === 'unblock') { phase = resume_phase; resume_phase = null }
          else assert.fail('unexpected fixture mutation')
          send({ jsonrpc: '2.0', id: call.id, result: { content: [{ type: 'text', text: JSON.stringify({ status: 'success', goal: goal() }) }] } })
        } else if (url.pathname.startsWith('/api/') || req.method !== 'GET') { res.statusCode = 404; send({error: 'fixture route not supported'}) }
        else next()
      })
    } }],
  })
  await vite.listen()
  const origin = `http://127.0.0.1:${vite.httpServer.address().port}`
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } })
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort())
  await page.goto(`${origin}/__goal_suspension`)
  async function capture(name, label) {
    await page.getByRole('button', { name: label, exact: true }).waitFor()
    const panel = page.locator('[data-goal-lifecycle-actions]')
    await panel.scrollIntoViewIfNeeded()
    const text = await panel.innerText()
    assert.match(text, /검증 중/)
    assert.equal(await page.getByRole('button', { name: 'Request completion', exact: true }).count(), 0)
    const geometry = await panel.boundingBox()
    assert.ok(geometry.x >= 0 && geometry.x + geometry.width <= page.viewportSize().width + 1)
    frames.push({ name, text, geometry, viewport: page.viewportSize() })
    await page.screenshot({path: resolve(output, name+'.png'), fullPage: true})
  }
  await capture('desktop-paused', 'Resume')
  await page.getByRole('button', { name: 'Block', exact: true }).click()
  await capture('desktop-blocked', 'Unblock')
  await page.getByRole('button', { name: 'Unblock', exact: true }).click()
  await page.getByRole('button', { name: 'Pause', exact: true }).waitFor()
  await page.waitForFunction(() => !document.querySelector('[data-goal-resume-phase]'))
  await page.getByRole('button', { name: 'Pause', exact: true }).click()
  await page.setViewportSize({width: 390, height: 844})
  await capture('mobile-paused', 'Resume')
  await page.getByRole('button', { name: 'Resume', exact: true }).click()
  await page.waitForFunction(() => !document.querySelector('[data-goal-resume-phase]'))
  assert.deepEqual(calls.map(call => call.action), ['block','unblock','pause','resume'])
  assert.deepEqual(errors, [])
  receipt.passed = true
} catch (error) { receipt.error = String(error); process.exitCode = 1 }
finally { await browser?.close(); await vite?.close(); await writeFile(resolve(output,'receipt.json'),JSON.stringify({...receipt,calls,errors,frames},null,2)+'\n') }
