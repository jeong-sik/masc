/* MASC v2 — Keeper roster + sample agent conversations.
   Grounded in dashboard/src/types/core.ts (Keeper) and keeper-badge.ts.
   Identity = color slot (1..12) + 2-letter sigil. Portrait is optional flavor. */

const PORTRAIT = (slug) => slug ? `assets/portraits/${slug}.png` : null;

// 12-state keeper machine (canonical MASC nouns)
const FSM_STATES = [
  'Offline', 'Restarting', 'Running', 'Compacting', 'HandingOff',
  'Failing', 'Overflowed', 'Draining', 'Paused', 'Stopped', 'Crashed', 'Dead',
];

// keeper_id → { slot, sigil }, mirrors KEEPER_REGISTRY anchors in keeper-badge.ts
const KEEPERS = [
  { id: 'masc-improver', kr: '미소',   sigil: 'MS', slot: 6,  role: 'analyst', status: 'run',   phase: 'Running',    model: 'claude-sonnet-4', runtime: 'oas·seoul-1', ns: 'kidsnote/retention', att: 0, uptime: '4h 12m', last: '41분', ctx: 0.62, traces: 318, tasks: 2, portrait: 'miso' },
  { id: 'nick0cave',     kr: '닉케이브', sigil: 'NK', slot: 3,  role: 'keeper',  status: 'run',   phase: 'Compacting', model: 'claude-opus-4',   runtime: 'oas·tokyo-2', ns: 'core/scheduler',     att: 2, uptime: '11h 03m', last: '3분',  ctx: 0.91, traces: 540, tasks: 4, portrait: 'grimja' },
  { id: 'sangsu',        kr: '상수',   sigil: 'SS', slot: 9,  role: 'keeper',  status: 'run',   phase: 'Running',    model: 'claude-sonnet-4', runtime: 'local·docker', ns: 'core/runtime',       att: 0, uptime: '2h 47m', last: '방금', ctx: 0.44, traces: 210, tasks: 3, portrait: 'iron' },
  { id: 'qa-king',       kr: 'QA킹',  sigil: 'QA', slot: 2,  role: 'keeper',  status: 'run',   phase: 'HandingOff', model: 'claude-haiku-4',  runtime: 'oas·seoul-1', ns: 'docs/site',          att: 1, uptime: '58m',    last: '8분',  ctx: 0.71, traces: 97,  tasks: 1, portrait: 'luna' },
  { id: 'rama',          kr: '라마',   sigil: 'RM', slot: 11, role: 'keeper',  status: 'pause', phase: 'Paused',     model: 'claude-sonnet-4', runtime: 'oas·tokyo-2', ns: 'core/scheduler',     att: 0, uptime: '22m',    last: '22분', ctx: 0.33, traces: 154, tasks: 2, portrait: 'cedric' },
  { id: 'scholar',       kr: '스콜라', sigil: 'SC', slot: 5,  role: 'keeper',  status: 'pause', phase: 'Draining',   model: 'claude-haiku-4',  runtime: 'local·docker', ns: 'infra/deploy',       att: 0, uptime: '1h 09m', last: '17분', ctx: 0.58, traces: 73,  tasks: 1, portrait: 'dara' },
  { id: 'analyst',       kr: '애널리스트', sigil: 'AN', slot: 7, role: 'keeper', status: 'pause', phase: 'Paused',    model: 'claude-sonnet-4', runtime: 'oas·seoul-1', ns: 'search/index',       att: 3, uptime: '34m',    last: '34분', ctx: 0.80, traces: 289, tasks: 2, portrait: 'brenna' },
  { id: 'reviewer',      kr: '리뷰어', sigil: 'RV', slot: 10, role: 'keeper',  status: 'pause', phase: 'Paused',     model: 'claude-haiku-4',  runtime: 'local·docker', ns: 'observatory',        att: 0, uptime: '51m',    last: '51분', ctx: 0.21, traces: 44,  tasks: 0, portrait: 'moth' },
  { id: 'herald',        kr: '헤럴드', sigil: 'HD', slot: 1,  role: 'keeper',  status: 'off',   phase: 'Stopped',    model: 'claude-haiku-4',  runtime: '—',           ns: 'connectors/slack',   att: 0, uptime: '—',      last: '2시간', ctx: 0.0, traces: 12,  tasks: 0, portrait: null },
  { id: 'drifter',       kr: '드리프터', sigil: 'DF', slot: 12, role: 'keeper', status: 'off',   phase: 'Overflowed', model: 'claude-sonnet-4', runtime: 'oas·tokyo-2', ns: 'core/runtime',       att: 5, uptime: '—',      last: '3시간', ctx: 1.0, traces: 401, tasks: 1, portrait: 'dust' },
  { id: 'marshal',       kr: '마샬',   sigil: 'MA', slot: 4,  role: 'keeper',  status: 'off',   phase: 'Crashed',    model: 'claude-sonnet-4', runtime: '—',           ns: 'infra/deploy',       att: 0, uptime: '—',      last: '5시간', ctx: 0.0, traces: 188, tasks: 0, portrait: null },
  { id: 'revenant',      kr: '레버넌트', sigil: 'RN', slot: 8, role: 'keeper',  status: 'off',   phase: 'Dead',       model: 'claude-sonnet-4', runtime: '—',           ns: 'archive',            att: 0, uptime: '—',      last: '1일',  ctx: 0.0, traces: 920, tasks: 0, portrait: 'songarak' },
];

const THREAD_IMPROVER = [
  {
    id: 'm1', role: 'user', source: 'dashboard', ts: '14:02',
    blocks: [{ t: 'p', html: 'kidsnote 첫 세션 리텐션을 세그먼트별로 쪼개서 보여줘. 원장/교사 차이가 궁금해.' }],
  },
  {
    id: 'm2', role: 'assistant', source: 'dashboard', ts: '14:02', verified: true,
    tools: [
      { name: 'masc_amplitude_query', status: 'ok', dur: '2.4s',
        args: { event: 'session_start', groupBy: 'gp:center_type', window: 'D0–D3' },
        result: '{ rows: 4, segments: ["teacher","admin","daycare","kindergarten"] }' },
    ],
    blocks: [
      { t: 'h4', html: '세그먼트별 첫 세션 리텐션 (D0–D3)' },
      { t: 'table',
        head: ['세그먼트', { v: 'Day 0', num: true }, { v: 'Day 1', num: true }, { v: 'Day 2', num: true }, { v: 'Day 3', num: true }],
        rows: [
          ['교사 (teacher)', { v: '19명', num: true }, { v: '100%', num: true }, { v: '20%', num: true }, { v: '33%', num: true }],
          ['원장 (admin)',   { v: '11명', num: true }, { v: '100%', num: true }, { v: '25%', num: true }, { v: '100%', num: true }],
          ['어린이집 (daycare)',  { v: '0명', num: true, muted: true }, { v: '—', num: true, muted: true }, { v: '—', num: true, muted: true }, { v: '—', num: true, muted: true }],
          ['유치원 (kindergarten)', { v: '0명', num: true, muted: true }, { v: '—', num: true, muted: true }, { v: '—', num: true, muted: true }, { v: '—', num: true, muted: true }],
        ] },
      { t: 'callout', html: '<strong>어린이집·유치원 세그먼트는 데이터 없음</strong> — <code>gp:center_type</code> 값이 <code>daycare / kindergarten</code> 으로 세팅되지 않은 것으로 보입니다. 실제로 어떤 값이 들어오는지 확인이 필요해요.' },
      { t: 'p', html: '교사/원장 리텐션은 샘플이 너무 작아(D2 기준 45명) 통계적으로 의미있는 비교는 아직 어렵습니다. <strong>Prod 배포 후 2~3주</strong> 더 데이터가 쌓이면 패턴이 또렷해질 거예요.' },
    ],
    suggestions: [
      '94503 원의 세션 리플레이를 확인',
      'gp:center_type 의 실제 값 분포 보기',
      '교사·원장 이탈 원인 더 파보기',
    ],
  },
];

const THREAD_NICK = [
  { id: 'g1', role: 'user', source: 'dashboard', ts: '13:48',
    blocks: [{ t: 'p', html: 'scheduler 라운드 지터가 왜 이렇게 튀어? 원인 찾아줘.' }] },
  { id: 'g2', role: 'assistant', source: 'dashboard', ts: '13:49', verified: true,
    tools: [
      { name: 'masc_trace_window', status: 'ok', dur: '1.1s',
        args: { ns: 'core/scheduler', last: '15m', metric: 'round_jitter_ms' },
        result: '{ p50: 12, p95: 380, p99: 1240, spikes: 7 }' },
      { name: 'masc_git_blame', status: 'ok', dur: '0.6s',
        args: { path: 'lib/scheduler/round.ml', lines: '88-140' },
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
  blocks: [
    { t: 'p', html: `확인했습니다. <code>${keeper.ns}</code> 네임스페이스에서 관련 trace를 모아 정리하고 있어요.` },
    { t: 'ul', items: ['관련 trace <strong>3건</strong> 수집 완료', '소유 태스크와의 연관성 점검 중'] },
    { t: 'p', html: '잠시 후 상세 결과를 올릴게요. 먼저 보고 싶은 게 있으면 골라주세요.' },
  ],
  suggestions: ['상세 trace 펼치기', '관련 태스크로 이동', '요약만 빠르게'],
});

const RECENT_TOOLS = [
  { name: 'masc_amplitude_query', dur: '2.4s', ago: '2m' },
  { name: 'masc_board_metrics', dur: '0.3s', ago: '6m' },
  { name: 'masc_trace_window', dur: '1.1s', ago: '11m' },
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

Object.assign(window, {
  PORTRAIT, FSM_STATES, KEEPERS, THREADS, DEFAULT_SUGGESTIONS,
  CANNED_REPLY, nowHM, RECENT_TOOLS, OWNED_TASKS,
});

// Dynamic API and Stream utilities for v2 Dashboard
const API = {
  // Fetch overall system status and running keepers
  async fetchDashboardShell() {
    try {
      const res = await fetch('/api/v1/dashboard/shell');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return await res.json();
    } catch (e) {
      console.warn('[API] fetchDashboardShell failed:', e);
      return null;
    }
  },

  // Fetch chat history for a specific keeper and map to UI schema
  async fetchKeeperHistory(keeperId) {
    try {
      const res = await fetch(`/api/v1/keepers/${encodeURIComponent(keeperId)}/chat/history`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (!Array.isArray(data)) return [];
      
      return data.map((msg, index) => {
        const date = msg.ts ? new Date(msg.ts * 1000) : new Date();
        const timeStr = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
        
        const blocks = [];
        if (msg.role === 'tool' || msg.tool_call_name) {
          blocks.push({
            t: 'p',
            html: `Tool call: <code>${msg.tool_call_name || 'unknown'}</code>`
          });
          if (msg.content) {
            blocks.push({
              t: 'code',
              html: `<pre><code>${msg.content}</code></pre>`
            });
          }
        } else {
          blocks.push({
            t: 'p',
            html: (msg.content || '').replace(/</g, '&lt;').replace(/\n/g, '<br />')
          });
        }

        return {
          id: msg.tool_call_id || `msg_${index}_${msg.ts || Date.now()}`,
          role: msg.role === 'assistant' ? 'assistant' : msg.role === 'user' ? 'user' : msg.role,
          source: msg.source || 'dashboard',
          ts: timeStr,
          blocks: blocks,
          ...(msg.tool_call_name ? {
            tools: [{
              name: msg.tool_call_name,
              status: 'ok',
              dur: '—',
              args: {},
              result: msg.content
            }]
          } : {})
        };
      });
    } catch (e) {
      console.warn(`[API] fetchKeeperHistory for ${keeperId} failed:`, e);
      return [];
    }
  },

  // Send a message and stream the assistant response chunk-by-chunk
  async sendMessageToKeeperStream(keeperId, text, onChunk, onDone, onError) {
    try {
      const res = await fetch('/api/v1/keepers/chat/stream', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: keeperId,
          message: text,
          channel: 'dashboard',
          channel_user_id: 'operator',
          channel_user_name: 'operator',
          channel_workspace_id: 'default'
        })
      });

      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      
      const reader = res.body.getReader();
      const decoder = new TextDecoder('utf-8');
      let buffer = '';
      let accumulatedText = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          onDone(accumulatedText);
          break;
        }
        
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed || !trimmed.startsWith('data:')) continue;
          
          try {
            const event = JSON.parse(trimmed.slice(5).trim());
            if (event.type === 'TEXT_MESSAGE_CONTENT' && event.delta) {
              accumulatedText += event.delta;
              onChunk(accumulatedText);
            } else if (event.type === 'RUN_ERROR') {
              throw new Error(event.value?.message || 'Run error');
            }
          } catch (err) {
            console.warn('[API] Parse stream event failed:', err);
          }
        }
      }
    } catch (e) {
      console.error('[API] Stream message failed:', e);
      onError(e);
    }
  },

  // Connect to the unified dashboard SSE event stream
  connectDashboardSSE(onEvent) {
    const sessionId = `dash_v2_${Math.random().toString(36).slice(2, 10)}`;
    const sseUrl = `/mcp?sse_kind=observer&session_id=${sessionId}`;
    
    console.debug('[SSE] Connecting Observer SSE:', sseUrl);
    const source = new EventSource(sseUrl);

    source.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        onEvent(data);
      } catch (e) {
        console.warn('[SSE] Parse event payload failed:', e);
      }
    };

    source.onerror = (err) => {
      console.warn('[SSE] Connection error, closing EventSource:', err);
      source.close();
    };

    return () => {
      console.debug('[SSE] Disconnecting SSE');
      source.close();
    };
  }
};

window.API = API;

