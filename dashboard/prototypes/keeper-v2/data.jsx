/* MASC v2 — Keeper roster + sample agent conversations.
   Grounded in dashboard/src/types/core.ts (Keeper) and keeper-badge.ts.
   Identity = color slot (1..12) + 2-letter sigil. Portrait is optional flavor. */

const PORTRAIT = (slug) => {
  if (!slug) return null;
  // When bundled standalone, portraits are lifted to inlined blob URLs.
  if (typeof window !== 'undefined' && window.__resources && window.__resources[slug]) return window.__resources[slug];
  return `assets/portraits/${slug}.png`;
};

// 12-state keeper machine (canonical MASC nouns)
const FSM_STATES = [
  'Offline', 'Restarting', 'Running', 'Compacting', 'HandingOff',
  'Failing', 'Overflowed', 'Draining', 'Paused', 'Stopped', 'Crashed', 'Dead',
];

// FSM state → short KR gloss (shown on hover so the canonical English noun stays primary)
const PHASE_INFO = {
  Offline:    '오프라인 — 실행 중이 아님',
  Restarting: '재시작 중',
  Running:    '실행 중 — 작업/라운드 순환',
  Compacting: '컨텍스트 압축 중',
  HandingOff: '작업을 다른 keeper 에게 인계하는 중',
  Failing:    '실패 처리 중',
  Overflowed: '컨텍스트 윈도우 초과',
  Draining:   '정상 종료를 위해 작업을 비우는 중',
  Paused:     '슈퍼바이저가 일시정지함',
  Stopped:    '중지됨',
  Crashed:    '비정상 종료',
  Dead:       '복구 불가 — 종료됨',
};

// phase → status dot tone (the 12 states collapse to 5 color buckets so
// danger/transient states are visually distinct, not all grey).
const PHASE_TONE = {
  Running: 'ok', Paused: 'warn', Draining: 'warn',
  Compacting: 'busy', HandingOff: 'busy', Restarting: 'busy',
  Failing: 'bad', Overflowed: 'bad', Crashed: 'bad', Dead: 'bad',
  Stopped: 'idle', Offline: 'idle',
};
// which phases breathe (live heartbeat pulse on the dot/sigil)
const PHASE_PULSE = {
  Running: true, Compacting: true, HandingOff: true, Restarting: true, Failing: true,
};
// coarse run/pause/off bucket derived from phase (drives roster grouping)
const phaseStatus = (phase) =>
  ['Running', 'Compacting', 'HandingOff', 'Restarting', 'Failing'].includes(phase) ? 'run'
    : ['Paused', 'Draining'].includes(phase) ? 'pause' : 'off';

// Operator-issued lifecycle actions legal from each phase.
//   to     — resolved phase
//   via/ms — transient phase shown first, auto-advances to `to` after ms
//   danger — destructive (red affordance)
const FSM_ACTIONS = {
  Running: [
    { id: 'pause',   label: '일시정지', glyph: '\u23F8', to: 'Paused',  hint: '슈퍼바이저가 잠시 멈춤 — 컨텍스트·소유 태스크 보존, 즉시 재개 가능' },
    { id: 'compact', label: '컴팩션',   glyph: '\u25C9', via: 'Compacting', to: 'Running', ms: 1700, hint: '컨텍스트를 지금 압축하고 실행 복귀' },
    { id: 'handoff', label: '핸드오프', glyph: '\u21C4', via: 'HandingOff', to: 'Stopped', ms: 1700, hint: '소유 태스크를 인계하고 이 세션 정리' },
    { id: 'stop',    label: '중지',     glyph: '\u23F9', via: 'Draining',  to: 'Stopped', ms: 1500, danger: true, hint: '작업을 비우고 종료 (Drain → Stopped)' },
  ],
  Paused: [
    { id: 'resume', label: '재개', glyph: '\u25B6', to: 'Running', hint: '멈춘 지점부터 다시 실행' },
    { id: 'stop',   label: '중지', glyph: '\u23F9', via: 'Draining', to: 'Stopped', ms: 1500, danger: true, hint: '작업을 비우고 종료' },
  ],
  Overflowed: [
    { id: 'compact', label: '컴팩션', glyph: '\u25C9', via: 'Compacting', to: 'Running', ms: 2000, hint: '윈도우 초과 — 압축으로 복구' },
    { id: 'stop',    label: '중지',   glyph: '\u23F9', via: 'Draining', to: 'Stopped', ms: 1500, danger: true, hint: '복구 대신 종료' },
  ],
  Failing: [
    { id: 'restart', label: '재시작', glyph: '\u21BB', via: 'Restarting', to: 'Running', ms: 1700, hint: '실패 처리 후 재시작' },
    { id: 'stop',    label: '중지',   glyph: '\u23F9', via: 'Draining', to: 'Stopped', ms: 1500, danger: true, hint: '종료' },
  ],
  Crashed: [
    { id: 'restart', label: '재시작', glyph: '\u21BB', via: 'Restarting', to: 'Running', ms: 1800, hint: '비정상 종료 — 재시작 시도' },
  ],
  Stopped: [
    { id: 'start', label: '시작', glyph: '\u25B6', via: 'Restarting', to: 'Running', ms: 1500, hint: '중지된 keeper 새로 시작' },
  ],
  Offline: [
    { id: 'start', label: '시작', glyph: '\u25B6', via: 'Restarting', to: 'Running', ms: 1500, hint: '오프라인 keeper 시작' },
  ],
  // transient + terminal phases take no operator action
  Compacting: [], HandingOff: [], Draining: [], Restarting: [], Dead: [],
};

// keeper_id → { slot, sigil }, mirrors KEEPER_REGISTRY anchors in keeper-badge.ts
const KEEPERS = [
  { id: 'masc-improver', sigil: 'MS', slot: 6,  role: 'keeper', status: 'run',   phase: 'Running',    model: 'deepseek-v4-flash', runtime: 'ollama_cloud.deepseek-v4-flash', ns: 'lib/trace-store', att: 0, uptime: '4h 12m', last: '41분', ctx: 0.62, traces: 318, tasks: 2, tps: 64, portrait: 'miso' },
  { id: 'nick0cave',     sigil: 'NK', slot: 3,  role: 'keeper',  status: 'run',   phase: 'Compacting', model: 'deepseek-v4-pro',   runtime: 'deepseek.deepseek-v4-pro', ns: 'core/scheduler',     att: 2, uptime: '11h 03m', last: '3분',  ctx: 0.91, traces: 540, tasks: 4, tps: 31, portrait: 'grimja' },
  { id: 'sangsu',        sigil: 'SS', slot: 9,  role: 'keeper',  status: 'run',   phase: 'Running',    model: 'gemma4-26b-a4b-qat', runtime: 'ollama.gemma4-26b-a4b-qat', ns: 'core/runtime',       att: 0, uptime: '2h 47m', last: '방금', ctx: 0.44, traces: 210, tasks: 3, tps: 88, portrait: 'iron' },
  { id: 'qa-king',       sigil: 'QA', slot: 2,  role: 'keeper',  status: 'run',   phase: 'HandingOff', model: 'deepseek-v4-flash',  runtime: 'ollama_cloud.deepseek-v4-flash', ns: 'docs/site',          att: 1, uptime: '58m',    last: '8분',  ctx: 0.71, traces: 97,  tasks: 1, tps: 142, portrait: 'luna' },
  { id: 'rama',          sigil: 'RM', slot: 11, role: 'keeper',  status: 'pause', phase: 'Paused',     model: 'deepseek-v4-pro', runtime: 'deepseek.deepseek-v4-pro', ns: 'core/scheduler',     att: 0, uptime: '22m',    last: '22분', ctx: 0.33, traces: 154, tasks: 2, tps: 0, portrait: 'cedric' },
  { id: 'scholar',       sigil: 'SC', slot: 5,  role: 'keeper',  status: 'pause', phase: 'Draining',   model: 'gemma4-26b-a4b-qat',  runtime: 'ollama.gemma4-26b-a4b-qat', ns: 'infra/deploy',       att: 0, uptime: '1h 09m', last: '17분', ctx: 0.58, traces: 73,  tasks: 1, tps: 0, portrait: 'dara' },
  { id: 'analyst',       sigil: 'AN', slot: 7, role: 'keeper', status: 'pause', phase: 'Paused',    model: 'deepseek-v4-flash', runtime: 'ollama_cloud.deepseek-v4-flash', ns: 'search/index',       att: 3, uptime: '34m',    last: '34분', ctx: 0.80, traces: 289, tasks: 2, tps: 0, portrait: 'brenna' },
  { id: 'reviewer',      sigil: 'RV', slot: 10, role: 'keeper',  status: 'pause', phase: 'Paused',     model: 'gemma4-26b-a4b-qat',  runtime: 'ollama.gemma4-26b-a4b-qat', ns: 'observatory',        att: 0, uptime: '51m',    last: '51분', ctx: 0.21, traces: 44,  tasks: 0, tps: 0, portrait: 'moth' },
  { id: 'herald',        sigil: 'HD', slot: 1,  role: 'keeper',  status: 'off',   phase: 'Stopped',    model: 'deepseek-v4-flash',  runtime: '—',           ns: 'connectors/slack',   att: 0, uptime: '—',      last: '2시간', ctx: 0.0, traces: 12,  tasks: 0, tps: 0, portrait: null },
  { id: 'drifter',       sigil: 'DF', slot: 12, role: 'keeper', status: 'off',   phase: 'Overflowed', model: 'deepseek-v4-pro', runtime: 'deepseek.deepseek-v4-pro', ns: 'core/runtime',       att: 5, uptime: '—',      last: '3시간', ctx: 1.0, traces: 401, tasks: 1, tps: 0, portrait: 'dust' },
  { id: 'marshal',       sigil: 'MA', slot: 4,  role: 'keeper',  status: 'off',   phase: 'Crashed',    model: 'deepseek-v4-flash', runtime: '—',           ns: 'infra/deploy',       att: 0, uptime: '—',      last: '5시간', ctx: 0.0, traces: 188, tasks: 0, tps: 0, portrait: null },
  { id: 'revenant',      sigil: 'RN', slot: 8, role: 'keeper',  status: 'off',   phase: 'Dead',       model: 'deepseek-v4-flash', runtime: '—',           ns: 'archive',            att: 0, uptime: '—',      last: '1일',  ctx: 0.0, traces: 920, tasks: 0, tps: 0, portrait: 'songarak' },
];

// keeper 는 namespace 를 소유하지 않는다 — 각자 격리된 worktree basepath 만 가진다.
// 노출이 의미 있는 건 namespace 가 아니라 keeper 의 현재 작업 경로(cwd)와 sandbox(=worktree 격리) 여부.
// MASC 는 단일 머신 localhost-trust 모델 → OS·컨테이너 sandbox 없음, 격리는 git worktree 뿐.
KEEPERS.forEach(k => {
  k.basepath = '~/wt/' + k.id;
  k.cwd = k.basepath;                                 // 현재 작업 경로 = 격리된 worktree 루트 (namespace 아님)
  k.sandbox = k.status === 'off' ? null : 'worktree';  // 격리 = git worktree (localhost-trust)
  // heartbeat wake cadence — keeper 는 heartbeat 간격마다 깨어나 mention/메시지에 반응한다.
  // Paused 는 느린 관찰 cadence, off 계열은 wake 없음(null). next = 다음 wake 까지 남은 초.
  k.hb = k.status === 'off' ? null : (k.status === 'pause' ? 60 : 15);
  k.hbNext = k.hb == null ? null : (k.status === 'pause' ? 60 - (k.traces % 60) : 15 - (k.traces % 15));
});

const THREAD_IMPROVER = [
  {
    id: 'm1', role: 'user', source: 'dashboard', ts: '14:02',
    blocks: [{ t: 'p', html: 'keeper가 drain 돼도 trace 라이터 쪽 fd가 안 닫히는 것 같아. <code>lib/trace/writer.ml</code> 에서 Eio.Switch 밖에서 flow를 열고 있는지 봐줘.' }],
  },
  {
    id: 'm2', role: 'assistant', source: 'dashboard', ts: '14:02', verified: true,
    trace: [
      { kind: 'think', text: 'fd 누수면 Switch 수명부터 의심해야지.' },
      { kind: 'reason', text: '전역 switch에 fork하면 keeper drain 시 fiber가 안 끊겨 flow가 남는다.',
        detail: 'Eio에서 리소스는 그것을 연 <code>Switch</code>가 닫힐 때 해제된다. 라이터가 keeper 수명 전체를 사는 <strong>전역 sw</strong>에 <code>Fiber.fork</code> 하면, Draining→Stopped 전이에서도 fiber가 살아남아 소켓 fd가 닫히지 않는다. blame으로 언제 이 구조가 들어왔는지부터 본다.' },
      { kind: 'tool', name: 'tool_execute', status: 'ok', dur: '0.6s',
        args: { cmd: 'git blame -L 40,58 lib/trace/writer.ml' },
        result: '{ commit: "a13f9c2e", author: "drifter", at: "6d ago", msg: "trace: async writer" }' },
      { kind: 'tool', name: 'tool_execute', status: 'ok', dur: '1.0s',
        args: { cmd: 'lsof -p $(pidof masc) | wc -l' },
        result: '{ start: 41, now: 87, leaked_per_drain: ~3 }' },
    ],
    blocks: [
      { t: 'p', html: '맞습니다 — drain 한 번에 <strong>fd 3개</strong>씩 새고 있어요(1시간새 41→87). 원인은 라이터가 keeper 전역 <code>sw</code> 에 fork되는 구조입니다.' },
      { t: 'code', cap: 'lib/trace/writer.ml — 현재 (누수)',
        html: '<span class="kw">let</span> <span class="fn">writer</span> ~sw env trace =\n  <span class="cm">(* sw = keeper 전역 switch *)</span>\n  <span class="kw">let</span> flow = <span class="fn">Eio.Net.connect</span> ~sw env#net store_addr <span class="kw">in</span>\n  <span class="fn">Eio.Fiber.fork</span> ~sw <span class="kw">@@</span> <span class="kw">fun</span> () -&gt;\n    <span class="fn">write_loop</span> flow trace   <span class="cm">(* drain 돼도 안 닫힘 *)</span>' },
      { t: 'callout', html: 'flow가 <strong>keeper 전역 sw</strong>에 묶여 있어 <code>Draining</code> 전이에서도 소켓이 살아남습니다. 라이터 수명을 자체 <code>Switch.run</code> 으로 가두면 fiber 취소 시 flow가 자동 close 됩니다.' },
      { t: 'code', cap: 'lib/trace/writer.ml — 제안 (수정)',
        html: '<span class="kw">let</span> <span class="fn">writer</span> env trace =\n  <span class="fn">Eio.Switch.run</span> <span class="kw">@@</span> <span class="kw">fun</span> sw -&gt;        <span class="cm">(* 라이터 수명에 묶인 로컬 switch *)</span>\n  <span class="kw">let</span> flow = <span class="fn">Eio.Net.connect</span> ~sw env#net store_addr <span class="kw">in</span>\n  <span class="fn">write_loop</span> flow trace        <span class="cm">(* Switch.run 종료 시 flow 자동 close *)</span>' },
      { t: 'p', html: '호출부는 <code>Fiber.fork ~sw:keeper_sw (fun () -&gt; writer env trace)</code> 로 바꾸면, keeper drain → keeper_sw 취소 → writer의 로컬 switch 정리 → fd 해제 순으로 깔끔히 끊깁니다.' },
    ],
    suggestions: [
      'writer 호출부 3곳도 같이 패치',
      'fd 누수 회귀 테스트 추가',
      'compact 라이터에도 같은 패턴 적용',
    ],
  },
  {
    id: 'm3', role: 'user', source: 'discord', who: '@sangsu', nick: 'sangsu', ts: '14:05',
    ctxFrom: { channel: '#core-eng', guild: 'masc', msgs: 9, range: '13:50–14:05', via: 'discord-gate',
      preview: [
        ['13:50', '@sangsu', 'writer fd 누수 건 보고 있는데, Switch.run 로 감싸는 게 맞지?'],
        ['13:58', '@operator', 'keeper drain 때 fiber 취소가 핵심이라 그게 맞아요.'],
        ['14:05', '@sangsu', 'ok 그럼 호출부도 내가 같이 정리할게요.'],
      ] },
    blocks: [{ t: 'p', html: 'Discord에서 봤어요 — <code>Switch.run</code> 로 감싸면 fiber 취소될 때 flow도 같이 닫히는 거 맞죠? 호출부 3곳은 제가 정리할게요.' }],
  },
  {
    id: 'm4', role: 'assistant', source: 'discord', ts: '14:06',
    ctxFrom: { channel: '#core-eng', guild: 'masc', msgs: 9, range: '13:50–14:05', via: 'discord-gate',
      preview: [
        ['13:50', '@sangsu', 'writer fd 누수 건 보고 있는데, Switch.run 로 감싸는 게 맞지?'],
        ['13:58', '@operator', 'keeper drain 때 fiber 취소가 핵심이라 그게 맞아요.'],
        ['14:05', '@sangsu', 'ok 그럼 호출부도 내가 같이 정리할게요.'],
      ] },
    blocks: [{ t: 'p', html: '맞습니다 — <code>Switch.run</code> 블록을 벗어나면 그 안에서 연 flow는 <code>cancel</code> 시 자동 해제됩니다. 호출부 정리는 sangsu님이 맡아주시면, 저는 회귀 테스트(<code>open_fds</code> 불변)부터 올려둘게요.' }],
    suggestions: ['회귀 테스트 PR 열기', 'open_fds 메트릭 대시보드에 추가'],
  },
  {
    id: 'm5', role: 'user', source: 'dashboard', ts: '14:09',
    blocks: [{ t: 'p', html: '좋아. 패치 적용하고 회귀 테스트 돌려서 fd 누수 잡혔는지 확인해줘. 결과는 md로 요약해서 남겨주고.' }],
  },
  {
    id: 'm6', role: 'assistant', source: 'dashboard', ts: '14:10', verified: true,
    trace: [
      { kind: 'think', text: '패치 적용 후 runtest로 before/after 비교.' },
      { kind: 'tool', name: 'tool_execute', status: 'ok', dur: '3.2s',
        args: { cmd: 'dune build @runtest', cwd: '~/wt/masc-improver' },
        result: '{ exit: 0, tests: 1, passed: 1 }' },
    ],
    blocks: [
      { t: 'p', html: '패치 적용 후 <code>dune build @runtest</code> 결과입니다 — 누수가 잡혔어요.' },
      { t: 'shell', title: 'masc-improver@~/wt/masc-improver', exit: 0, dur: '3.2s',
        lines: [
          { t: 'cmd', v: 'dune build @runtest' },
          { t: 'dim', v: 'Running 1 test (trace_writer_fd_leak)...' },
          { t: 'ok', v: 'PASS  trace_writer_fd_leak' },
          { v: '  before patch:  open_fds 41 → 87   (+46 leaked / 15 drains)' },
          { t: 'ok', v: '  after  patch:  open_fds 41 → 41   (0 leaked)' },
        ] },
      { t: 'svg', cap: 'open_fds — drain 횟수에 따른 추이',
        svg: '<svg viewBox="0 0 380 168" width="380" height="168" xmlns="http://www.w3.org/2000/svg" font-family="JetBrains Mono, monospace">\\n  <!-- legend -->\\n  <g font-size="10">\\n    <rect x="44" y="8" width="9" height="9" rx="1" fill="#c4a265"/><text x="58" y="16" fill="#ede0c8">패치 전 (누수)</text>\\n    <rect x="150" y="8" width="9" height="9" rx="1" fill="#5ea66a"/><text x="164" y="16" fill="#ede0c8">패치 후 (안정)</text>\\n  </g>\\n  <!-- gridlines + y labels -->\\n  <g stroke="#2a2420" stroke-width="1">\\n    <line x1="44" y1="36" x2="356" y2="36"/>\\n    <line x1="44" y1="84" x2="356" y2="84"/>\\n    <line x1="44" y1="132" x2="356" y2="132"/>\\n  </g>\\n  <g font-size="9" fill="#6a5d4d" text-anchor="end">\\n    <text x="38" y="39">100</text>\\n    <text x="38" y="87">50</text>\\n    <text x="38" y="135">0</text>\\n  </g>\\n  <!-- before: 41→87 leaking up -->\\n  <polyline fill="none" stroke="#c4a265" stroke-width="2" points="44,96 106,87 168,79 230,71 292,63 356,53"/>\\n  <g fill="#c4a265"><circle cx="356" cy="53" r="3"/></g>\\n  <text x="350" y="46" font-size="9" fill="#c4a265" text-anchor="end">87</text>\\n  <!-- after: flat ~41 -->\\n  <polyline fill="none" stroke="#5ea66a" stroke-width="2" points="44,96 106,96 168,96 230,95 292,96 356,96"/>\\n  <g fill="#5ea66a"><circle cx="356" cy="96" r="3"/></g>\\n  <text x="350" y="108" font-size="9" fill="#5ea66a" text-anchor="end">41</text>\\n  <!-- x axis label -->\\n  <text x="200" y="160" font-size="9" fill="#6a5d4d" text-anchor="middle">drain 횟수 →</text>\\n</svg>' },
      { t: 'artifact', kind: 'md', name: 'fd-leak-fix.md', size: '2.1 KB', note: '요약 리포트' },
      { t: 'p', html: '참고로 같은 누수 패턴이 upstream에도 보고돼 있어요 — Eio Switch 수명 관련 이슈입니다.' },
      { t: 'link', url: 'https://github.com/ocaml-multicore/eio/issues/388', fav: '◫', kind: 'git',
        title: 'Resource leak when forking into a parent Switch · ocaml-multicore/eio',
        desc: '부모 switch에 fork된 fiber가 취소 시 정리되지 않아 fd가 누수되는 패턴. Switch.run 으로 수명을 가두는 것이 권장 해법.',
        meta: 'github.com · Issue #388 · open' },
      { t: 'p', html: '요약 리포트를 <code>fd-leak-fix.md</code> 로 남겨뒀습니다. PR 올릴까요?' },
    ],
    suggestions: ['PR #7763 열기', 'open_fds 패널 추가', 'compact 라이터에도 적용'],
  },
];

const THREAD_NICK = [
  { id: 'g1', role: 'user', source: 'slack', ts: '13:48',
    blocks: [{ t: 'p', html: 'scheduler 라운드 지터가 왜 이렇게 튀어? 원인 찾아줘.' }] },
  { id: 'g2', role: 'assistant', source: 'dashboard', ts: '13:49', verified: true,
    trace: [
      { kind: 'think', text: '지터가 어디서 튰는지 trace 윈도우부터 본다.' },
      { kind: 'tool', name: 'tool_execute', status: 'ok', dur: '1.1s',
        args: { cmd: 'tail -n 200 logs/core-scheduler.jsonl | jq .round_jitter_ms' },
        result: '{ p50: 12, p95: 380, p99: 1240, spikes: 7 }' },
      { kind: 'reason', text: '스파이크가 compact() 직후에 몰려 있다 — lock 재진입 의심.',
        detail: 'p99가 <strong>1240ms</strong>까지 가는데 스파이크가 전부 <code>compact()</code> 호출 200ms 내에 몰려 있다. <code>round.ml</code> 의 최근 변경과 시점이 겹치므로 git blame 으로 책임 커밋을 확인한다.' },
      { kind: 'tool', name: 'tool_execute', status: 'ok', dur: '0.6s',
        args: { cmd: 'git blame -L 88,140 lib/scheduler/round.ml' },
        result: '{ commit: "c7be26acfb", author: "sangsu", at: "2d ago" }' },
    ],
    blocks: [
      { t: 'p', html: 'p95가 <strong>380ms</strong>까지 튀는 구간이 15분 동안 7번 있었어요. 전부 <code>round.ml</code> 의 lock 재진입 경로와 겹칩니다.' },
      { t: 'ul', items: [
        'p50 <strong>12ms</strong> → p99 <strong>1240ms</strong> 으로 꼬리가 매우 김',
        '스파이크는 <code>compact()</code> 호출 직후 200ms 내에 발생',
        '2일 전 커밋 <code>c7be26acfb</code> 이후로 빈도 증가',
      ] },
      { t: 'p', html: 'lock을 잡은 채 <code>compact()</code>를 호출하는 게 의심됩니다. 핸드오프로 <code>sangsu</code> 에게 패치를 넘길까요?' },
    ],
    suggestions: ['c7be26acfb diff 보기', 'sangsu 에게 핸드오프', 'compact() 호출부 격리 제안'] },
  // ── multimodal: 이미지 첨부 (Grafana 패널 캡처) ──
  { id: 'g3', role: 'user', source: 'slack', ts: '13:51',
    blocks: [
      { t: 'p', html: 'Grafana 패널 캡처 떠왔어. 이 스파이크 구간 직접 읽어서 우리 trace 수치랑 맞는지 봐줘.' },
      { t: 'attach', kind: 'image', name: 'grafana-scheduler-p99.png', dims: '1180×420', size: '184 KB', via: 'Slack 업로드',
        svg: '<svg viewBox="0 0 480 200" width="480" height="200" xmlns="http://www.w3.org/2000/svg" font-family="JetBrains Mono, monospace"><rect x="0" y="0" width="480" height="200" fill="#0a0b0f"/><rect x="0" y="0" width="480" height="28" fill="#11120f"/><text x="14" y="18" font-size="10" fill="#b7a98f">core/scheduler · round_jitter_ms</text><g font-size="9"><rect x="372" y="9" width="8" height="8" fill="#d4793f"/><text x="384" y="16" fill="#c9bca6">p99</text><rect x="420" y="9" width="8" height="8" fill="#5f7585"/><text x="432" y="16" fill="#c9bca6">p50</text></g><g stroke="#22201d" stroke-width="1"><line x1="50" y1="48" x2="460" y2="48"/><line x1="50" y1="87" x2="460" y2="87"/><line x1="50" y1="126" x2="460" y2="126"/><line x1="50" y1="165" x2="460" y2="165"/></g><g font-size="8" fill="#6a5d4d" text-anchor="end"><text x="44" y="51">1200</text><text x="44" y="90">800</text><text x="44" y="129">400</text><text x="44" y="168">0</text></g><rect x="284" y="40" width="20" height="125" fill="#d4793f" opacity="0.12"/><line x1="294" y1="40" x2="294" y2="165" stroke="#d4793f" stroke-width="1" stroke-dasharray="3 3" opacity="0.6"/><text x="298" y="54" font-size="8" fill="#d4793f">compact()</text><polyline fill="none" stroke="#5f7585" stroke-width="1.5" points="50,163.8 77,163.8 104,163.8 131,163.8 158,163.8 185,163.2 212,163.8 239,163.8 266,163.8 294,162.9 320,163.8 347,163.8 374,163.4 401,163.8 428,163.8 455,163.8"/><polyline fill="none" stroke="#d4793f" stroke-width="1.6" points="50,163.5 77,163.1 104,163.9 131,162.6 158,163.4 185,128.0 212,162.2 239,163.0 266,162.5 294,44.3 320,160.9 347,162.0 374,121.5 401,162.6 428,163.1 455,162.4"/><circle cx="294" cy="44.3" r="2.8" fill="#d4793f"/><text x="290" y="40" font-size="8" fill="#d4793f" text-anchor="end">1.24s</text><circle cx="185" cy="128.0" r="2.4" fill="#d4793f"/><text x="200" y="190" font-size="8" fill="#6a5d4d" text-anchor="middle">13:36 — 13:51 · deepseek.deepseek-v4-pro</text></svg>' },
    ] },
  { id: 'g4', role: 'assistant', source: 'dashboard', ts: '13:52', verified: true,
    trace: [
      { kind: 'think', text: '첨부 이미지부터 비전으로 읽어서 축·피크를 수치화한다.' },
      { kind: 'reason', text: '첨부된 Grafana 캡처를 (멀티모달 입력) 그대로 읽어 축·피크를 수치화한다.',
        detail: '이미지는 도구 호출이 아니라 턴 입력으로 모델에 직접 들어온다(supports-image-input). 차트에서 두 피크 <strong>380ms / 1240ms</strong>, 피크 시각 <strong>13:42 · 13:48</strong>, p50 ~12ms(평탄)을 읽었다.' },
      { kind: 'reason', text: '이미지에서 읽은 피크가 trace 윈도우 수치와 일치 — 같은 사건이다.',
        detail: '비전으로 읽은 두 피크 <strong>380ms / 1240ms</strong> 와 <code>compact()</code> 마커 위치(13:48)가 앞서 <code>tool_execute</code> 로 본 round_jitter <code>{ p95: 380, p99: 1240 }</code> 및 스파이크 7건과 정확히 겹친다. 캡처는 trace 와 동일 사건을 외부 패널에서 본 것일 뿐, 새 정보는 아니다.' },
    ],
    blocks: [
      { t: 'p', html: '이미지에서 읽은 값입니다 — 우리 trace 수치와 <strong>정확히 일치</strong>해요. 같은 사건을 Grafana 쪽에서 본 거예요.' },
      { t: 'ul', items: [
        'p99 피크 <strong>1.24s</strong> @ 13:48 — <code>compact()</code> 마커와 같은 지점',
        '중간 피크 <strong>380ms</strong> @ 13:42, p50 는 <strong>~12ms</strong> 로 평탄',
        '패널 윈도우(13:36–13:51)가 trace 윈도우와 동일 → 중복 신호',
      ] },
      { t: 'p', html: '캡처가 외부 근거를 한 겹 더해줄 뿐 원인 판단은 그대로입니다 — lock 보유 중 <code>compact()</code> 호출. 핸드오프 진행할까요?' },
    ],
    suggestions: ['읽은 수치 trace 에 핀 고정', 'sangsu 에게 핸드오프', '패널 링크 T-3880 에 첨부'] },
  // ── multimodal: 음성 메모 (iMessage, 이동 중 operator) ──
  { id: 'g5', role: 'user', source: 'imessage', who: '@operator', ts: '13:54',
    blocks: [
      { t: 'voice', secs: 14, size: '47 KB', via: 'iMessage 음성 메모',
        wave: [0.3, 0.55, 0.8, 0.45, 0.7, 0.92, 0.4, 0.6, 0.85, 0.5, 0.3, 0.72, 0.95, 0.6, 0.4, 0.82, 0.5, 0.68, 0.6, 0.34, 0.55, 0.8, 0.45, 0.62, 0.3, 0.7, 0.5, 0.88, 0.42, 0.6],
        transcript: '닉, 방금 그 1.2초 스파이크 말인데 — compact 도는 타이밍이랑 겹치는 거 확실하면 바로 sangsu한테 핸드오프 걸어. 나 이동 중이라 음성으로 남긴다.' },
    ] },
  { id: 'g6', role: 'assistant', source: 'dashboard', ts: '13:54', verified: true,
    trace: [
      { kind: 'tool', name: 'keeper_voice_listen', status: 'ok', dur: '0.8s',
        args: { audio: 'voice-memo-1354.m4a', secs: 14, lang: 'ko' },
        result: '{ conf: 0.96, intent: "conditional_handoff", target: "sangsu", cond: "compact 타이밍 겹침" }' },
      { kind: 'think', text: '음성 지시 = 조건부 핸드오프. 조건(타이밍 겹침)은 trace·이미지로 이미 확정됨 → 바로 실행.' },
    ],
    blocks: [
      { t: 'p', html: '음성 메모 받아 처리했습니다 (신뢰도 0.96). 조건 “compact 타이밍 겹침”은 trace·캡처로 이미 확정돼서, 바로 핸드오프 걸었어요.' },
      { t: 'callout', html: '<strong>핸드오프 실행</strong> — <code>T-3902</code> compact lock 재진입 수정을 <code>sangsu</code> 에게 인계. 근거(trace 윈도우 + Grafana 캡처 + 음성 지시)를 컨텍스트로 함께 전달했습니다.' },
    ],
    suggestions: ['핸드오프 상태 보기', 'core/scheduler 에 브로드캐스트', '음성 원본 다시 듣기'] },
  // ── keeper-to-keeper 브로드캐스트 ──
  { id: 'g7', role: 'assistant', source: 'dashboard', ts: '13:55',
    blocks: [
      { t: 'p', html: '핸드오프 사실을 <code>core/scheduler</code> 네임스페이스 keeper 들에게 브로드캐스트했습니다.' },
      { t: 'broadcast', scope: 'core/scheduler', via: 'discord-gate · #core-scheduler', audience: 'speech',
        note: 'round lock 재진입 확인 — compact() 호출 경로 격리(T-3902) 전까지 신규 라운드 튜닝 보류. 패치 소유: sangsu. 근거 trace·캡처는 T-3880 에 연결.',
        recipients: [
          { id: 'sangsu', ack: 'acked', at: '13:55' },
          { id: 'rama', ack: 'read', at: '13:56' },
          { id: 'reviewer', ack: 'delivered' },
        ] },
    ],
    suggestions: ['브로드캐스트 audit 보기', 'rama 응답 기다리기', 'T-3880 에 근거 첨부'] },
  // ── out-of-band Fusion 심의 결론이 chat lane 에 도착 (RFC-0252 §8.1) ──
  { id: 'g8', role: 'assistant', source: 'dashboard', ts: '14:18', verified: true,
    blocks: [
      { t: 'p', html: '핸드오프 방향이 맞는지 고위험 결정으로 보고 <code>masc_fusion</code> 을 돌렸습니다. 패널 3개 + 심판 종합 결론이 도착했어요 — 전체 패널·심판은 보드로 빠졌습니다.' },
      { t: 'fusion', run_id: 'fus-7f3a91', decision: 'Answer', panel: 3,
        resolved: '방향 A(unlock 후 compact)를 채택하되 두 가드를 추가: ① compact 진입 시 round epoch 캡처+종료 시 재검증(TOCTOU 차단), ② shadow 버퍼 atomic swap(롤백 안전). 더블 체크 락(C)은 기각. 머지 전 동시 compact 회귀 테스트 추가.' },
    ],
    suggestions: ['보드에서 패널 답변 비교', 'sangsu 에게 가드 2개 전달', '회귀 테스트 케이스 초안'] },
];

const THREADS = { 'masc-improver': THREAD_IMPROVER, 'nick0cave': THREAD_NICK };

const DEFAULT_SUGGESTIONS = ['지금 맡은 태스크 요약해줘', '최근 실패한 trace 보여줘', '다음 액션 추천'];

function nowHM() {
  const d = new Date();
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

const CANNED_REPLY = (keeper) => ({
  id: 'r' + Math.random().toString(36).slice(2, 7),
  role: 'assistant', source: 'dashboard', ts: nowHM(),
  trace: [
    { kind: 'think', text: `${keeper.basepath} 부터 볼까.` },
    { kind: 'tool', name: 'tool_execute', status: 'ok', dur: '0.9s',
      args: { cmd: `grep ${keeper.id} logs/keeper.jsonl | tail -30` },
      result: '{ traces: 3, related: true }' },
  ],
  blocks: [
    { t: 'p', html: `확인했습니다. <code>${keeper.basepath}</code> 에서 관련 trace를 모아 정리하고 있어요.` },
    { t: 'ul', items: ['관련 trace <strong>3건</strong> 수집 완료', '소유 태스크와의 연관성 점검 중'] },
    { t: 'p', html: '잠시 후 상세 결과를 올릴게요. 먼저 보고 싶은 게 있으면 골라주세요.' },
  ],
  suggestions: ['상세 trace 펼치기', '관련 태스크로 이동', '요약만 빠르게'],
});

const RECENT_TOOLS = [
  { name: 'keeper_board_search', dur: '0.4s', ago: '2m', status: 'ok',
    args: { q: 'center_type 명당 계 세그먼트', scope: 'retention' },
    result: '{ hits: 4, segments: ["teacher","admin","daycare","kindergarten"] }' },
  { name: 'tool_read_file', dur: '0.3s', ago: '6m', status: 'ok',
    args: { path: 'lib/search/index.ml', lines: '120-160' },
    result: '{ ok: true, center_type: "enum(4)", indexed: false }' },
  { name: 'keeper_memory_search', dur: '1.1s', ago: '11m', status: 'ok',
    args: { q: 'retention 색인 실패 이력', ns: 'search/index' },
    result: '{ episodes: 3, related: true }' },
];

const OWNED_TASKS = {
  'masc-improver': [
    { id: 'T-4412', title: '세그먼트 리텐션 대시보드', state: 'in-progress' },
    { id: 'T-4418', title: 'center_type 값 정규화', state: 'blocked' },
  ],
  'nick0cave': [
    { id: 'T-3901', title: 'round jitter 회귀 추적', state: 'in-progress' },
    { id: 'T-3902', title: 'compact lock 재진입 수정', state: 'review' },
    { id: 'T-3880', title: 'scheduler p99 SLO', state: 'in-progress' },
    { id: 'T-3855', title: 'telemetry 샘플링 조정', state: 'in-progress' },
  ],
};

const PERSONAS = {
  'masc-improver': { persona: 'OCaml·Eio에 능하고, 리소스 수명(Switch)과 fiber 취소를 꼼꼼히 따진다.', instructions: 'lib/trace-store 모듈을 담당한다. Eio Switch/fiber 수명, fd·메모리 누수를 우선 점검하고, 수정은 작은 diff로 제시하며 회귀 테스트를 함께 올린다.', traits: ['정확함', 'OCaml/Eio', '리소스안전'] },
  'nick0cave': { persona: '집요하고 직설적. 루트 코즈를 잡을 때까지 파고든다.', instructions: 'core/scheduler 회귀를 추적한다. p99 꼬리와 lock 재진입을 우선한다. 가설은 trace로 검증하고 git blame으로 책임 커밋을 특정한다.', traits: ['집요함', '직설적', '근본추적'] },
  'sangsu': { persona: '차분하고 협업적. 인계와 문서화를 중시한다.', instructions: 'core/runtime 안정성을 담당한다. 변경은 작게 쪼개고, 핸드오프 시 컨텍스트를 충분히 남긴다.', traits: ['협업적', '안정지향', '문서화'] },
  'qa-king': { persona: '꼼꼼하고 회의적. 통과 기준을 엄격히 적용한다.', instructions: 'docs/site 품질을 검증한다. 회귀 테스트를 우선하고, 불확실하면 통과시키지 않는다.', traits: ['꼼꼼함', '회의적', '엄격함'] },
  'rama': { persona: '신중하고 보수적. 위험한 변경은 operator 승인을 구한다.', instructions: 'core/scheduler 보조. 위험 작업은 항상 승인을 요청한다.', traits: ['보수적', '안전우선'] },
  'analyst': { persona: '탐색적이고 폭넓게 본다. 패턴을 먼저 잡는다.', instructions: 'search/index를 담당한다. 색인 실패를 빠르게 격리하고 재색인 전략을 제시한다.', traits: ['탐색적', '패턴인식'] },
  'drifter': { persona: '실험적이고 빠르다. 단, 컨텍스트 관리가 약하다.', instructions: 'core/runtime 실험. 컨텍스트 사용을 자주 점검하고 임계치 전 compact한다.', traits: ['실험적', '빠름'] },
};
const DEFAULT_PERSONA = { persona: '기본 keeper 성격. 작업에 충실하고 trace를 남긴다.', instructions: '담당 namespace의 작업을 수행하고 모든 행동을 trace로 기록한다.', traits: ['기본'] };

// Goal store — core.ts Goal{horizon,priority(num),status,phase,parent_goal_id,
//   require_completion_approval,verifier_policy} → Task{status(6-state),assignee,
//   goal_id,contract,gate,handoff_context}. Task.status ∈ todo|claimed|in_progress|
//   awaiting_verification|done|cancelled. todo + no assignee = claimable backlog.
const GOAL_STATUS = {
  active:   { lbl: '진행', cls: 'ok' },
  at_risk:  { lbl: '위험', cls: 'warn' },
  blocked:  { lbl: '막힘', cls: 'bad' },
  verifying:{ lbl: '검증', cls: 'volt' },
};
const TASK_STATUS = {
  todo:                 { lbl: '대기',     cls: 'todo' },
  claimed:              { lbl: '클레임',   cls: 'claimed' },
  in_progress:          { lbl: '진행 중',  cls: 'wip' },
  awaiting_verification:{ lbl: '검증 대기', cls: 'verify' },
  done:                 { lbl: '완료',     cls: 'done' },
  cancelled:            { lbl: '취소',     cls: 'cancelled' },
};
const GATE_OUTCOME = { satisfied: '충족', missing: '누락', failed: '실패', unsupported: '미지원' };

const GOALS = [
  {
    id: 'goal-scheduler-p99-slo', horizon: 'short', title: 'scheduler p99 SLO 400ms 회복', ns: 'core/scheduler', lead: 'nick0cave',
    priority: 9, status: 'active', phase: 'executing', metric: 'p99 1.24s → 400ms', target: '< 400ms', due_date: 'D-3',
    note: '금주 최우선 — 신규 기능 보류. 관련 trace 는 전부 task-3880 에 연결.',
    tasks: [
      { id: 'task-3880', title: 'p99 꼬리 원인 추적', assignee: 'nick0cave', status: 'in_progress', priority: 9,
        lineage: [
          { at: '09:40', actor: 'nick0cave', ev: 'created', note: 'p99 회복 목표에서 분기' },
          { at: '09:41', actor: 'nick0cave', ev: 'claimed' },
          { at: '09:44', actor: 'nick0cave', ev: 'started' },
        ] },
      { id: 'task-3901', title: 'round jitter 회귀 추적', assignee: 'nick0cave', status: 'in_progress', priority: 8 },
      { id: 'task-3902', title: 'compact lock 재진입 수정', assignee: 'sangsu', status: 'awaiting_verification', priority: 9,
        lineage: [
          { at: '11:20', actor: 'nick0cave', ev: 'created', note: 'p99 회복 목표에서 분기' },
          { at: '11:24', actor: 'nick0cave', ev: 'handoff', to: 'sangsu', note: 'compact 경로 소유 — round lock 재진입 패치 인계' },
          { at: '11:26', actor: 'sangsu', ev: 'claimed' },
          { at: '11:31', actor: 'sangsu', ev: 'started' },
          { at: '13:48', actor: 'sangsu', ev: 'submitted', note: 'open_fds·스위트 통과 · p99 측정 남음' },
        ],
        gate: [
          { evidence: 'open_fds 회귀 (41 유지)', outcome: 'satisfied' },
          { evidence: 'scheduler 스위트 84/84', outcome: 'satisfied' },
          { evidence: 'p99 측정 < 400ms', outcome: 'missing' },
          { evidence: '동시 compact 회귀 테스트', outcome: 'missing' },
        ] },
      { id: 'task-3855', title: 'telemetry 샘플링 조정', assignee: null, status: 'todo', priority: 5 },
    ],
  },
  {
    id: 'goal-retention-pipeline', horizon: 'mid', title: 'D0–D3 리텐션 분석 파이프라인', ns: 'lib/trace-store', lead: 'masc-improver',
    priority: 6, status: 'at_risk', phase: 'executing', metric: 'center_type 정규화 + 백필', target: '미정값 0', due_date: 'D-9',
    note: 'gp:center_type 분류 미정값 다수 — 정규화가 대시보드의 선행 조건.',
    tasks: [
      { id: 'task-4412', title: '세그먼트 리텐션 대시보드', assignee: 'masc-improver', status: 'in_progress', priority: 6 },
      { id: 'task-4418', title: 'center_type 값 정규화', assignee: 'analyst', status: 'in_progress', priority: 7,
        lineage: [
          { at: '10:10', actor: 'masc-improver', ev: 'created' },
          { at: '10:12', actor: 'masc-improver', ev: 'handoff', to: 'analyst', note: '데이터 정규화 — analyst 소유' },
          { at: '10:15', actor: 'analyst', ev: 'claimed' },
          { at: '10:20', actor: 'analyst', ev: 'started' },
          { at: '13:30', actor: 'analyst', ev: 'blocked', note: '재색인 권한 승인 대기 (H-040)' },
        ],
        blocker: 'search/index 색인 실패 1건 — 재색인 권한 승인 대기 (H-040)' },
      { id: 'task-4401', title: 'D0 정의 합의 (가입일·첫 세션 기준)', assignee: 'masc-improver', status: 'done', priority: 4,
        lineage: [
          { at: '08:50', actor: 'masc-improver', ev: 'created' },
          { at: '08:51', actor: 'masc-improver', ev: 'claimed' },
          { at: '10:05', actor: 'masc-improver', ev: 'done', note: 'D0 = 가입일 기준 합의' },
        ] },
    ],
  },
  {
    id: 'goal-trace-writer-fd-leak', horizon: 'short', title: 'trace writer fd 누수 제거', ns: 'lib/trace-store', lead: 'masc-improver',
    priority: 5, status: 'verifying', phase: 'verifying', metric: 'open_fds 41→41 · 0 leaked', target: '0 leaked',
    require_completion_approval: true, verifier: ['operator', 'reviewer'],
    note: 'Switch.run 으로 writer 수명 격리 — 패치·회귀 통과. 완료 승인(operator+reviewer) 후 종료.',
    tasks: [
      { id: 'task-7711', title: 'writer 수명 Switch.run 격리', assignee: 'masc-improver', status: 'done', priority: 5 },
      { id: 'task-7712', title: 'open_fds 불변 회귀 테스트', assignee: 'masc-improver', status: 'done', priority: 5 },
      { id: 'task-7713', title: '호출부 3곳 정리', assignee: 'sangsu', status: 'in_progress', priority: 4,
        lineage: [
          { at: '12:40', actor: 'masc-improver', ev: 'created' },
          { at: '12:44', actor: 'masc-improver', ev: 'handoff', to: 'sangsu', note: 'writer 호출부 정리 인계 — 비가역, 결재 대기' },
          { at: '12:46', actor: 'sangsu', ev: 'claimed' },
          { at: '12:50', actor: 'sangsu', ev: 'started' },
        ],
        handoff: { summary: 'writer.ml 호출부 3곳 덮어쓰기 — 비가역, H-041 결재 대기', next_step: 'operator 승인 후 머지', failure_mode: null } },
      { id: 'task-7763', title: 'PR #7763 리뷰·머지', assignee: 'reviewer', status: 'awaiting_verification', priority: 4,
        lineage: [
          { at: '13:10', actor: 'masc-improver', ev: 'created' },
          { at: '13:12', actor: 'reviewer', ev: 'claimed' },
          { at: '13:40', actor: 'reviewer', ev: 'submitted', note: 'CI green · operator 완료 승인 대기' },
        ],
        gate: [
          { evidence: 'PR #7763 리뷰 승인', outcome: 'satisfied' },
          { evidence: 'CI green', outcome: 'satisfied' },
          { evidence: 'operator 완료 승인', outcome: 'missing' },
        ] },
    ],
  },
  {
    id: 'goal-docs-site-revamp', horizon: 'long', title: 'docs/site 개편', ns: 'docs/site', lead: 'qa-king',
    priority: 2, status: 'active', phase: 'planning', metric: null, target: null, due_date: 'D-21',
    note: '핸드오프 인계 대기 — 우선순위 낮음. 미배정 task 는 백로그에서 claim 가능.',
    tasks: [
      { id: 'task-8101', title: '컴포넌트 문서 재작성', assignee: 'qa-king', status: 'in_progress', priority: 2 },
      { id: 'task-8102', title: '예제 코드 검증', assignee: null, status: 'todo', priority: 2 },
      { id: 'task-8103', title: '레거시 가이드 아카이브', assignee: null, status: 'cancelled', priority: 1 },
    ],
  },
];

// keeper_id → compaction snapshot history (before → after the Compacting state ran)
const COMPACTIONS = {
  'nick0cave': [
    {
      id: 'cmp_7f3a', at: '14:01', trigger: 'provider overflow — Compaction_started', runtime: 'deepseek.deepseek-v4-pro',
      before: { tok: 182400, msgs: 64, traces: 38 },
      after:  { tok: 58200,  msgs: 12, traces: 9  },
      kept: ['소유 태스크 4건 (T-3902 외)', 'core/scheduler 최근 변경 요약', 'compact lock 재진입 가설'],
      summarized: ['14:01 이전 라운드 로그 52개 → 6줄 요약', '완료된 trace 29건 → 통계만 보존'],
      dropped: ['중복 도구 결과 11건', '취소된 분기 탐색 로그'],
    },
    {
      id: 'cmp_6b12', at: '11:48', trigger: '수동 — operator 요청', runtime: 'deepseek.deepseek-v4-pro',
      before: { tok: 156000, msgs: 51, traces: 30 },
      after:  { tok: 47800,  msgs: 10, traces: 7  },
      kept: ['활성 가설 2건', '핀 고정 메모'],
      summarized: ['초기 탐색 단계 → 3줄'],
      dropped: ['실패한 빌드 로그 8건'],
    },
  ],
  'masc-improver': [
    {
      id: 'cmp_3d90', at: '13:30', trigger: 'provider overflow — Compaction_started', runtime: 'ollama_cloud.deepseek-v4-flash',
      before: { tok: 172000, msgs: 48, traces: 27 },
      after:  { tok: 61400,  msgs: 11, traces: 8  },
      kept: ['리텐션 정의 (D0=가입일)', 'center_type 분류 미정값 메모'],
      summarized: ['amplitude 쿼리 결과 14건 → 표 1개'],
      dropped: ['중복 세그먼트 응답 6건'],
    },
    {
      id: 'cmp_2c55', at: '10:12', trigger: 'operator 수동 — 지금 컴팩트', runtime: 'ollama_cloud.deepseek-v4-flash',
      before: { tok: 168200, msgs: 44, traces: 22 },
      after:  { tok: 55900,  msgs: 9,  traces: 6  },
      kept: ['활성 코호트 정의', '대시보드 스펙 메모'],
      summarized: ['세그먼트 탐색 로그 31건 → 4줄'],
      dropped: ['만료된 쿼리 캐시 9건'],
    },
    {
      id: 'cmp_1a08', at: '08:47', trigger: '수동 — operator 요청', runtime: 'ollama.gemma4-26b-a4b-qat',
      before: { tok: 142000, msgs: 38, traces: 18 },
      after:  { tok: 49100,  msgs: 8,  traces: 5  },
      kept: ['초기 가설 메모'],
      summarized: ['온보딩 컨텍스트 → 2줄'],
      dropped: ['중복 로그 5건'],
    },
  ],
};

const ATTENTION = {
  'nick0cave': [
    { sev: 'warn', text: 'provider overflow — Compacting 진행 중' },
    { sev: 'warn', text: 'T-3902 compact lock 재진입 — 검토 대기' },
  ],
  'qa-king': [
    { sev: 'warn', text: 'HandingOff 8분째 — 인계 응답 대기' },
  ],
  'analyst': [
    { sev: 'warn', text: '일시정지 34분째 — 재개 보류 중' },
    { sev: 'warn', text: '컨텍스트 80% — 재개 시 압축 가능성' },
    { sev: 'bad',  text: 'search/index 색인 실패 1건' },
  ],
  'drifter': [
    { sev: 'bad',  text: 'Overflowed — 컨텍스트 초과로 세션 중단' },
    { sev: 'bad',  text: '컨텍스트 100% — 수동 재시작 필요' },
    { sev: 'bad',  text: '최근 trace 5건 연속 실패' },
    { sev: 'warn', text: 'core/runtime 워치독 응답 없음' },
    { sev: 'warn', text: '소유 태스크 1건 정체 (3시간+)' },
  ],
};

// Shared keeper prompt base — inherited by every keeper. persona·instructions stack on top.
// {{keeper}} {{namespace}} {{runtime}} {{model}} are substituted per keeper.
const KEEPER_BASE = {
  system:
`당신은 MASC 코디네이션 서버의 keeper "{{keeper}}" 입니다.
namespace       : {{namespace}}
runtime · model : {{runtime}} · {{model}}

원칙
- 모든 작업은 trace 로 기록한다.
- 컨텍스트 사용량이 85% 를 넘으면 compact() 를 호출한다.
- 소유하지 않은 태스크는 핸드오프(HandingOff)로 넘긴다.
- 답변은 근거(도구 결과·trace)를 함께 제시한다.`,
  world:
`# MASC — 주머니 속 작은 세상
여러 keeper가 하나의 레포를 향해 영속적으로 공존한다.
각자 다른 성격·프롬프트로 선택하고, 실패하고, 성공하며, 자기 길을 즉흥한다.

규칙
- keeper는 자신의 namespace(조정 범위) 안에서만 task를 소유한다.
- 다른 keeper의 worktree·소유 태스크를 침범하지 않는다.
- 공유가 필요한 결정은 board 브로드캐스트로 알린다.
- operator는 이 세상을 관조한다 — 명령은 최소, 관찰이 기본.`,
};

// Gate 큐 — keeper 가 외부 효과(external effect) 호출 시 Gate 가 HITL 처분으로 보낸 항목.
// HITL 은 nonblocking: 요청을 그대로 영속하고 결정이 오면 그 keeper 레인만 깨운다.
// kind: 행동 종류 · opened: 큐에 머문 초 · req: keeper가 청한 한 줄. (위험 등급 sev 는 소스에서 제거됨)
const APPROVAL_KIND = {
  'tool-grant':     { lbl: '도구 권한',   glyph: '\u26BF' },  // ⚿
  'destructive-fs': { lbl: '파괴적 쓰기', glyph: '\u26A0' },  // ⚠
  'handoff':        { lbl: '핸드오프',    glyph: '\u21C4' },  // ⇄
  'spend':          { lbl: '예산',        glyph: '\u25F7' },  // ◷
  'model-switch':   { lbl: '모델 교체',   glyph: '\u27F3' },  // ⟳
  'restart':        { lbl: '재시작',      glyph: '\u21BB' },  // ↻
};
// masc_* 도구 카탈로그 — 서버가 /mcp 로 노출하는 도구(operator 설정 · MCP)와 동일 집합.
// risk: read(읽기 전용) · write(쓰기) · lifecycle(keeper 수명 조작) — risky 호출은 승인 정책에 따라 HILT 큐로 간다.
// 도구 카탈로그 — tool_policy.toml 의 실제 도구. 서버가 /mcp 로 노출하는 masc_* · keeper 로컬 keeper_*/tool_*.
// risk: read(읽기 전용) · write(쓰기) · lifecycle(FSM 전이) — risky 호출은 정책에 따라 HILT 큐로 간다.
const MASC_TOOLS = [
  { id: 'masc_status',          risk: 'read',      ro: true,  desc: 'namespace·keeper 상태 조회' },
  { id: 'masc_web_search',      risk: 'read',      ro: true,  desc: '웹 검색' },
  { id: 'keeper_context_status', risk: 'read',     ro: true,  desc: '컨텍스트 윈도우 사용량' },
  { id: 'keeper_memory_search', risk: 'read',      ro: true,  desc: '장기 메모리 검색' },
  { id: 'keeper_board_search',  risk: 'read',      ro: true,  desc: '보드 검색' },
  { id: 'tool_read_file',       risk: 'read',      ro: true,  desc: '파일 읽기' },
  { id: 'masc_tasks',           risk: 'read',      ro: true,  desc: '태스크 목록 조회' },
  { id: 'keeper_board_post',    risk: 'write',     ro: false, desc: '보드 글 작성' },
  { id: 'masc_broadcast',       risk: 'write',     ro: false, desc: '브로드캐스트 발신' },
  { id: 'tool_edit_file',       risk: 'write',     ro: false, desc: '파일 편집' },
  { id: 'tool_write_file',      risk: 'write',     ro: false, desc: '파일 쓰기' },
  { id: 'tool_execute',         risk: 'write',     ro: false, desc: 'typed argv 실행 — 3계층 가드' },
  { id: 'masc_add_task',        risk: 'write',     ro: false, desc: '태스크 생성' },
  { id: 'masc_transition',      risk: 'lifecycle', ro: false, desc: 'FSM 전이 — claim·done·handoff·drain' },
  { id: 'masc_goal_verify',     risk: 'lifecycle', ro: false, desc: '목표 검증 전이' },
];
const TOOL_RISK = Object.fromEntries(MASC_TOOLS.map(t => [t.id, t.risk]));

// keeper_id → 권한·범위. fs: none(읽기 전용) · worktree(자기 워크트리) · namespace(소유 ns 전체)
//  git: 원격 push/merge · net: 외부 호출(Slack·Discord 발신) · tools: 호출 가능한 masc_* id 집합.
// 서버 노출(설정·MCP)과 keeper별 호출 권한은 다른 계층 — 둘 다 켜져야 호출된다.
const KEEPER_GRANTS = {
  'masc-improver': { fs: 'worktree',  git: false, net: false, tools: ['masc_status', 'keeper_context_status', 'tool_read_file', 'tool_edit_file', 'keeper_board_post', 'masc_transition'] },
  'nick0cave':     { fs: 'namespace', git: true,  net: false, tools: ['masc_status', 'tool_read_file', 'tool_edit_file', 'tool_write_file', 'tool_execute', 'masc_transition', 'masc_broadcast'] },
  'sangsu':        { fs: 'worktree',  git: true,  net: false, tools: ['masc_status', 'tool_read_file', 'tool_edit_file', 'tool_execute', 'masc_transition'] },
  'qa-king':       { fs: 'worktree',  git: false, net: false, tools: ['masc_tasks', 'masc_transition', 'keeper_board_post', 'tool_read_file', 'masc_broadcast'] },
  'analyst':       { fs: 'namespace', git: false, net: false, tools: ['masc_status', 'masc_web_search', 'keeper_memory_search', 'keeper_board_search', 'tool_read_file'] },
  'scholar':       { fs: 'worktree',  git: false, net: true,  tools: ['masc_web_search', 'keeper_board_post', 'tool_read_file'] },
  'herald':        { fs: 'none',      git: false, net: true,  tools: ['masc_status', 'keeper_board_post', 'masc_broadcast'] },
};
const DEFAULT_GRANT = { fs: 'worktree', git: false, net: false, tools: ['masc_status', 'keeper_context_status', 'tool_read_file', 'masc_tasks'] };
function keeperGrant(id) {
  const g = KEEPER_GRANTS[id] || DEFAULT_GRANT;
  return { ...g, tools: [...g.tools] };
}

const APPROVALS = [
  { id: 'H-041', kind: 'destructive-fs', keeper: 'sangsu', goal: 'G-03', job: 'J-13', opened: 96, origin: 'dashboard',
    title: 'tool_write_file · lib/trace/writer.ml 호출부 3곳 덮어쓰기',
    detail: 'Switch.run 격리 패치 적용 — 312 bytes overwrite, 머지 전 되돌리기 필요. 영향: writer 호출 경로 전체.',
    req: '회귀(open_fds 41 유지) 통과했고, 호출부 정리만 남았습니다. 덮어써도 될까요?',
    tool: 'tool_write_file' },
  { id: 'H-040', kind: 'tool-grant', keeper: 'analyst', goal: 'G-02', job: 'T-4418', opened: 184, origin: 'dashboard',
    title: 'search/index 재색인 — tool_execute 쓰기 권한',
    detail: 'center_type 백필을 위해 색인 전체 재생성(쓰기). 색인 락 ~6분 점유 · 그동안 검색 저하.',
    req: 'center_type 정규화가 색인 실패로 막혀 있습니다. 재색인 권한을 주시면 백필까지 한 번에 끝냅니다.',
    tool: 'tool_execute' },
  { id: 'H-039', kind: 'handoff', keeper: 'qa-king', goal: 'G-04', job: null, opened: 503, origin: 'discord',
    title: '핸드오프 · qa-king \u2192 sangsu',
    detail: 'docs/site 소유 태스크 1건 인계 — 8분째 인계 응답 대기. 승인 시 sangsu 가 즉시 이어받음.',
    req: 'docs/site 우선순위가 낮아 sangsu 에게 넘기려 합니다. 인계 승인 부탁드립니다.',
    tool: 'masc_transition' },
  { id: 'H-038', kind: 'spend', keeper: 'nick0cave', goal: 'G-01', job: 'T-3880', opened: 47, origin: 'slack',
    title: '예산 초과 · deepseek-v4-pro 추적 라운드 추가',
    detail: 'p99 꼬리 재현에 cross_verifier(deepseek-v4-pro) 라운드 2회 추가 — 시간당 $5.00 라인 초과 예상($5.42 @ 현재 burn).',
    req: 'p99 원인이 거의 잡혔는데 라운드가 더 필요합니다. 예산 라인 초과를 허용해 주세요.',
    tool: 'masc_transition' },
  { id: 'H-037', kind: 'model-switch', keeper: 'rama', goal: 'G-01', job: 'T-3855', opened: 22, origin: 'imessage',
    title: '모델 교체 · deepseek-v4-flash → deepseek-v4-pro',
    detail: 'telemetry 샘플링 설계 — 판단 신뢰도 0.6 미만 3회. 보수적으로 smart lane(Pro) 전환을 청함.',
    req: '샘플링 트레이드오프가 애매해 deepseek-v4-pro 로 한 번 더 검토하고 싶습니다. 보수적 승인 요청합니다.',
    tool: 'masc_transition' },
];

// Gate 결정 이력 (감사 로그) — 이미 처리된 과거 결재. 큐와 달리 영속 기록:
// 누가(decided_by) 언제(at) 무엇을 어떻게(decision) 왜(reason) 결정했고, keeper가 청한 뒤
// 결정까지 얼마나(latency_s) 걸렸는지. decided_by: operator=HITL 수동 · judge=LLM Auto Judge · always=Always Allow 정확일치 규칙.
const APPROVAL_HISTORY = [
  { id: 'H-036', kind: 'destructive-fs', keeper: 'sangsu',       tool: 'tool_write_file', at: '13:52', decided_by: 'operator', decision: 'approved', latency_s: 142, reason: '회귀 open_fds 41 유지 확인 후 승인. writer 호출부 정리 커밋.' },
  { id: 'H-035', kind: 'spend',          keeper: 'nick0cave',    tool: 'masc_transition', at: '13:40', decided_by: 'operator', decision: 'denied',   latency_s: 88,  reason: '시간당 $5 라인 유지. cross_verifier 라운드는 다음 예산 창에서.' },
  { id: 'H-034', kind: 'model-switch',   keeper: 'rama',         tool: 'masc_transition', at: '13:31', decided_by: 'judge',    decision: 'approved', latency_s: 3,   reason: 'LLM Auto Judge — flash→pro 보수적 전환 근거 확인 후 자동 승인.' },
  { id: 'H-033', kind: 'handoff',        keeper: 'qa-king',      tool: 'masc_transition', at: '13:18', decided_by: 'operator', decision: 'approved', latency_s: 311, reason: 'docs/site 우선순위 낮음 — scholar 로 인계 승인.' },
  { id: 'H-032', kind: 'tool-grant',     keeper: 'analyst',      tool: 'tool_execute',    at: '12:57', decided_by: 'operator', decision: 'deferred', latency_s: 64,  reason: '색인 락 6분 점유 — 트래픽 낮은 02:00 예약으로 보류.' },
  { id: 'H-031', kind: 'restart',        keeper: 'drifter',      tool: 'masc_transition', at: '12:44', decided_by: 'operator', decision: 'approved', latency_s: 39,  reason: 'Overflowed → 체크포인트 무결성 확인(sha256) 후 재시작 승인.' },
  { id: 'H-030', kind: 'destructive-fs', keeper: 'nick0cave',    tool: 'tool_write_file', at: '12:20', decided_by: 'operator', decision: 'denied',   latency_s: 205, reason: 'round.ml 직접 덮어쓰기 대신 PR 경유 요구 — 리뷰 없는 덮어쓰기 거부.' },
  { id: 'H-029', kind: 'tool-grant',     keeper: 'masc-improver', tool: 'tool_edit_file', at: '11:58', decided_by: 'always',   decision: 'approved', latency_s: 0,   reason: 'Always Allow — 정확일치 규칙(tool_edit_file · masc-improver worktree) 1회 소비.' },
  { id: 'H-028', kind: 'spend',          keeper: 'scholar',      tool: 'masc_web_search', at: '11:31', decided_by: 'judge',    decision: 'approved', latency_s: 2,   reason: 'LLM Auto Judge — 웹검색 요청 근거 확인 후 자동 승인.' },
  { id: 'H-027', kind: 'handoff',        keeper: 'herald',       tool: 'masc_transition', at: '11:05', decided_by: 'operator', decision: 'approved', latency_s: 127, reason: 'connectors/slack 브릿지 예외 처리 확인 후 인계 승인.' },
];

Object.assign(window, { PHASE_INFO, PHASE_TONE, PHASE_PULSE, phaseStatus, FSM_ACTIONS, KEEPERS, THREADS, DEFAULT_SUGGESTIONS,
  CANNED_REPLY, nowHM, RECENT_TOOLS, OWNED_TASKS, ATTENTION, COMPACTIONS, PERSONAS, DEFAULT_PERSONA, KEEPER_BASE, GOALS,
  GOAL_STATUS, TASK_STATUS, GATE_OUTCOME,
  APPROVALS, APPROVAL_KIND, APPROVAL_HISTORY, MASC_TOOLS, TOOL_RISK, KEEPER_GRANTS, DEFAULT_GRANT, keeperGrant,
});
