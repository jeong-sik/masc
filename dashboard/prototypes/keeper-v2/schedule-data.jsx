/* MASC v2 — Scheduled-automation model, grounded in the real codebase
   (lib/schedule/ + tool_schedule). A keeper schedules deferred intent via
   masc_schedule_create (scheduled_by = caller agent = keeper, Automated_actor);
   a human operator must approve before the runner fires at due time
   (separation of duties: approver ≠ requester ≠ scheduler). Read-only data +
   constants; ScheduleSurface (schedule.jsx) drives the interactions. */

// status → label + tone + glyph (mirrors Schedule_domain.schedule_status)
const SCHED_STATUS = {
  Pending_approval: { lbl: '승인 대기', cls: 'warn', glyph: '◷' },
  Scheduled:        { lbl: '예약됨',   cls: 'info', glyph: '◈' },
  Due:              { lbl: 'due',      cls: 'warn', glyph: '◉' },
  Running:          { lbl: '실행 중',  cls: 'ok',   glyph: '▶' },
  Succeeded:        { lbl: '완료',     cls: 'ok',   glyph: '✓' },
  Failed:           { lbl: '실패',     cls: 'bad',  glyph: '✕' },
  Rejected:         { lbl: '거부됨',   cls: 'bad',  glyph: '⊘' },
  Cancelled:        { lbl: '취소됨',   cls: 'dim',  glyph: '◌' },
  Expired:          { lbl: '만료',     cls: 'dim',  glyph: '⊗' },
};
const SCHED_TERMINAL = ['Succeeded', 'Failed', 'Rejected', 'Cancelled', 'Expired'];

// payload kind → glyph + human label
const SCHED_PAYLOAD = {
  'keeper.start':     { glyph: '◇', lbl: 'keeper 기동' },
  'compact.sweep':    { glyph: '◉', lbl: '컴팩션 스윕' },
  'index.reindex':    { glyph: '▤', lbl: '재색인' },
  'report.generate':  { glyph: '▦', lbl: '리포트 생성' },
  'trace.export':     { glyph: '▥', lbl: 'trace 내보내기' },
  'gate.recheck':     { glyph: '◬', lbl: '게이트 재점검' },
  'broadcast.send':   { glyph: '◈', lbl: '브로드캐스트' },
  'archive.purge':    { glyph: '⊗', lbl: '아카이브 정리' },
};

function schedFmtInterval(sec) {
  if (sec % 86400 === 0) return `매 ${sec / 86400}d`;
  if (sec % 3600 === 0) return `매 ${sec / 3600}h`;
  if (sec % 60 === 0) return `매 ${sec / 60}m`;
  return `매 ${sec}s`;
}
function schedRecurrenceText(r) {
  if (!r || r.kind === 'One_shot') return '1회';
  if (r.kind === 'Interval') return schedFmtInterval(r.interval_sec);
  if (r.kind === 'Daily') {
    const hh = String(r.hour).padStart(2, '0'), mm = String(r.minute).padStart(2, '0');
    return `매일 ${hh}:${mm} ${r.timezone}`;
  }
  return '1회';
}

const OPERATOR = { id: 'operator', kind: 'Human_operator', display_name: 'operator' };
const kpr = (id) => ({ id, kind: 'Automated_actor', display_name: id });

// durable schedule requests. due_off = seconds from now (negative = past) for
// derived ordering; due_rel = display. scheduled_by is always a keeper.
const SCHEDULES = [
  {
    schedule_id: 'sch_9f2a', status: 'Pending_approval', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('nick0cave'),
    at: '14:02', due_rel: '내일 02:00 KST', due_off: 41400, expires_rel: '+24h', approval_required: true,
    recurrence: { kind: 'One_shot' },
    payload: { kind: 'keeper.start', schema_version: 1, body: { ns: 'core/scheduler', goal: 'goal-scheduler-p99-slo', note: '야간 회귀 스위트 — round_jitter 재측정' } },
    summary: 'core/scheduler 야간 회귀 스위트 실행 (round jitter 재측정)',
  },
  {
    schedule_id: 'sch_b714', status: 'Pending_approval', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('drifter'),
    at: '13:50', due_rel: '매일 02:00', due_off: 41400, expires_rel: '없음', approval_required: true,
    recurrence: { kind: 'Daily', hour: 2, minute: 0, second: 0, timezone: 'KST' },
    payload: { kind: 'index.reindex', schema_version: 1, body: { ns: 'search/index', docs: '~1.2M', est: '34m', est_cost_usd: 4.20 } },
    summary: 'search/index 전체 재색인 — 야간 윈도우, 예상 $4.20',
  },
  {
    schedule_id: 'sch_c081', status: 'Pending_approval', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('analyst'),
    at: '13:30', due_rel: '매일 09:00 KST', due_off: 66600, expires_rel: '없음', approval_required: true,
    recurrence: { kind: 'Daily', hour: 9, minute: 0, second: 0, timezone: 'KST' },
    payload: { kind: 'report.generate', schema_version: 2, body: { report: 'retention-weekly', deliver: 'slack:#kidsnote-growth' } },
    summary: '리텐션 주간 리포트 생성 후 Slack #kidsnote-growth 게시',
  },
  {
    schedule_id: 'sch_4d3e', status: 'Scheduled', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('masc-improver'),
    at: '11:20', due_rel: '4h 12m 후', due_off: 15120, expires_rel: '없음', approval_required: false,
    recurrence: { kind: 'Interval', interval_sec: 21600 },
    payload: { kind: 'keeper.wake', schema_version: 1, body: { scope: 'lib/trace-store' } },
    summary: 'lib/trace-store 정기 wake — trace 라이터 상태 점검',
    grant: { by: 'operator', at: '11:21' },
  },
  {
    schedule_id: 'sch_77a0', status: 'Due', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('sangsu'),
    at: '14:00', due_rel: '지금', due_off: -40, expires_rel: '+10m', approval_required: false,
    recurrence: { kind: 'Interval', interval_sec: 3600 },
    payload: { kind: 'gate.recheck', schema_version: 1, body: { gates: ['slack', 'discord', 'amplitude'] } },
    summary: '커넥터 게이트 헬스 재점검 (slack · discord · amplitude)',
    grant: { by: 'operator', at: '09:00' },
  },
  {
    schedule_id: 'sch_2e55', status: 'Running', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('qa-king'),
    at: '13:58', due_rel: '2분 전', due_off: -120, expires_rel: '없음', approval_required: false,
    recurrence: { kind: 'One_shot' },
    payload: { kind: 'report.generate', schema_version: 1, body: { report: 'docs-linkcheck', target: 'docs/site' } },
    summary: 'docs/site 링크 점검 리포트 — PR 프리뷰 검증',
    grant: { by: 'operator', at: '13:40' },
    exec: { status: 'Execution_running', started: '14:00' },
  },
  {
    schedule_id: 'sch_18bc', status: 'Succeeded', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('masc-improver'),
    at: '12:00', due_rel: '13:30 실행', due_off: -1800, expires_rel: '없음', approval_required: false,
    recurrence: { kind: 'Interval', interval_sec: 5400 },
    payload: { kind: 'trace.export', schema_version: 1, body: { ns: 'lib/trace-store', window: '90m', sink: 's3://masc-traces' } },
    summary: 'trace 윈도우 내보내기 → s3://masc-traces',
    grant: { by: 'operator', at: '12:01' },
    exec: { status: 'Execution_succeeded', started: '13:30', finished: '13:30', detail: '318 traces · 12.4MB' },
  },
  {
    schedule_id: 'sch_a93f', status: 'Failed', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('nick0cave'),
    at: '10:40', due_rel: '11:00 실행', due_off: -10800, expires_rel: '없음', approval_required: true,
    recurrence: { kind: 'One_shot' },
    payload: { kind: 'keeper.start', schema_version: 1, body: { ns: 'core/scheduler', note: 'compact-lock 재현 잡' } },
    summary: 'compact-lock 재현 잡 기동 — runtime 연결 실패',
    grant: { by: 'operator', at: '10:41' },
    exec: { status: 'Execution_failed', started: '11:00', finished: '11:00', error: 'runtime agent-core·tokyo-2 연결 거부 (fallback 소진)' },
  },
  {
    schedule_id: 'sch_55d1', status: 'Rejected', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('drifter'),
    at: '09:10', due_rel: '—', due_off: 99999, expires_rel: '없음', approval_required: true,
    recurrence: { kind: 'One_shot' },
    payload: { kind: 'archive.purge', schema_version: 1, body: { ns: 'archive', older_than: '30d' } },
    summary: 'archive 네임스페이스 30일 경과 항목 영구 삭제',
    rejected: { by: 'operator', at: '09:12', reason: '백업 검증 전까지 destructive 보류 — 수동 재요청 요망' },
  },
  {
    schedule_id: 'sch_30c8', status: 'Cancelled', source: 'Operator_request',
    requested_by: OPERATOR, scheduled_by: kpr('reviewer'),
    at: '08:30', due_rel: '—', due_off: 99999, expires_rel: '—', approval_required: true,
    recurrence: { kind: 'Daily', hour: 18, minute: 0, second: 0, timezone: 'KST' },
    payload: { kind: 'broadcast.send', schema_version: 1, body: { scope: 'observatory', channel: '#deploy-alerts' } },
    summary: '일일 옵저버토리 요약 브로드캐스트',
    cancelled: { by: 'operator', at: '12:05' },
  },
  {
    schedule_id: 'sch_71fa', status: 'Expired', source: 'Automated_request',
    requested_by: OPERATOR, scheduled_by: kpr('scholar'),
    at: '07:00', due_rel: '만료됨', due_off: -7200, expires_rel: '경과', approval_required: false,
    recurrence: { kind: 'One_shot' },
    payload: { kind: 'gate.recheck', schema_version: 1, body: { gates: ['imessage'] } },
    summary: 'iMessage 게이트 재점검 리마인더 — 승인 창 경과',
  },
];

// durable wake signals emitted by schedule_runner.tick (read-only feed)
const SCHED_SIGNALS = [
  { signal_id: 'sig_4a21', kind: 'Due_candidate',        schedule_id: 'sch_77a0', at: '14:00' },
  { signal_id: 'sig_4a18', kind: 'Due_blocked_approval', schedule_id: 'sch_a93f', at: '11:00' },
  { signal_id: 'sig_49f7', kind: 'Due_candidate',        schedule_id: 'sch_18bc', at: '13:30' },
  { signal_id: 'sig_49e0', kind: 'Due_candidate',        schedule_id: 'sch_2e55', at: '14:00' },
];
const SCHED_SIGNAL_KIND = {
  Due_candidate:        { lbl: 'due-candidate', cls: 'ok' },
  Due_blocked_approval: { lbl: 'due-blocked-approval', cls: 'warn' },
};

// ── cadence (예약 종류) ────────────────────────────────────────────
// The one axis operators actually reason about: is this a one-off, a
// polling loop, or a fixed daily job? Derived from recurrence.kind.
const SCHED_CADENCE = {
  oneshot:  { key: 'oneshot',  lbl: '1회 · ad-hoc', short: '1회',  glyph: '•', cls: 'info', hint: '한 번 실행하고 종료 — keeper가 상황에 맞춰 건 단발성 예약' },
  interval: { key: 'interval', lbl: '폴링 · 주기',   short: '폴링', glyph: '↻', cls: 'volt', hint: '고정 간격마다 반복 — 상시 폴링 루프' },
  daily:    { key: 'daily',    lbl: '정기 · 매일',   short: '정기', glyph: '◈', cls: 'ok',   hint: '매일 지정 시각에 반복되는 정기 잡' },
};
function schedCadence(s) {
  const r = s && s.recurrence;
  if (!r || r.kind === 'One_shot') return 'oneshot';
  if (r.kind === 'Interval') return 'interval';
  if (r.kind === 'Daily') return 'daily';
  return 'oneshot';
}
// anchor "now" to the data narrative (14:00 today) so due_off math lines up
// with the stored due_rel labels ("내일 02:00" 등).
function schedNow() { const d = new Date(); d.setHours(14, 0, 0, 0); return d; }
function schedFireTime(s, now) {
  now = now || schedNow();
  if (s.status === 'Due' || s.status === 'Running') return new Date(Math.max(now.getTime(), now.getTime() + s.due_off * 1000));
  return new Date(now.getTime() + s.due_off * 1000);
}
// next tick of an interval schedule, aligned to midnight boundaries
function schedNextTick(intervalSec, now) {
  now = now || schedNow();
  const midnight = new Date(now); midnight.setHours(0, 0, 0, 0);
  const elapsed = Math.floor((now - midnight) / 1000);
  const next = Math.ceil((elapsed + 1) / intervalSec) * intervalSec;
  return new Date(midnight.getTime() + next * 1000);
}
// project active (non-terminal) daily + one-shot schedules onto N day columns.
// interval schedules are excluded here — they belong in the always-on polling strip.
function schedAgenda(list, days) {
  days = days || 7;
  const now = schedNow();
  const d0 = new Date(now); d0.setHours(0, 0, 0, 0);
  const cols = [];
  for (let i = 0; i < days; i++) {
    const date = new Date(d0); date.setDate(d0.getDate() + i);
    cols.push({ offset: i, date, events: [] });
  }
  const dayOffset = (dt) => { const x = new Date(dt); x.setHours(0, 0, 0, 0); return Math.round((x - d0) / 86400000); };
  (list || []).forEach(s => {
    if (SCHED_TERMINAL.includes(s.status)) return;
    const cad = schedCadence(s);
    if (cad === 'interval') return;
    if (cad === 'daily') {
      const r = s.recurrence;
      for (let i = 0; i < days; i++) {
        const dt = new Date(d0); dt.setDate(d0.getDate() + i); dt.setHours(r.hour, r.minute || 0, 0, 0);
        if (i === 0 && dt < now) continue;   // today's slot already passed
        cols[i].events.push({ s, at: dt, cad });
      }
    } else {
      const dt = schedFireTime(s, now);
      let off = dayOffset(dt);
      if (off < 0) off = 0;                   // running/overdue → surface on today
      if (off >= 0 && off < days) cols[off].events.push({ s, at: dt, cad });
    }
  });
  cols.forEach(c => c.events.sort((a, b) => a.at - b.at));
  return cols;
}
// counts by cadence over the effective list (for the summary strip)
function schedCadenceCounts(list) {
  const out = { oneshot: 0, interval: 0, daily: 0 };
  (list || []).forEach(s => { out[schedCadence(s)]++; });
  return out;
}

// ── keeper 자율 백그라운드 ──────────────────────────────────────────
// operator 승인 큐(SCHEDULES)와 별개로, keeper가 자기 turn에서 스스로 도는
// 폴링 루프 + 결과를 기다리는 비동기(deferred) 도구 호출. HITL 게이트가 아니라
// keeper 자율 행동 → 여기 "잡아서" operator가 전체 시간축을 볼 수 있게 한다.
const SCHED_BG_STATUS = {
  running:   { lbl: '도는 중',   cls: 'ok',   glyph: '▶' },
  paused:    { lbl: '멈춤',      cls: 'dim',  glyph: '‖' },
  in_flight: { lbl: '실행 중',   cls: 'ok',   glyph: '▶' },
  awaiting:  { lbl: '결과 대기', cls: 'warn', glyph: '◷' },
};
const KEEPER_BG = [
  // 폴링 루프 — keeper가 주기적으로 감시 (read-only 중심)
  { id: 'bg_p01', keeper: 'masc-improver', kind: 'poll', label: 'board 새 post·comment 감시', cadence_sec: 30,  status: 'running', since: '09:12' },
  { id: 'bg_p02', keeper: 'qa-king',       kind: 'poll', label: 'git worktree fetch · origin/main', cadence_sec: 300, status: 'running', since: '11:40' },
  { id: 'bg_p03', keeper: 'nick0cave',     kind: 'poll', label: 'dune build 진단 감시 · round.ml', cadence_sec: 60,  status: 'running', since: '13:20' },
  { id: 'bg_p04', keeper: 'sangsu',        kind: 'poll', label: 'connector gate heartbeat', cadence_sec: 120, status: 'paused', since: '—' },
  // 비동기 도구 호출 — in-flight / 결과 대기 (tool_execute · MCP)
  { id: 'bg_a01', keeper: 'masc-improver', kind: 'async_tool', label: 'tool_execute · 회귀 스위트 빌드', tool: 'tool_execute', status: 'in_flight', issued: '13:58', eta: '~2m' },
  { id: 'bg_a02', keeper: 'analyst',       kind: 'async_tool', label: 'amplitude 쿼리 · retention 30d', tool: 'mcp.amplitude', status: 'awaiting', issued: '13:55', eta: '응답 대기' },
  { id: 'bg_a03', keeper: 'nick0cave',     kind: 'async_tool', label: 'MCP fetch · docs 링크 검증', tool: 'mcp.fetch', status: 'in_flight', issued: '14:00', eta: '~40s' },
];
function schedBgCadence(sec) {
  if (sec % 3600 === 0) return `매 ${sec / 3600}h`;
  if (sec % 60 === 0) return `매 ${sec / 60}m`;
  return `매 ${sec}s`;
}

// merge base schedule list with an operator-action overlay (statusMap)
function schedEffective(statusMap) {
  return SCHEDULES.map(s => {
    const ov = statusMap && statusMap[s.schedule_id];
    return ov ? Object.assign({}, s, ov) : s;
  });
}

// counts for the topbar chip + nav badge
function schedSummary(statusMap) {
  const list = schedEffective(statusMap);
  const pending = list.filter(s => s.status === 'Pending_approval').length;
  const due = list.filter(s => s.status === 'Due').length;
  const scheduled = list.filter(s => s.status === 'Scheduled').length;
  const running = list.filter(s => s.status === 'Running').length;
  return { pending, due, scheduled, running, total: list.length };
}

Object.assign(window, {
  SCHED_STATUS, SCHED_TERMINAL, SCHED_PAYLOAD, SCHED_SIGNALS, SCHED_SIGNAL_KIND,
  SCHED_CADENCE, SCHEDULES, schedRecurrenceText, schedEffective, schedSummary,
  schedCadence, schedNow, schedFireTime, schedNextTick, schedAgenda, schedCadenceCounts,
  SCHED_BG_STATUS, KEEPER_BG, schedBgCadence,
});
