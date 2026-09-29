import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join, resolve } from 'node:path'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'

const [workspaceArg, measuredArg, outputArg, mode] = process.argv.slice(2)
if (!workspaceArg || !measuredArg || !outputArg || !['before', 'after'].includes(mode)) {
  throw new Error('usage: replay.mjs WORKSPACE MEASURED_DIR OUTPUT before|after')
}
const workspace = resolve(workspaceArg)
const dashboard = join(workspace, 'dashboard')
const measured = resolve(measuredArg)
const output = resolve(outputArg)
await mkdir(output, { recursive: true })
const require = createRequire(join(dashboard, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const nativeMetadata = JSON.parse(await readFile(join(measured, 'metadata.json'), 'utf8'))
const available = (await readFile(join(measured, 'results.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse)
const rows = ['grade', 'relation', 'weights'].map(stage => {
  const row = available.find(row => row.stage === stage && row.trial === 1 && row.status === 'ok')
  assert.ok(row, `a real completed ${stage} response must exist`)
  assert.equal(row.receipt.input.payload.stage, stage)
  assert.equal(row.receipt.lane, 'candle_appraiser')
  assert.equal(row.receipt.status, 'succeeded')
  assert.deepEqual(row.answer, row.receipt.output.result)
  return row
})
assert.equal(new Set(rows.map(row => row.receipt.run_id)).size, 3)
assert.equal(new Set(rows.map(row => row.receipt.actor)).size, 1)
assert.equal(new Set(rows.map(row => row.receipt.selected_slot)).size, 1)
const actor = rows[0].receipt.actor
const slot = rows[0].receipt.selected_slot
const summaries = rows.map(({ receipt }) => {
  const { input, output, payload_availability, ...summary } = receipt
  return { ...summary, run_kind: 'exact_output' }
}).sort((a, b) => b.started_at - a.started_at)
const details = new Map(rows.map(({ receipt }) => [receipt.run_id, {
  ...receipt, run_kind: 'exact_output', skill_evidence: { state: 'no_keeper_skills' },
}]))
const observedAt = Math.max(...rows.map(row => row.receipt.started_at + row.receipt.elapsed_s))
const generatedAt = new Date(observedAt * 1000).toISOString()
const laneNames = [
  ['board_attention_exact', 'Board Attention', true],
  ['hitl_auto_judge', 'Auto Judge', true],
  ['librarian_exact', 'Librarian', false],
  ['workspace_curator_exact', 'Workspace Curator', false],
  ['verifier_exact', 'Verifier', false],
  ['browser_stagehand_exact', 'Browser Stagehand', false],
  ['candle_appraiser', 'Candle Appraiser', false],
]
const lanes = laneNames.map(([id, label, required]) => {
  const included = id === 'candle_appraiser'
  return {
    lane_id: id, label, required, observation_only: true,
    purpose: included ? 'Replay of three measured Grade, Relation and Weights receipts' : 'Not measured in this isolated replay',
    configured: included ? true : null,
    configuration_state: included ? 'ready' : 'unavailable',
    admitted_slots: included ? [slot] : [], cli_slots: [], dropped_slots: [],
    declared_slots: included ? [slot] : [], declared_cli_slots: [],
    admission_error: included ? null : 'Outside the recorded replay scope',
    status: included ? 'idle' : 'unavailable',
    retained_run_count: included ? rows.length : 0, running_count: 0,
    succeeded_count: included ? rows.length : 0, failed_count: 0, cancelled_count: 0,
    last_started_at: included ? Math.max(...rows.map(row => row.receipt.started_at)) : null,
    last_terminal_at: included ? observedAt : null,
    last_outcome: included ? 'succeeded' : null,
    p50_elapsed_s: included ? rows.map(row => row.receipt.elapsed_s).sort((a,b) => a-b)[1] : null,
    selected_slots: included ? [{ slot_id: slot, count: rows.length }] : [],
    ...(id === 'board_attention_exact' ? { jev: { state: 'lane_unavailable' } } : {}),
  }
})
const laneSnapshot = {
  schema: 'masc.standalone_llm_lanes.v2', generated_at: generatedAt,
  observed_at_unix: observedAt, observation_only: true,
  exact_run_projection_count: rows.length, exact_run_source_total: rows.length,
  exact_run_projection_truncated: false, lanes,
}
const sourceFiles = [
  'dashboard/src/components/internal-agents-monitor.ts',
  'dashboard/src/api/dashboard-exact-lane-runs.ts',
  'dashboard/src/api/dashboard-standalone-lanes.ts',
  'dashboard/src/demo/internal-agents-monitor-fixture.ts',
]
const evidence = {
  scope: 'Source browser replay of unchanged actual-model receipts through the real InternalAgentsMonitor and decoders; fixture API envelopes. Not native HTTP, live dashboard, Goal verification or Candle payment proof.',
  source_head: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: workspace, encoding: 'utf8' }).trim(),
  source_diff: execFileSync('git', ['diff', '--', ...sourceFiles], { cwd: workspace, encoding: 'utf8' }),
  source_hashes: Object.fromEntries(await Promise.all(sourceFiles.map(async file => [file, hash(await readFile(join(workspace, file)))]))),
  native_metadata: nativeMetadata,
  mode, actor, selected_slot: slot,
  rows: rows.map(row => ({ stage: row.stage, case_id: row.case_id, trial: row.trial, run_id: row.receipt.run_id,
    receipt_sha256: hash(JSON.stringify(row.receipt)), answer: row.answer })),
  fixture_projection: 'Only run_kind=exact_output and skill_evidence=no_keeper_skills are added to detail. List omits payloads. Lane counts are derived from these three records; other lane observations are explicitly unavailable.',
  requests: [], errors: [], assertions: [], screenshots: [],
}
await writeFile(join(output, 'recorded-rows.json'), JSON.stringify(rows, null, 2)+'\n')
await writeFile(join(output, 'fixture-envelopes.json'), JSON.stringify({ summaries, details: Object.fromEntries(details), lanes: laneSnapshot }, null, 2)+'\n')
const banner = '<aside data-testid="recorded-replay-scope" style="padding:16px 24px;background:#14253b;color:#dceaff;font:14px system-ui">SOURCE BROWSER + ACTUAL RECORDED DATA · three isolated GLM decisions · fixture API replay · no live server or payment</aside>'
process.env.MASC_DASHBOARD_PROXY_TARGET = 'http://127.0.0.1:1'
const server = await createServer({ root: dashboard, configFile: join(dashboard, 'vite.config.ts'),
  cacheDir: join(output, 'vite-cache'), plugins: [{ name: 'recorded-evidence-label', transformIndexHtml: html => html.replace('<div id="app">', banner+'<div id="app">') }],
  server: { host: '127.0.0.1', port: 0, strictPort: false }, logLevel: 'warn' })
let browser
let page
try {
  await server.listen()
  const address = server.httpServer.address()
  assert.equal(typeof address, 'object')
  const origin = `http://127.0.0.1:${address.port}`
  browser = await chromium.launch({ headless: true })
  evidence.browser = { name: 'Chromium', version: browser.version(), viewport: { width: 1520, height: 1080 } }
  page = await browser.newPage({ viewport: evidence.browser.viewport, deviceScaleFactor: 1 })
  page.setDefaultTimeout(20000)
  page.on('pageerror', error => evidence.errors.push(error.message))
  await page.route('**/*', async route => {
    const url = new URL(route.request().url())
    if (!url.pathname.startsWith('/api/')) {
      if (url.origin === origin) return route.continue()
      evidence.errors.push('Unexpected external browser request: '+url.origin)
      return route.abort()
    }
    const path = url.pathname
    const request = { path, method: route.request().method(), response_sha256: null }
    evidence.requests.push(request)
    assert.equal(request.method, 'GET')
    const empty = { generated_at: generatedAt, runs: [], count: 0 }
    let body
    if (path === '/api/v1/dashboard/exact-lane-runs') body = { ...empty, runs: summaries, count: 3, total: 3, has_more: false }
    else if (path.startsWith('/api/v1/dashboard/exact-lane-runs/')) {
      const id = decodeURIComponent(path.slice('/api/v1/dashboard/exact-lane-runs/'.length))
      assert.ok(details.has(id), 'detail must request an actual recorded run ID')
      body = { generated_at: generatedAt, run: details.get(id) }
    }
    else if (path === '/api/v1/dashboard/standalone-lanes') body = laneSnapshot
    else if (path === '/api/v1/dev-token') body = { token: 'isolated-candle-replay', actor: 'dashboard', role: 'admin' }
    else if (path === '/api/v1/dashboard/fusion-runs') body = { ...empty, replay: { status: 'absent' }, historical_evidence: [] }
    else if (path === '/api/v1/dashboard/verification-runs') body = empty
    else {
      evidence.errors.push('Unexpected fixture API request: '+path)
      return route.fulfill({ status: 400, contentType: 'application/json', body: '{"error":"unexpected fixture request"}' })
    }
    const text = JSON.stringify(body)
    request.response_sha256 = hash(text)
    await route.fulfill({ status: 200, contentType: 'application/json', body: text })
  })
  const screenshot = async (name, locator = page) => {
    const file = name+'.png'
    if (locator === page) await page.screenshot({ path: join(output,file), fullPage: true })
    else await locator.screenshot({ path: join(output,file) })
    evidence.screenshots.push({ file, sha256: hash(await readFile(join(output,file))) })
  }
  await page.goto(origin+'/dashboard/dev-fixtures/internal-agents-monitor-fixture.html')
  const monitor = page.getByTestId('internal-agents-monitor')
  await monitor.getByRole('button', { name: 'Candle Appraiser 3', exact: true }).click()
  await page.waitForFunction(() => document.querySelectorAll('.ia-card').length === 3)
  assert.match(await monitor.innerText(), /3 runs · 0 Keeper owners/)
  await screenshot('01-recorded-inventory')
  for (const row of rows) {
    const index = summaries.findIndex(summary => summary.run_id === row.receipt.run_id)
    const card = monitor.locator('.ia-card').nth(index)
    await card.locator('.ia-row').click()
    await card.locator('[data-exact-payload="input"][data-payload-state="available"]').waitFor()
    await card.locator('[data-exact-payload="output"][data-payload-state="available"]').waitFor()
    const input = await card.locator('[data-exact-payload="input"]').textContent()
    const outputText = await card.locator('[data-exact-payload="output"]').textContent()
    for (const value of [row.stage, row.case_id, row.receipt.input.payload.request_id,
      row.receipt.input.payload.actual_input.goal.title, row.receipt.input.payload.actual_input.goal.metric]) {
      assert.ok(input.includes(JSON.stringify(value)), 'actual recorded input value must be rendered: '+value)
    }
    const actual = row.receipt.input.payload.actual_input
    const taskTitles = actual.task_title ? [actual.task_title] : (actual.tasks ?? []).map(task => task.title)
    for (const title of taskTitles) assert.ok(input.includes(JSON.stringify(title)), 'actual recorded Task title must be rendered')
    for (const [key, value] of Object.entries(row.answer)) {
      assert.ok(outputText.includes(key), 'decision key must be rendered')
      if (typeof value === 'string') assert.ok(outputText.includes(JSON.stringify(value)))
      else for (const [name, weight] of Object.entries(value)) assert.ok(outputText.includes(name+':'+String(weight)), 'actual weight must be rendered')
    }
    assert.ok((await card.innerText()).includes(slot))
    assert.ok((await card.innerText()).includes('Workspace '+actor))
    const runIdVisible = (await card.innerText()).includes(row.receipt.run_id)
    assert.equal(runIdVisible, mode === 'after', 'run ID visibility must match recorded before/after expectation')
    evidence.rows.find(value => value.stage === row.stage).run_id_visible = runIdVisible
    evidence.assertions.push(`${row.stage}: recorded input, result, request ID, workspace actor and selected slot rendered; fetched exact run ID ${row.receipt.run_id}`)
    await screenshot('02-'+row.stage, card)
    await writeFile(join(output, row.stage+'-visible.txt'), await card.innerText())
    if (taskTitles.length > 0) {
      await card.locator('[data-exact-payload="input"]').getByText(JSON.stringify(taskTitles[0]), { exact: true }).scrollIntoViewIfNeeded()
      await screenshot('03-'+row.stage+'-task-input', card)
    }
  }
  assert.equal(await monitor.getByRole('link', { name: /Keeper 전체 evidence/ }).count(), 0)
  assert.equal(evidence.requests.filter(row => row.path.startsWith('/api/v1/keepers/')).length, 0)
  const references = await monitor.locator('a, option').evaluateAll(nodes => nodes.map(node => ({ href: node.getAttribute('href'), value: node.getAttribute('value') })))
  assert.equal(references.some(row => row.value === actor || row.href?.includes(encodeURIComponent(actor))), false)
  assert.equal(await monitor.locator('.ia-err').count(), 0)
  assert.deepEqual(evidence.errors, [])
  evidence.assertions.push('Zero Keeper owners, Keeper evidence links, workspace-as-Keeper options and Keeper API requests')
  evidence.outcome = mode === 'after' ? 'passed' : 'observation_gap_reproduced'
  if (mode === 'before') evidence.observed_gap = 'None of the three Candle rows or details renders its exact run ID.'
  console.log(JSON.stringify({ outcome: evidence.outcome, output, rows: evidence.rows.map(({stage,run_id,run_id_visible}) => ({stage,run_id,run_id_visible})), browser_errors: evidence.errors }, null, 2))
} catch (error) {
  evidence.outcome = 'failed'
  evidence.failure = { message: error.message, stack: error.stack }
  if (page) {
    await page.screenshot({ path: join(output, 'failure.png'), fullPage: true }).catch(() => {})
    evidence.visible = await page.locator('body').innerText().catch(() => '')
  }
  throw error
} finally {
  await writeFile(join(output, 'evidence.json'), JSON.stringify(evidence, null, 2)+'\n')
  if (browser) await browser.close()
  await server.close()
}
