/* MASC v2 — Monitor 신규 섹션 (2026-08 소스 정합)
   · monitoring?section=internal-agents  → dashboard/src/components/internal-agents-monitor.ts
   · lab?section=audit-integrity         → dashboard/src/components/memory/audit-integrity.ts
   mock 은 Lab surface 를 별도로 두지 않으므로 두 패널을 Monitor 안에 모으고,
   각 패널 헤더에 정식 라우트를 그대로 표기한다. */
const { useState: useStateIA } = React;

/* lane = Exact_lane (librarian_exact · hitl_auto_judge · board_attention_exact)
   + verification lane + fusion run registry. */
const IA_LANE = {
  librarian_exact: 'Librarian',
  hitl_auto_judge: 'Auto Judge',
  board_attention_exact: 'Board Judge',
};
const IA_FILTERS = [
  ['all', 'All'], ['librarian', 'Librarian'], ['judge', 'Judge'],
  ['verification', 'Verification'], ['fusion', 'Fusion'],
];
const IA_RUNS = [
  { src: 'exact', id: 'exact:lb-8841', lane: 'librarian_exact', status: 'succeeded', actor: 'librarian', subject: 'masc-improver · fact upsert', elapsed: 1.8, at: '14:33',
    input: { keeper: 'masc-improver', turn: 41, declared_facts: 3, window: 'turn 39–41' },
    output: { upserted: 2, unchanged: 1, valid_until: '2026-08-12T00:00:00Z' } },
  { src: 'exact', id: 'exact:aj-2210', lane: 'hitl_auto_judge', status: 'succeeded', actor: 'ollama_cloud.deepseek-v4-pro', subject: 'H-041 · tool_edit_file', elapsed: 2.4, at: '14:31',
    input: { operation: 'tool_edit_file', keeper: 'sangsu', causal_context: 'trace T-3902 · keeper_turn 118' },
    output: { decision: 'approved', grant: 'exact one-use', persisted: '.masc/gate/judgments' } },
  { src: 'verification', id: 'verification:vr-771', status: 'completed', actor: 'openrouter.claude-opus-4', subject: 'task-7741', elapsed: 18.6, at: '14:28',
    producer: 'verifier', authorityKind: 'cross_agent', tools: [
      { name: 'tool_read_file', disposition: 'allowed', ms: 312, input: { path: 'lib/scheduler/round.ml', range: '88,140' }, out: 'compact() 호출이 unlock 이후로 이동됨 — 재진입 경로 없음' },
      { name: 'tool_execute', disposition: 'allowed', ms: 41220, input: { cmd: 'dune build @runtest' }, out: 'scheduler 스위트 84/84 통과', truncated: true },
    ] },
  { src: 'fusion', id: 'fusion:fus-2261', status: 'failed', actor: 'analyst', subject: 'fus-2261', elapsed: null, at: '14:05',
    preset: 'conditional', failureCode: 'joj_panel_missing', error: 'live config 에 first-order judges 패널이 없어 JoJ 단계가 fail-closed' },
  { src: 'exact', id: 'exact:ba-1903', lane: 'board_attention_exact', status: 'rejected', actor: 'ollama_cloud.deepseek-v4-flash', subject: 'post-4471 · attention candidate', elapsed: 0.9, at: '13:58',
    input: { post: 'post-4471', candidates: ['qa-king', 'reviewer'] },
    output: { decision: 'no_wake', reason: '이미 소유자가 같은 스레드에서 응답 중' } },
];
const IA_TONE = { succeeded: 'ok', completed: 'ok', approved: 'ok', running: 'warn', rejected: 'info', failed: 'bad' };

function iaMatch(r, f) {
  if (f === 'all') return true;
  if (f === 'verification') return r.src === 'verification';
  if (f === 'fusion') return r.src === 'fusion';
  if (f === 'librarian') return r.lane === 'librarian_exact';
  return r.lane === 'hitl_auto_judge' || r.lane === 'board_attention_exact';
}
function iaLabel(r) {
  if (r.src === 'verification') return 'Verification';
  if (r.src === 'fusion') return 'Fusion';
  return IA_LANE[r.lane] || r.lane;
}
function iaElapsed(v) { return v == null ? '—' : v < 1 ? Math.round(v * 1000) + 'ms' : v.toFixed(1) + 's'; }

function IaDetail({ r }) {
  if (r.src === 'verification') {
    return (
      <div className="ia-detail">
        <div className="ia-evi">
          <div className="ia-k">Evidence path</div>
          <code className="mono">producer {r.producer} → {r.authorityKind} → {r.status}</code>
        </div>
        <div className="ia-evi">
          <div className="ia-k">Tools ({r.tools.length})</div>
          <ol className="ia-tools">
            {r.tools.map((t, i) => (
              <li key={i} className="ia-tool">
                <div className="ia-tool-h"><b>{i + 1}. {t.name}</b><code className="mono">{t.disposition}</code><span className="ia-ms mono">{t.ms}ms</span></div>
                <div className="ia-tool-io">
                  <pre className="mono">{JSON.stringify(t.input, null, 2)}</pre>
                  <pre className="mono">{t.out}{t.truncated ? '\n… truncated' : ''}</pre>
                </div>
              </li>
            ))}
          </ol>
        </div>
      </div>
    );
  }
  if (r.src === 'fusion') {
    return (
      <div className="ia-detail">
        <div className="ia-evi">
          <div className="ia-k">Run</div>
          <code className="mono">preset {r.preset} · status {r.status}</code>
          {r.error && <div className="ia-err">{r.failureCode}: {r.error}</div>}
          <p className="ia-note">참여 모델·심판 상세는 Fusion surface 에 있습니다 — 같은 run 레지스트리를 씁니다.</p>
        </div>
      </div>
    );
  }
  return (
    <div className="ia-detail two">
      <div className="ia-evi"><div className="ia-k">Input evidence</div><pre className="mono">{JSON.stringify(r.input, null, 2)}</pre></div>
      <div className="ia-evi"><div className="ia-k">Result</div><pre className="mono">{JSON.stringify(r.output, null, 2)}</pre></div>
      <p className="ia-note span2">도구 없음 — exact-output 레인은 구조화된 모델 실행 1회이며 MASC 도구 디스패치가 아닙니다.</p>
    </div>
  );
}

function InternalAgentsPanel() {
  const [filter, setFilter] = useStateIA('all');
  const [open, setOpen] = useStateIA(null);
  const rows = IA_RUNS.filter(r => iaMatch(r, filter));
  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>Internal Agent Runs</h3>
        <span className="ia-count mono">{IA_RUNS.length} observed</span>
        <span className="ia-route mono">monitoring?section=internal-agents</span>
      </div>
      <p className="ia-lede">Librarian · Judge · Verification · Compaction · Fusion 의 typed run 기록. 갱신은 WebSocket 무효화로 도착하고, 진실원천은 HTTP 스냅샷입니다.</p>
      <div className="ia-filters" role="group" aria-label="Internal agent filters">
        {IA_FILTERS.map(([id, lbl]) => (
          <button key={id} className={`ia-filter ${filter === id ? 'on' : ''}`} aria-pressed={filter === id} onClick={() => setFilter(id)}>{lbl}</button>
        ))}
      </div>
      {rows.length === 0 ? (
        <div className="ia-empty">이 필터에 해당하는 internal agent run 이 없습니다.</div>
      ) : (
        <div className="ia-list">
          {rows.map(r => {
            const on = open === r.id;
            return (
              <article key={r.id} className={`ia-card ${on ? 'on' : ''}`}>
                <button className="ia-row" aria-expanded={on} onClick={() => setOpen(on ? null : r.id)}>
                  <span className="ia-badge" data-tone={IA_TONE[r.status] || 'neutral'}><i></i>{r.status}</span>
                  <span className="ia-sub">
                    <b>{iaLabel(r)}</b>
                    <code className="mono" title={r.subject}>{r.subject}</code>
                  </span>
                  <span className="ia-meta mono">
                    <span>{r.actor}</span>
                    <span>{iaElapsed(r.elapsed)} · {r.at}</span>
                  </span>
                </button>
                {on && <IaDetail r={r} />}
              </article>
            );
          })}
        </div>
      )}
    </div>
  );
}

/* 감사 무결성(resilience hash-chain) 패널 제거(2026-08-23) — 대상 서브시스템이
   #28170로 사라졌다. 죽은 기능의 화면을 프로토타입이 계속 그리면 다음 re-sync
   때 대시보드에 없는 것이 component gap으로 다시 등장한다. */

/* ── 비용 원장 — masc-cost / inference metrics 공용 행 코덱 (2026-08 재설계) ── */
const CL_DAYS = [
  { day: '2026-08-05', rows: 4128, usd: 12.41, dup: 0, bad: 0 },
  { day: '2026-08-04', rows: 3960, usd: 11.02, dup: 2, bad: 1 },
  { day: '2026-08-03', rows: 2871, usd: 7.88, dup: 0, bad: 0 },
];
const CL_AGENTS = [
  { agent: 'masc-improver', state: 'settled', turns: 412, tokens: 8412000, usd: 4.82, models: 2 },
  { agent: 'nick0cave', state: 'settled', turns: 388, tokens: 7710400, usd: 3.91, models: 1, model: 'ollama_cloud.deepseek-v4-pro' },
  { agent: 'sangsu', state: 'open', turns: 201, tokens: 3980100, usd: 2.14, models: 1, model: 'deepseek.deepseek-v4-flash' },
  { agent: 'analyst', state: 'settled', turns: 96, tokens: 1120800, usd: 1.54, models: 3 },
];
function CostLedgerPanel() {
  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>비용 원장</h3>
        <span className="ia-count mono">.masc/costs/YYYY-MM/DD.jsonl</span>
        <span className="ia-route mono">monitoring?section=runtime&view=cost</span>
      </div>
      <p className="ia-lede">Keeper 프로듀서 · <span className="mono">masc-cost</span> · inference metrics 가 하나의 현행 행 코덱과 날짜 분할 저장소를 공유합니다. 자동 기록 행은 런타임이 소유한 <span className="mono">(trace_id, keeper_turn_id, oas_turn_ordinal)</span> 신원을 지니며, <b>정확히 같은 신원일 때만</b> 병합됩니다 — 비슷한 타임스탬프나 동일 토큰 수는 더 이상 중복 판정 규칙이 아닙니다.</p>
      <div className="ai-strip">
        {CL_DAYS.map(d => (
          <div key={d.day} className="ai-stat">
            <span className="k">{d.day}</span>
            <span className="v mono">${d.usd.toFixed(2)}</span>
            <span className="cl-sub mono">{d.rows.toLocaleString()} rows{d.dup ? ` · dup ${d.dup}` : ''}{d.bad ? ` · malformed ${d.bad}` : ''}</span>
          </div>
        ))}
      </div>
      <div className="ai-tablewrap">
        <table className="ai-table">
          <thead><tr><th>by_agent[]</th><th>state</th><th>turns</th><th>tokens</th><th>model</th><th>USD</th></tr></thead>
          <tbody>
            {CL_AGENTS.map(a => (
              <tr key={a.agent}>
                <td className="mono">{a.agent}</td>
                <td><span className={`ai-b ${a.state === 'settled' ? 'ok' : ''}`}>{a.state}</span></td>
                <td className="mono">{a.turns}</td>
                <td className="mono">{(a.tokens / 1000000).toFixed(2)}M</td>
                <td className="mono">{a.models > 1 ? <span className="cl-multi">여러 모델 집계 · 미표기</span> : a.model}</td>
                <td className="mono">${a.usd.toFixed(2)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="ia-note">윈도우 리더는 요청한 날짜 범위만 엽니다. 잘못된 행 · 스키마 위반 · 중복 신원은 조용히 버려지지 않고 명시적 진단으로 남습니다. <span className="mono">masc-cost --json</span> 봉투는 <span className="mono">status</span> 대신 <span className="mono">state</span> 를 쓰고, 여러 모델에 걸친 집계 행에는 대표 <span className="mono">model</span> 값을 싣지 않습니다. 대체 저장소·구 필드 디코더·마이그레이션 경로는 없습니다.</p>
    </div>
  );
}

Object.assign(window, { InternalAgentsPanel, CostLedgerPanel });
