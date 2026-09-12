import assert from 'node:assert/strict'
import { mkdir, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [url, directory] = process.argv.slice(2)
if (!url || !directory) throw new Error('Usage: node scripts/verify-workspace-curator-owner.mjs FIXTURE_URL OUTPUT_DIR')
await mkdir(directory, { recursive: true })
const actor = '/workspace/shared-memory-fixture'
const run = {
  run_id: 'workspace-curator-browser', run_kind: 'exact_output', lane: 'workspace_curator_exact',
  subject_id: null, actor, started_at: 1786200000, status: 'succeeded', elapsed_s: 1,
  selected_slot: 'fixture.exact-slot',
}
const detail = {
  ...run, input: { kind: 'exact', payload: { sources: [{ source_id: 's1', claim: 'Attributed fixture observation' }] } },
  output: { proposal_id: 'fixture-proposal', semantic_verification: 'not_performed' },
  payload_availability: { input: { state: 'available' }, output: { state: 'available' } },
  skill_evidence: { state: 'no_keeper_skills' },
}
const lane = (lane_id, label) => ({
  lane_id, label, required: false, observation_only: true,
  configured: true, configuration_state: 'ready', admitted_slots: ['fixture.exact-slot'],
  cli_slots: [], dropped_slots: [], admission_error: null, status: 'idle',
  retained_run_count: lane_id === run.lane ? 1 : 0, running_count: 0,
  succeeded_count: lane_id === run.lane ? 1 : 0, failed_count: 0, cancelled_count: 0,
  last_started_at: null, last_terminal_at: null, last_outcome: null, p50_elapsed_s: null, selected_slots: [],
})
const browser = await chromium.launch({ headless: true })
const errors = [], requests = []
let page
try {
  page = await browser.newPage({ viewport: { width: 1440, height: 1100 } })
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname
    requests.push(path)
    const empty = { generated_at: '2026-09-13T00:00:00Z', runs: [], count: 0 }
    let body
    if (path.endsWith('/exact-lane-runs/' + run.run_id)) body = { generated_at: empty.generated_at, run: detail }
    else if (path.endsWith('/exact-lane-runs')) body = { ...empty, runs: [run], count: 1, total: 1, has_more: false }
    else if (path.endsWith('/standalone-lanes')) body = {
      schema: 'masc.standalone_llm_lanes.v1', generated_at: empty.generated_at, observed_at_unix: 1786200001,
      observation_only: true, exact_run_projection_count: 1, exact_run_source_total: 1, exact_run_projection_truncated: false,
      lanes: [lane('librarian_exact', 'Librarian'), lane('hitl_auto_judge', 'Auto Judge'),
        lane('board_attention_exact', 'Board Attention'), lane('verifier_exact', 'Verifier'),
        lane('workspace_curator_exact', 'Workspace Curator')],
    }
    else if (path.endsWith('/dev-token')) body = { token: 'synthetic-fixture', actor: 'dashboard', role: 'admin' }
    else if (path.endsWith('/fusion-runs')) body = { ...empty, replay: { status: 'absent' }, historical_evidence: [] }
    else if (path.endsWith('/verification-runs')) body = empty
    else { errors.push('Unexpected API request: ' + path); body = { error: 'unexpected fixture request' } }
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
  })
  await page.goto(url)
  const monitor = page.getByTestId('internal-agents-monitor')
  await monitor.getByRole('button', { name: /succeeded Workspace Curator/ }).click()
  await monitor.getByText(/model-proposed; semantic verification not performed/).waitFor()
  assert.match(await monitor.innerText(), /1 runs · 0 Keeper owners/)
  assert.equal(await monitor.getByRole('link', { name: /Keeper 전체 evidence/ }).count(), 0)
  const references = await monitor.locator('a, option').evaluateAll(nodes => nodes.map(node => ({
    href: node.getAttribute('href'), value: node.getAttribute('value'),
  })))
  assert.equal(references.some(row => row.value === actor || row.href?.includes(encodeURIComponent(actor))), false)
  assert.equal(requests.some(path => path.startsWith('/api/v1/keepers/')), false)
  assert.match(await monitor.innerText(), /workspace inventory와 curator prompt/ )
  assert.equal(await monitor.locator('.ia-err').count(), 0)
  assert.equal((await monitor.innerText()).includes('Error:'), false)
  assert.deepEqual(errors, [])
  await page.screenshot({ path: `${directory}/workspace-curator-owner.png`, fullPage: true })
  await writeFile(`${directory}/receipt.json`, JSON.stringify({
    scope: 'source-browser-synthetic-api', url, actor, outcome: 'passed',
    workspace_run_visible: true, keeper_owner_count: 0, fake_keeper_links: 0,
    keeper_api_requests: 0, errors, requests,
    limits: ['No native worker or installed runtime execution is asserted by this browser fixture'],
  }, null, 2) + '\n')
} catch (error) {
  await writeFile(`${directory}/failure.json`, JSON.stringify({ error: String(error), errors, requests, body: await page?.locator('body').innerText() }, null, 2))
  throw error
} finally {
  await browser.close()
}
