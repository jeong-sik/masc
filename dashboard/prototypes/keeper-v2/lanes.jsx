/* MASC v3 — 레인 · 큐 (Monitor)
   근거: keeper-lane-strip.ts(keeper_waiting_inventory.v3) · fsm-hub-lane-analysis.ts
        · queue-drain-status.ts · keeper-lifecycle-timeline.ts
   표현 원칙: 레인은 시간축 스윔레인으로, 큐는 producer→queue→keeper 파이프라인으로 본다.
   격자/목록은 값만 보여줄 뿐 "언제 멈췄는지"를 못 보여준다. */
const { useState: useStateLQ } = React;

/* 기본은 운영자 시야. 배선 이름(스키마 · enum · producer · 영수증)은 기술 상세에서만 드러낸다. */
const DevCtx = React.createContext(false);
function useDev() { return React.useContext(DevCtx); }
function DevToggle({ on, set }) {
  return <button className={`ia-filter ${on ? 'on' : ''}`} onClick={() => set(!on)} title="내부 식별자 · 원본 필드 표시">기술 상세</button>;
}
const VAL_LBL = {
  running: '실행 중', failing: '문제 발생', overflowed: '컨텍스트 초과', compacting: '압축 중', handing_off: '인계 중', draining: '정리 중',
  idle: '쉬는 중', prompting: '준비 중', executing: '작업 중', finalizing: '마무리', undecided: '미결정', guard_ok: '점검 통과',
  tool_policy_selected: '도구 확정', selecting: '경로 선택', trying: '모델 호출 중', done: '완료', exhausted: '가능한 경로 없음', accumulating: '누적 중',
};

const WINDOW_S = 1200; // 스윔레인 관측창 20분

/* ── 닫힌 enum 어휘 ──────────────────────────────────────────────────── */
const LANE_STATE = {
  idle: { lbl: '비어 있음', tone: 'ok' }, busy: { lbl: '처리 중', tone: 'info' },
  waiting: { lbl: '대기 중', tone: 'warn' }, deferred: { lbl: '외부 응답 대기', tone: 'warn' },
};
const LANE_SOURCE = {
  /* 원본 대기 소스는 10종(dashboard-tools-prompts.ts DASHBOARD_KEEPER_WAITING_SOURCE_VALUES).
     workspace_message는 대기 소스가 아니라 이벤트 큐 payload_kind(keeper_event_queue.ml)라
     여기 없다 — keeper가 보낸 메시지는 event_queue_pending으로 잡힌다. */
  event_queue_pending: { lbl: '자율 이벤트', tone: 'volt', stage: 'queue' },
  chat_operation_queued: { lbl: '채팅 대기', tone: 'volt', stage: 'queue' },
  chat_operation_running: { lbl: '채팅 처리 중', tone: 'warn', stage: 'keeper' },
  hitl_pending: { lbl: '승인 대기', tone: 'warn', stage: 'operator' },
  external_attention: { lbl: '외부 알림', tone: 'volt', stage: 'external' },
  fusion_running: { lbl: 'Fusion 실행 중', tone: 'ok', stage: 'keeper' },
  schedule_waiting: { lbl: '예약 실행', tone: 'warn', stage: 'schedule' },
  owner_shutdown: { lbl: '종료 정리', tone: 'dim', stage: 'keeper' },
  operator_pending_confirm: { lbl: '운영자 확인', tone: 'warn', stage: 'operator' },
  read_error: { lbl: '읽기 오류', tone: 'bad', stage: 'queue' },
};
const STAGE = {
  external: { lbl: '외부 자극', sub: 'connector · attention store' },
  schedule: { lbl: '예약', sub: 'schedule_runner' },
  queue: { lbl: '큐', sub: 'keeper_event_queue' },
  operator: { lbl: '운영자', sub: 'hitl · console' },
  keeper: { lbl: 'keeper', sub: 'turn 실행' },
};

const WAIT_INVENTORY = {
  schema: 'masc.dashboard.keeper_waiting_inventory.v3', generated_at: '14:00', external_attention_row_limit: 64,
  keepers: {
    'masc-improver': { state: 'busy', waiting_count: 3, sources: { chat_operation_running: 1, event_queue_pending: 2 },
      rows: [
        { source: 'chat_operation_running', waiting_on: 'op_7c19 · keeper_chat', what: '운영자와 진행 중인 대화', wake: 'chat_operation_store', since: 2, next: 'await_turn_finalize', detail: { operation_id: 'op_7c19', turn: 41 } },
        { source: 'event_queue_pending', waiting_on: 'masc.task_assigned', what: '새로 배정된 작업 (T-3880)', wake: 'keeper_event_queue', since: 11, next: 'keeper_process_event', detail: { event_id: 'evt-3f0a', task: 'T-3880' } },
        { source: 'event_queue_pending', waiting_on: 'workspace-message:wmsg-1f4c', what: 'nick0cave가 보낸 메시지 (즉시)', wake: 'keeper_event_queue', since: 4, next: 'keeper_process_event', detail: { payload_kind: 'workspace_message', message_request_id: 'wmsg-1f4c', message_from: 'nick0cave', urgency: 'immediate' } },
      ] },
    sangsu: { state: 'waiting', waiting_count: 64, waiting_count_truncated: true, sources: { external_attention: 62, schedule_waiting: 1, hitl_pending: 1 }, truncated_sources: { external_attention: true },
      rows: [
        { source: 'external_attention', waiting_on: 'discord:product-review', what: 'Discord · product-review 알림', wake: 'external_attention_store', since: 6, next: 'keeper_process_external_attention', detail: { event_id: 'evt-new', connector: 'discord' } },
        { source: 'hitl_pending', waiting_on: 'gate:apr_51c8 · tool_execute', what: '운영자 승인 (쓰기 작업)', wake: 'hitl_queue', since: 34, next: 'await_operator_decision', detail: { approval_id: 'apr_51c8', risk: 'write' } },
        { source: 'schedule_waiting', waiting_on: 'masc.keeper_wake', what: '예약 실행 · daily-news', wake: 'schedule_runner', since: 442, due_in: 1049, next: 'wait_until_due', detail: { schedule_id: 'daily-news' } },
        { source: 'external_attention', waiting_on: 'discord:incident-room', what: 'Discord · incident-room 알림', wake: 'external_attention_store', since: 2760, next: 'keeper_process_external_attention', detail: { event_id: 'evt-old', connector: 'discord' } },
      ] },
    nick0cave: { state: 'deferred', waiting_count: 2, sources: { fusion_running: 1, operator_pending_confirm: 1 },
      rows: [
        { source: 'fusion_running', waiting_on: 'fus_2b71 · panel 3 · judge', what: 'Fusion 판정 · 패널 3', wake: 'fusion_runner', since: 4, next: 'await_fusion_verdict', detail: { run_id: 'fus_2b71', panel: 3 } },
        { source: 'operator_pending_confirm', waiting_on: 'handoff → sangsu', what: 'sangsu에게 넘기기 확인', wake: 'operator_console', since: 19, next: 'await_operator_confirm', detail: { intent: 'handoff', to: 'sangsu' } },
      ] },
    scholar: { state: 'waiting', waiting_count: 1, sources: { owner_shutdown: 1 },
      rows: [{ source: 'owner_shutdown', waiting_on: 'drain · 소유 태스크 2건', what: '맡은 작업 2건 마무리', wake: 'keeper_supervisor', since: 3, next: 'drain_then_stop', detail: { owned: 2, phase: 'Draining' } }] },
    drifter: { state: 'waiting', waiting_count: 1, sources: { read_error: 1 },
      rows: [{ source: 'read_error', waiting_on: 'keeper_event_queue 스냅샷', what: '대기 기록 읽기 실패', wake: '미기록', since: 27, next: 'retry_snapshot_read', detail: { error: 'ENOENT', path: 'state/keeper_event_queue/drifter.jsonl' } }] },
  },
};
function laneEntry(id) { return WAIT_INVENTORY.keepers[id] || null; }
function bounded(n, t) { return t ? '\u2265' + n : String(n); }
function agoTxt(m) { return m == null ? '시각 미기록' : m < 60 ? `${m}분 전` : m < 1440 ? `${Math.floor(m / 60)}시간 전` : `${Math.floor(m / 1440)}일 전`; }
function untilTxt(m) { return m < 60 ? `${m}분 후` : m < 1440 ? `${Math.floor(m / 60)}시간 후` : `${Math.floor(m / 1440)}일 후`; }
function secTxt(s) { return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m` : `${(s / 3600).toFixed(1)}h`; }

/* ── 복합 FSM 레인 ───────────────────────────────────────────────────── */
const CL_LANES = [
  { key: 'phase', lbl: 'lifecycle', ko: '생명주기', field: 'phase' },
  { key: 'turn', lbl: 'turn-cycle', ko: '턴 진행', field: 'turn_state' },
  { key: 'decision', lbl: 'decision', ko: '판단', field: 'decision_state' },
  { key: 'runtime', lbl: 'runtime', ko: '모델 호출', field: 'runtime_state' },
  { key: 'compaction', lbl: 'compaction', ko: '압축', field: 'compaction_state' },
];
/* 스윔레인 소스: [값, 지속(초)] 순서열. 마지막 원소가 현재 관측 중인 값이며
   그 지속시간이 정체 임계와 비교된다. 합이 관측창(1200s)을 넘으면 좌측이 잘린다. */
const LANE_TL = {
  'masc-improver': { live: true, tl: {
    phase: [['running', 1200]],
    turn: [['idle', 180], ['prompting', 26], ['executing', 96], ['finalizing', 12], ['idle', 40], ['prompting', 18], ['executing', 210], ['compacting', 44], ['finalizing', 14], ['idle', 130], ['prompting', 22], ['executing', 380], ['finalizing', 6], ['idle', 0], ['prompting', 10], ['executing', 22]],
    decision: [['undecided', 190], ['guard_ok', 8], ['tool_policy_selected', 120], ['undecided', 46], ['guard_ok', 6], ['tool_policy_selected', 270], ['undecided', 140], ['guard_ok', 5], ['tool_policy_selected', 389], ['undecided', 0], ['guard_ok', 2], ['tool_policy_selected', 26]],
    runtime: [['idle', 200], ['selecting', 4], ['trying', 88], ['done', 14], ['idle', 60], ['selecting', 3], ['trying', 240], ['done', 10], ['idle', 120], ['selecting', 5], ['trying', 396], ['done', 8], ['idle', 34], ['selecting', 2], ['trying', 18]],
    compaction: [['accumulating', 520], ['compacting', 44], ['done', 20], ['accumulating', 616]],
  } },
  nick0cave: { live: true, tl: {
    phase: [['running', 900], ['compacting', 300]],
    turn: [['idle', 120], ['prompting', 30], ['executing', 420], ['finalizing', 18], ['idle', 220], ['prompting', 24], ['executing', 68], ['compacting', 300]],
    decision: [['undecided', 130], ['guard_ok', 12], ['tool_policy_selected', 428], ['undecided', 230], ['guard_ok', 400]],
    runtime: [['idle', 140], ['selecting', 6], ['trying', 410], ['done', 12], ['idle', 240], ['selecting', 4], ['trying', 62], ['done', 20], ['idle', 306]],
    compaction: [['accumulating', 620], ['done', 26], ['accumulating', 258], ['compacting', 296]],
  } },
  sangsu: { live: false, tl: {
    phase: [['running', 1200]],
    turn: [['finalizing', 14], ['idle', 1186]],
    decision: [['tool_policy_selected', 10], ['undecided', 1190]],
    runtime: [['done', 12], ['idle', 1188]],
    compaction: [['accumulating', 1200]],
  } },
  'qa-king': { live: true, tl: {
    phase: [['running', 1126], ['handing_off', 74]],
    turn: [['idle', 240], ['prompting', 20], ['executing', 300], ['finalizing', 16], ['idle', 380], ['prompting', 18], ['executing', 185], ['finalizing', 41]],
    decision: [['undecided', 250], ['guard_ok', 8], ['tool_policy_selected', 310], ['undecided', 390], ['guard_ok', 60], ['tool_policy_selected', 182]],
    runtime: [['idle', 260], ['selecting', 4], ['trying', 292], ['done', 14], ['idle', 396], ['selecting', 6], ['trying', 184], ['done', 44]],
    compaction: [['compacting', 60], ['done', 210], ['accumulating', 930]],
  } },
  scholar: { live: true, tl: {
    phase: [['running', 1012], ['draining', 188]],
    turn: [['idle', 300], ['prompting', 24], ['executing', 402], ['finalizing', 20], ['idle', 454]],
    decision: [['undecided', 310], ['guard_ok', 10], ['tool_policy_selected', 410], ['undecided', 470]],
    runtime: [['idle', 320], ['selecting', 5], ['trying', 398], ['done', 16], ['idle', 461]],
    compaction: [['compacting', 40], ['done', 900], ['accumulating', 260]],
  } },
  drifter: { live: false, tl: {
    phase: [['running', 240], ['failing', 448], ['overflowed', 512]],
    turn: [['idle', 200], ['prompting', 68], ['executing', 420], ['prompting', 512]],
    decision: [['undecided', 1200]],
    runtime: [['idle', 220], ['selecting', 40], ['trying', 260], ['exhausted', 168], ['idle', 0], ['selecting', 512]],
    compaction: [['accumulating', 1200]],
  } },
};
function clStall(key, v, sec) {
  if (key === 'phase') return v === 'failing' ? sec >= 90 : v === 'overflowed' ? sec >= 60 : v === 'compacting' ? sec >= 90 : (v === 'handing_off' || v === 'draining') ? sec >= 60 : false;
  if (key === 'turn') return (v === 'prompting' || v === 'executing') ? sec >= 45 : v === 'compacting' ? sec >= 60 : v === 'finalizing' ? sec >= 30 : false;
  if (key === 'runtime') return v === 'selecting' ? sec >= 30 : v === 'trying' ? sec >= 45 : false;
  if (key === 'compaction') return v === 'compacting' && sec >= 60;
  return false;
}
const VAL_TONE = {
  running: 'info', failing: 'bad', overflowed: 'warn', compacting: 'warn', handing_off: 'warn', draining: 'warn',
  idle: 'idle', prompting: 'info', executing: 'info', finalizing: 'info',
  undecided: 'idle', guard_ok: 'ok', tool_policy_selected: 'info',
  selecting: 'info', trying: 'info', done: 'ok', exhausted: 'bad', accumulating: 'idle',
};
const CL_MEANING = {
  phase: { running: (v) => v ? '정상 동작 중 — 지금 턴을 하나 돌리고 있다' : '정상 동작 중 — 지금 맡은 턴은 없다', failing: () => '문제가 걸려 있어 새 턴을 시작하지 못한다', overflowed: () => '대화가 한도를 넘어 정리 전에는 새 턴을 못 받는다', compacting: () => '턴을 마치고 기록을 줄이는 중', handing_off: () => '다른 keeper 에게 넘기고 멈추는 중', draining: () => '남은 일을 마무리하고 멈추는 중' },
  turn: { idle: (v) => v ? '턴은 열려 있지만 지금 하는 일이 없다' : '지금 맡은 턴이 없다', prompting: () => '무엇을 할지 정리해 모델에 넘길 준비 중', executing: () => '모델을 부르거나 도구를 쓰는 중', compacting: () => '기록 정리가 끝나야 턴을 닫을 수 있다', finalizing: () => '결과를 저장하고 턴을 닫는 중' },
  decision: { undecided: (v) => v ? '아직 무엇을 할지 정하지 않았다' : '진행 중인 턴이 없어 정할 것도 없다', guard_ok: () => '안전 점검을 통과해 계속 진행할 수 있다', tool_policy_selected: () => '쓸 도구를 정했고 실행으로 넘어갈 수 있다' },
  runtime: { idle: () => '모델을 부르고 있지 않다', selecting: () => '어떤 모델로 부를지 고르는 중', trying: () => '모델 응답을 기다리는 중', done: () => '모델 응답을 받아 처리했다', exhausted: () => '쓸 수 있는 모델이 없다 — 사람이 손대야 한다' },
  compaction: { accumulating: () => '기록이 쌓이는 중 — 정리는 하지 않는다', compacting: () => '오래된 기록을 줄이는 중', done: () => '기록 정리를 끝냈다' },
};
const CL_MEANING_DEV = {
  phase: { running: (v) => v ? 'parent lifecycle 정상 — live turn 진행 중' : 'keeper 는 살아있고 진행 중인 turn 은 없음', failing: () => 'parent lifecycle degraded — healthy turn 재개 전 해소 필요', overflowed: () => 'context overflow latched — 해소 전 healthy turn 재개 불가', compacting: () => 'post-turn compaction 이 lifecycle 점유 중', handing_off: () => 'handoff 가 keeper 를 stop 방향으로 drain 중', draining: () => 'in-flight work drain 중 (stop 전)' },
  turn: { idle: (v) => v ? 'turn context 존재하지만 work 미진행' : '진행 중인 turn 없음', prompting: () => 'prompt assembly 가 turn input 준비 중', executing: () => 'model/tool execution work 안에 있음', compacting: () => 'turn finalization 이 compaction 종료 대기 중', finalizing: () => '결과 seal + 다음 idle snapshot 준비 중' },
  decision: { undecided: (v) => v ? 'decision work 미커밋' : '진행 중인 turn 이 없어 결정 단계 없음', guard_ok: () => 'guardrail 통과 — turn 계속 진행 허용', tool_policy_selected: () => '도구 목록 선택 커밋됨 — execution 진행 가능' },
  runtime: { idle: () => 'provider/runtime 실행 중 아님', selecting: () => 'provider routing 이 다음 execution path 선택 중', trying: () => 'provider execution 진행 중', done: () => 'runtime 가 이번 turn 의 provider 결과 수락', exhausted: () => 'runtime 옵션 모두 소진 — 사용 가능한 path 없음' },
  compaction: { accumulating: () => '메모리 누적 중 — compaction 실행 중 아님', compacting: () => 'memory compaction 이 context state 를 rewrite 중', done: () => '관측된 turn 의 compaction 완료' },
};
// [값,지속] 순서열 → 관측창 안의 세그먼트(시작초, 폭초). 창을 넘는 앞부분은 잘린다.
function segments(seq) {
  const total = seq.reduce((s, x) => s + x[1], 0);
  let t = total - WINDOW_S, at = 0, out = [];
  seq.forEach(([v, d], i) => {
    const a = at, b = at + d; at = b;
    if (d <= 0 || b <= t) return;
    out.push({ v, t0: Math.max(a, t) - t, d: b - Math.max(a, t), clipped: a < t, last: i === seq.length - 1, dur: d });
  });
  return out;
}
function laneNow(id, key) {
  const k = LANE_TL[id]; if (!k) return null;
  const seq = k.tl[key], last = seq[seq.length - 1];
  const v = last[0], sec = last[1];
  const stalled = clStall(key, v, sec);
  const fn = (CL_MEANING[key] || {})[v], fnDev = (CL_MEANING_DEV[key] || {})[v];
  return {
    v, sec, stalled, tr: seq.length - 1,
    meaning: stalled ? '이 상태에서 너무 오래 멈춰 있습니다' : (fn ? fn(k.live) : '상태만 확인됨'),
    meaningDev: stalled ? 'state movement 이 이 창에서 정체된 것으로 보임' : (fnDev ? fnDev(k.live) : 'state 관측됨'),
  };
}

/* ── 스윔레인 ───────────────────────────────────────────────────────── */
function Swimlane({ id, focus, setFocus }) {
  const k = LANE_TL[id], dev = useDev();
  const [hov, setHov] = useStateLQ(null);
  if (!k) return <div className="lq-gap"><b>기록 없음</b></div>;
  const ticks = [1200, 900, 600, 300, 0];
  return (
    <div className="sw">
      <div className="sw-axis">
        <span className="sw-axis-pad"></span>
        <div className="sw-axis-track">
          {ticks.map(t => <span key={t} className="sw-tick" style={{ left: `${(1 - t / WINDOW_S) * 100}%` }}>{t === 0 ? 'now' : `-${t / 60}m`}</span>)}
        </div>
      </div>
      {CL_LANES.map(l => {
        const segs = segments(k.tl[l.key]), now = laneNow(id, l.key);
        return (
          <div key={l.key} className={`sw-row ${focus === l.key ? 'on' : ''}`} onClick={() => setFocus(l.key)}>
            <div className="sw-lbl"><span>{dev ? l.lbl : l.ko}</span>{dev && <span className="sw-field mono">{l.field}</span>}</div>
            <div className="sw-track">
              {segs.map((s, i) => (
                <span key={i} className={`sw-seg ${s.clipped ? 'clip' : ''} ${s.last && now.stalled ? 'stall' : ''}`} data-tone={VAL_TONE[s.v] || 'info'}
                  style={{ left: `${(s.t0 / WINDOW_S) * 100}%`, width: `${(s.d / WINDOW_S) * 100}%` }}
                  onMouseEnter={() => setHov({ lane: l.key, ...s })} onMouseLeave={() => setHov(null)}
                  title={`${dev ? s.v : (VAL_LBL[s.v] || s.v)} · ${secTxt(s.dur)}${s.clipped ? ' (창 이전부터 계속)' : ''}`}>
                  {(s.d / WINDOW_S) >= 0.085 && <b className={`sw-seg-v ${dev ? 'mono' : ''}`}>{dev ? s.v : (VAL_LBL[s.v] || s.v)}</b>}
                </span>
              ))}
              {now.stalled && <span className="sw-stallmark" title="정체 임계 초과">정체 {secTxt(now.sec)}</span>}
            </div>
          </div>
        );
      })}
      {hov && (
        <div className="sw-foot">
          <b className={dev ? 'mono' : ''}>{dev ? hov.v : (VAL_LBL[hov.v] || hov.v)}</b> · {secTxt(hov.dur)} 유지{hov.clipped ? ' · 이전부터 계속' : ''}
        </div>
      )}
    </div>
  );
}

/* ── 큐 파이프라인 ──────────────────────────────────────────────────── */
function Pipeline({ entry }) {
  const dev = useDev();
  const byStage = {};
  Object.keys(entry.sources || {}).forEach(s => {
    /* 모르는 소스는 큐에 흡수하지 않는다 — 원본(keeper-lane-strip.ts)은 미분류 source
       박스로 따로 보여서 새 소스가 조용히 사라지는 일이 없게 한다. */
    const st = (LANE_SOURCE[s] || {}).stage || 'unclassified';
    (byStage[st] = byStage[st] || []).push({ s, n: entry.sources[s], trunc: (entry.truncated_sources || {})[s] === true });
  });
  const order = ['external', 'schedule', 'queue', 'operator', 'keeper'];
  return (
    <div className="pl">
      {order.map((st, i) => {
        const items = byStage[st] || [];
        return (
          <React.Fragment key={st}>
            {i > 0 && <span className={`pl-arrow ${items.length ? 'on' : ''}`} aria-hidden="true">{'\u2192'}</span>}
            <div className={`pl-stage ${items.length ? 'on' : ''}`}>
              <div className="pl-stage-h"><b>{STAGE[st].lbl}</b>{dev && <span className="mono">{STAGE[st].sub}</span>}</div>
              {items.length
                ? items.map(it => (
                    <div key={it.s} className="pl-item" data-tone={(LANE_SOURCE[it.s] || {}).tone}>
                      <span>{(LANE_SOURCE[it.s] || {}).lbl}</span><b className="mono">{bounded(it.n, it.trunc)}</b>
                    </div>
                  ))
                : <div className="pl-empty">—</div>}
            </div>
          </React.Fragment>
        );
      })}
      {(byStage.unclassified || []).length > 0 && (
        <React.Fragment>
          <span className="pl-arrow on" aria-hidden="true">{'→'}</span>
          <div className="pl-stage on" data-stage="unknown">
            <div className="pl-stage-h"><b>미분류 source</b>{dev && <span className="mono">unknown</span>}</div>
            {byStage.unclassified.map(it => (
              <div key={it.s} className="pl-item" data-tone="bad">
                <span>{it.s}</span><b className="mono">{bounded(it.n, it.trunc)}</b>
              </div>
            ))}
          </div>
        </React.Fragment>
      )}
    </div>
  );
}

/* 대기 행 — 경과시간 축 위에 놓는다. 목록이 아니라 나이 분포로 읽힌다. */
function WaitAges({ entry, limit }) {
  const dev = useDev();
  const [open, setOpen] = useStateLQ(null);
  const rows = (entry.rows || []).slice().sort((a, b) => (a.since || 0) - (b.since || 0));
  const max = Math.max(60, ...rows.map(r => r.since || 0));
  const pos = (m) => Math.min(100, (Math.log10(1 + (m || 0)) / Math.log10(1 + max)) * 100);
  return (
    <div className="wa">
      <div className="wa-scale"><span>지금</span><span>1시간</span><span>1일+</span></div>
      {rows.map((r, i) => {
        const src = LANE_SOURCE[r.source] || { lbl: r.source, tone: 'dim' };
        const on = open === i;
        return (
          <div key={r.source + r.waiting_on} className="wa-row" data-tone={src.tone}>
            <button className="wa-bar" onClick={() => setOpen(on ? null : i)} style={{ width: `${Math.max(6, pos(r.since))}%` }}>
              <span className="wa-src">{src.lbl}</span>
              <span className={`wa-on ${dev ? 'mono' : ''}`} title={r.waiting_on}>{dev ? r.waiting_on : (r.what || r.waiting_on)}</span>
              <span className="wa-age mono">{agoTxt(r.since)}</span>
            </button>
            {on && (
              <div className="wa-detail">
                <div className="wa-meta">
                  <span>{dev ? r.waiting_on : (r.what || r.waiting_on)}</span>
                  {r.due_in != null && <span className="warn">실행 예정 · {untilTxt(r.due_in)}</span>}
                  {dev && <span>wake · <b className="mono">{r.wake}</b></span>}
                  {dev && <span>다음 동작 · <b className="mono">{r.next}</b></span>}
                </div>
                {dev && <pre className="mono">{JSON.stringify({ source: r.source, wake_producer: r.wake, detail: r.detail }, null, 2)}</pre>}
              </div>
            )}
          </div>
        );
      })}
      {entry.waiting_count_truncated && (
        <div className="lq-trunc">{limit}건까지만 표시 — 실제 대기는 더 많습니다</div>
      )}
    </div>
  );
}

/* ── 예약 wake 드레인 ───────────────────────────────────────────────── */
const DRAIN_PRESENT = {
  pending: { lbl: '큐 대기', tone: 'info', op: '아직 실행되지 않고 차례를 기다리는 중', why: 'wake 가 keeper_event_queue pending 에 있음 — 드레인 대기 중' },
  drained: { lbl: '완료', tone: 'ok', op: 'keeper 가 받아서 실행했다', why: '큐에서 빠졌고 keeper 반응이 기록됨 (consumed_ack / turn_started)' },
  missed: { lbl: '누락', tone: 'bad', op: '보냈지만 아무도 실행하지 않았다 — 다시 걸어야 한다', why: 'dispatch 기록만 남았고 keeper 반응이 없음 — 큐에서 빠졌으나 아무도 소비 안 함' },
  read_error: { lbl: '읽기 오류', tone: 'warn', op: '기록을 읽지 못해 실행됐는지 알 수 없다', why: '큐 스냅샷 또는 reaction ledger 읽기 실패 — 드레인 상태 확인 불가' },
  evidence_invalid: { lbl: '증거 격리', tone: 'warn', op: '기록이 손상돼 실행 여부를 단정할 수 없다', why: '해당 occurrence 의 reaction ledger 행이 격리되어 정확한 판정 불가' },
  indeterminate: { lbl: '확인 불가', tone: 'dim', op: '남은 기록만으로는 확인할 수 없다', why: '영수증 · stimulus_id · ledger completeness 부재로 큐-반응 상관 불가' },
};
const REACTED = ['matched_consumed_ack', 'matched_turn_started'];
function drainState(r) {
  const q = r.queue;
  if (q == null) return null;
  if (q === 'matched_pending') return 'pending';
  if (q === 'read_error') return 'read_error';
  if (q === 'unrecognized_receipt') return 'indeterminate';
  if (q === 'not_found') {
    const a = r.reaction;
    if (a != null && REACTED.indexOf(a) >= 0) return 'drained';
    if (a === 'matched_stimulus' || a === 'not_found') return 'missed';
    if (a === 'read_error') return 'read_error';
    if (a === 'quarantined') return 'evidence_invalid';
  }
  return 'indeterminate';
}
const DRAIN_ROWS = [
  { id: 'sch_77a0', keeper: 'sangsu', payload: 'keeper.wake · daily-news', at: '14:00', queue: 'matched_pending', reaction: null },
  { id: 'sch_2e55', keeper: 'masc-improver', payload: 'keeper.wake · board sweep', at: '13:30', queue: 'not_found', reaction: 'matched_turn_started' },
  { id: 'sch_a93f', keeper: 'qa-king', payload: 'keeper.wake · docs 검증', at: '11:00', queue: 'not_found', reaction: 'matched_stimulus' },
  { id: 'sch_5d10', keeper: 'nick0cave', payload: 'keeper.wake · compact sweep', at: '09:15', queue: 'not_found', reaction: 'matched_consumed_ack' },
  { id: 'sch_18bc', keeper: 'drifter', payload: 'keeper.wake · runtime probe', at: '08:40', queue: 'read_error', reaction: null },
  { id: 'sch_0c44', keeper: 'scholar', payload: 'keeper.wake · digest', at: '07:05', queue: 'not_found', reaction: 'quarantined' },
];
const Q_AXIS = ['matched_pending', 'not_found', 'read_error', 'unrecognized_receipt'];
const R_AXIS = ['matched_consumed_ack', 'matched_turn_started', 'matched_stimulus', 'not_found', 'quarantined', 'read_error', null];

/* 운영자 기본 시야 — 판정 결과만 남긴다. */
function DrainList() {
  const rows = DRAIN_ROWS.map(r => ({ ...r, st: drainState(r) }));
  const order = ['missed', 'read_error', 'evidence_invalid', 'pending', 'indeterminate', 'drained'];
  rows.sort((a, b) => order.indexOf(a.st) - order.indexOf(b.st));
  return (
    <div className="dl">
      {rows.map(r => {
        const p = DRAIN_PRESENT[r.st];
        return (
          <div key={r.id} className="dl-row" data-tone={p.tone}>
            <span className="lq-chip" data-tone={p.tone} title={p.op}>{p.lbl}</span>
            <span className="dl-payload">{r.payload.replace('keeper.wake · ', '')}</span>
            <span className="dl-keeper mono">{r.keeper}</span>
            <span className="dl-at mono">{r.at}</span>
          </div>
        );
      })}
      <div className="dl-legend">{['missed','pending','read_error','drained'].map(k => <span key={k} className="dl-leg"><span className="lq-chip" data-tone={DRAIN_PRESENT[k].tone}>{DRAIN_PRESENT[k].lbl}</span><span>{DRAIN_PRESENT[k].op}</span></span>)}</div>
    </div>
  );
}

function DrainMatrix() {
  const [sel, setSel] = useStateLQ(null);
  const cell = (q, r) => DRAIN_ROWS.filter(x => x.queue === q && (x.reaction || null) === r);
  return (
    <div className="dm">
      <div className="dm-grid" style={{ gridTemplateColumns: `132px repeat(${R_AXIS.length}, minmax(0,1fr))` }}>
        <div className="dm-corner mono">queue \ reaction</div>
        {R_AXIS.map(r => <div key={String(r)} className="dm-h mono">{r || '없음'}</div>)}
        {Q_AXIS.map(q => (
          <React.Fragment key={q}>
            <div className="dm-rh mono">{q}</div>
            {R_AXIS.map(r => {
              const rows = cell(q, r);
              const st = drainState({ queue: q, reaction: r });
              const p = st ? DRAIN_PRESENT[st] : null;
              return (
                <button key={String(r)} className={`dm-c ${rows.length ? 'has' : ''} ${sel && sel.q === q && sel.r === r ? 'on' : ''}`} data-tone={p ? p.tone : 'dim'}
                  onClick={() => setSel(rows.length ? { q, r, rows, st } : null)} title={p ? p.why : ''}>
                  <span className="dm-c-l">{p ? p.lbl : '—'}</span>
                  {rows.length > 0 && <b className="mono">{rows.length}</b>}
                </button>
              );
            })}
          </React.Fragment>
        ))}
      </div>
      <div className="dm-detail">
        {sel
          ? <React.Fragment>
              <div className="dm-detail-h"><span className="lq-chip" data-tone={DRAIN_PRESENT[sel.st].tone}>{DRAIN_PRESENT[sel.st].lbl}</span><span>{DRAIN_PRESENT[sel.st].why}</span></div>
              {sel.rows.map(r => <div key={r.id} className="dm-row"><b className="mono">{r.id}</b><span className="mono">{r.keeper}</span><span>{r.payload}</span><span className="mono">{r.at}</span></div>)}
            </React.Fragment>
          : <span className="dm-hint">칸을 누르면 해당 조합의 예약이 나옵니다.</span>}
      </div>
    </div>
  );
}

/* ── 라이프사이클 이벤트 (supervisor) ───────────────────────────────── */
/* 원본 어휘(#29218 이후): supervisor_cleaned · '부재 Keeper 정리됨' · neutral.
   dead_cleaned는 Dead phase·tombstone과 함께 사라진 옛 키다. */
const LC_TONE = { started: 'ok', reconciled: 'ok', restarted: 'warn', supervisor_cleaned: 'neutral', purged: 'info' };
const LC_LBL = { started: '기동됨', reconciled: '재조정됨', restarted: '재시작됨', supervisor_cleaned: '부재 Keeper 정리됨', purged: '완전 삭제됨' };
const LIFECYCLE = {
  'masc-improver': [{ ev: 'started', phase: 'Running', ago: '3일 전', detail: '처음 기동 · 모델 opus-4.6', detailDev: 'supervisor boot · runtime opus-4.6' }],
  drifter: [
    { ev: 'restarted', phase: 'Overflowed', ago: '9분 전', detail: '연속 재시작 3회 — 잠시 쉬고 다시 시도', detailDev: 'restart burst 3/3 — backoff 적용' },
    { ev: 'restarted', phase: 'Failing', ago: '21분 전', detail: '쓸 수 있는 모델이 없어 재시작', detailDev: 'provider exhausted 후 재시작' },
    { ev: 'started', phase: 'Running', ago: '2시간 전', detail: '처음 기동', detailDev: 'supervisor boot' },
  ],
  scholar: [{ ev: 'reconciled', phase: 'Draining', ago: '3분 전', detail: '운영자의 정리 요청 반영', detailDev: 'owner drain 요청 반영' }, { ev: 'started', phase: 'Running', ago: '1일 전', detail: '처음 기동', detailDev: 'supervisor boot' }],
  'qa-king': [{ ev: 'started', phase: 'HandingOff', ago: '6시간 전', detail: '처음 기동', detailDev: 'supervisor boot' }],
  nick0cave: [{ ev: 'started', phase: 'Running', ago: '5일 전', detail: '처음 기동', detailDev: 'supervisor boot' }],
  sangsu: [{ ev: 'supervisor_cleaned', ago: '어제', detail: '부재 keeper 정리 후 다시 기동', detailDev: 'supervisor_cleaned 후 재기동' }, { ev: 'started', phase: 'Running', ago: '어제', detail: '처음 기동', detailDev: 'supervisor boot' }],
};
function LifecycleEvents({ id }) {
  const dev = useDev();
  const evs = LIFECYCLE[id];
  if (!evs) return <div className="lq-gap"><b>기동 · 재시작 기록 없음</b></div>;
  return (
    <div className="lc">
      {evs.map((e, i) => (
        <div key={i} className="lc-row" data-tone={LC_TONE[e.ev] || 'info'}>
          <span className="lc-dot" aria-hidden="true"></span>
          <span className="lc-ev">{LC_LBL[e.ev] || e.ev}</span>
          <span className="lc-phase mono">{e.phase}</span>
          <span className="lc-detail">{dev ? (e.detailDev || e.detail) : e.detail}</span>
          <span className="lc-ago mono">{e.ago}</span>
        </div>
      ))}
    </div>
  );
}

/* ── 컨텍스트 레일 ──────────────────────────────────────────────────── */
function KeeperWaitQueue({ keeper }) {
  const entry = laneEntry(keeper.id);
  const st = entry ? (LANE_STATE[entry.state] || { lbl: entry.state, tone: 'dim' }) : null;
  return (
    <div className="ctx-sec">
      <h4 style={{ display: 'flex', alignItems: 'center', gap: '7px' }}>작업 대기열
        {entry && entry.waiting_count > 0 && <CountBadge>{bounded(entry.waiting_count, entry.waiting_count_truncated)}</CountBadge>}
      </h4>
      {!entry
        ? <div className="lq-gap"><b>상태 알 수 없음</b></div>
        : <div className="lq-rail-body">
            <div className="lq-state-row"><span className="lq-chip" data-tone={st.tone}>{st.lbl}</span></div>
            <WaitAges entry={entry} limit={WAIT_INVENTORY.external_attention_row_limit} />
          </div>}
    </div>
  );
}

/* ── Monitor 섹션 ───────────────────────────────────────────────────── */
function LaneQueuePanel() {
  const ids = Object.keys(LANE_TL);
  const [sel, setSel] = useStateLQ('masc-improver');
  const [focus, setFocus] = useStateLQ('turn');
  const [dev, setDev] = useStateLQ(false);
  const entry = laneEntry(sel), now = laneNow(sel, focus);
  const stalls = ids.reduce((n, id) => n + CL_LANES.filter(l => (laneNow(id, l.key) || {}).stalled).length, 0);
  const misses = DRAIN_ROWS.filter(r => drainState(r) === 'missed').length;
  const focusLane = CL_LANES.find(l => l.key === focus) || {};

  return (
    <DevCtx.Provider value={dev}>
    <div className="ia-wrap lq-wrap">
      <div className="ia-head">
        <h3>레인 · 큐</h3>
        <span className="ia-count">진행 타임라인 · 대기 파이프라인 · 예약 실행</span>
        <span className="ia-devslot"><DevToggle on={dev} set={setDev} /></span>
      </div>

      <div className="lq-kpis">
        <div className="lq-kpi"><span className="k">멈춘 진행</span><b className={stalls ? 'warn' : 'ok'}>{stalls}</b></div>
        <div className="lq-kpi"><span className="k">기다리는 keeper</span><b>{Object.keys(WAIT_INVENTORY.keepers).length}</b></div>
        <div className="lq-kpi"><span className="k">실행 안 된 예약</span><b className={misses ? 'bad' : 'ok'}>{misses}</b></div>
        <div className="lq-kpi"><span className="k">보는 구간</span><b>20분</b></div>
      </div>

      <div className="lq-sec">
        <div className="lq-sec-h"><h4>진행 타임라인</h4>{dev && <span className="mono">wire format = lowercase snake_case</span>}
          <div className="lq-tabs">{ids.map(id => <button key={id} className={`lq-tab mono ${sel === id ? 'on' : ''}`} onClick={() => setSel(id)}>{id}{CL_LANES.some(l => (laneNow(id, l.key) || {}).stalled) && <i className="lq-tab-dot"></i>}</button>)}</div>
        </div>
        <Swimlane id={sel} focus={focus} setFocus={setFocus} />
        {now && (
          <div className={`lq-read ${now.stalled ? 'stalled' : ''}`}>
            <span className="lq-read-l">{dev ? focusLane.lbl : focusLane.ko}</span>
            <b className={dev ? 'mono' : ''}>{dev ? now.v : (VAL_LBL[now.v] || now.v)}</b>
            <span className="lq-read-m">{dev ? now.meaningDev : now.meaning}</span>
            <span className="lq-read-o">{secTxt(now.sec)} 지속 · {LANE_TL[sel].live ? '진행 중인 턴 있음' : '진행 중인 턴 없음'}</span>
          </div>
        )}
      </div>

      <div className="lq-split">
        <div className="lq-sec">
          <div className="lq-sec-h"><h4>{sel} · 무엇을 기다리는가</h4>
            {entry && <span className="lq-chip" data-tone={(LANE_STATE[entry.state] || {}).tone}>{(LANE_STATE[entry.state] || {}).lbl}</span>}
            {entry && <span className="mono">{bounded(entry.waiting_count, entry.waiting_count_truncated)}건</span>}
          </div>
          {entry
            ? <React.Fragment>
                <Pipeline entry={entry} />
                <div className="lq-batch">한 턴이 밀린 자극을 묶어서 처리합니다.</div>
                <div className="lq-sec-sub">오래 기다린 순서</div>
                <WaitAges entry={entry} limit={WAIT_INVENTORY.external_attention_row_limit} />
              </React.Fragment>
            : <div className="lq-gap"><b>상태 알 수 없음</b></div>}
        </div>
        <div className="lq-sec">
          <div className="lq-sec-h"><h4>{sel} · 기동 · 재시작 기록</h4>{dev && <span className="mono">supervisor stream · 최근 30건</span>}</div>
          <LifecycleEvents id={sel} />
        </div>
      </div>

      <div className="lq-sec">
        <div className="lq-sec-h"><h4>예약 실행 결과</h4>{dev && <span className="mono">queue evidence × reaction evidence</span>}{misses > 0 && <span className="lq-chip" data-tone="bad">누락 {misses}</span>}</div>
        {dev ? <DrainMatrix /> : <DrainList />}
      </div>
    </div>
    </DevCtx.Provider>
  );
}

Object.assign(window, { DevToggle, DevCtx, LaneQueuePanel, KeeperWaitQueue, WAIT_INVENTORY, laneEntry, drainState, DRAIN_ROWS, LANE_TL, secTxt });
