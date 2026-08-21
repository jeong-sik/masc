/* MASC v2 — Monitor 나머지 섹션 (2026-08 소스 정합, 2차)
   · monitoring?section=fleet-health  → components/fleet-health-panel.ts (Tool Monitor)
       view = default(Operations) · tool-quality · gate · event-log · comparison ·
              attribution · keeper-health(반응성 모니터)
   · monitoring?section=observatory   → components/observatory/observatory.ts
   레거시 라우트: monitoring:telemetry→event-log · fleet→comparison ·
   tool-quality→tool-quality · gate→gate · attribution→attribution */
const { useState: useStateTM, useEffect: useEffectTM, useMemo: useMemoTM } = React;

/* ── Tool Monitor · 관측 데이터 (tool_call_io 소스) ───────────────────── */
const TM_WINDOW_H = 24;
const TM_SOURCE = { source: 'tool_call_io', health: 'healthy', latest_age_s: 42, entry_count: 128410 };
const TM_TOOLS = [
  { name: 'keeper_board_list', calls: 4182, success_pct: 99.8, avg_ms: 128, avg_output_chars: 2410 },
  { name: 'keeper_tasks_list', calls: 3901, success_pct: 99.4, avg_ms: 141, avg_output_chars: 3180 },
  { name: 'tool_read_file', calls: 3350, success_pct: 97.1, avg_ms: 96, avg_output_chars: 8820 },
  { name: 'tool_execute', calls: 2214, success_pct: 88.6, avg_ms: 18420, output_truncated_count: 61 },
  { name: 'keeper_board_comment', calls: 1908, success_pct: 99.9, avg_ms: 210, avg_output_chars: 640 },
  { name: 'tool_edit_file', calls: 1502, success_pct: 94.2, avg_ms: 302, avg_output_chars: 1120 },
  { name: 'masc_fusion', calls: 288, success_pct: 71.5, avg_ms: 24110, avg_output_chars: 12400 },
  { name: 'keeper_memory_upsert', calls: 264, success_pct: 100, avg_ms: 88, avg_output_chars: 320 },
];
const TM_FAILCATS = [
  { category: 'exec_nonzero_exit', count: 188 },
  { category: 'descriptor_validation_rejected', count: 94 },
  { category: 'joj_panel_missing', count: 41 },
  { category: 'provider_stream_idle_timeout', count: 12 },
  { category: 'path_outside_workspace', count: 9 },
];
const TM_FLEET = { executable: 5, target: 7, shortfall: 2, paused: 2 };
const TM_FACTS = [
  { keeper: 'sangsu', task: 'task-7741', label: '실행 불가 · fiber 없음', tone: 'bad',
    reason: 'fiber_unresolved(unexpected)', truth: 'execution_truth=not_running', cause: 'supervisor 재기동 대기',
    action: '재시작 후 소유 태스크 재확인' },
  { keeper: 'nick0cave', task: null, label: 'operator 일시정지', tone: 'warn',
    reason: 'paused_by_operator', truth: 'execution_truth=paused', cause: 'operator 명령',
    action: '재개하거나 태스크를 인계' },
];
const TM_PAUSED = [
  { name: 'nick0cave', pause_kind: 'operator', klass: null, detail: null, elapsed: 1840 },
  { name: 'reviewer', pause_kind: 'blocked', klass: 'gate_wait', detail: 'H-041 HITL 응답 대기', elapsed: 265 },
];
const TM_PAUSE_ERRS = [{ keeper: 'ghost-04', error: 'paused-state read 실패 — .masc/keepers/ghost-04 없음' }];
const TM_EVENTS = [
  { at: '14:33:02', keeper: 'masc-improver', tool: 'tool_read_file', disposition: 'allowed', ms: 96, bytes: 8820, trace: 'T-3902' },
  { at: '14:32:41', keeper: 'sangsu', tool: 'tool_execute', disposition: 'allowed', ms: 41220, bytes: 12400, trace: 'T-3901', truncated: true },
  { at: '14:31:58', keeper: 'sangsu', tool: 'tool_edit_file', disposition: 'gate_hitl', ms: null, bytes: 0, trace: 'T-3901' },
  { at: '14:30:12', keeper: 'qa-king', tool: 'keeper_tasks_list', disposition: 'allowed', ms: 141, bytes: 3180, trace: 'T-3898' },
  { at: '14:28:44', keeper: 'analyst', tool: 'masc_fusion', disposition: 'rejected', ms: 210, bytes: 0, trace: 'T-3896' },
];
const TM_CMP = [
  { keeper: 'masc-improver', calls: 5120, success_pct: 98.9, avg_ms: 184, trust: 'high', rows: 41200 },
  { keeper: 'nick0cave', calls: 3980, success_pct: 97.2, avg_ms: 240, trust: 'high', rows: 32040 },
  { keeper: 'sangsu', calls: 2210, success_pct: 89.4, avg_ms: 6120, trust: 'partial', rows: 18800, gap: 3 },
  { keeper: 'qa-king', calls: 1180, success_pct: 99.1, avg_ms: 132, trust: 'high', rows: 9400 },
  { keeper: 'analyst', calls: 402, success_pct: 74.6, avg_ms: 20140, trust: 'low', rows: 2810, gap: 11 },
];
const TM_GATES = [
  { gate: 'descriptor_validation', passed: 8420, policy_failed: 94, transition_blocked: 0, partial_pass: 0 },
  { gate: 'gate_always_allow', passed: 5104, policy_failed: 0, transition_blocked: 0, partial_pass: 0 },
  { gate: 'gate_auto_judge', passed: 612, policy_failed: 88, transition_blocked: 14, partial_pass: 22 },
  { gate: 'gate_hitl', passed: 141, policy_failed: 6, transition_blocked: 3, partial_pass: 0 },
  { gate: 'completion_contract', passed: 388, policy_failed: 41, transition_blocked: 9, partial_pass: 61 },
];
const TM_ATTR = [
  { at: '14:33', origin: 'keeper:masc-improver', outcome: 'passed', gate: 'descriptor_validation', subject: 'tool_read_file' },
  { at: '14:31', origin: 'gate:auto_judge', outcome: 'partial_pass', gate: 'gate_auto_judge', subject: 'H-041 tool_edit_file' },
  { at: '14:28', origin: 'keeper:analyst', outcome: 'policy_failed', gate: 'completion_contract', subject: 'task-7741 증거 누락' },
  { at: '14:19', origin: 'connector:discord', outcome: 'transition_blocked', gate: 'gate_hitl', subject: 'post-4471 wake' },
];

const TM_VIEWS = [
  ['default', 'Operations'], ['tool-quality', 'Tool Quality'], ['gate', 'Gate'],
  ['event-log', 'Evidence Log'], ['comparison', 'Keeper 비교'], ['attribution', 'Attribution'],
  ['keeper-health', '반응성 모니터'],
];

function tmMs(v) { return v == null ? '—' : v >= 1000 ? (v / 1000).toFixed(1) + 's' : v + 'ms'; }
function tmOut(r) { return r.output_truncated_count ? `${r.output_truncated_count} clipped` : `${((r.avg_output_chars || 0) / 1000).toFixed(1)}k`; }
function tmShort(n) { return n.replace('keeper_', '').replace('masc_', 'm:'); }
function tmElapsed(s) { return s < 60 ? `${s}s` : s < 3600 ? `${Math.round(s / 60)}m` : `${Math.round(s / 3600)}h`; }

function TmTile({ k, v, tone, sub }) {
  return (
    <div className="tm-tile" data-tone={tone || 'neutral'}>
      <span className="k">{k}</span>
      <span className="v mono">{v}</span>
      {sub && <span className="s mono">{sub}</span>}
    </div>
  );
}

function TmToolTable({ rows, full }) {
  return (
    <div className="ai-tablewrap">
      <table className="ai-table">
        <thead><tr><th>도구</th><th className="r">호출</th><th className="r">성공</th><th className="r">지연</th><th className="r">출력</th>{full && <th className="r">클립</th>}</tr></thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.name}>
              <td className="mono" title={r.name}>{tmShort(r.name)}</td>
              <td className="mono r">{r.calls.toLocaleString()}</td>
              <td className={`mono r ${r.success_pct < 90 ? 'bad' : ''}`}>{r.success_pct.toFixed(1)}%</td>
              <td className="mono r dim">{tmMs(r.avg_ms)}</td>
              <td className="mono r dim">{tmOut(r)}</td>
              {full && <td className="mono r dim">{r.output_truncated_count || 0}</td>}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function TmOperations({ onView }) {
  const total = TM_TOOLS.reduce((a, r) => a + r.calls, 0);
  const fail = Math.round(TM_TOOLS.reduce((a, r) => a + r.calls * (1 - r.success_pct / 100), 0));
  const rate = ((1 - fail / total) * 100).toFixed(1);
  return (
    <div className="tm-board">
      <div className="tm-src">
        <span className="mono">{TM_SOURCE.source}</span>
        <span className="mono ok">{TM_SOURCE.health}</span>
        <span className="mono dim">latest {TM_SOURCE.latest_age_s}s · {TM_SOURCE.entry_count.toLocaleString()} durable rows</span>
        <span className="mono dim">최근 {TM_WINDOW_H}h · 자동 갱신 30s</span>
      </div>
      <div className="tm-tiles">
        <TmTile k="Success" v={`${rate}%`} tone="ok" />
        <TmTile k="Calls" v={total.toLocaleString()} />
        <TmTile k="Failures" v={fail.toLocaleString()} tone={fail ? 'warn' : 'neutral'} />
        <TmTile k="Reaction capacity" v={`${TM_FLEET.executable}/${TM_FLEET.target}`} tone="warn" sub={`shortfall ${TM_FLEET.shortfall}`} />
        <TmTile k="Paused keepers" v={TM_FLEET.paused} tone="warn" sub={TM_PAUSED.map(p => p.name).join(', ')} />
      </div>

      <section className="tm-sec">
        <h4>Keeper operator facts</h4>
        <div className="ai-tablewrap">
          <table className="ai-table">
            <thead><tr><th>키퍼</th><th>현재 사실</th><th>operator 행동</th></tr></thead>
            <tbody>
              {TM_FACTS.map(f => (
                <tr key={f.keeper}>
                  <td className="mono">{f.keeper}{f.task && <div className="mono dim tm-sub">{f.task}</div>}</td>
                  <td>
                    <span className={`ai-b ${f.tone}`}>{f.label}</span>
                    <div className="mono dim tm-sub">{f.reason} · {f.truth} · {f.cause}</div>
                  </td>
                  <td className="ai-d">{f.action}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="tm-sec">
        <h4>Paused keeper diagnostics</h4>
        <div className="ai-tablewrap">
          <table className="ai-table">
            <thead><tr><th>키퍼</th><th>일시정지</th><th className="r">경과</th></tr></thead>
            <tbody>
              {TM_PAUSED.map(p => (
                <tr key={p.name}>
                  <td className="mono">{p.name}</td>
                  <td title={p.detail || ''}>{p.pause_kind}{p.klass ? ` · blocker=${p.klass}` : ''}{p.detail && <div className="mono dim tm-sub">{p.detail}</div>}</td>
                  <td className="mono r dim">{tmElapsed(p.elapsed)}</td>
                </tr>
              ))}
              {TM_PAUSE_ERRS.map(e => (
                <tr key={e.keeper} className="fail"><td className="mono bad">{e.keeper}</td><td className="bad" colSpan={2}>{e.error}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <div className="tm-split">
        <section className="tm-sec">
          <h4>Tool observations</h4>
          <TmToolTable rows={TM_TOOLS.slice(0, 6)} />
          <button className="tm-link" onClick={() => onView('tool-quality')}>전체 품질 표 →</button>
        </section>
        <div className="tm-side">
          <section className="tm-sec">
            <h4>Lanes</h4>
            <div className="tm-lanes">
              {[['tool-quality', 'Tool Quality', 'success · latency · output truncation'],
                ['gate', 'Gate', 'HITL 큐 · 도구 거절 관측'],
                ['event-log', 'Keeper Tool I/O', 'durable tool-call 증거'],
                ['comparison', 'Keeper Comparison', 'keeper 행 · tool confidence']].map(([v, t, m]) => (
                <button key={v} className="tm-lane" onClick={() => onView(v)}>
                  <span className="tm-lane-t">{t}</span>
                  <span className="tm-lane-m">{m}</span>
                  <span className="tm-lane-o mono">Open</span>
                </button>
              ))}
            </div>
          </section>
          <section className="tm-sec">
            <h4>Failure categories</h4>
            <div className="tm-cats">
              {TM_FAILCATS.map(c => (
                <div key={c.category} className="tm-cat"><span className="mono">{c.category}</span><span className="mono dim">{c.count}x</span></div>
              ))}
            </div>
          </section>
        </div>
      </div>
    </div>
  );
}

/* 반응성 모니터 — 상태 그리드 · 상태 전환 · 생명주기 이벤트 · 일시정지 */
const TM_REACT_VIEWS = [['health', '상태 그리드'], ['lifecycle', '상태 전환'], ['events', '생명주기 이벤트'], ['pause', '일시정지']];
const TM_LIFE = [
  { at: '14:33', keeper: 'masc-improver', from: 'Idle', to: 'Running', by: 'wake · board mention' },
  { at: '14:31', keeper: 'sangsu', from: 'Running', to: 'Overflowed', by: 'provider overflow' },
  { at: '14:31', keeper: 'sangsu', from: 'Overflowed', to: 'Compacting', by: 'Compaction_started' },
  { at: '14:22', keeper: 'nick0cave', from: 'Running', to: 'Paused', by: 'operator' },
];
const TM_LIFE_EV = [
  { at: '14:34', ev: 'Started', keeper: 'reviewer', detail: 'autoboot · slot 6' },
  { at: '14:29', ev: 'Restarted', keeper: 'sangsu', detail: 'fiber_unresolved(unexpected) → 재기동 예산 2/3' },
  { at: '14:11', ev: 'Dead_cleaned', keeper: 'ghost-04', detail: 'graceful_shutdown 이후 정리' },
  { at: '13:58', ev: 'Cancelled', keeper: 'analyst', detail: 'cancelled_by_parent' },
];
function TmReactivity() {
  const [rv, setRv] = useStateTM('health');
  const ks = (window.KEEPERS || []);
  const paused = ks.filter(k => k.status === 'pause');
  return (
    <div className="tm-board">
      <div className="ia-filters">
        {TM_REACT_VIEWS.map(([id, lbl]) => (
          <button key={id} className={`ia-filter ${rv === id ? 'on' : ''}`} aria-pressed={rv === id} onClick={() => setRv(id)}>{lbl}</button>
        ))}
      </div>
      {rv === 'health' && (
        <div className="ai-tablewrap">
          <table className="ai-table">
            <thead><tr><th>키퍼</th><th>단계</th><th>활동</th><th>마지막 활동</th><th className="r">회전 수</th></tr></thead>
            <tbody>
              {ks.map(k => (
                <tr key={k.id}>
                  <td className="mono">{k.id}</td>
                  <td>{k.phase}{k.status === 'pause' && <span className="tm-pausedot">⏸ 일시정지</span>}</td>
                  <td className="dim">{k.status === 'run' ? 'streaming' : k.status === 'pause' ? 'paused' : 'offline'}</td>
                  <td className="mono dim">{k.last}</td>
                  <td className="mono r dim">{k.turns != null ? k.turns : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {rv === 'lifecycle' && (
        <div className="tm-time">
          {TM_LIFE.map((t, i) => (
            <div key={i} className="tm-time-row">
              <span className="mono dim">{t.at}</span>
              <span className="mono">{t.keeper}</span>
              <span className="tm-tr"><b>{t.from}</b> → <b>{t.to}</b></span>
              <span className="dim">{t.by}</span>
            </div>
          ))}
        </div>
      )}
      {rv === 'events' && (
        <div className="tm-time">
          {TM_LIFE_EV.map((t, i) => (
            <div key={i} className="tm-time-row">
              <span className="mono dim">{t.at}</span>
              <span className="ai-b">{t.ev}</span>
              <span className="mono">{t.keeper}</span>
              <span className="dim">{t.detail}</span>
            </div>
          ))}
        </div>
      )}
      {rv === 'pause' && (paused.length === 0
        ? <div className="tm-ok">✓ 일시정지된 키퍼 없음 — 모든 키퍼가 정상 운영 중입니다</div>
        : <div className="tm-paused-list">
            {paused.map(k => (
              <div key={k.id} className="tm-paused-card">
                <span className="mono">⏸ {k.id}</span>
                <span className="dim">{k.phase}</span>
                {(TM_PAUSED.find(p => p.name === k.id) || {}).detail && <span className="tm-blk">{TM_PAUSED.find(p => p.name === k.id).detail}</span>}
              </div>
            ))}
          </div>)}
    </div>
  );
}

function ToolMonitorPanel() {
  const [view, setView] = useStateTM('default');
  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>도구 실행</h3>
        <span className="ia-count mono">최근 {TM_WINDOW_H}시간</span>
        <span className="ia-route mono">monitoring?section=fleet-health{view === 'default' ? '' : `&view=${view}`}</span>
      </div>
      <p className="ia-lede">도구 품질 · 도구 이벤트 증거 · Gate 지표 · keeper 비교를 한 섹션에서 봅니다. 구 <span className="mono">telemetry · fleet · tool-quality · gate · attribution</span> 라우트는 모두 이 섹션의 view 로 정규화됩니다.</p>
      <div className="ia-filters">
        {TM_VIEWS.map(([id, lbl]) => (
          <button key={id} className={`ia-filter ${view === id ? 'on' : ''}`} aria-pressed={view === id} onClick={() => setView(id)}>{lbl}</button>
        ))}
      </div>
      {view === 'default' && <TmOperations onView={setView} />}
      {view === 'tool-quality' && (
        <div className="tm-board">
          <p className="ia-note">by_tool 전체 — 성공률 · 평균 지연 · 출력 절단. 출력이 절단된 호출은 증거 로그에 <span className="mono">truncated</span> 로 남습니다.</p>
          <TmToolTable rows={TM_TOOLS} full />
        </div>
      )}
      {view === 'gate' && (
        <div className="tm-board">
          <p className="ia-note">Gate 관측 — 3 비계층 모드(Always Allow · LLM Auto Judge · HITL)의 게이트별 판정 집계. 상태는 <span className="mono">.masc/gate/</span> 가 소유하며, Always Allowed 규칙 저장소가 손상되면 exact-rule 조회만 degrade 합니다.</p>
          <div className="ai-tablewrap">
            <table className="ai-table">
              <thead><tr><th>gate</th><th className="r">passed</th><th className="r">policy_failed</th><th className="r">transition_blocked</th><th className="r">partial_pass</th><th className="r">total</th></tr></thead>
              <tbody>
                {TM_GATES.map(g => {
                  const total = g.passed + g.policy_failed + g.transition_blocked + g.partial_pass;
                  return (
                    <tr key={g.gate}>
                      <td className="mono">{g.gate}</td>
                      <td className="mono r ok">{g.passed.toLocaleString()}</td>
                      <td className={`mono r ${g.policy_failed ? 'bad' : 'dim'}`}>{g.policy_failed}</td>
                      <td className="mono r dim">{g.transition_blocked}</td>
                      <td className="mono r dim">{g.partial_pass}</td>
                      <td className="mono r">{total.toLocaleString()}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {view === 'event-log' && (
        <div className="tm-board">
          <p className="ia-note">durable tool-call 증거 — <span className="mono">tool_call_io</span>. identity-translated <span className="mono">Execute · WebSearch · WebFetch</span> 는 public descriptor 검증이 단일 schema Gate 입니다.</p>
          <div className="ai-tablewrap">
            <table className="ai-table">
              <thead><tr><th>시각</th><th>키퍼</th><th>도구</th><th>disposition</th><th className="r">ms</th><th className="r">출력</th><th>trace</th></tr></thead>
              <tbody>
                {TM_EVENTS.map((e, i) => (
                  <tr key={i}>
                    <td className="mono dim">{e.at}</td>
                    <td className="mono">{e.keeper}</td>
                    <td className="mono">{tmShort(e.tool)}</td>
                    <td><span className={`ai-b ${e.disposition === 'allowed' ? 'ok' : e.disposition === 'rejected' ? 'bad' : 'warn'}`}>{e.disposition}</span></td>
                    <td className="mono r dim">{tmMs(e.ms)}</td>
                    <td className="mono r dim">{e.bytes ? (e.bytes / 1000).toFixed(1) + 'k' : '—'}{e.truncated ? ' · trunc' : ''}</td>
                    <td className="mono dim">{e.trace}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {view === 'comparison' && (
        <div className="tm-board">
          <p className="ia-note">keeper 행 + execution trust. coverage gap 이 있는 행은 다른 소스가 비어 있어도 그 자체가 provenance 신호입니다.</p>
          <div className="ai-tablewrap">
            <table className="ai-table">
              <thead><tr><th>키퍼</th><th className="r">호출</th><th className="r">성공</th><th className="r">지연</th><th>trust</th><th className="r">durable rows</th><th className="r">coverage gap</th></tr></thead>
              <tbody>
                {TM_CMP.map(r => (
                  <tr key={r.keeper}>
                    <td className="mono">{r.keeper}</td>
                    <td className="mono r">{r.calls.toLocaleString()}</td>
                    <td className={`mono r ${r.success_pct < 90 ? 'bad' : ''}`}>{r.success_pct.toFixed(1)}%</td>
                    <td className="mono r dim">{tmMs(r.avg_ms)}</td>
                    <td><span className={`ai-b ${r.trust === 'high' ? 'ok' : r.trust === 'low' ? 'bad' : 'warn'}`}>{r.trust}</span></td>
                    <td className="mono r dim">{r.rows.toLocaleString()}</td>
                    <td className={`mono r ${r.gap ? 'bad' : 'dim'}`}>{r.gap || 0}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {view === 'attribution' && (
        <div className="tm-board">
          <p className="ia-note">게이트별 귀속 요약(<span className="mono">/attribution/summary</span>) + 최근 링 버퍼 이벤트(<span className="mono">/attribution/recent</span>). 구 <span className="mono">monitoring:attribution</span> 라우트가 이 view 로 정규화됩니다.</p>
          <div className="ai-tablewrap">
            <table className="ai-table">
              <thead><tr><th>시각</th><th>origin</th><th>outcome</th><th>gate</th><th>대상</th></tr></thead>
              <tbody>
                {TM_ATTR.map((a, i) => (
                  <tr key={i}>
                    <td className="mono dim">{a.at}</td>
                    <td className="mono">{a.origin}</td>
                    <td><span className={`ai-b ${a.outcome === 'passed' ? 'ok' : a.outcome === 'policy_failed' ? 'bad' : 'warn'}`}>{a.outcome}</span></td>
                    <td className="mono dim">{a.gate}</td>
                    <td className="ai-d">{a.subject}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {view === 'keeper-health' && <TmReactivity />}
    </div>
  );
}

/* ── Observatory — 공유 시간축 위의 3 트랙 (events · tool calls · metrics) ── */
const OB_RANGES = [['15m', 15 * 60e3], ['1h', 3600e3], ['6h', 6 * 3600e3], ['24h', 24 * 3600e3], ['7d', 7 * 24 * 3600e3]];
const OB_KINDS = {
  wake: { lbl: 'Keeper_woken', tone: 'ok' },
  compact: { lbl: 'Compaction_started', tone: 'warn' },
  gate: { lbl: 'Gate_requested', tone: 'info' },
  fail: { lbl: 'Keeper_failed', tone: 'bad' },
  fusion: { lbl: 'Fusion_run', tone: 'info' },
};
function obSeed(span) {
  // 결정적 의사난수 — 범위를 바꿔도 같은 창에서는 같은 그림
  let s = 7;
  const rnd = () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648;
  const kinds = Object.keys(OB_KINDS);
  const events = Array.from({ length: 26 }, (_, i) => ({
    id: i, t: rnd(), kind: kinds[Math.floor(rnd() * kinds.length)],
    keeper: ['masc-improver', 'sangsu', 'nick0cave', 'qa-king', 'analyst'][Math.floor(rnd() * 5)],
  })).sort((a, b) => a.t - b.t);
  const calls = Array.from({ length: 44 }, () => ({ t: rnd(), ms: Math.round(60 + rnd() * 4200), ok: rnd() > 0.14 }));
  const metric = Array.from({ length: 24 }, (_, i) => ({ t: i / 23, pct: 88 + Math.sin(i * 0.7) * 6 + rnd() * 3 }));
  return { events, calls, metric, span };
}
function obTicks(span) {
  const end = Date.now(), start = end - span;
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(start + (span * i) / 6);
    const hh = String(d.getHours()).padStart(2, '0'), mm = String(d.getMinutes()).padStart(2, '0');
    return span <= 24 * 3600e3 ? `${hh}:${mm}` : `${d.getMonth() + 1}/${d.getDate()} ${hh}h`;
  });
}

function ObservatoryPanel() {
  const [range, setRange] = useStateTM('1h');
  const [cursor, setCursor] = useStateTM(null);   // 0..1 공유 커서
  const [pick, setPick] = useStateTM(null);       // detail pane 선택
  const span = (OB_RANGES.find(r => r[0] === range) || OB_RANGES[1])[1];
  const data = useMemoTM(() => obSeed(span), [span]);
  useEffectTM(() => { setPick(null); setCursor(null); }, [range]);

  const near = cursor == null ? [] : data.events.filter(e => Math.abs(e.t - cursor) < 0.03);
  const nearCalls = cursor == null ? [] : data.calls.filter(c => Math.abs(c.t - cursor) < 0.03);
  const move = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    setCursor(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)));
  };

  return (
    <div className="ia-wrap">
      <div className="ia-head">
        <h3>관측</h3>
        <span className="ia-count mono">이벤트 {data.events.length}건</span>
        <span className="ia-route mono">monitoring?section=observatory&range={range}</span>
      </div>
      <p className="ia-lede">전체 keeper · {range} 창. 하나의 시간축 위에 텔레메트리 이벤트 · 도구 호출 · 성공률 지표를 겹쳐 봅니다. 갱신은 필터 변경 시 폴링이며, 라이브 스트리밍은 아직 없습니다.</p>
      <div className="ob-ranges">
        {OB_RANGES.map(([r]) => (
          <button key={r} className={`ia-filter ${range === r ? 'on' : ''}`} aria-pressed={range === r} onClick={() => setRange(r)}>{r}</button>
        ))}
      </div>

      <div className="ob-panel" onMouseMove={move} onMouseLeave={() => setCursor(null)}>
        <div className="ob-axis mono">{obTicks(span).map((t, i) => <span key={i}>{t}</span>)}</div>
        <div className="ob-track">
          <span className="ob-track-k mono">events</span>
          <div className="ob-lane">
            {data.events.map(e => (
              <button key={e.id} className={`ob-ev t-${OB_KINDS[e.kind].tone}`} style={{ left: (e.t * 100) + '%' }}
                title={`${OB_KINDS[e.kind].lbl} · ${e.keeper}`} onClick={() => setPick({ type: 'event', e })}></button>
            ))}
          </div>
        </div>
        <div className="ob-track">
          <span className="ob-track-k mono">tool calls</span>
          <div className="ob-lane">
            {data.calls.map((c, i) => (
              <span key={i} className={`ob-call ${c.ok ? '' : 'bad'}`} style={{ left: (c.t * 100) + '%', height: Math.min(100, 18 + (c.ms / 4200) * 82) + '%' }} title={`${c.ms}ms · ${c.ok ? 'ok' : 'failed'}`}></span>
            ))}
          </div>
        </div>
        <div className="ob-track">
          <span className="ob-track-k mono">success %</span>
          <div className="ob-lane">
            <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="ob-svg">
              <polyline points={data.metric.map(p => `${p.t * 100},${100 - (p.pct - 80) * 5}`).join(' ')} fill="none" stroke="currentColor" strokeWidth="1.2" vectorEffect="non-scaling-stroke" />
            </svg>
          </div>
        </div>
        {cursor != null && <div className="ob-cursor" style={{ left: (cursor * 100) + '%' }}></div>}
      </div>

      <div className="ob-readout">
        <span className="ia-k">Cross-signal readout</span>
        {cursor == null
          ? <span className="dim">트랙 위에 커서를 올리면 같은 시점의 이벤트 · 도구 호출 · 지표를 함께 읽습니다.</span>
          : <span className="mono">이벤트 {near.length} · 도구 호출 {nearCalls.length} · 성공률 {(data.metric[Math.min(23, Math.round(cursor * 23))].pct).toFixed(1)}%</span>}
      </div>

      <div className="ob-detail">
        <span className="ia-k">Detail pane</span>
        {pick
          ? <div className="ob-detail-body">
              <span className={`ai-b ${OB_KINDS[pick.e.kind].tone === 'bad' ? 'bad' : OB_KINDS[pick.e.kind].tone === 'ok' ? 'ok' : ''}`}>{OB_KINDS[pick.e.kind].lbl}</span>
              <span className="mono">{pick.e.keeper}</span>
              <span className="dim">이 이벤트의 전체 turn 은 Keepers 대화에서 turn inspector 로 엽니다.</span>
            </div>
          : <span className="dim">이벤트 마커를 클릭하면 상세가 여기에 열립니다.</span>}
      </div>
    </div>
  );
}

Object.assign(window, { ToolMonitorPanel, ObservatoryPanel });
