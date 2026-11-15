import { createHash } from 'node:crypto'
import { chromium } from 'playwright'

// Opens the Internal agents monitor fixture and walks one Librarian run and the
// lane filter against fakes of the current dashboard API.
//
// Every path the Vite dev server proxies (dashboard/vite.config.ts) is answered
// here or blocked. A blocked request fails the run: without this, a request the
// fakes do not answer reaches the proxy target, and the harness default is the
// local MASC server.

const fixtureUrl = process.env.INTERNAL_AGENTS_FIXTURE_URL
if (!fixtureUrl) throw new Error('INTERNAL_AGENTS_FIXTURE_URL is required')

const artifactDir = process.env.INTERNAL_AGENTS_ARTIFACT_DIR ?? '/tmp'
const screenshot = `${artifactDir}/internal-agents-monitor-evidence.png`

const PROXIED_PATHS = ['/health', '/api', '/mcp', '/sse', '/ws', '/yjs']
const GENERATED_AT = '2026-08-09T13:00:00Z'
const KEEPER = 'keeper-e2e'
const LIBRARIAN_TRACE = 'trace-e2e'
const LIBRARIAN_REVISION = 9
const SLOT = 'primary'

// The Librarian run records the prompt template and the sections substituted
// into it; the monitor rebuilds the rendered prompt from those two.
const PROMPT_TEMPLATE = 'ACTUAL_PROMPT_SENTINEL\nHistory={{conversation_history}}'
const PROMPT_VARIABLES = { conversation_history: 'ACTUAL_INPUT_SENTINEL' }
const RENDERED_PROMPT = 'ACTUAL_PROMPT_SENTINEL\nHistory=ACTUAL_INPUT_SENTINEL'

const sha256 = text => createHash('sha256').update(text).digest('hex')
const isProxied = url => PROXIED_PATHS.some(path => url.pathname === path || url.pathname.startsWith(`${path}/`))

// GET /api/v1/dashboard/exact-lane-runs rows carry no payloads; opening a row
// reads /exact-lane-runs/<run_id>, which adds them.
const librarianSummary = {
  run_id: 'librarian-e2e', run_kind: 'exact_output', lane: 'librarian_exact', subject_id: LIBRARIAN_TRACE,
  actor: KEEPER, started_at: 1786280000, status: 'succeeded',
  elapsed_s: 1.25, completion_origin: 'producer', usage: null, selected_slot: SLOT,
}
const judgeSummary = {
  run_id: 'judge-e2e', run_kind: 'exact_output', lane: 'hitl_auto_judge', subject_id: 'approval-e2e',
  actor: KEEPER, started_at: 1786279900, status: 'succeeded',
  elapsed_s: 0.2, completion_origin: 'producer', usage: null, selected_slot: SLOT,
}
const opened = (summary, payload, output) => ({
  run: {
    ...summary,
    input: { kind: 'exact', payload },
    payload_availability: { input: { state: 'available' }, output: { state: 'available' } },
    skill_evidence: { state: 'no_keeper_skills' },
    output,
  },
  generated_at: GENERATED_AT,
})

// Payload fields follow the server producers (keeper_librarian_runtime.ml,
// hitl_summary_worker.ml). The monitor shows payloads as JSON and reads only
// actual_input.prompt, rendered_prompt_variables and before/after; producer
// fields it does not read are left out.
const librarianRun = opened(librarianSummary, {
  actual_input: {
    prompt: {
      key: 'librarian', source: 'file', file_path: '/config/prompts/librarian.md',
      effective_template: PROMPT_TEMPLATE,
      rendered_bytes: Buffer.byteLength(RENDERED_PROMPT), rendered_sha256: sha256(RENDERED_PROMPT),
    },
    rendered_prompt_variables: PROMPT_VARIABLES,
  },
  message_count: 1,
  current_fact_count: 1,
}, {
  exact_output: { evidence: 'ACTUAL_OUTPUT_SENTINEL' },
  before: { present: true, fact_count: 1 },
  after: {
    commit: 'rewritten', revision: LIBRARIAN_REVISION, updated_at: 1786280001.25, fact_count: 1,
    change: { added_count: 1, removed_count: 1, retained: 0 },
  },
})
const judgeRun = opened(judgeSummary, {
  tool_name: 'bash', tool_input: { command: 'git status' },
  request_context: { reason: 'JUDGE_ACTUAL_INPUT' },
  turn_id: 7, task_id: null, goal_id: null, partial_context: false, observation: null,
}, {
  summary_version: 2, generated_at: 1786279900.2, model_run_id: 'judge-e2e',
  context_summary: 'Read-only git status.', key_questions: [], judgment: 'approve', rationale: 'No write.',
})

const journalFact = (claim, firstSeen) => ({
  claim, category: 'fact', first_seen: firstSeen, last_seen: firstSeen,
  origin: { kind: 'injected', trace_id: LIBRARIAN_TRACE }, basis: { kind: 'observed' },
})
const memoryJournal = {
  keeper: KEEPER,
  dashboard_surface: '/api/v1/keepers/:name/memory-journal',
  returned: 1,
  undecodable_lines: 0,
  entries: [{
    structural_id: `memory:journal:10:${KEEPER}:0`,
    ok: true, outcome: 'committed', recorded_at: 1786280002, revision: LIBRARIAN_REVISION,
    source: { kind: 'librarian', trace_id: LIBRARIAN_TRACE },
    change: {
      added: [journalFact('MEMORY_AFTER_SENTINEL', 1786280001)],
      removed: [journalFact('MEMORY_BEFORE_SENTINEL', 1786200000)],
      retained: 0,
      invalidated: [],
    },
    dropped: [{ memory_id: `sha256:${'b'.repeat(64)}`, reason: 'replaced by exact evidence' }],
  }],
}

const lane = (laneId, label, observed) => ({
  lane_id: laneId, label, purpose: `${label} fixture lane`,
  required: laneId === 'board_attention_exact' || laneId === 'hitl_auto_judge',
  observation_only: true, configured: true, configuration_state: 'ready',
  admitted_slots: [SLOT], cli_slots: [], dropped_slots: [], declared_slots: [SLOT], declared_cli_slots: [],
  admission_error: null,
  ...(observed === undefined
    ? {
        status: 'no_retained_observation', retained_run_count: 0, succeeded_count: 0,
        last_started_at: null, last_terminal_at: null, last_outcome: null, p50_elapsed_s: null, selected_slots: [],
      }
    : {
        status: 'idle', retained_run_count: 1, succeeded_count: 1,
        last_started_at: observed.started_at, last_terminal_at: observed.started_at + observed.elapsed_s,
        last_outcome: 'succeeded', p50_elapsed_s: observed.elapsed_s, selected_slots: [{ slot_id: SLOT, count: 1 }],
      }),
  running_count: 0, failed_count: 0, cancelled_count: 0,
  ...(laneId === 'board_attention_exact' ? { jev: { state: 'off' } } : {}),
})

// Keyed by path and query exactly as the monitor requests them.
const answers = new Map([
  ['/api/v1/dashboard/dev-token', { token: 'fixture-admin-token', actor: 'dashboard', role: 'admin' }],
  ['/api/v1/dashboard/exact-lane-runs?run_kind=exact_output', {
    runs: [librarianSummary, judgeSummary], count: 2, total: 2, has_more: false, generated_at: GENERATED_AT,
  }],
  ['/api/v1/dashboard/exact-lane-runs/librarian-e2e', librarianRun],
  ['/api/v1/dashboard/exact-lane-runs/judge-e2e', judgeRun],
  ['/api/v1/dashboard/verification-runs', { generated_at: GENERATED_AT, count: 0, runs: [] }],
  ['/api/v1/dashboard/goal-verification-runs', { runs: [], count: 0, generated_at: GENERATED_AT }],
  ['/api/v1/dashboard/fusion-runs', {
    runs: [], count: 0, generated_at: GENERATED_AT, replay: { status: 'absent' }, historical_evidence: [],
  }],
  ['/api/v1/dashboard/standalone-lanes', {
    schema: 'masc.standalone_llm_lanes.v2', generated_at: GENERATED_AT, observed_at_unix: 1786280010,
    observation_only: true,
    lanes: [
      lane('board_attention_exact', 'Board Attention'),
      lane('hitl_auto_judge', 'Auto Judge', judgeSummary),
      lane('librarian_exact', 'Librarian', librarianSummary),
      lane('candle_appraiser', 'Candle Appraiser'),
      lane('verifier_exact', 'Verifier'),
    ],
  }],
  [`/api/v1/keepers/${KEEPER}/memory-journal?limit=500`, memoryJournal],
  [`/api/v1/keepers/${KEEPER}/raw-traces?limit=50`, { keeper: KEEPER, returned: 0, turns: [] }],
])

const unanswered = []
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1360, height: 1000 } })
  await page.route(isProxied, route => {
    const request = route.request()
    const url = new URL(request.url())
    const key = `${url.pathname}${url.search}`
    const body = request.method() === 'GET' ? answers.get(key) : undefined
    if (body === undefined) {
      unanswered.push(`${request.method()} ${key}`)
      return route.abort('blockedbyclient')
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
  })
  await page.routeWebSocket(isProxied, socket => {
    unanswered.push(`WebSocket ${new URL(socket.url()).pathname}`)
    return socket.close()
  })

  await page.goto(fixtureUrl)
  const monitor = page.getByTestId('internal-agents-monitor')
  await monitor.waitFor()

  const librarianRow = page.getByRole('button', { name: /Librarian trace-e2e/i })
  await librarianRow.click()
  const librarian = page.locator('article').filter({ has: librarianRow })
  const viewer = title => librarian.locator(`[data-testid="json-viewer-card"][data-title="${title}"]`)
  await librarian.locator('[data-exact-payload="input"]').filter({ hasText: 'ACTUAL_INPUT_SENTINEL' }).waitFor()
  await viewer('실행 당시 effective template').filter({ hasText: 'ACTUAL_PROMPT_SENTINEL' }).waitFor()
  await viewer('실제 치환 input sections').filter({ hasText: 'ACTUAL_INPUT_SENTINEL' }).waitFor()
  await librarian.locator('[data-exact-payload="output"]').filter({ hasText: 'ACTUAL_OUTPUT_SENTINEL' }).waitFor()
  // The journal draws a commit under these titles only when its trace and
  // revision both match the run.
  await viewer('추가된 기억 1건').filter({ hasText: 'MEMORY_AFTER_SENTINEL' }).waitFor()
  await viewer('제거된 기억 1건').filter({ hasText: 'MEMORY_BEFORE_SENTINEL' }).waitFor()

  await librarian.getByRole('button', { name: '최종 rendered prompt 보기' }).click()
  const rendered = librarian.locator('[data-librarian-input-evidence] pre')
  await rendered.waitFor()
  const renderedText = await rendered.textContent()
  if (renderedText !== RENDERED_PROMPT) {
    throw new Error(`rendered prompt is ${JSON.stringify(renderedText)}, expected ${JSON.stringify(RENDERED_PROMPT)}`)
  }

  const filters = page.getByRole('group', { name: 'Internal agent filters' })
  await filters.getByRole('button', { name: 'Auto Judge 1', exact: true }).click()
  const judgeRow = page.getByRole('button', { name: /Auto Judge approval-e2e/i })
  await judgeRow.click()
  await page.locator('article').filter({ has: judgeRow })
    .locator('[data-exact-payload="input"]').filter({ hasText: 'JUDGE_ACTUAL_INPUT' }).waitFor()
  if (await page.getByRole('button', { name: /Librarian trace-e2e/i }).count() !== 0) {
    throw new Error('lane filter did not remove the Librarian row')
  }

  await filters.getByRole('button', { name: 'All 2', exact: true }).click()
  await page.getByRole('button', { name: /Librarian trace-e2e/i }).click()
  await librarian.locator('[data-exact-payload="input"]').filter({ hasText: 'ACTUAL_INPUT_SENTINEL' }).waitFor()

  const alerts = await monitor.getByRole('alert').allInnerTexts()
  if (alerts.length !== 0) throw new Error(`monitor shows alerts: ${JSON.stringify(alerts)}`)
  if (unanswered.length !== 0) throw new Error(`requests this e2e does not answer: ${unanswered.join(', ')}`)
  await page.screenshot({ path: screenshot, fullPage: true })
  process.stdout.write(`screenshot=${screenshot}\n`)
} catch (error) {
  if (unanswered.length !== 0) process.stderr.write(`requests this e2e does not answer: ${unanswered.join(', ')}\n`)
  throw error
} finally {
  await browser.close()
}
