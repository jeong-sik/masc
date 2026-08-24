/* MASC v3 — 턴 워터폴 (Monitor)
   근거: journey-waterfall-state.ts (buildJourneyWaterfall / summarizeRuntimeTrace)
        · agent-monitor/live-timeline.ts (필터 칩 · events/min · 이벤트 배지)
   turn 으로 묶인 thinking / tool_call 항목을 시간축 위에 놓고, 그 turn 에
   상관된 runtime trace 증거를 같은 카드 안에서 읽는다. */
const { useState: useStateJW } = React;

const ENTRY_STATUS = {
  success: { lbl: '성공', tone: 'ok' }, failure: { lbl: '실패', tone: 'bad' },
  gate_rejected: { lbl: '승인 대기로 전환', tone: 'warn' }, unknown: { lbl: '미판정', tone: 'dim' },
};
const ENTRY_SOURCE = {
  trajectory: 'trajectory', 'trajectory+tool_call_log': 'trajectory+log', tool_call_log: 'tool_call_log', unknown: '출처 미기록',
};

/* 항목: kind thinking|tool_call, at = turn 시작 이후 ms, dur = duration_ms(null 가능) */
const JOURNEY = {
  'masc-improver': {
    turns: [
      { turn: 41, stimuli: [
          { kind: 'workspace_message', from: 'nick0cave', urgency: 'immediate', what: 'nick0cave가 보낸 메시지' },
          { kind: 'workspace_message', from: 'sangsu', urgency: 'normal', what: 'sangsu가 보낸 메시지' },
          { kind: 'board_signal', from: 'masc', urgency: 'normal', what: 'T-3880 배정' },
        ], evidence: { health: 'healthy', staleReason: null, traceId: 'tr_9a41c0', keeperTurnId: 41, maxAgentCoreTurnCount: 24, providerTerminalStatus: 'succeeded', providerTerminalExceptionKind: null, providerAttemptStartedCount: 3, providerAttemptFinishedCount: 3, eventBusCorrelatedCount: 18, contextCompactedCount: 0, contextCompactStartedCount: 0, memoryInjectedCount: 4, memoryFlushedCount: 1 },
        entries: [
          { id: 'e1', kind: 'thinking', at: 0, dur: null, status: 'unknown', source: 'trajectory', summary: '검토한 항목 중 T-3880 만 실제 수정이 필요하다고 판단', redacted: false },
          { id: 'e2', kind: 'tool_call', at: 1400, dur: 2100, status: 'success', source: 'trajectory+tool_call_log', tool: 'masc_board_list', plannedIndex: 0, batchIndex: 0, batchSize: 2, mode: 'concurrent', summary: '보드 목록 읽기' },
          { id: 'e3', kind: 'tool_call', at: 1450, dur: 3400, status: 'success', source: 'trajectory+tool_call_log', tool: 'masc_task_list', plannedIndex: 1, batchIndex: 1, batchSize: 2, mode: 'concurrent', summary: '진행 중인 작업 목록 읽기' },
          { id: 'e4', kind: 'thinking', at: 5100, dur: null, status: 'unknown', source: 'trajectory', summary: '사고 내용 비공개', redacted: true },
          { id: 'e5', kind: 'tool_call', at: 6000, dur: 14200, status: 'success', source: 'trajectory+tool_call_log', tool: 'masc_file_edit', plannedIndex: 2, batchIndex: 0, batchSize: 1, mode: 'serial', summary: 'lib/keeper/keeper_event_queue.ml 수정 (2곳)' },
          { id: 'e6', kind: 'tool_call', at: 21000, dur: 900, status: 'gate_rejected', source: 'tool_call_log', tool: 'masc_shell', plannedIndex: 3, batchIndex: 0, batchSize: 1, mode: 'serial', summary: 'dune build @runtest', gateReason: '쓰기 위험이 있어 운영자 승인 대기로 전환됨' },
        ] },
      { turn: 40, stimuli: [
          { kind: 'schedule_due', from: 'schedule', urgency: 'normal', what: '예약 실행 · board sweep' },
        ], evidence: { health: 'healthy', staleReason: null, traceId: 'tr_9a3f88', keeperTurnId: 40, maxAgentCoreTurnCount: 24, providerTerminalStatus: 'succeeded', providerTerminalExceptionKind: null, providerAttemptStartedCount: 2, providerAttemptFinishedCount: 2, eventBusCorrelatedCount: 11, contextCompactedCount: 1, contextCompactStartedCount: 1, memoryInjectedCount: 2, memoryFlushedCount: 2 },
        entries: [
          { id: 'f1', kind: 'thinking', at: 0, dur: null, status: 'unknown', source: 'trajectory', summary: '이전 턴 실패 원인부터 다시 읽는다', redacted: false },
          { id: 'f2', kind: 'tool_call', at: 800, dur: 5200, status: 'failure', source: 'trajectory+tool_call_log', tool: 'masc_file_read', plannedIndex: 0, batchIndex: 0, batchSize: 1, mode: 'serial', summary: 'state/keeper_event_queue/drifter.jsonl', error: '파일이 없습니다 (ENOENT)' },
          { id: 'f3', kind: 'tool_call', at: 6500, dur: 3100, status: 'success', source: 'trajectory+tool_call_log', tool: 'masc_grep', plannedIndex: 1, batchIndex: 0, batchSize: 1, mode: 'serial', summary: '대기 기록 파일이 만들어지는 지점 추적' },
        ] },
    ] },
  drifter: {
    turns: [
      { turn: null, evidence: { health: 'stale', staleReason: '마지막 기록 이후 8분 이상 갱신 없음', traceId: 'tr_71dd02', keeperTurnId: null, maxAgentCoreTurnCount: 24, providerTerminalStatus: 'exhausted', providerTerminalExceptionKind: 'ProviderRateLimited', providerAttemptStartedCount: 5, providerAttemptFinishedCount: 4, eventBusCorrelatedCount: 3, contextCompactedCount: 0, contextCompactStartedCount: 2, memoryInjectedCount: 0, memoryFlushedCount: 0 },
        entries: [
          { id: 'g1', kind: 'tool_call', at: 0, dur: 61000, status: 'failure', source: 'tool_call_log', tool: 'masc_shell', plannedIndex: null, batchIndex: null, batchSize: null, mode: null, summary: '빌드 실행', error: '60초 안에 끝나지 않아 중단' },
          { id: 'g2', kind: 'tool_call', at: 62000, dur: 1200, status: 'failure', source: 'tool_call_log', tool: 'masc_shell', plannedIndex: null, batchIndex: null, batchSize: null, mode: null, summary: '재시도', error: '모델 요청 한도 초과' },
        ] },
    ] },
  nick0cave: {
    turns: [
      { turn: 12, stimuli: [
          { kind: 'hitl_resolved', from: 'operator', urgency: 'immediate', what: '운영자 승인 해소' },
          { kind: 'workspace_message', from: 'qa-king', urgency: 'normal', what: '큐에이킹이 보낸 메시지' },
        ], evidence: { health: 'healthy', staleReason: null, traceId: 'tr_2b7101', keeperTurnId: 12, maxAgentCoreTurnCount: 24, providerTerminalStatus: 'succeeded', providerTerminalExceptionKind: null, providerAttemptStartedCount: 1, providerAttemptFinishedCount: 1, eventBusCorrelatedCount: 9, contextCompactedCount: 2, contextCompactStartedCount: 2, memoryInjectedCount: 6, memoryFlushedCount: 3 },
        entries: [
          { id: 'h1', kind: 'thinking', at: 0, dur: null, status: 'unknown', source: 'trajectory', summary: 'Fusion 패널 3개 결과를 하나로 합칠 기준 정리', redacted: false },
          { id: 'h2', kind: 'tool_call', at: 2000, dur: 8800, status: 'success', source: 'trajectory+tool_call_log', tool: 'masc_fusion_run', plannedIndex: 0, batchIndex: 0, batchSize: 3, mode: 'concurrent', summary: 'panel 1 · claude' },
          { id: 'h3', kind: 'tool_call', at: 2100, dur: 12400, status: 'success', source: 'trajectory+tool_call_log', tool: 'masc_fusion_run', plannedIndex: 1, batchIndex: 1, batchSize: 3, mode: 'concurrent', summary: 'panel 2 · gpt' },
          { id: 'h4', kind: 'tool_call', at: 2150, dur: 19600, status: 'unknown', source: 'trajectory', summary: 'panel 3 · judge (진행 중)', tool: 'masc_fusion_run', plannedIndex: 2, batchIndex: 2, batchSize: 3, mode: 'concurrent' },
        ] },
    ] },
};

function msTxt(ms) { return ms == null ? '미기록' : ms < 1000 ? `${ms}ms` : ms < 60000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s`; }
function turnSpan(t) { return Math.max(1, ...t.entries.map(e => e.at + (e.dur || 0))); }
function summarize(model) {
  const all = model ? model.turns.flatMap(t => t.entries) : [];
  return {
    turns: model ? model.turns.length : 0, entries: all.length,
    thinking: all.filter(e => e.kind === 'thinking').length,
    tools: all.filter(e => e.kind === 'tool_call').length,
    fail: all.filter(e => e.status === 'failure').length,
    gate: all.filter(e => e.status === 'gate_rejected').length,
    dur: all.reduce((s, e) => s + (e.dur || 0), 0),
  };
}

function EvidenceStrip({ ev, dev }) {
  if (!ev) return <div className="jw-ev none">실행 기록 없음</div>;
  const items = dev ? [
    ['health', ev.health, ev.health === 'healthy' ? 'ok' : 'warn'],
    ['trace_id', ev.traceId, 'dim'],
    ['keeper_turn_id', ev.keeperTurnId == null ? '미기록' : `${ev.keeperTurnId} / max ${ev.maxAgentCoreTurnCount}`, 'dim'],
    ['provider terminal', ev.providerTerminalStatus + (ev.providerTerminalExceptionKind ? ` · ${ev.providerTerminalExceptionKind}` : ''), ev.providerTerminalStatus === 'succeeded' ? 'ok' : 'bad'],
    ['provider attempt', `${ev.providerAttemptFinishedCount}/${ev.providerAttemptStartedCount} 완료`, ev.providerAttemptFinishedCount === ev.providerAttemptStartedCount ? 'dim' : 'warn'],
    ['event bus 상관', ev.eventBusCorrelatedCount, 'dim'],
    ['compaction', `${ev.contextCompactedCount} 완료 / ${ev.contextCompactStartedCount} 시작`, ev.contextCompactStartedCount > ev.contextCompactedCount ? 'warn' : 'dim'],
    ['memory', `주입 ${ev.memoryInjectedCount} · flush ${ev.memoryFlushedCount}`, 'dim'],
  ] : [
    ['상태', ev.health === 'healthy' ? '정상' : '오래된 기록', ev.health === 'healthy' ? 'ok' : 'warn'],
    ['모델 호출', ev.providerTerminalStatus === 'succeeded' ? '성공' : '실패 · 가능한 경로 소진', ev.providerTerminalStatus === 'succeeded' ? 'ok' : 'bad'],
    ['압축', ev.contextCompactedCount > 0 ? `${ev.contextCompactedCount}회` : '없음', ev.contextCompactStartedCount > ev.contextCompactedCount ? 'warn' : 'dim'],
    ['기억', `불러옴 ${ev.memoryInjectedCount} · 저장 ${ev.memoryFlushedCount}`, 'dim'],
  ];
  return (
    <div className="jw-ev">
      {items.map(([k, v, tone]) => <span key={k} className="jw-ev-i" data-tone={tone}><i>{k}</i><b className="mono">{v}</b></span>)}
      {ev.staleReason && <span className="jw-ev-stale">{dev ? `stale · ${ev.staleReason}` : '오래된 기록입니다'}</span>}
    </div>
  );
}

function TurnCard({ t, open, onToggle, dev }) {
  const [pick, setPick] = useStateJW(null);
  const span = turnSpan(t);
  const tools = t.entries.filter(e => e.kind === 'tool_call');
  const fails = t.entries.filter(e => e.status === 'failure').length;
  const gates = t.entries.filter(e => e.status === 'gate_rejected').length;
  const lanes = [];
  tools.forEach(e => { // concurrent batch 는 별도 행으로 쌓는다
    let i = lanes.findIndex(row => row.every(x => e.at >= x.at + (x.dur || 0) + 200));
    if (i < 0) { lanes.push([e]); } else { lanes[i].push(e); }
  });
  const sel = pick && t.entries.find(e => e.id === pick);
  return (
    <div className={`jw-turn ${open ? 'open' : ''}`}>
      <button className="jw-turn-h" onClick={onToggle}>
        <span className="jw-turn-t mono">{t.turn == null ? '턴 번호 없음' : `${t.turn}번째 턴`}</span>
        <span className="jw-turn-s">생각 {t.entries.filter(e => e.kind === 'thinking').length} · 도구 {tools.length}</span>
        {fails > 0 && <span className="lq-chip" data-tone="bad">실패 {fails}</span>}
        {gates > 0 && <span className="lq-chip" data-tone="warn">승인 대기 {gates}</span>}
        <span className="jw-turn-d mono">{msTxt(t.entries.reduce((s, e) => s + (e.dur || 0), 0))}</span>
        <span className="jw-caret" aria-hidden="true">{open ? '\u25BE' : '\u25B8'}</span>
      </button>
      {open && (
        <div className="jw-body">
          <div className="jw-track">
            <div className="jw-think">
              {t.entries.filter(e => e.kind === 'thinking').map(e => (
                <button key={e.id} className={`jw-think-m ${pick === e.id ? 'on' : ''}`} style={{ left: `${(e.at / span) * 100}%` }} onClick={() => setPick(pick === e.id ? null : e.id)} title={e.summary}>{'\u25C7'}</button>
              ))}
            </div>
            {lanes.map((row, ri) => (
              <div key={ri} className="jw-lane">
                {row.map(e => {
                  const st = ENTRY_STATUS[e.status] || ENTRY_STATUS.unknown;
                  return (
                    <button key={e.id} className={`jw-bar ${pick === e.id ? 'on' : ''}`} data-tone={st.tone}
                      style={{ left: `${(e.at / span) * 100}%`, width: `${Math.max(3, ((e.dur || 300) / span) * 100)}%` }}
                      onClick={() => setPick(pick === e.id ? null : e.id)} title={`${e.tool} · ${msTxt(e.dur)} · ${st.lbl}`}>
                      {((e.dur || 300) / span) >= 0.13 && <span className="jw-bar-l mono">{e.tool}</span>}
                    </button>
                  );
                })}
              </div>
            ))}
            <div className="jw-scale"><span className="mono">0</span><span className="mono">{msTxt(span)}</span></div>
          </div>
          {sel && (
            <div className="jw-detail" data-tone={(ENTRY_STATUS[sel.status] || {}).tone}>
              <div className="jw-detail-h">
                <b className="mono">{sel.kind === 'thinking' ? 'thinking' : sel.tool}</b>
                <span className="lq-chip" data-tone={(ENTRY_STATUS[sel.status] || {}).tone}>{(ENTRY_STATUS[sel.status] || {}).lbl}</span>
                {dev && <span className="jw-src mono">{ENTRY_SOURCE[sel.source] || sel.source}</span>}
                {sel.dur != null && <span className="mono">{msTxt(sel.dur)}</span>}
                {sel.mode && <span className="jw-mode mono">{dev ? `${sel.mode} · batch ${sel.batchIndex}/${sel.batchSize}${sel.plannedIndex != null ? ` · planned #${sel.plannedIndex}` : ''}` : (sel.mode === 'concurrent' ? '동시 실행' : '순차 실행')}</span>}
              </div>
              <div className="jw-detail-b">{sel.redacted ? '사고 내용은 비공개 처리되어 요약만 남습니다.' : sel.summary}</div>
              {sel.gateReason && <div className="jw-detail-r warn">{sel.gateReason}</div>}
              {sel.error && <div className="jw-detail-r bad">{dev ? `error · ${sel.error}` : `실패 · ${sel.error}`}</div>}
            </div>
          )}
          {t.stimuli && t.stimuli.length > 0 && (
            <div className="jw-stim">
              <span className="jw-stim-h">이 턴이 함께 처리한 자극 {t.stimuli.length}건</span>
              {t.stimuli.map((s, i) => (
                <span key={i} className="jw-stim-i" data-urgent={s.urgency === 'immediate' ? '1' : '0'} title={dev ? `payload_kind=${s.kind} · from=${s.from} · urgency=${s.urgency}` : ''}>
                  {dev ? s.kind : s.what}{s.urgency === 'immediate' && <i>즉시</i>}
                </span>
              ))}
            </div>
          )}
          <EvidenceStrip ev={t.evidence} dev={dev} />
        </div>
      )}
    </div>
  );
}

/* 라이브 이벤트 스트립 — 필터 칩 + events/min */
const EV_CHIPS = [['all', '전체'], ['heartbeat', '하트비트'], ['message', '메시지/보드'], ['agent_core_turn', '턴'], ['tool', '도구'], ['error', '오류'], ['lifecycle', '상태 변화']];
const EV_BADGE = {
  keeper_heartbeat: ['HB', 'ok', 'heartbeat'], agent_core_turn: ['TURN', 'info', 'agent_core_turn'],
  agent_core_tool: ['TOOL', 'warn', 'tool'], keeper_tool_call: ['TOOL', 'warn', 'tool'],
  agent_core_context: ['CTX', 'dim', 'lifecycle'], agent_core_event: ['Agent Core', 'info', 'lifecycle'],
  keeper_handoff: ['HAND', 'info', 'lifecycle'], keeper_compaction: ['COMP', 'warn', 'lifecycle'],
  keeper_phase_changed: ['PHASE', 'info', 'lifecycle'], broadcast: ['CAST', 'info', 'message'],
  board_post: ['POST', 'info', 'message'], board_comment: ['CMNT', 'info', 'message'], unknown: ['SYS', 'dim', 'other'],
};
const EV_ROWS = [
  { t: 'keeper_tool_call', ago: '방금', text: 'masc-improver · 셸 명령이 승인 대기로 전환됨', err: true },
  { t: 'agent_core_turn', ago: '12초 전', text: 'masc-improver · 41번째 턴 작업 중' },
  { t: 'keeper_heartbeat', ago: '18초 전', text: '큐에이킹 · 정상 동작' },
  { t: 'keeper_compaction', ago: '41초 전', text: 'nick0cave · 기록 정리 시작' },
  { t: 'board_post', ago: '1분 전', text: 'sangsu · T-3880 에 의견 남김' },
  { t: 'keeper_phase_changed', ago: '2분 전', text: '스칼라 · 실행 중 → 정리 중' },
  { t: 'agent_core_context', ago: '3분 전', text: 'drifter · 대화량 알 수 없음' },
  { t: 'keeper_handoff', ago: '4분 전', text: '큐에이킹 · sangsu에게 넘기기 확인 대기' },
  { t: 'unknown', ago: '6분 전', text: 'drifter · 쓸 수 있는 모델 없음 (요청 한도 초과)', err: true },
  { t: 'broadcast', ago: '9분 전', text: 'masc-improver · 전체 알림 1건' },
];
const EV_KO = { HB: '하트비트', TURN: '턴', TOOL: '도구', CTX: '컨텍스트', 'Agent Core': '내부', HAND: '인계', COMP: '압축', PHASE: '단계', CAST: '알림', POST: '게시', CMNT: '댓글', SYS: '시스템' };
function LiveStrip({ dev }) {
  const [f, setF] = useStateJW('all');
  const match = (r) => {
    if (f === 'all') return true;
    if (f === 'error') return r.err === true;
    return (EV_BADGE[r.t] || [])[2] === f;
  };
  const rows = EV_ROWS.filter(match);
  const perMin = EV_ROWS.filter(r => /초 전|방금/.test(r.ago)).length;
  return (
    <div className="ev">
      <div className="ev-head">
        <div className="ev-chips">{EV_CHIPS.map(([k, l]) => <button key={k} className={`ia-filter ${f === k ? 'on' : ''}`} onClick={() => setF(k)}>{l}</button>)}</div>
        <span className="ev-rate mono">{perMin}/min</span>
        <span className="ev-count mono">{rows.length} events</span>
      </div>
      {rows.length === 0
        ? <div className="lq-gap"><b>해당 이벤트 없음</b></div>
        : <div className="ev-rows">{rows.map((r, i) => {
            const b = EV_BADGE[r.t] || EV_BADGE.unknown;
            return <div key={i} className="ev-row"><span className={`lq-chip ${dev ? 'mono' : ''}`} data-tone={r.err ? 'bad' : b[1]}>{dev ? b[0] : (EV_KO[b[0]] || b[0])}</span><span className="ev-text">{r.text}</span><span className="ev-ago mono">{r.ago}</span></div>;
          })}</div>}
    </div>
  );
}

function JourneyPanel() {
  const ids = Object.keys(window.LANE_TL || JOURNEY);
  const [sel, setSel] = useStateJW('masc-improver');
  const [open, setOpen] = useStateJW('t0');
  const [dev, setDev] = useStateJW(false);
  const model = JOURNEY[sel] || null;
  const s = summarize(model);
  return (
    <div className="ia-wrap jw-wrap">
      <div className="ia-head">
        <h3>턴 워터폴</h3>
        <span className="ia-count">턴 안에서 무엇을 얼마나 오래 했는가</span>
        <span className="ia-devslot">{window.DevToggle ? <window.DevToggle on={dev} set={setDev} /> : <button className={`ia-filter ${dev ? 'on' : ''}`} onClick={() => setDev(!dev)}>기술 상세</button>}</span>
      </div>
      <p className="ia-lede">막대를 누르면 무엇을 했고 왜 실패했는지 나옵니다. 턴의 최종 텍스트는 자동 전달되지 않습니다 — 발화 도구로 보낸 것만 나갑니다.</p>

      <div className="lq-kpis">
        <div className="lq-kpi"><span className="k">턴</span><b>{s.turns}</b></div>
        <div className="lq-kpi"><span className="k">생각 · 도구</span><b>{s.thinking} · {s.tools}</b></div>
        <div className="lq-kpi"><span className="k">실패</span><b className={s.fail ? 'bad' : 'ok'}>{s.fail}</b></div>
        <div className="lq-kpi"><span className="k">승인 대기로 전환</span><b className={s.gate ? 'warn' : 'ok'}>{s.gate}</b></div>
        <div className="lq-kpi"><span className="k">도구 사용 시간</span><b className="mono">{msTxt(s.dur)}</b></div>
      </div>

      <div className="lq-sec">
        <div className="lq-sec-h"><h4>워터폴</h4>
          <div className="lq-tabs">{ids.map(id => <button key={id} className={`lq-tab mono ${sel === id ? 'on' : ''}`} onClick={() => { setSel(id); setOpen('t0'); }}>{id}{!JOURNEY[id] && <i className="lq-tab-none">·</i>}</button>)}</div>
        </div>
        {!model
          ? <div className="lq-gap"><b>최근 턴 기록 없음</b></div>
          : model.turns.map((t, i) => <TurnCard key={t.turn == null ? 'nr' + i : t.turn} t={t} dev={dev} open={open === 't' + i} onToggle={() => setOpen(open === 't' + i ? null : 't' + i)} />)}
      </div>

      <div className="lq-sec">
        <div className="lq-sec-h"><h4>라이브 이벤트</h4>{dev && <span className="mono">journal ring buffer · 최근 50건</span>}</div>
        <LiveStrip dev={dev} />
      </div>
    </div>
  );
}

Object.assign(window, { JourneyPanel, JOURNEY });
