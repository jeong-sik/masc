/* MASC v2 — Fleet scheduling + provider routing model.
   masc surfaces the mock wires:

   · Provider failover — ❌ NOT wired. On provider failure MASC does NOT rotate
     across providers automatically; the operator edits runtime.toml (default /
     assignment) and restarts the server. The candidate `order` below is the
     CONFIGURED preference list, not an automatic failover chain. Within a single
     turn a transient infra error (5xx / timeout / connection refused) is retried
     and can widen to the catalog (0.19.56 · #23383/#23392 capped the retry loop)
     — that in-turn retry is the only automatic part; cross-provider failover is
     manual (README Features: Provider Failover ❌).
   · Keeper admission — WFQ over runtime slots (RFC-0026) + Cascade Tier
     Bounded-Wait Admission (RFC-0153): OBSERVABILITY ONLY. slots/waiting/p95 and
     capacity_backpressure are observed signals — not authorization, not a
     fleet-wide stop, and they do NOT pause keepers (failure-derived pauses were
     removed from source).
   · Keeper_event_queue (#12396): typed per-keeper stimulus queue — every
     incoming stimulus is an enqueue decision (admitted · deferred · dropped),
     draining, and retention accounting. On Draining the queue drains to empty.

   Consumed by fleet.jsx (Monitor: lane/admission observability + failover candidates),
   runtime-editor.jsx (candidate order + toml), and rails.jsx (drain queue,
   heartbeat poll). Runtime ids are binding keys "provider.model" (runtime-data.jsx). */

// ── provider routing candidates (per lane) — CONFIGURED preference, manual failover ──
// order = configured candidate preference in runtime.toml. transient_retry =
// within-turn retry widens to the catalog on transient infra errors. Automatic
// cross-provider failover is ❌ not wired — provider failure needs a manual
// runtime.toml edit + server restart.
const RT_ROTATION = {
  default: {
    lane: 'default', label: '기본 런타임',
    order: ['ollama_cloud.deepseek-v4-flash', 'deepseek.deepseek-v4-flash', 'ollama_cloud.ollama-cloud-glm-5-2'],
    expand_on_transient: true, cap: 'capacity_backpressure',
    note: '자동 페일오버 미구현(❌) — provider 실패 시 runtime.toml 수정 + 재시작. 턴 내 transient 오류는 카탈로그로 확장해 재시도.',
  },
  librarian: {
    lane: 'librarian', label: 'memory-os 라이브러리안',
    order: ['ollama_cloud.minimax-m3', 'ollama_cloud.kimi-k2-6'],
    expand_on_transient: false, cap: 'capacity_backpressure',
    note: 'JSON 모드 필요 — JSON 지원 후보. 자동 페일오버 미구현(수동).',
  },
  cross_verifier: {
    lane: 'cross_verifier', label: 'cross-verifier',
    order: ['deepseek.deepseek-v4-pro', 'glm-coding.glm-5-turbo'],
    expand_on_transient: false, cap: 'capacity_backpressure',
    note: 'JSON 모드 필요 — 반-합리화 평가자 후보. 자동 페일오버 미구현(수동).',
  },
};

// recent runtime-attempt log — outcome: recovered(턴 내 transient 재시도 성공) ·
// backpressure(capacity_backpressure 관측 — 자동 pause 아님 · 수동 조치 필요)
const ROTATION_EVENTS = [
  { at: '14:07', keeper: 'nick0cave', lane: 'cross_verifier', from: 'deepseek.deepseek-v4-pro', to: 'glm-coding.glm-5-turbo', reason: 'provider_error_timeout:http_operation', outcome: 'recovered', ms: 1840, hop: 1 },
  { at: '13:52', keeper: 'sangsu', lane: 'default', from: 'ollama.gemma4-26b-a4b-qat', to: 'ollama_cloud.deepseek-v4-flash', reason: 'connection_refused · local ollama', outcome: 'recovered', ms: 900, hop: 1, expanded: true },
  { at: '13:19', keeper: 'analyst', lane: 'default', from: 'ollama_cloud.deepseek-v4-flash', to: null, reason: 'capacity_backpressure', outcome: 'backpressure', ms: 0, hop: 2 },
  { at: '12:41', keeper: 'drifter', lane: 'cross_verifier', from: 'deepseek.deepseek-v4-pro', to: 'deepseek.deepseek-v4-pro', reason: 'transient 5xx → 재시도', outcome: 'recovered', ms: 620, hop: 0 },
];

// ── fleet admission — WFQ over runtime slots ───────────────────────────
// slots = concurrent execution slots for the binding (num max-concurrent);
// active = turns holding a slot now; waiting = enqueued (bounded-wait);
// backpressure = lane is saturated (waiting ≥ slots) → capacity_backpressure.
const ADMISSION_LANES = [
  { id: 'ollama_cloud.deepseek-v4-flash', label: '기본 · flash', slots: 4, active: 2, waiting: 1, weight: 1.0, backpressure: false, wait_p95: 120, keepers: ['masc-improver', 'qa-king', 'analyst'] },
  { id: 'deepseek.deepseek-v4-pro', label: 'smart · pro', slots: 2, active: 2, waiting: 2, weight: 1.4, backpressure: true, wait_p95: 2400, keepers: ['nick0cave', 'rama', 'drifter'] },
  { id: 'ollama.gemma4-26b-a4b-qat', label: '로컬 · gemma4', slots: 1, active: 1, waiting: 1, weight: 0.6, backpressure: true, wait_p95: 5200, keepers: ['sangsu', 'scholar', 'reviewer'] },
];

// ── per-keeper event queue (Keeper_event_queue) ────────────────────────
// enqueue decision counts + the pending stimuli list. `draining` list = what
// is being flushed while the keeper is in Draining (drained, not re-admitted).
const EVENT_KIND = {
  mention: { lbl: 'mention', glyph: '@' },
  board:   { lbl: 'board',   glyph: '\u25A4' },  // ▤
  gate:    { lbl: 'gate',    glyph: '\u26BF' },  // ⚿
  wake:    { lbl: 'wake',    glyph: '\u25CB' },  // ○
  handoff: { lbl: 'handoff', glyph: '\u21C4' },  // ⇄
};
const KEEPER_QUEUE = {
  'nick0cave': { admitted: 1, deferred: 3, dropped: 1, retained: 8, pending: [
    { kind: 'mention', from: '@operator · slack', at: '방금' },
    { kind: 'board', from: 'core/scheduler · T-3902 코멘트', at: '2m' },
    { kind: 'gate', from: 'HITL H-038 결재 대기', at: '3m' },
  ] },
  'qa-king': { admitted: 1, deferred: 1, dropped: 0, retained: 3, pending: [
    { kind: 'handoff', from: 'qa-king → sangsu 인계', at: '진행' },
  ] },
  'analyst': { admitted: 0, deferred: 2, dropped: 0, retained: 5, pending: [
    { kind: 'gate', from: 'HITL H-040 재색인 권한', at: '3m' },
    { kind: 'board', from: 'search/index 색인 실패 알림', at: '11m' },
  ] },
  'scholar': { admitted: 0, deferred: 0, dropped: 0, retained: 0, draining: [
    { kind: 'board', from: 'infra/deploy 공지', at: '보류' },
    { kind: 'wake', from: 'heartbeat', at: '취소' },
  ] },
};

// ── helpers ────────────────────────────────────────────────────────────
function admissionSummary() {
  return ADMISSION_LANES.reduce((a, l) => ({
    active: a.active + l.active,
    waiting: a.waiting + l.waiting,
    slots: a.slots + l.slots,
    backpressure: a.backpressure + (l.backpressure ? 1 : 0),
  }), { active: 0, waiting: 0, slots: 0, backpressure: 0 });
}
function rotationForLane(laneId) { return RT_ROTATION[laneId] || null; }
// which routing lane a runtime id serves as the head of (for the per-keeper aside)
function rotationForRuntime(runtimeId) {
  return Object.values(RT_ROTATION).find(r => r.order[0] === runtimeId) || null;
}
function keeperQueue(id) { return KEEPER_QUEUE[id] || null; }

Object.assign(window, {
  RT_ROTATION, ROTATION_EVENTS, ADMISSION_LANES, EVENT_KIND, KEEPER_QUEUE,
  admissionSummary, rotationForLane, rotationForRuntime, keeperQueue,
});
