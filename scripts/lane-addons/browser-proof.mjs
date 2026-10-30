#!/usr/bin/env node
/** Actual candidate Dashboard/API interaction. No fixtures, routing overrides,
 * response interception, local build, attach or deployment are performed. */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdir, writeFile, appendFile, readFile, realpath } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { resolve, dirname, join, relative, isAbsolute, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const { values } = parseArgs({ options: {
  url: { type: 'string' }, out: { type: 'string' },
  'expected-addon': { type: 'string', multiple: true },
  'run-id': { type: 'string' },
  keeper: { type: 'string' }, 'token-env': { type: 'string' },
  'timeout-ms': { type: 'string', default: '60000' },
  'verify-evidence-files': { type: 'boolean', default: false },
  headed: { type: 'boolean', default: false }, help: { type: 'boolean', default: false },
} })
if (values.help) {
  process.stdout.write(`Usage: node scripts/lane-addons/browser-proof.mjs --url URL --out DIR
  [--expected-addon ID] [--expected-addon ID] [--run-id RUN] [--keeper NAME]
  [--token-env EXISTING_ENV_NAME] [--timeout-ms 60000] [--headed] [--verify-evidence-files]

URL/DIR may instead use MASC_LANE_ADDON_DASHBOARD_URL and MASC_LANE_ADDON_EVIDENCE_DIR.
The URL must serve the already built candidate Dashboard and its real API.
At least two different packages with retained observations must already be present.
This runner refreshes, drags the timeline, submits a slice, and preserves one row.
--run-id first selects that run through the UI and preserves evidence only from its instances.
Keeper delivery occurs ONLY when --keeper is explicitly supplied; default is preserve only.
Output contains raw API replies, request bodies (never auth headers), screenshots and a summary.
A preservation receipt is recorded separately from independent file verification or Keeper consumption.
--verify-evidence-files additionally reads the candidate's local retained files and checks their hashes.
No dev server, build, deploy, package attach, response mocking, or data seeding is performed.
`)
  process.exit(0)
}
const urlValue = values.url ?? process.env.MASC_LANE_ADDON_DASHBOARD_URL
const outputValue = values.out ?? process.env.MASC_LANE_ADDON_EVIDENCE_DIR
assert(urlValue && outputValue, '--url and --out (or their documented environment values) are required')
const target = new URL(urlValue)
assert(['http:', 'https:'].includes(target.protocol), 'candidate URL must use HTTP(S)')
assert(!target.username && !target.password, 'URL credentials are not supported; use --token-env')
if (values.keeper !== undefined) assert(values.keeper.trim(), '--keeper must be non-blank')
const timeout = Number(values['timeout-ms'])
assert(Number.isSafeInteger(timeout) && timeout > 0, '--timeout-ms must be a positive integer')
const token = values['token-env'] ? process.env[values['token-env']] : undefined
if (values['token-env']) assert(token, 'the named token environment variable is empty')
if (token) target.searchParams.set('token', token)
const secrets = [target.searchParams.get('token')].filter(Boolean).flatMap(secret => [secret, encodeURIComponent(secret)])
const sanitize = text => secrets.reduce((value, secret) => value.split(secret).join('[redacted]'), String(text))
const publicUrl = new URL(target)
publicUrl.searchParams.delete('token')
target.hash = '/monitoring/lane-addons'
publicUrl.hash = target.hash
const output = resolve(outputValue)
await mkdir(output, { recursive: true })
const writeJson = (name, data) => writeFile(join(output, name), `${JSON.stringify(data, null, 2)}\n`)
const journal = async (step, detail = {}) => appendFile(join(output, 'events.jsonl'), `${JSON.stringify({ at: new Date().toISOString(), step, ...detail })}\n`)
const summary = {
  schema: 'masc.lane-addon-browser-proof.v1', status: 'running', started_at: new Date().toISOString(),
  candidate_url: publicUrl.href, response_mocking: false, keeper_delivery_requested: values.keeper !== undefined,
  keeper_name: values.keeper ?? null, evidence_file_independently_verified: false,
  keeper_consumption_verified: false, expected_addons: values['expected-addon'] ?? [], artifacts: [],
  run_id: values['run-id'] ?? null,
}
await writeJson('summary.json', summary)
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const require = createRequire(join(root, 'dashboard/package.json'))
const { chromium } = require('playwright')
let browser
let page
const pageErrors = []
const endpoint = (response, path, method) => {
  const responseUrl = new URL(response.url())
  return responseUrl.origin === target.origin && responseUrl.pathname === path
    && response.request().method() === method
}
async function captureResponse(response, name) {
  const text = await response.text()
  await writeFile(join(output, name), text)
  await journal('api-response', { path: new URL(response.url()).pathname, status: response.status(), artifact: name })
  assert(response.ok(), `${name}: HTTP ${response.status()}; raw response saved`)
  return JSON.parse(text)
}
async function screenshot(locator, name) {
  await locator.screenshot({ path: join(output, name) })
  const bytes = await readFile(join(output, name))
  summary.artifacts.push({ name, sha256: createHash('sha256').update(bytes).digest('hex') })
  await journal('screenshot', { artifact: name })
}
try {
  browser = await chromium.launch({ headless: !values.headed })
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } })
  if (token) await context.setExtraHTTPHeaders({ Authorization: `Bearer ${token}` })
  page = await context.newPage()
  page.setDefaultTimeout(timeout)
  page.on('pageerror', error => pageErrors.push(sanitize(error.message)))
  await journal('navigate', { url: publicUrl.href })
  await page.goto(target.href, { waitUntil: 'domcontentloaded' })
  const panel = page.getByRole('region', { name: 'Lane Add-ons', exact: true })
  await panel.waitFor({ state: 'visible' })
  await panel.getByRole('table').waitFor({ state: 'visible' })
  await panel.getByText('Reading retained observations…', { exact: true }).waitFor({ state: 'hidden' })
  const health = await context.request.get(new URL('/health?full=1', target).href)
  const healthText = await health.text()
  await writeFile(join(output, 'health.json'), healthText)
  summary.health_http_status = health.status()
  assert(health.ok(), 'candidate health must answer successfully')
  const healthData = JSON.parse(healthText)
  summary.host_build = healthData.build

  const inspectWait = page.waitForResponse(response => endpoint(response, '/api/v1/lane-addons', 'GET'))
  await panel.getByRole('button', { name: 'Refresh', exact: true }).click()
  const snapshot = await captureResponse(await inspectWait, 'inspect.json')
  assert(Array.isArray(snapshot.instances) && Array.isArray(snapshot.rows), 'inspect must contain instances and rows')
  const observedInstances = snapshot.instances.filter(instance => (!values['run-id'] || instance.run_id === values['run-id']) && instance.observation_seq > 0
    && snapshot.rows.some(row => row.id.startsWith(`${instance.instance_id}/`)))
  const packageIds = [...new Set(observedInstances.map(instance => instance.addon_id))]
  assert(packageIds.length >= 2, 'two different installed packages must already have retained observations')
  for (const expected of summary.expected_addons) assert(packageIds.includes(expected), `expected observed package is missing: ${expected}`)
  assert(new Set(snapshot.rows.map(row => row.lane_id)).size >= 2, 'at least two actual lanes must appear')
  for (const instance of observedInstances) {
    const instanceRow = panel.getByRole('row').filter({ hasText: instance.instance_id })
    assert.equal(await instanceRow.count(), 1, `instance must appear exactly once: ${instance.instance_id}`)
    await instanceRow.waitFor({ state: 'visible' })
  }
  summary.observed_instances = observedInstances.map(({ instance_id, addon_id, revision, phase }) => ({ instance_id, addon_id, revision, phase }))
  if (values['run-id']) {
    await panel.getByLabel('Run filter', { exact: true }).fill(values['run-id'])
    const runWait = page.waitForResponse(response => endpoint(response, '/api/v1/lane-addons/slice', 'GET'))
    await panel.getByRole('button', { name: 'Slice', exact: true }).click()
    const runResponse = await runWait
    assert.equal(new URL(runResponse.url()).searchParams.get('run_id'), values['run-id'])
    const runSlice = await captureResponse(runResponse, 'fresh-run-slice.json')
    assert(new Set(runSlice.rows.map(row => row.lane_id)).size >= 2, 'selected run must contain two actual lanes')
    await panel.getByText(/^Slice: /).waitFor({ state: 'visible' })
  }
  const figure = panel.getByRole('figure', { name: 'Lane by time' })
  const plot = figure.getByRole('img', { name: 'Parallel lanes with events and recorded relationships' })
  await plot.scrollIntoViewIfNeeded()
  await screenshot(figure, 'lane-axis.png')

  // The axis element is the rendered geometry. This runner does not duplicate
  // the component's viewBox widths or estimate them from screenshots.
  const drag = await plot.locator('g line').first().evaluate(line => {
    const matrix = line.getScreenCTM()
    if (!matrix) throw new Error('timeline has no screen transform')
    const left = line.x1.baseVal.value, right = line.x2.baseVal.value, y = line.y1.baseVal.value
    // Start inside the SVG's right margin and release past the plot's left
    // edge. The component clamps this reverse drag to the observed extent,
    // including real events at both endpoints instead of an empty middle.
    const from = new DOMPoint(right + 2, y).matrixTransform(matrix)
    const to = new DOMPoint(left - 2, y).matrixTransform(matrix)
    return { from: { x: from.x, y: from.y }, to: { x: to.x, y: to.y } }
  })
  await page.mouse.move(drag.from.x, drag.from.y)
  await page.mouse.down()
  await page.mouse.move(drag.to.x, drag.to.y, { steps: 8 })
  await page.mouse.up()
  const sinceText = await panel.getByLabel('Since (Unix seconds)', { exact: true }).inputValue()
  const untilText = await panel.getByLabel('Until (Unix seconds)', { exact: true }).inputValue()
  assert(sinceText && untilText, 'drag must populate both window fields')
  const since = Number(sinceText), until = Number(untilText)
  assert(Number.isFinite(since) && Number.isFinite(until) && since <= until, 'drag must produce a valid time window')
  const sliceWait = page.waitForResponse(response => endpoint(response, '/api/v1/lane-addons/slice', 'GET'))
  await panel.getByRole('button', { name: 'Slice', exact: true }).click()
  const sliceResponse = await sliceWait
  const query = new URL(sliceResponse.url()).searchParams
  assert.equal(Number(query.get('since')), since, 'submitted since must equal the selected window')
  assert.equal(Number(query.get('until')), until, 'submitted until must equal the selected window')
  const slice = await captureResponse(sliceResponse, 'slice.json')
  assert(Array.isArray(slice.rows) && Array.isArray(slice.coverage) && typeof slice.complete === 'boolean', 'slice must carry rows, coverage and completeness')
  if (values['run-id']) {
    assert.equal(query.get('run_id'), values['run-id'])
    assert(slice.rows.every(row => observedInstances.some(instance => row.id.startsWith(`${instance.instance_id}/`))),
      'every returned row must belong to an observed instance from the selected run')
  }
  const slicedLanes = [...new Set(slice.rows.map(row => row.lane_id))]
  assert(slicedLanes.length >= 2, 'the actual selected interval must contain at least two lanes')
  await panel.getByText(/^Slice: /).waitFor({ state: 'visible' })
  summary.selected_window = { since, until, returned_rows: slice.rows.length, lane_ids: slicedLanes, complete: slice.complete }
  await screenshot(panel.getByLabel('Source coverage', { exact: true }), 'slice-coverage.png')
  await panel.getByRole('button', { name: 'Clear slice', exact: true }).click()

  const instance = observedInstances.find(item => snapshot.rows.some(row => row.kind === 'relation'
    && row.id.startsWith(`${item.instance_id}/`))) ?? observedInstances[0]
  const row = snapshot.rows.find(row => row.kind === 'relation' && row.id.startsWith(`${instance.instance_id}/`))
    ?? snapshot.rows.find(row => row.id.startsWith(`${instance.instance_id}/`))
  assert(row, 'selected instance has no retained row')
  await panel.getByRole('row').filter({ hasText: instance.instance_id }).getByRole('radio').check()
  const article = panel.locator('article').filter({ has: page.getByText(`Fields and original evidence · ${row.id}`, { exact: true }) })
  assert.equal(await article.count(), 1, 'selected evidence must identify exactly one displayed row')
  await article.getByRole('checkbox').check()
  await article.locator('summary').click()
  const keeperField = panel.getByLabel('Keeper (optional)', { exact: true })
  assert.equal(await keeperField.inputValue(), '', 'Keeper recipient must start empty')
  if (values.keeper !== undefined) await keeperField.fill(values.keeper)
  const preserveWait = page.waitForResponse(response => endpoint(response, '/api/v1/lane-addons/evidence', 'POST'))
  await panel.getByRole('button', { name: values.keeper === undefined
    ? 'Preserve selected evidence' : 'Preserve and send selected evidence', exact: true }).click()
  const preserveResponse = await preserveWait
  const request = preserveResponse.request().postDataJSON()
  assert.equal(request.instance_id, instance.instance_id)
  assert.deepEqual(request.row_ids, [row.id])
  if (values.keeper === undefined) assert(!Object.hasOwn(request, 'keeper_name'), 'default run must never request Keeper delivery')
  else assert.equal(request.keeper_name, values.keeper)
  await writeJson('evidence-request.json', request)
  const preserved = await captureResponse(preserveResponse, 'evidence-receipt.json')
  assert(typeof preserved.evidence?.uri === 'string' && typeof preserved.evidence?.sha256 === 'string', 'preservation must return an evidence identity and digest')
  if (values.keeper === undefined) assert(!Object.hasOwn(preserved, 'delivery'), 'preserve-only run unexpectedly reports a delivery')
  else assert.equal(preserved.delivery?.status, 'accepted', 'explicit Keeper delivery was not accepted')
  const receipt = panel.locator('details').filter({ has: page.getByText('Last action receipt', { exact: true }) })
  await receipt.waitFor({ state: 'visible' })
  assert((await receipt.innerText()).includes(preserved.evidence.sha256), 'displayed receipt must contain the actual server evidence digest')
  await screenshot(receipt, 'evidence-receipt.png')
  summary.evidence = { instance_id: instance.instance_id, row_id: row.id, ...preserved.evidence,
    delivery_status: preserved.delivery?.status ?? 'not_requested' }
  if (values['verify-evidence-files']) {
    assert(typeof healthData.paths?.effective_masc_root === 'string', 'health must name the candidate runtime root')
    const evidenceRoot = await realpath(join(healthData.paths.effective_masc_root, 'lane-addons/evidence'))
    async function verifyFile(ref) {
      assert(typeof ref.path === 'string' && typeof ref.sha256 === 'string', 'retained reference needs a path and digest')
      const path = await realpath(ref.path)
      const within = relative(evidenceRoot, path)
      assert(within && within !== '..' && !within.startsWith(`..${sep}`) && !isAbsolute(within), 'retained file must be inside the candidate evidence directory')
      const raw = await readFile(path)
      const digest = createHash('sha256').update(raw).digest('hex')
      assert.equal(digest, ref.sha256, 'independently read file digest must match the server receipt')
      return { content: JSON.parse(raw.toString()), record: { path, sha256: digest, bytes: raw.byteLength } }
    }
    const manifest = await verifyFile(preserved.evidence)
    assert(Array.isArray(manifest.content.observations), 'frozen manifest must identify retained observation records')
    const records = []
    const retainedRows = new Set()
    for (const ref of manifest.content.observations) {
      const record = await verifyFile(ref)
      records.push(record.record)
      for (const retained of record.content.output.rows) retainedRows.add(retained.id)
    }
    for (const id of request.row_ids) assert(retainedRows.has(id), 'selected row must be present in verified original records')
    await writeJson('independent-evidence-verification.json', {
      manifest: manifest.record, records, selected_ids_present: true, after_rotation_verified: false,
    })
    summary.evidence_file_independently_verified = true
  }
  summary.status = 'passed'
  await journal('completed', { evidence_row: row.id, keeper_delivery: summary.evidence.delivery_status })
} catch (error) {
  summary.status = 'failed'
  summary.error = sanitize(error?.stack ?? error)
  await journal('failed', { error: sanitize(error?.message ?? error) })
  if (page && !page.isClosed()) {
    try { await screenshot(page, 'failure.png') } catch (captureError) { summary.screenshot_error = sanitize(captureError?.message ?? captureError) }
  }
  process.exitCode = 1
} finally {
  summary.finished_at = new Date().toISOString()
  summary.page_errors = pageErrors
  await writeJson('summary.json', summary)
  await browser?.close()
  process.stdout.write(`${JSON.stringify({ status: summary.status, output, summary: join(output, 'summary.json') })}\n`)
}
