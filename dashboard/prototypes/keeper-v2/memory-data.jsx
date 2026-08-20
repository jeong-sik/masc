/* MASC v2 — Keeper memory model (read-only), re-derived from what the
   Memory OS ACTUALLY holds (RFC keeper-memory-panel-real-data, 2026-06-24).

   The score model (salience / uses / lastUsed / pinned facts) was deleted by
   RFC-0247 — "a fact's value is the librarian's judgment, not a number on the
   row." We do NOT resurrect it. Each store row carries only real fact fields:
     · category   — the real closed-sum taxonomy (10 arms), not fact/decision/…
     · claim      — the fact text
     · provenance — { trace, turn } (provenance_event), not a single tag
     · age        — time since reference_time (last_verified ∨ first_seen),
                    NOT last_accessed
     · current    — fact_is_current (TTL not expired)
   Context composition is measured prompt-block BYTES over the real
   Prompt_block_id taxonomy (RFC-0233) + turn-level input_tokens / context_window
   — no `ctx * 200000`, no per-part magic multipliers. */

// fact.category — real closed sum (keeper_memory_os_types.ml). Exhaustive; an
// unknown arm carries its raw label forward rather than being dropped.
const MEM_CATEGORY = {
  code_change:        { lbl: '코드 변경',   glyph: '◆', cls: 'code' },
  fact:               { lbl: '사실',        glyph: '◈', cls: 'fact' },
  preference:         { lbl: '선호',        glyph: '○', cls: 'pref' },
  blocker:            { lbl: '차단',        glyph: '⊘', cls: 'blocker' },
  goal:               { lbl: '목표',        glyph: '◎', cls: 'goal' },
  constraint:         { lbl: '제약',        glyph: '▣', cls: 'constraint' },
  ephemeral:          { lbl: '임시',        glyph: '◌', cls: 'ephemeral' },
  validated_approach: { lbl: '검증된 접근', glyph: '✓', cls: 'validated' },
  lesson:             { lbl: '교훈',        glyph: '✦', cls: 'lesson' },
  unknown:            { lbl: '미분류',      glyph: '·', cls: 'unknown' },
};

// Prompt_block_id arms (RFC-0233). The "memory" portion is memory_os_recall +
// user_model. Bar is measured BYTES per block, header is tokens.
const MEM_BLOCKS = {
  persona:           { lbl: '페르소나',      color: 'var(--volt-dim)', mem: false },
  dynamic_context:   { lbl: '동적 컨텍스트', color: 'var(--info)', mem: false },
  memory_os_recall:  { lbl: '메모리 회상',   color: 'var(--status-ok)', mem: true },
  user_model:        { lbl: '유저 모델',     color: 'var(--accent-bone)', mem: true },
  connected_surface: { lbl: '연결 표면',     color: 'var(--status-warn)', mem: false },
};

// episode.role for the memory-shaping timeline (real episode/compaction events,
// not a fabricated per-token op log).
const MEM_EPISODE = {
  compact:   { lbl: '압축',   glyph: '◉', cls: 'compact' },
  summarize: { lbl: '요약',   glyph: '◈', cls: 'summarize' },
  evict:     { lbl: '폐기',   glyph: '◌', cls: 'evict' },
};

// fact rows: real fact shape only. age = since reference_time. current = TTL ok.
const KEEPER_MEMORY = {
  'masc-improver': {
    usage: { input_tokens: 158400, context_window: 200000 },
    blocks: [
      { block: 'persona', bytes: 8200 },
      { block: 'dynamic_context', bytes: 286000 },
      { block: 'memory_os_recall', bytes: 41200 },
      { block: 'user_model', bytes: 9400 },
      { block: 'connected_surface', bytes: 22800 },
    ],
    store: [
      { id: 's1', category: 'fact', claim: 'trace-store p99 쓰기 지연 목표 < 20ms (현재 19ms)', prov: { trace: 'T-3902', turn: 41 }, age: '12분', current: true },
      { id: 's2', category: 'validated_approach', claim: '리텐션 대시보드 = 코호트 히트맵 + D0/D1/D7 3열로 확정', prov: { trace: 'goal-retention', turn: 18 }, age: '41분', current: true },
      { id: 's3', category: 'validated_approach', claim: 'amplitude 쿼리 결과는 표로 정규화 후 캐시 — 동일 segment 재질의 빈번', prov: { trace: 'self', turn: 33 }, age: '1시간', current: true },
      { id: 's4', category: 'preference', claim: 'operator는 숫자에 천단위 구분 + 단위 명시 선호', prov: { trace: 'operator', turn: 7 }, age: '3시간', current: true },
      { id: 's5', category: 'fact', claim: 'gp:center_type — 가맹점 분류 차원 (마트/편의점/기타/미정)', prov: { trace: 'T-3880', turn: 12 }, age: '2시간', current: true },
      { id: 's6', category: 'ephemeral', claim: '이번 세션 amplitude 토큰 만료 14:40 — 갱신 필요', prov: { trace: 'self', turn: 39 }, age: '8분', current: false, ttl: '만료' },
    ],
    episodes: [
      { id: 'e1', role: 'compact', at: '13:58', range: 'turn 1–28', claims: 5, summary: 'D0 정의·코호트 히트맵 합의까지 압축 — 도구 ref 4건 유지', freed: 64000 },
      { id: 'e2', role: 'summarize', at: '13:12', range: 'turn 29–37', claims: 2, summary: 'amplitude 쿼리 패턴을 1개 검증된 접근으로 요약' },
    ],
  },
  'nick0cave': {
    usage: { input_tokens: 182000, context_window: 200000 },
    blocks: [
      { block: 'persona', bytes: 8200 },
      { block: 'dynamic_context', bytes: 372000 },
      { block: 'memory_os_recall', bytes: 38600 },
      { block: 'user_model', bytes: 7100 },
      { block: 'connected_surface', bytes: 15400 },
    ],
    store: [
      { id: 's1', category: 'fact', claim: 'core/scheduler jitter p95 회귀 가드: 380ms → 19ms', prov: { trace: 'T-3902', turn: 52 }, age: '3분', current: true },
      { id: 's2', category: 'validated_approach', claim: 'unlock 후 압축으로 이동 — compact()를 critical section 밖으로', prov: { trace: 'T-3902', turn: 49 }, age: '9분', current: true },
      { id: 's3', category: 'lesson', claim: 'lock 재진입 가설은 trace_window open_fds 메트릭으로 검증', prov: { trace: 'self', turn: 44 }, age: '22분', current: true },
      { id: 's4', category: 'fact', claim: 'Exec_policy — 실행 정책 통합 표면 (RFC-0254)', prov: { trace: 'goal-exec-policy', turn: 20 }, age: '1시간', current: true },
      { id: 's5', category: 'constraint', claim: 'compact()는 lock 보유 중 호출 금지 — p95 380ms 스파이크 원인', prov: { trace: 'T-3902', turn: 31 }, age: '6시간', current: true },
    ],
    episodes: [
      { id: 'e1', role: 'compact', at: '14:19', range: 'turn 1–46', claims: 4, summary: 'round.ml lock 재진입 진단 전 과정을 압축 — 패치 방향 결론 유지', freed: 128000 },
    ],
  },
  'sangsu': {
    usage: { input_tokens: 94600, context_window: 200000 },
    blocks: [
      { block: 'persona', bytes: 8200 },
      { block: 'dynamic_context', bytes: 138000 },
      { block: 'memory_os_recall', bytes: 24800 },
      { block: 'user_model', bytes: 6200 },
      { block: 'connected_surface', bytes: 11600 },
    ],
    store: [
      { id: 's1', category: 'fact', claim: 'core/runtime dune test 84/84 ok (41.2s)', prov: { trace: 'self', turn: 28 }, age: '방금', current: true },
      { id: 's2', category: 'validated_approach', claim: 'Eio 리소스는 연 Switch가 닫힐 때 해제 — 라이터는 로컬 Switch.run으로', prov: { trace: 'T-3902', turn: 24 }, age: '4분', current: true },
      { id: 's3', category: 'preference', claim: 'diff는 side-by-side, 탭 너비 2', prov: { trace: 'operator', turn: 5 }, age: '2시간', current: true },
      { id: 's4', category: 'constraint', claim: 'round_test.ml 84/84 통과가 머지 게이트 — 깨지면 즉시 중단', prov: { trace: 'operator', turn: 9 }, age: '1일', current: true },
    ],
    episodes: [
      { id: 'e1', role: 'summarize', at: '14:30', range: 'turn 1–22', claims: 3, summary: 'fd 누수 핸드오프 수신 + Switch.run 패치 착수를 요약' },
    ],
  },
  'qa-king': {
    usage: { input_tokens: 71200, context_window: 200000 },
    blocks: [
      { block: 'persona', bytes: 8200 },
      { block: 'dynamic_context', bytes: 102000 },
      { block: 'memory_os_recall', bytes: 17600 },
      { block: 'user_model', bytes: 5400 },
      { block: 'connected_surface', bytes: 9200 },
    ],
    store: [
      { id: 's1', category: 'fact', claim: 'docs 사이트 빌드 시간 평균 58s', prov: { trace: 'self', turn: 14 }, age: '8분', current: true },
      { id: 's2', category: 'validated_approach', claim: '핸드오프 시 미해결 링크 점검 항목을 다음 keeper에 전달', prov: { trace: 'self', turn: 16 }, age: '8분', current: true },
      { id: 's3', category: 'constraint', claim: 'docs/site는 PR마다 프리뷰 배포 — 링크 깨지면 fail', prov: { trace: 'self', turn: 4 }, age: '8시간', current: true },
    ],
    episodes: [],
  },
  'analyst': {
    usage: { input_tokens: 66800, context_window: 200000 },
    blocks: [
      { block: 'persona', bytes: 8200 },
      { block: 'dynamic_context', bytes: 96000 },
      { block: 'memory_os_recall', bytes: 14200 },
      { block: 'user_model', bytes: 5000 },
      { block: 'connected_surface', bytes: 8800 },
    ],
    store: [
      { id: 's1', category: 'fact', claim: 'search/index 문서 ~1.2M, 재색인 ~34분', prov: { trace: 'self', turn: 11 }, age: '34분', current: true },
      { id: 's2', category: 'fact', claim: 'gp:center_type 분포 — 분석 코호트 핵심 차원', prov: { trace: 'T-3880', turn: 8 }, age: '2시간', current: true },
      { id: 's3', category: 'constraint', claim: 'search/index 재색인은 야간 윈도우(02:00 KST)에만', prov: { trace: 'operator', turn: 6 }, age: '12시간', current: true },
      { id: 's4', category: 'blocker', claim: 'search/index 색인 실패 1건 — 재색인 권한 승인 대기 (H-040)', prov: { trace: 'self', turn: 19 }, age: '13분', current: true },
    ],
    episodes: [],
  },
  'drifter': {
    usage: { input_tokens: 0, context_window: 200000 },
    blocks: [],
    store: [
      { id: 's1', category: 'lesson', claim: 'core/runtime overflow 재현: 컨텍스트 100%에서 trace 라이터 fd 누수 누적', prov: { trace: 'T-3902', turn: 180 }, age: '3시간', current: true },
    ],
    episodes: [],
  },
};

// composition = group prompt blocks by id, sum BYTES (RFC-0233). The header
// reports real input_tokens / context_window; the bar is bytes per block.
function memComposition(k) {
  const rec = KEEPER_MEMORY[k.id];
  if (!rec || !rec.blocks || rec.blocks.length === 0) return { totalBytes: 0, parts: [], usage: null };
  const parts = rec.blocks.map(b => {
    const meta = MEM_BLOCKS[b.block] || { lbl: b.block, color: 'var(--text-dim)', mem: false };
    return { key: b.block, lbl: meta.lbl, bytes: b.bytes, color: meta.color, mem: meta.mem };
  });
  const totalBytes = parts.reduce((s, p) => s + p.bytes, 0);
  return { totalBytes, parts, usage: rec.usage || null };
}

function getKeeperMemory(k) {
  return KEEPER_MEMORY[k.id] || { store: [], episodes: [], blocks: [], usage: null };
}

// aggregate across the fleet — counts + real category distribution + memory
// recall bytes. No salience, no pin count.
function memAggregate(keepers) {
  const rows = [];
  let store = 0, memBytes = 0;
  const catTotals = {};
  const allFacts = [];
  keepers.forEach(k => {
    const m = getKeeperMemory(k);
    const comp = memComposition(k);
    const mb = comp.parts.filter(p => p.mem).reduce((s, p) => s + p.bytes, 0);
    store += m.store.length;
    memBytes += mb;
    m.store.forEach(s => {
      catTotals[s.category] = (catTotals[s.category] || 0) + 1;
      allFacts.push(Object.assign({}, s, { keeper: k.id }));
    });
    rows.push({ id: k.id, kr: k.kr, ctx: k.ctx, status: k.status, store: m.store.length, memBytes: mb });
  });
  // "recent" facts by age proxy — first rows are most recently verified in the
  // seed; no salience sort (RFC-0247).
  const recentFacts = allFacts.slice(0, 6);
  return { rows, store, memBytes, catTotals, recentFacts, keeperCount: keepers.length };
}

Object.assign(window, { MEM_CATEGORY, MEM_BLOCKS, MEM_EPISODE, KEEPER_MEMORY, getKeeperMemory, memComposition, memAggregate });
