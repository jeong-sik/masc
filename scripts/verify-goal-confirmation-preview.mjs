// CI-built browser UI with explicitly synthetic Goal/confirmation HTTP fixtures.
// Confirmation POST is fulfilled locally and never forwarded to the backend.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFile, mkdir, writeFile, readdir } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [preview, head, backend, destination] = process.argv.slice(2)
assert.ok(preview && head && backend && destination, 'PREVIEW HEAD BACKEND OUTPUT required')
const healthResponse = await fetch(new URL('/health?full=1', backend))
assert.ok(healthResponse.ok, 'backend health is required to bind fixture reads')
const health = await healthResponse.json()
const expectedWorkspace = { base_path: health.paths.effective_base_path, masc_root: health.paths.effective_masc_root }
assert.ok(expectedWorkspace.base_path && expectedWorkspace.masc_root)
// This is an intercepted UI fixture. Its execution authority and confirmation
// response use one synthetic pair rather than combining two live observations.
const fixtureInstance = '018f83d7-93a4-7f5d-9a72-123456789abc'
const fixtureEpoch = '018f83d7-93a4-4f5d-9a72-abcdef123456'
const artifactRoot = resolve(preview), output = resolve(destination)
const buildReceipt = JSON.parse(await readFile(resolve(artifactRoot, 'dashboard-build-receipt.json'), 'utf8'))
assert.equal(buildReceipt.source_commit, head)
const archive = resolve(artifactRoot, buildReceipt.archive)
assert.equal(relative(artifactRoot, archive), buildReceipt.archive)
assert.equal(createHash('sha256').update(await readFile(archive)).digest('hex'), buildReceipt.archive_sha256)
const unpack = output + '-bundle'
execFileSync('python3', ['-c', `import pathlib,sys,tarfile
out=pathlib.Path(sys.argv[2]);out.mkdir()
with tarfile.open(sys.argv[1]) as archive:
 for member in archive.getmembers():
  if not member.name.startswith('dashboard/') and member.name != 'dashboard': raise ValueError('unexpected archive root')
 archive.extractall(out, filter='data')
`, archive, unpack])
const root = resolve(unpack, 'dashboard')
assert.equal(createHash('sha256').update(await readFile(resolve(root, 'index.html'))).digest('hex'), buildReceipt.index_sha256)
const manifest = { files: {} }
for (const item of await readdir(root, { recursive: true, withFileTypes: true })) {
  if (item.isFile()) {
    const file = resolve(item.parentPath, item.name)
    const name = relative(root, file)
    assert.ok(!name.startsWith(`..${sep}`))
    manifest.files[name] = createHash('sha256').update(await readFile(file)).digest('hex')
  }
}
await mkdir(output, { recursive: false })
const criterion = { revision: 'fixture-revision-1', title: 'Browser synthetic Goal', metric: 'verified artifacts', target_value: '1' }
const verdict = { criterion, request_id: 'fixture-request-1', verification_run_id: 'fixture-run-1', outcome: 'proven', reason: null,
  authority: { kind: 'system_llm_agent', actor: 'synthetic-verifier' }, evidence: 'Exact synthetic evidence: artifact 1/1. <script>literal</script>', recorded_at: '2026-09-10T00:00:00Z' }
let completed = false, mode = 'success', readCount = 0
const posts = [], reads = [], blocked = []
function payload() {
  return { inspection_operator_id: 'synthetic-operator', goal: { id: 'fixture-goal', title: criterion.title, metric: criterion.metric,
      target_value: criterion.target_value, criterion_revision: criterion.revision,
      phase: completed ? 'completed' : 'awaiting_confirmation' },
    verification: { goal_id: 'fixture-goal', updated_at: '2026-09-10T00:00:00Z', completion: completed
      ? { state: 'human_confirmed', verdict, operator_id: 'synthetic-operator', confirmed_at: '2026-09-10T01:00:00Z' }
      : { state: 'proof_proven', verdict } } }
}
function goal() {
  const phase = completed ? 'completed' : 'awaiting_confirmation'
  return { id: 'fixture-goal', title: criterion.title, criterion_revision: criterion.revision, phase, phase_color: '', priority: 3,
    goal_fsm: { state: phase, source: 'goal.phase', next_actions: [], activity_observation: 'goal_metadata' },
    metric: criterion.metric, target_value: criterion.target_value, due_date: null, tasks: [], task_count: 0, task_done_count: 0,
    timeline_events: [], children: [], child_count: 0, linked_keeper_names: [], pending_approval_count: 0,
    activity_observation: 'goal_metadata', last_activity_at: '2026-09-10T00:00:00Z', stagnation_seconds: 0,
    created_at: '2026-09-10T00:00:00Z', updated_at: '2026-09-10T00:00:00Z', verification: payload().verification }
}
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' }
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1050 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => socket.close())
  await page.route('**/*', async route => {
    const req = route.request(), url = new URL(req.url())
    if (url.origin === new URL(backend).origin && url.pathname === '/api/v1/dashboard/execution' && req.method() === 'GET') {
      const requestHeaders = { ...req.headers() }
      delete requestHeaders['if-none-match']
      delete requestHeaders['if-modified-since']
      const response = await route.fetch({ headers: requestHeaders })
      if (response.status() !== 200) return route.fulfill({ response })
      const execution = await response.json()
      return route.fulfill({ json: { ...execution, execution_publication_epoch: fixtureEpoch },
        headers: { 'cache-control': 'no-store' } })
    }
    if (url.origin === new URL(backend).origin && url.pathname === '/api/v1/goals/confirmation') {
      if (req.method() === 'POST') {
        const binding = req.postDataJSON(); posts.push(binding)
        assert.deepEqual(binding, { goal_id: 'fixture-goal', criterion_revision: criterion.revision,
          request_id: verdict.request_id, verification_run_id: verdict.verification_run_id, expected_workspace: expectedWorkspace,
          expected_operator_id: 'synthetic-operator', expected_runtime_instance_id: fixtureInstance })
        completed = true
        return route.fulfill({ json: payload() })
      }
      readCount++; reads.push({ mode, completed })
      assert.equal(url.searchParams.get('expected_base_path'), expectedWorkspace.base_path)
      assert.equal(url.searchParams.get('expected_masc_root'), expectedWorkspace.masc_root)
      if (mode === 'denied') return route.fulfill({ status: 403, json: { error: 'synthetic operator permission denied' } })
      if (mode === 'readback-failed' && completed) return route.fulfill({ status: 503, json: { error: 'synthetic readback unavailable' } })
      return route.fulfill({ headers: { 'x-masc-workspace-read': 'matched-v1',
        'x-masc-runtime-instance-id': fixtureInstance, 'x-masc-execution-publication-epoch': fixtureEpoch }, json: payload() })
    }
    if (url.origin === new URL(backend).origin && url.pathname === '/api/v1/dashboard/goals/candle' && req.method() === 'GET') {
      return route.fulfill({ headers: { 'x-masc-workspace-read': 'matched-v1',
        'x-masc-runtime-instance-id': fixtureInstance, 'x-masc-execution-publication-epoch': fixtureEpoch },
        json: { schema: 'masc.goal-candle-observation.v1', goal_id: 'fixture-goal', config: { state: 'off' },
          ledger: { state: 'missing' }, execution: { state: 'not_observed', reason: 'no_complete_goal_request_index' } } })
    }
    if (!['GET', 'HEAD'].includes(req.method())) { blocked.push({ method: req.method(), path: url.pathname }); return route.abort() }
    if (url.pathname === '/api/v1/dashboard/goals') return route.fulfill({ headers: { 'x-masc-workspace-read': 'matched-v1' }, json: {
      approval_queue_state: { state: 'ready' }, tree: [goal()], summary: { total_goals: 1, active_goals: 1,
        phase_counts: { [goal().phase]: 1 }, total_tasks: 0, done_tasks: 0, pending_approvals: 0 } } })
    if (url.pathname === '/api/v1/dashboard/goals/detail') return route.fulfill({ headers: { 'x-masc-workspace-read': 'matched-v1' }, json: {
      approval_queue_state: { state: 'ready' }, goal: goal(), linked_tasks: [], linked_keepers: [], approvals: [], execution_receipts: [], timeline: [] } })
    if (url.origin === new URL(backend).origin && url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name))
      return route.fulfill({ body: await readFile(resolve(root, name)), contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue()
  })
  const panel = page.getByTestId('goal-confirmation-panel')
  await page.goto(new URL('/dashboard/#workspace?section=planning&goal=fixture-goal', backend).href)
  await panel.getByRole('button', { name: '이 증명으로 목표 완료 확인' }).waitFor()
  assert.ok((await panel.textContent()).includes(verdict.evidence))
  assert.equal(await panel.locator('script').count(), 0)
  await panel.screenshot({ path: resolve(output, 'evidence-before.png') })
  await page.screenshot({ path: resolve(output, 'detail-desktop.png') })
  await panel.getByRole('button', { name: '이 증명으로 목표 완료 확인' }).click()
  await panel.getByText(/최종 확인 완료 · synthetic-operator/).waitFor()
  assert.equal(posts.length, 1); assert.ok(readCount >= 2)
  await panel.screenshot({ path: resolve(output, 'confirmed.png') })
  mode = 'readback-failed'; completed = false
  await page.reload()
  await panel.getByRole('button', { name: '이 증명으로 목표 완료 확인' }).click()
  await panel.getByText(/서버에 반영되었을 수 있습니다/).waitFor()
  assert.equal(await panel.getByText(/최종 확인 완료/).count(), 0)
  await panel.screenshot({ path: resolve(output, 'readback-failed.png') })
  mode = 'success'; completed = false
  await page.setViewportSize({ width: 390, height: 844 }); await page.reload()
  await panel.getByRole('button', { name: '이 증명으로 목표 완료 확인' }).waitFor()
  const evidenceBounds = await panel.boundingBox()
  assert.ok(evidenceBounds && evidenceBounds.x >= 0 && evidenceBounds.x + evidenceBounds.width <= 390)
  await panel.screenshot({ path: resolve(output, 'evidence-mobile.png') })
  mode = 'denied'; completed = false
  await page.setViewportSize({ width: 390, height: 844 }); await page.reload()
  await panel.getByText(/synthetic operator permission denied/).waitFor()
  await panel.screenshot({ path: resolve(output, 'permission-denied-mobile.png') })
  const bounds = await panel.boundingBox()
  assert.ok(bounds && bounds.x >= 0 && bounds.x + bounds.width <= 390)
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ head, buildReceipt, scope: 'CI-built UI, synthetic confirmation HTTP; no real Goal mutation or human-auth proof', posts, reads, blocked, mobileBounds: bounds, mobileEvidenceBounds: evidenceBounds }, null, 2) + '\n')
} finally { await browser.close() }
