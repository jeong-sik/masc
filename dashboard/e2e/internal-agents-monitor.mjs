import { chromium } from 'playwright'

const fixtureUrl = process.env.INTERNAL_AGENTS_FIXTURE_URL
if (!fixtureUrl) throw new Error('INTERNAL_AGENTS_FIXTURE_URL is required')

const artifactDir = process.env.INTERNAL_AGENTS_ARTIFACT_DIR ?? '/tmp'
const screenshot = `${artifactDir}/internal-agents-monitor-evidence.png`
const json = (route, body) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1360, height: 1000 } })
  await page.route('**/api/v1/dashboard/dev-token', route => json(route, {
    token: 'fixture-worker-token', actor: 'dashboard', role: 'worker',
  }))
  await page.route('**/api/v1/dashboard/exact-lane-runs', route => json(route, {
    generated_at: '2026-08-09T13:00:00Z',
    count: 2,
    runs: [
      {
        run_id: 'librarian-e2e', lane: 'librarian_exact', subject_id: 'trace-e2e',
        actor: 'keeper-e2e', started_at: 1786280000,
        input: {
          kind: 'research', raw_trace_path: '/tmp/raw-traces/librarian-e2e.jsonl',
          payload: {
            actual_input: { messages: [{ role: 'user', content: 'ACTUAL_INPUT_SENTINEL' }] },
            frozen_prompt: 'ACTUAL_PROMPT_SENTINEL',
          },
        },
        status: 'succeeded', elapsed_s: 1.25,
        output: {
          actual_output: { decision: 'replace', evidence: 'ACTUAL_OUTPUT_SENTINEL' },
          before: { present: true, revision: 8, fact_count: 1 },
          after: { revision: 9, fact_count: 1, change: { added_count: 1, removed_count: 1, retained: 0 } },
        },
      },
      {
        run_id: 'judge-e2e', lane: 'hitl_auto_judge', subject_id: 'approval-e2e',
        actor: 'keeper-e2e', started_at: 1786279900,
        input: { kind: 'exact', payload: { request_context: 'JUDGE_ACTUAL_INPUT' } },
        status: 'succeeded', elapsed_s: 0.2, output: { decision: 'allow' },
      },
    ],
  }))
  await page.route('**/api/v1/dashboard/verification-runs', route => json(route, {
    generated_at: '2026-08-09T13:00:00Z', count: 0, runs: [],
  }))
  await page.route('**/api/v1/dashboard/fusion-runs', route => json(route, {
    generated_at: '2026-08-09T13:00:00Z', count: 0, runs: [],
  }))
  await page.route('**/api/v1/keepers/keeper-e2e/memory-journal?limit=500', route => json(route, {
    keeper: 'keeper-e2e', returned: 1, undecodable_lines: 0,
    entries: [{
      ok: true, outcome: 'committed', recorded_at: 1786280002, revision: 9,
      source: { kind: 'librarian', trace_id: 'trace-e2e' },
      change: {
        added: [{ claim: 'MEMORY_AFTER_SENTINEL', category: 'fact', first_seen: 1786280001 }],
        removed: [{ claim: 'MEMORY_BEFORE_SENTINEL', category: 'fact', first_seen: 1786200000 }],
        retained: 0,
      },
      dropped: [{ memory_id: 'sha256:before', reason: 'replaced by exact evidence' }],
    }],
  }))
  await page.route('**/api/v1/keepers/keeper-e2e/raw-trace?**', route => json(route, {
    file: 'librarian-e2e.jsonl', total_records: 2, offset: 0,
    records: [
      { ok: true, raw: '{"record_type":"tool_execution_started","tool_input":{"query":"RAW_INPUT_SENTINEL"}}', record: { record_type: 'tool_execution_started', tool_input: { query: 'RAW_INPUT_SENTINEL' } } },
      { ok: true, raw: '{"record_type":"tool_execution_finished","tool_result":"RAW_OUTPUT_SENTINEL"}', record: { record_type: 'tool_execution_finished', tool_result: 'RAW_OUTPUT_SENTINEL' } },
    ],
  }))
  await page.route('**/api/v1/keepers/keeper-e2e/raw-traces?**', route => json(route, {
    keeper: 'keeper-e2e', returned: 0, turns: [],
  }))

  await page.goto(fixtureUrl)
  const monitor = page.getByTestId('internal-agents-monitor')
  await monitor.waitFor()
  await page.getByRole('button', { name: /Librarian trace-e2e/i }).click()

  for (const marker of [
    'ACTUAL_INPUT_SENTINEL', 'ACTUAL_PROMPT_SENTINEL', 'ACTUAL_OUTPUT_SENTINEL',
    'MEMORY_AFTER_SENTINEL', 'MEMORY_BEFORE_SENTINEL', 'RAW_INPUT_SENTINEL', 'RAW_OUTPUT_SENTINEL',
  ]) {
    await page.waitForFunction(
      expected => document.body.textContent?.includes(expected) === true,
      marker,
    )
  }

  const rawGroup = page.getByRole('group', { name: 'Librarian RAW 표시 방식' })
  await rawGroup.getByRole('button', { name: 'Readable JSON' }).click()
  if (await rawGroup.getByRole('button', { name: 'Readable JSON' }).getAttribute('aria-pressed') !== 'true') {
    throw new Error('Readable JSON interaction did not change the RAW view')
  }

  const filters = page.getByRole('group', { name: 'Internal agent filters' })
  await filters.getByRole('button', { name: 'Auto Judge 1', exact: true }).click()
  await page.getByRole('button', { name: /Auto Judge approval-e2e/i }).click()
  await page.waitForFunction(
    expected => document.body.textContent?.includes(expected) === true,
    'JUDGE_ACTUAL_INPUT',
  )
  if (await page.getByRole('button', { name: /Librarian trace-e2e/i }).count() !== 0) {
    throw new Error('lane filter did not remove the Librarian row')
  }

  await filters.getByRole('button', { name: 'All 2', exact: true }).click()
  await page.getByRole('button', { name: /Librarian trace-e2e/i }).click()
  await page.screenshot({ path: screenshot, fullPage: true })
  process.stdout.write(`screenshot=${screenshot}\n`)
} finally {
  await browser.close()
}
