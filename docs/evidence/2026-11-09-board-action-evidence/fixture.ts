import { html } from 'htm/preact'
import { render } from 'preact'
import './styles.ts'

const scenario = new URLSearchParams(location.search).get('case') ?? 'observed'
const keeper = 'fixture-reviewer'
const trace = 'fixture-trace'
const turn = 7
const turnRef = `${trace}#${turn}`
const schema = 'masc.board-action-evidence/v1'
const comment = `c-${'a'.repeat(32)}`
const parent = `c-${'b'.repeat(32)}`
const requestLog: { method: string; path: string; status: number }[] = []
const failures: string[] = []
Object.assign(window, { fixtureRequestLog: requestLog, fixtureFailures: failures })
window.addEventListener('error', event => { failures.push(event.message) })
window.addEventListener('unhandledrejection', event => { failures.push(String(event.reason)) })
const row = (execution_id: string, tool: string, evidence: unknown, extra = {}) => ({
  keeper, trace_id: trace, keeper_turn_id: turn, execution_id, tool,
  ts: 1794231000, input: {}, output: 'Synthetic response, not evidence',
  wire_outcome: 'ok', disposition: 'completed', duration_ms: 4,
  board_action_evidence: evidence, ...extra,
})
const rows = [
  row('fixture-comment', 'masc_board_comment', {
    schema, kind: 'comment_added', post_id: 'p-fixture', comment_id: comment,
    parent_id: parent, author: keeper,
  }, { wire_outcome: 'error', disposition: 'failed' }),
  row('fixture-reaction-remove', 'masc_board_reaction', {
    schema, kind: 'reaction_changed', post_id: 'p-fixture', target_type: 'comment',
    target_id: comment, user_id: keeper, emoji: '👍', reacted: false,
  }),
  row('fixture-reaction-add', 'masc_board_reaction', {
    schema, kind: 'reaction_changed', post_id: 'p-other', target_type: 'post',
    target_id: 'p-other', user_id: keeper, emoji: '🎉', reacted: true,
  }),
]
const sources = [1, 2].map(n => ({ stimulus_id: `board-input-${n}`, source_kind: 'board_signal',
  source_snapshot_ref: `sha256:${String(n).repeat(64)}`, admitted_revision: String(n), first_admitted_at: 1794230900 }))
const manifest = { keeper_name: keeper, trace_id: trace, keeper_turn_id: turn,
  event: 'turn_started', status: 'ok', decision: { channel: 'reactive', intake_sources: sources } }
const runtimeTrace = {
  keeper, trace_id: trace, turn_id: turn, health: 'ok',
  manifest_total_rows: 1, manifest_total_rows_exact: true, manifest_returned_rows: 1,
  manifest_scan_diagnostics: { schema: 'keeper.runtime_manifest_scan_diagnostics.v1',
    unsupported_event_count: 0, unsupported_event_counts: [], unsupported_event_unattributed_count: 0,
    invalid_manifest_row_count: 0, invalid_json_row_count: 0, samples: [] },
  runtime_lens: { axes: { lifecycle: { turn_started_count: 1 } } }, manifest_rows: [manifest],
  source_outcomes: { schema: 'masc.keeper.turn-source-outcomes/v1', state: 'observed', observed_at: 1794231000,
    sources: sources.map(({ first_admitted_at: _first, source_kind: _kind, ...source }) => ({ ...source, receipts: [] })),
    coverage: { state: 'read', rows_inspected: 2, invalid_json_rows: 0, invalid_ledger_rows: 0, storage_error: false } },
}
const skillEvidence = { schema: 'masc.dashboard.skill-physical-turn/v1', turn_ref: turnRef, origins: [],
  coverage: { scope: 'complete_retained_trace_snapshot', sessions_inspected: 0, ledgers_loaded: 0, gaps: [] } }
window.fetch = async (input, init) => {
  const url = new URL(typeof input === 'string' ? input : input instanceof Request ? input.url : String(input), location.href)
  let status = 200
  let payload: unknown
  if (url.pathname === `/api/v1/keepers/${keeper}/tool-calls` && url.searchParams.has('execution_ids')) {
    const ids = JSON.parse(url.searchParams.get('execution_ids')!) as string[]
    if (scenario === 'denied') { status = 403; payload = { error: 'admin_required', detail: 'Admin permission required (synthetic)' } }
    else {
      const matching = rows.filter(item => ids.includes(item.execution_id))
      payload = { keeper, requested_execution_ids: ids,
        entries: scenario === 'duplicate' ? [...matching, { ...rows[0] }] : matching }
    }
  } else if (url.pathname === `/api/v1/keepers/${keeper}/runtime-trace`) payload = runtimeTrace
  else if (url.pathname === '/api/v1/dashboard/skill-activations/physical-turn') payload = skillEvidence
  else { status = 500; payload = { error: `Unexpected synthetic fixture request: ${url.pathname}` }; failures.push(String((payload as {error:string}).error)) }
  requestLog.push({ method: init?.method ?? 'GET', path: url.pathname + url.search, status })
  return new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } })
}
const { KeeperTurnFlow } = await import('@masc-dashboard/components/keeper-turn-flow')
const { fetchKeeperToolCalls } = await import('@masc-dashboard/api/dashboard-keeper-tool-calls')
// The actual ordinary parser produces a recent-tail seed. No server is contacted.
const strictFetch = window.fetch
window.fetch = async (input, init) => {
  const url = new URL(typeof input === 'string' ? input : input instanceof Request ? input.url : String(input), location.href)
  if (url.pathname === `/api/v1/keepers/${keeper}/tool-calls` && url.searchParams.has('limit')) {
    return new Response(JSON.stringify({ keeper, count: 1, entries: [rows[0]] }), { headers: { 'content-type': 'application/json' } })
  }
  return strictFetch(input, init)
}
const tail = scenario === 'observed' ? [] : (await fetchKeeperToolCalls(keeper, 200)).entries
const record = { keeper, trace_id: trace, absolute_turn: turn, turn_ref: turnRef,
  execution_ids: rows.map(item => item.execution_id), blocks: [] }
render(html`
  <main style="max-width:1000px;margin:24px auto;padding:24px;background:var(--color-bg-surface);border:1px solid var(--color-border-default);">
    <h2>Keeper 턴 · 입력과 실행</h2>
    <p class="rt-note">Synthetic fixture · ${scenario} · 실제 컴포넌트, 가상 HTTP 응답</p>
    <${KeeperTurnFlow} record=${record} toolEntries=${tail} toolCallError=${null}
      onMessages=${() => {}} onContext=${() => {}} />
  </main>`, document.getElementById('fixture')!)
