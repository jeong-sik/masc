/* MASC v2 — Lab surface (2026-08 소스 정합, 2차)
   정식 IA 에서 Lab 은 rail 밖 surface(route 로 접근)지만, mock 에서는 도달 가능하도록
   rail 에 두고 각 패널 헤더에 정식 라우트를 표기한다.
   · lab?section=tools                 → components/tools/tools-main.ts
   · lab?section=harness               → components/harness-health*.ts
   · lab?section=performance           → 성능 프로브
   · lab?section=keeper-memory-health   → components/memory/keeper-memory-health.ts
   · lab?section=audit-integrity        → components/memory/audit-integrity.ts (기존 패널 재사용)
   제거된 라우트: lab:memory-explore → keeper-memory-health · lab:design-canvas → tools ·
   lab:memory-subsystems(Memory OS) → 삭제 */
const { useState: useStateLab, useEffect: useEffectLab, useRef: useRefLab } = React;

const LAB_SECS = [
  ['tools', '도구'], ['harness', '세이프티 하네스'], ['performance', '성능'],
  ['memory', '키퍼 메모리 상태'], ['audit', '감사 무결성'],
];

/* ── 도구 ─────────────────────────────────────────────────────────────── */
const LAB_CONFIG_RES = [
  { k: 'config root', v: '~/.masc', src: 'MASC_CONFIG_ROOT' },
  { k: 'workspace root marker', v: '.masc/root-state.json', src: '단일 마커' },
  { k: 'model catalog', v: 'OAS embedded + oas-models-overlay.toml', src: 'OAS_MODEL_CATALOG' },
  { k: 'stream idle timeout', v: '600s (floor)', src: '미설정 시 기본 · boot log 가 출처 명시' },
  { k: 'tool_policy.toml', v: 'config-root 마커 · 런타임 masc-improver비', src: 'legacy' },
];
const LAB_AUTOMATION = [
  { id: 'sch-daily-digest', state: 'Scheduled', next: '내일 09:00', payload: 'keeper.wake · masc-improver' },
  { id: 'sch-board-sweep', state: 'Firing', next: '지금', payload: 'keeper.wake · qa-king' },
  { id: 'sch-cost-rollup', state: 'Draining', next: '—', payload: 'masc-cost --json' },
  { id: 'sch-legacy-compact', state: 'Retired', next: '—', payload: 'compact.sweep — 임계치 정책 제거로 은퇴' },
];
const LAB_WAITING = [
  { keeper: 'reviewer', waiting: 'gate_hitl', since: '4m', detail: 'H-041 응답 대기' },
  { keeper: 'qa-king', waiting: 'verification', since: '11m', detail: 'task-7741 교차 검증 응답 대기' },
  { keeper: 'analyst', waiting: 'fusion_panel', since: '26m', detail: 'JoJ fail-closed — judges 패널 없음' },
];
const LAB_TOOLS = [
  { name: 'keeper_board_list', server: 'masc', kind: 'read', schema: 'ok' },
  { name: 'keeper_board_comment', server: 'masc', kind: 'write', schema: 'ok' },
  { name: 'keeper_tasks_list', server: 'masc', kind: 'read', schema: 'ok' },
  { name: 'keeper_memory_upsert', server: 'masc', kind: 'write', schema: 'ok' },
  { name: 'tool_read_file', server: 'workspace', kind: 'read', schema: 'ok' },
  { name: 'tool_edit_file', server: 'workspace', kind: 'write', schema: 'ok' },
  { name: 'tool_execute', server: 'workspace', kind: 'exec', schema: 'descriptor gate' },
  { name: 'WebSearch', server: 'identity-translated', kind: 'read', schema: 'descriptor gate' },
  { name: 'WebFetch', server: 'identity-translated', kind: 'read', schema: 'descriptor gate' },
  { name: 'masc_fusion', server: 'masc', kind: 'panel', schema: 'ok' },
];
const LAB_USAGE = { registered_count: 38, distinct_tools_called: 21, never_called_count: 17, source: 'tool_call_io', health: 'healthy', latest_age_s: 42, entry_count: 128410 };

function LabTools() {
  const [view, setView] = useStateLab('inventory');
  const [q, setQ] = useStateLab('');
  const rows = LAB_TOOLS.filter(t => !q || t.name.toLowerCase().includes(q.toLowerCase()));
  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>도구</h3>
        <span className="ia-count mono">등록 {LAB_USAGE.registered_count} · 사용 {LAB_USAGE.distinct_tools_called}</span>
        <span className="ia-route mono">lab?section=tools</span>
      </div>
      <div className="ia-filters">
        <button className={`ia-filter ${view === 'inventory' ? 'on' : ''}`} onClick={() => setView('inventory')}>인벤토리</button>
        <button className={`ia-filter ${view === 'executor' ? 'on' : ''}`} onClick={() => setView('executor')}>도구 실행기</button>
      </div>

      {view === 'executor' ? (
        <div className="lab-panel">
          <h4>도구 실행기</h4>
          <p className="ia-note">descriptor 의 JSON schema 로 폼을 생성해 도구를 1회 실행합니다. 실행 결과는 일반 keeper 호출과 같은 <span className="mono">tool_call_io</span> 증거로 남고, 승인이 필요한 도구는 Gate 로 라우팅됩니다.</p>
          <div className="lab-exec">
            <label className="lab-f"><span>tool</span><select defaultValue="tool_read_file">{LAB_TOOLS.map(t => <option key={t.name} value={t.name}>{t.name}</option>)}</select></label>
            <label className="lab-f"><span>path</span><input defaultValue="lib/scheduler/round.ml" /></label>
            <label className="lab-f"><span>range</span><input defaultValue="88,140" /></label>
            <button className="lab-run" onClick={() => window.pushToast && window.pushToast({ tone: 'ok', msg: '도구 실행 요청', sub: 'tool_read_file · descriptor 검증 통과' })}>실행</button>
          </div>
        </div>
      ) : (
        <React.Fragment>
          <section className="lab-panel">
            <h4>설정 해석 · config resolution</h4>
            <div className="lab-kv">
              {LAB_CONFIG_RES.map(r => (
                <div key={r.k} className="lab-kv-row"><span className="k">{r.k}</span><span className="v mono">{r.v}</span><span className="s mono">{r.src}</span></div>
              ))}
            </div>
          </section>

          <section className="lab-panel">
            <h4>프롬프트 레지스트리</h4>
            <p className="ia-note">전역 프롬프트 · 오버라이드 편집은 <span className="mono">설정 › 프롬프트</span> 한 곳에서만 관리합니다. Lab 에 있던 중복 편집기는 제거되었습니다.</p>
          </section>

          <section className="lab-panel">
            <h4>예약 자동화 FSM</h4>
            <div className="ai-tablewrap">
              <table className="ai-table">
                <thead><tr><th>스케줄</th><th>state</th><th>다음 실행</th><th>payload</th></tr></thead>
                <tbody>
                  {LAB_AUTOMATION.map(a => (
                    <tr key={a.id}>
                      <td className="mono">{a.id}</td>
                      <td><span className={`ai-b ${a.state === 'Firing' ? 'ok' : a.state === 'Retired' ? 'bad' : ''}`}>{a.state}</span></td>
                      <td className="mono dim">{a.next}</td>
                      <td className="ai-d">{a.payload}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <section className="lab-panel">
            <h4>Keeper Waiting Inventory</h4>
            <div className="ai-tablewrap">
              <table className="ai-table">
                <thead><tr><th>키퍼</th><th>대기 종류</th><th className="r">경과</th><th>상세</th></tr></thead>
                <tbody>
                  {LAB_WAITING.map(w => (
                    <tr key={w.keeper}><td className="mono">{w.keeper}</td><td className="mono">{w.waiting}</td><td className="mono r dim">{w.since}</td><td className="ai-d">{w.detail}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <section className="lab-panel">
            <h4>시스템 도구 목록</h4>
            <input className="lab-search" placeholder="도구 검색…" value={q} onChange={e => setQ(e.target.value)} />
            <div className="ai-tablewrap">
              <table className="ai-table">
                <thead><tr><th>도구</th><th>서버</th><th>종류</th><th>schema</th></tr></thead>
                <tbody>
                  {rows.map(t => (
                    <tr key={t.name}>
                      <td className="mono">{t.name}</td>
                      <td className="mono dim">{t.server}</td>
                      <td className="mono dim">{t.kind}</td>
                      <td><span className={`ai-b ${t.schema === 'ok' ? 'ok' : ''}`}>{t.schema}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <section className="lab-panel">
            <h4>도구 사용 현황</h4>
            <p className="ia-note">등록됨 {LAB_USAGE.registered_count} (모든 MCP 서버 합산) · 사용된 {LAB_USAGE.distinct_tools_called} · 미사용 {LAB_USAGE.never_called_count}</p>
            <div className="lab-srcline mono">
              <span>{LAB_USAGE.source}</span><span className="ok">{LAB_USAGE.health}</span>
              <span className="dim">latest {LAB_USAGE.latest_age_s}s · {LAB_USAGE.entry_count.toLocaleString()} durable rows</span>
              <span className="dim">metrics 기준 최근 1시간</span>
            </div>
          </section>
        </React.Fragment>
      )}
    </div>
  );
}

/* ── 세이프티 하네스 ──────────────────────────────────────────────────── */
const HN_OVERVIEW = {
  evaluator_status: 'healthy', pre_compact_status: 'warning', handoff_status: 'idle',
  last_signal_at: '14:33', fallback_ratio: 0.06, cross_model_rate: 0.41,
  latest_pre_compact_checkpoint_bytes: 1841200, latest_handoff_generation: 4,
};
const HN_CAL = {
  total_verdicts: 612, approve_count: 508, reject_count: 104,
  gate_distribution: { completion_contract: 388, tests_pass: 141, review_ack: 83 },
  labeled_count: 210, false_positive_count: 7, false_negative_count: 4, agreement_rate: 0.948,
  fallback_count: 37, recent_fallback_reasons: ['evaluator_runtime_unavailable', 'json_schema_violation'],
};
const HN_VERDICTS = [
  { at: '14:33', task_id: 'task-7741', task_title: 'scheduler 재진입 제거', agent_name: 'sangsu', gate: 'completion_contract', verdict: 'approve', evaluator_runtime: 'openrouter.claude-opus-4', generator_runtime: 'ollama_cloud.deepseek-v4-pro', cross_runtime: true },
  { at: '14:21', task_id: 'task-7736', task_title: 'board 첨부 검증', agent_name: 'qa-king', gate: 'tests_pass', verdict: 'approve', evaluator_runtime: 'openrouter.claude-opus-4', generator_runtime: 'openrouter.claude-opus-4', cross_runtime: false },
  { at: '14:02', task_id: 'task-7729', task_title: 'connector 재시도 백오프', agent_name: 'analyst', gate: 'completion_contract', verdict: 'reject', evaluator_runtime: 'deepseek.deepseek-v4-flash', generator_runtime: null, cross_runtime: false, fallback_reason: 'evaluator_runtime_unavailable' },
];
const HN_PRECOMPACT = [
  { at: '14:31', keeper_name: 'sangsu', checkpoint_bytes: 1841200, message_count: 118, strategies: ['keep_active_task', 'summarize_thinking', 'drop_cancelled_paths'], trigger: 'provider overflow recovery' },
  { at: '13:44', keeper_name: 'nick0cave', checkpoint_bytes: 1122400, message_count: 96, strategies: ['keep_active_task', 'summarize_tool_logs'], trigger: 'owner lane 수동 실행' },
];
const HN_HANDOFFS = [
  { at: '13:12', keeper_name: 'masc-improver', trace_id: 'T-3902', generation: 3, next_generation: 4, prev_trace_id: 'T-3871', new_trace_id: 'T-3902' },
];
const HN_RAIL_TONE = { healthy: 'ok', warning: 'warn', stale: 'warn', idle: 'neutral' };

function LabHarness() {
  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>세이프티 하네스</h3>
        <span className="ia-count mono">마지막 신호 {HN_OVERVIEW.last_signal_at}</span>
        <span className="ia-route mono">lab?section=harness</span>
      </div>
      <p className="ia-lede">평가 모델(evaluator) · 압축 직전 상태(pre-compact) · 세대 핸드오프 세 레일의 신호를 지켜봅니다. 모두 <b>보기 전용</b>이며, 여기에는 정책 저작 컨트롤이 없습니다.</p>
      <div className="ai-strip">
        {[['evaluator', HN_OVERVIEW.evaluator_status], ['pre-compact', HN_OVERVIEW.pre_compact_status], ['handoff', HN_OVERVIEW.handoff_status]].map(([k, v]) => (
          <div key={k} className="ai-stat"><span className="k">{k}</span><span className={`v mono ${HN_RAIL_TONE[v] === 'ok' ? 'ok' : HN_RAIL_TONE[v] === 'warn' ? 'bad' : ''}`}>{v}</span></div>
        ))}
        <div className="ai-stat"><span className="k">fallback 비율</span><span className="v mono">{(HN_OVERVIEW.fallback_ratio * 100).toFixed(1)}%</span></div>
        <div className="ai-stat"><span className="k">교차 모델 비율</span><span className="v mono">{(HN_OVERVIEW.cross_model_rate * 100).toFixed(0)}%</span><span className="cl-sub mono">generator ≠ evaluator</span></div>
        <div className="ai-stat"><span className="k">최근 checkpoint</span><span className="v mono">{(HN_OVERVIEW.latest_pre_compact_checkpoint_bytes / 1048576).toFixed(2)} MB</span></div>
        <div className="ai-stat"><span className="k">최근 세대</span><span className="v mono">gen {HN_OVERVIEW.latest_handoff_generation}</span></div>
      </div>

      <section className="lab-panel">
        <h4>캘리브레이션</h4>
        <div className="lab-kv">
          <div className="lab-kv-row"><span className="k">판정 수</span><span className="v mono">{HN_CAL.total_verdicts}</span><span className="s mono">approve {HN_CAL.approve_count} · reject {HN_CAL.reject_count}</span></div>
          <div className="lab-kv-row"><span className="k">일치율</span><span className="v mono">{(HN_CAL.agreement_rate * 100).toFixed(1)}%</span><span className="s mono">labeled {HN_CAL.labeled_count} · FP {HN_CAL.false_positive_count} · FN {HN_CAL.false_negative_count}</span></div>
          <div className="lab-kv-row"><span className="k">gate 분포</span><span className="v mono">{Object.entries(HN_CAL.gate_distribution).map(([g, n]) => `${g} ${n}`).join(' · ')}</span><span className="s mono">gate_distribution</span></div>
          <div className="lab-kv-row"><span className="k">fallback</span><span className="v mono">{HN_CAL.fallback_count}</span><span className="s mono">{HN_CAL.recent_fallback_reasons.join(' · ')}</span></div>
        </div>
      </section>

      <section className="lab-panel">
        <h4>최근 판정</h4>
        <div className="ai-tablewrap">
          <table className="ai-table">
            <thead><tr><th>시각</th><th>태스크</th><th>agent</th><th>gate</th><th>판정</th><th>evaluator ← generator</th></tr></thead>
            <tbody>
              {HN_VERDICTS.map(v => (
                <tr key={v.task_id}>
                  <td className="mono dim">{v.at}</td>
                  <td className="mono">{v.task_id}<div className="ai-d">{v.task_title}</div></td>
                  <td className="mono">{v.agent_name}</td>
                  <td className="mono dim">{v.gate}</td>
                  <td><span className={`ai-b ${v.verdict === 'approve' ? 'ok' : 'bad'}`}>{v.verdict}</span></td>
                  <td className="mono dim">
                    {v.evaluator_runtime} ← {v.generator_runtime || '—'}
                    {v.cross_runtime && <span className="lab-x">cross</span>}
                    {v.fallback_reason && <div className="lab-fb mono">{v.fallback_reason}</div>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="lab-panel">
        <h4>압축 직전 상태 · pre-compact</h4>
        <div className="ai-tablewrap">
          <table className="ai-table">
            <thead><tr><th>시각</th><th>키퍼</th><th className="r">checkpoint</th><th className="r">메시지</th><th>전략</th><th>트리거</th></tr></thead>
            <tbody>
              {HN_PRECOMPACT.map((e, i) => (
                <tr key={i}>
                  <td className="mono dim">{e.at}</td>
                  <td className="mono">{e.keeper_name}</td>
                  <td className="mono r">{(e.checkpoint_bytes / 1048576).toFixed(2)} MB</td>
                  <td className="mono r dim">{e.message_count}</td>
                  <td className="mono dim">{e.strategies.join(' · ')}</td>
                  <td className="ai-d">{e.trigger}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="ia-note">트리거는 임계치가 아니라 provider overflow 복구 또는 owner-lane 수동 실행입니다 — 비율 · 메시지 수 · 토큰 게이트는 제거되었습니다.</p>
      </section>

      <section className="lab-panel">
        <h4>세대 핸드오프</h4>
        {HN_HANDOFFS.length === 0
          ? <div className="ia-empty">최근 핸드오프 이벤트 없음.</div>
          : <div className="ai-tablewrap">
              <table className="ai-table">
                <thead><tr><th>시각</th><th>키퍼</th><th>세대</th><th>prev trace</th><th>new trace</th></tr></thead>
                <tbody>
                  {HN_HANDOFFS.map((h, i) => (
                    <tr key={i}>
                      <td className="mono dim">{h.at}</td>
                      <td className="mono">{h.keeper_name}</td>
                      <td className="mono">gen {h.generation} → {h.next_generation}</td>
                      <td className="mono dim">{h.prev_trace_id}</td>
                      <td className="mono dim">{h.new_trace_id}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>}
        <p className="ia-note">핸드오프 이벤트는 남아 있지만 <span className="mono">Handoff_triggered</span> · <span className="mono">handoff_rate</span> 프로듀서와 자동 임계치는 제거되었습니다. HandingOff FSM 상태와 task 의 <span className="mono">handoff_context</span> 는 그대로 유지됩니다.</p>
      </section>
    </div>
  );
}

/* ── 성능 프로브 ──────────────────────────────────────────────────────── */
function LabPerf() {
  const [fps, setFps] = useStateLab(0);
  const [rows, setRows] = useStateLab(2000);
  const raf = useRefLab(0);
  useEffectLab(() => {
    let frames = 0, last = performance.now(), alive = true;
    const loop = () => {
      if (!alive) return;
      frames++;
      const now = performance.now();
      if (now - last >= 500) { setFps(Math.round((frames * 1000) / (now - last))); frames = 0; last = now; }
      raf.current = requestAnimationFrame(loop);
    };
    raf.current = requestAnimationFrame(loop);
    return () => { alive = false; cancelAnimationFrame(raf.current); };
  }, []);
  const probes = [
    ['VirtualList', `행 ${rows.toLocaleString()} · 가시 행만 렌더`, 'KVP.VirtualList'],
    ['content-visibility', '로스터 행 · 오프스크린 레이아웃 생략', 'contain-intrinsic-size'],
    ['native dialog', '<dialog> top-layer · Esc 닫기', 'showModal'],
    ['ResizeObserver', '레일 폭 측정 · 윈도잉 계산', 'useSize'],
    ['IntersectionObserver', '스레드 unread 경계 관측', 'useVisible'],
  ];
  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>성능</h3>
        <span className="ia-count mono">{fps} fps</span>
        <span className="ia-route mono">lab?section=performance</span>
      </div>
      <p className="ia-lede">FPS 미터 · VirtualList · content-visibility · native dialog · observer 프로브. 같은 컴포넌트 라이브러리를 수만 행 규모로 밀어보는 계측 패널입니다.</p>
      <div className="ai-strip">
        <div className="ai-stat"><span className="k">FPS</span><span className={`v mono ${fps >= 50 ? 'ok' : fps ? 'bad' : ''}`}>{fps || '—'}</span></div>
        <div className="ai-stat"><span className="k">windowed rows</span><span className="v mono">{rows.toLocaleString()}</span></div>
        <div className="ai-stat"><span className="k">DOM 행</span><span className="v mono">~28</span><span className="cl-sub mono">가시 영역만</span></div>
      </div>
      <div className="lab-perf-ctl">
        <label className="lab-f"><span>행 수</span>
          <input type="range" min="500" max="50000" step="500" value={rows} onChange={e => setRows(+e.target.value)} />
        </label>
        <span className="mono dim">{rows.toLocaleString()} rows</span>
      </div>
      <div className="ai-tablewrap">
        <table className="ai-table">
          <thead><tr><th>프로브</th><th>측정</th><th>구현</th></tr></thead>
          <tbody>
            {probes.map(([p, m, i]) => (
              <tr key={p}><td className="mono">{p}</td><td className="ai-d">{m}</td><td className="mono dim">{i}</td></tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

/* ── 키퍼 메모리 상태 ─────────────────────────────────────────────────── */
const KMH_ROWS = [
  { keeper_id: 'masc-improver', revision: 412, facts: 1841, snapshot_bytes: 512400, added: 6, removed: 2, lane_busy: 0, failures: 0, snapshot_present: true, alerts: [] },
  { keeper_id: 'nick0cave', revision: 388, facts: 1204, snapshot_bytes: 388100, added: 3, removed: 0, lane_busy: 1, failures: 0, snapshot_present: true, alerts: [{ label: 'lane busy', severity: 'warn', message: 'Librarian lane 점유 — upsert 지연' }] },
  { keeper_id: 'sangsu', revision: 201, facts: 640, snapshot_bytes: 190200, added: 0, removed: 0, lane_busy: 0, failures: 3, snapshot_present: false, alerts: [{ label: 'librarian starvation', severity: 'error', message: 'current-memory snapshot 없음 — Librarian 실패 3회' }] },
  { keeper_id: 'qa-king', revision: 96, facts: 288, snapshot_bytes: 74100, added: 1, removed: 1, lane_busy: 0, failures: 0, snapshot_present: true, alerts: [] },
  { keeper_id: 'analyst', revision: 44, facts: 120, snapshot_bytes: 31200, added: 0, removed: 0, lane_busy: 0, failures: 0, snapshot_present: true, alerts: [{ label: 'read error', severity: 'warn', message: 'snapshot 읽기 1회 실패 — 재시도 성공' }] },
];
function kmhBytes(b) { return b < 1024 ? b + ' B' : b < 1048576 ? (b / 1024).toFixed(1) + ' KB' : (b / 1048576).toFixed(2) + ' MB'; }
function LabMemoryHealth() {
  const t = KMH_ROWS.reduce((a, r) => ({
    facts: a.facts + r.facts, bytes: a.bytes + r.snapshot_bytes, added: a.added + r.added, removed: a.removed + r.removed,
    busy: a.busy + r.lane_busy, fail: a.fail + r.failures,
    read: a.read + r.alerts.filter(x => x.label === 'read error').length,
    starv: a.starv + (r.snapshot_present ? 0 : 1), alerts: a.alerts + r.alerts.length,
  }), { facts: 0, bytes: 0, added: 0, removed: 0, busy: 0, fail: 0, read: 0, starv: 0, alerts: 0 });
  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>키퍼 메모리 상태</h3>
        <span className="ia-count mono">current-memory snapshot</span>
        <span className="ia-route mono">lab?section=keeper-memory-health</span>
      </div>
      <p className="ia-lede">keeper 별 현행 스냅샷 revision · 정확 델타 · 읽기 실패 · Librarian 레인 압력만 보여주는 읽기 전용 진단입니다. 구 이벤트/사실 스토어 뷰나 GC 뷰는 없습니다 — 주기 consolidation 은 제거되었고 GC 는 <span className="mono">valid_until</span> 지난 행만 지웁니다.</p>
      <div className="ai-strip">
        <div className="ai-stat"><span className="k">전체 사실</span><span className="v mono">{t.facts.toLocaleString()}</span></div>
        <div className="ai-stat"><span className="k">스냅샷 크기</span><span className="v mono">{kmhBytes(t.bytes)}</span></div>
        <div className="ai-stat"><span className="k">최근 추가</span><span className="v mono">+{t.added}</span></div>
        <div className="ai-stat"><span className="k">최근 제거</span><span className="v mono">−{t.removed}</span></div>
        <div className="ai-stat"><span className="k">읽기 오류</span><span className={`v mono ${t.read ? 'bad' : ''}`}>{t.read}</span></div>
        <div className="ai-stat"><span className="k">lane busy</span><span className={`v mono ${t.busy ? 'bad' : ''}`}>{t.busy}</span></div>
        <div className="ai-stat"><span className="k">Librarian 실패</span><span className={`v mono ${t.fail ? 'bad' : ''}`}>{t.fail}</span></div>
        <div className="ai-stat"><span className="k">메모리 없는 키퍼</span><span className={`v mono ${t.starv ? 'bad' : ''}`}>{t.starv}</span></div>
        <div className="ai-stat"><span className="k">경보</span><span className={`v mono ${t.alerts ? 'bad' : ''}`}>{t.alerts}</span></div>
        <div className="ai-stat"><span className="k">케이던스 카운터</span><span className="v mono">{KMH_ROWS.length}</span></div>
      </div>
      <div className="ai-tablewrap">
        <table className="ai-table">
          <thead><tr><th>키퍼</th><th className="r">revision</th><th className="r">사실</th><th className="r">bytes</th><th className="r">추가</th><th className="r">제거</th><th className="r">lane busy</th><th className="r">실패</th><th>snapshot</th><th>경보</th></tr></thead>
          <tbody>
            {KMH_ROWS.map(r => {
              const err = r.alerts.some(a => a.severity === 'error');
              return (
                <tr key={r.keeper_id} className={err ? 'fail' : ''}>
                  <td className="mono">{r.keeper_id}</td>
                  <td className="mono r dim">{r.revision}</td>
                  <td className="mono r">{r.facts.toLocaleString()}</td>
                  <td className="mono r dim">{kmhBytes(r.snapshot_bytes)}</td>
                  <td className="mono r"><span className="ai-b ok">+{r.added}</span></td>
                  <td className="mono r"><span className="ai-b ok">−{r.removed}</span></td>
                  <td className="mono r"><span className={`ai-b ${r.lane_busy ? '' : 'ok'}`}>{r.lane_busy}</span></td>
                  <td className="mono r"><span className={`ai-b ${r.failures ? 'bad' : 'ok'}`}>{r.failures}</span></td>
                  <td>{r.snapshot_present ? <span className="ai-b ok">정상</span> : <span className="ai-b bad">없음</span>}</td>
                  <td>{r.alerts.length === 0 ? <span className="ai-b ok">정상</span> : r.alerts.map((a, i) => <span key={i} className={`ai-b ${a.severity === 'error' ? 'bad' : ''}`} title={a.message}>{a.label}</span>)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function LabSurface() {
  const [sec, setSec] = useStateLab('tools');
  return (
    <div className="fl-shell">
      <div className="fl-top">
        <div className="fl-brand">
          <span className="ov-eyebrow">비 rail surface · route 접근</span>
          <span className="fl-title">Lab</span>
        </div>
        <div className="fl-health">
          <span className="fl-hpill">도구 진단</span>
          <span className="fl-hpill">실험 제어</span>
        </div>
        <div className="fl-spacer"></div>
        <div className="fl-meta">
          <span className="mono">lab?section={sec === 'memory' ? 'keeper-memory-health' : sec === 'audit' ? 'audit-integrity' : sec}</span>
          <span>{window.FL_VERSION || ''}</span>
        </div>
      </div>
      <div className="fl-secs">
        {LAB_SECS.map(([id, lbl]) => (
          <button key={id} className={`fl-sec ${sec === id ? 'on' : ''}`} onClick={() => setSec(id)}>{lbl}</button>
        ))}
      </div>
      {sec === 'tools' && <LabTools />}
      {sec === 'harness' && <LabHarness />}
      {sec === 'performance' && <LabPerf />}
      {sec === 'memory' && <LabMemoryHealth />}
      {sec === 'audit' && window.AuditIntegrityPanel && <window.AuditIntegrityPanel />}
    </div>
  );
}

Object.assign(window, { LabSurface });
