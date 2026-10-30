/* MASC v2 — 이벤트 로그 surface (observe / trace stream).
   A live fleet-wide event stream. Every row maps to a real MASC server
   event: tool {tool_name, outcome, latency_ms, summary}, turn {model,
   tools_used, stop_reason, duration_ms}, lifecycle {from→to phase},
   approval (HILT queue), broadcast. Events are synthesized deterministically
   from the roster + conversation traces + approvals + compactions so the
   stream is grounded, not random filler. */
const { useState: useLgS, useMemo: useLgMemo } = React;

// kind → label + which nav target (if any) the detail can jump to
const LG_KIND = {
  tool:      { lbl: 'TOOL' },
  turn:      { lbl: 'TURN' },
  lifecycle: { lbl: 'LIFECYCLE' },
  approval:  { lbl: 'APPROVAL' },
  broadcast: { lbl: 'BROADCAST' },
};
const LG_SEV_RANK = { bad: 0, warn: 1, busy: 2, info: 3, ok: 4 };

// small deterministic PRNG so the stream is stable across reloads
function lgRand(seed) { let s = seed >>> 0 || 1; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }
function lgClock(sec) {
  sec = ((sec % 86400) + 86400) % 86400;
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  return [h, m, s].map(n => String(n).padStart(2, '0')).join(':');
}
const lgHM = (sec) => lgClock(sec).slice(0, 5);
function lgHMtoSec(hm) { const [h, m] = hm.split(':').map(Number); return h * 3600 + m * 60; }

// one-line human summary for a tool call, from its args (mirrors `summary` field)
function lgToolMsg(name, args = {}) {
  const a = args || {};
  // real tools (tool_policy.toml)
  if (name === 'tool_read_file') return `read · ${a.path || a.file || ''}`.trim();
  if (name === 'tool_edit_file') return `edit · ${a.path || a.file || ''}`.trim();
  if (name === 'tool_write_file') return `write · ${a.path || a.file || ''}`.trim();
  if (name === 'tool_execute') return `exec · ${a.cmd || a.argv || ''}`.trim();
  if (name === 'tool_search_files') return `search files · ${a.q || a.query || ''}`.trim();
  if (name === 'keeper_context_status') return `context status · ${a.ns || ''}`.trim();
  if (name === 'keeper_memory_search') return `memory search · ${a.q || a.query || ''}`.trim();
  if (name === 'keeper_board_search') return `board search · ${a.q || a.query || ''}`.trim();
  if (name === 'keeper_board_post') return `board post · ${a.board || a.scope || ''}`.trim();
  if (name === 'masc_web_search') return `web search · ${a.q || a.query || ''}`.trim();
  if (name === 'masc_status') return `status · ${a.ns || ''}`.trim();
  if (name === 'masc_tasks') return `tasks · ${a.ns || ''}`.trim();
  if (name === 'masc_transition') return a.to || a.action ? `transition · ${a.to || a.action}` : 'transition';
  if (name === 'masc_broadcast') return a.scope ? `broadcast · ${a.scope}` : 'broadcast';
  if (name === 'keeper_voice_listen') return `voice listen · ${a.audio || ''}`.trim();
  if (name === 'masc_add_task') return `add task · ${a.title || ''}`.trim();
  const vals = Object.values(a).filter(v => typeof v !== 'object');
  return `${name}${vals.length ? ' · ' + vals.slice(0, 2).join(' · ') : ''}`;
}

const LG_STOPS = ['end_turn', 'tool_use', 'end_turn', 'end_turn', 'max_tokens'];

// Build the grounded event stream. NOW anchors to the conversation clock (~14:10).
function lgBuildEvents() {
  const NOW = 14 * 3600 + 10 * 60 + 40;
  const ks = (window.KEEPERS || []);
  const byId = Object.fromEntries(ks.map(k => [k.id, k]));
  const ev = [];
  let uid = 0;
  const push = (sec, keeper, kind, sev, msg, detail) => ev.push({ id: 'e' + (uid++), sec, keeper, kind, sev, msg, detail });

  // 1) Real tool calls lifted out of the conversation traces (fully wireable).
  const threads = window.THREADS || {};
  Object.keys(threads).forEach(kid => {
    const rnd = lgRand(kid.length * 7919 + 13);
    threads[kid].forEach(m => {
      if (m.role !== 'assistant' || !Array.isArray(m.trace)) return;
      const base = lgHMtoSec(m.ts || '14:00');
      m.trace.forEach(tr => {
        if (tr.kind !== 'tool') return;
        const sec = Math.min(NOW, base + Math.floor(rnd() * 50));
        const sev = tr.status === 'ok' ? 'ok' : 'bad';
        push(sec, kid, 'tool', sev, lgToolMsg(tr.name, tr.args), {
          kind: 'tool', name: tr.name, status: tr.status, dur: tr.dur,
          ns: (tr.args && tr.args.ns) || byId[kid] && byId[kid].ns,
          args: tr.args, result: tr.result,
        });
      });
      // each assistant message is itself a completed turn
      const tools = (m.trace || []).filter(t => t.kind === 'tool').map(t => t.name);
      push(Math.min(NOW, base + 51), kid, 'turn', m.verified ? 'ok' : 'info',
        `turn 완료 · ${tools.length} tool · ${m.verified ? 'verified' : 'draft'}`,
        { kind: 'turn', model: byId[kid] && byId[kid].model, tools, stop_reason: tools.length ? 'tool_use' : 'end_turn', dur: (1 + (tools.length * 1.3)).toFixed(1) + 's' });
    });
  });

  // 2) HILT approval requests → approval events (opened N secs ago).
  (window.APPROVALS || []).forEach(a => {
    const meta = (window.APPROVAL_KIND || {})[a.kind] || { lbl: a.kind };
    push(NOW - (a.opened || 60), a.keeper, 'approval', a.sev === 'bad' ? 'bad' : a.sev === 'warn' ? 'warn' : 'info',
      `승인 요청 · ${a.title}`,
      { kind: 'approval', tool: a.tool, sev: a.sev, req: a.req, detail: a.detail, goal: a.goal, job: a.job, label: meta.lbl });
  });

  // 3) Compaction runs → lifecycle events with real before/after token counts.
  const comp = window.COMPACTIONS || {};
  Object.keys(comp).forEach(kid => comp[kid].slice(0, 2).forEach(c => {
    push(lgHMtoSec(c.at), kid, 'lifecycle', 'busy',
      `Compacting · 컨텍스트 ${(c.before.tok / 1000).toFixed(0)}k → ${(c.after.tok / 1000).toFixed(0)}k tok`,
      { kind: 'lifecycle', from: 'Running', to: 'Compacting', trigger: c.trigger,
        gloss: `메시지 ${c.before.msgs}→${c.after.msgs} · trace ${c.before.traces}→${c.after.traces}` });
  }));

  // 4) Current phase transitions for non-steady keepers (grounded in roster phase).
  const TRANS = {
    'qa-king':  { sev: 'warn', from: 'Running', to: 'HandingOff', off: 8 * 60, msg: '핸드오프 시작 · docs/site → sangsu' },
    'analyst':  { sev: 'warn', from: 'Running', to: 'Paused', off: 34 * 60, msg: '슈퍼바이저 일시정지' },
    'scholar':  { sev: 'warn', from: 'Running', to: 'Draining', off: 17 * 60, msg: 'Draining — 정상 종료 중' },
    'drifter':  { sev: 'bad',  from: 'Running', to: 'Overflowed', off: 180 * 60, msg: 'Overflowed — 컨텍스트 100% 초과' },
    'marshal':  { sev: 'bad',  from: 'Running', to: 'Crashed', off: 300 * 60, msg: 'Crashed — 비정상 종료' },
  };
  Object.keys(TRANS).forEach(kid => {
    const tr = TRANS[kid];
    push(NOW - tr.off, kid, 'lifecycle', tr.sev, tr.msg,
      { kind: 'lifecycle', from: tr.from, to: tr.to, gloss: (window.PHASE_INFO || {})[tr.to] });
  });

  // 5) Broadcast (from the nick0cave handoff thread) — keeper-to-keeper.
  push(NOW - 15 * 60, 'nick0cave', 'broadcast', 'info', 'broadcast · core/scheduler · 핸드오프 통지 (T-3902)',
    { kind: 'broadcast', scope: 'core/scheduler', via: 'discord-gate · #core-scheduler',
      note: 'round lock 재진입 확인 — compact() 격리 전까지 신규 라운드 튜닝 보류. 패치 소유: sangsu.',
      recipients: ['sangsu · acked', 'rama · read', 'reviewer · delivered'] });

  // 6) Density — recent tool+turn activity for active keepers, from their granted tools.
  ks.filter(k => k.status === 'run' || k.status === 'pause').forEach((k, i) => {
    const grant = (window.KEEPER_GRANTS || {})[k.id] || (window.DEFAULT_GRANT || { tools: [] });
    const pool = (grant.tools && grant.tools.length ? grant.tools : ['masc_status']);
    const rnd = lgRand(k.id.length * 104729 + i * 31 + 5);
    const n = k.status === 'run' ? 5 : 2;
    for (let j = 0; j < n; j++) {
      const sec = NOW - Math.floor(rnd() * (k.status === 'run' ? 1500 : 2400)) - j * 40;
      const name = pool[Math.floor(rnd() * pool.length)];
      const risk = (window.TOOL_RISK || {})[name];
      const fail = rnd() < 0.08 && risk !== 'read';
      push(sec, k.id, 'tool', fail ? 'bad' : 'ok', lgToolMsg(name, { ns: k.ns }),
        { kind: 'tool', name, status: fail ? 'err' : 'ok', dur: (0.3 + rnd() * 2.4).toFixed(1) + 's', ns: k.ns,
          result: fail ? '{ error: "timeout" }' : '{ ok: true }' });
      if (rnd() < 0.5) {
        const stop = LG_STOPS[Math.floor(rnd() * LG_STOPS.length)];
        push(sec + 6, k.id, 'turn', stop === 'max_tokens' ? 'warn' : 'ok', `turn 완료 · stop=${stop}`,
          { kind: 'turn', model: k.model, tools: [name], stop_reason: stop, dur: (1 + rnd() * 3).toFixed(1) + 's' });
      }
    }
  });

  ev.sort((a, b) => b.sec - a.sec);
  return ev.map(e => ({ ...e, t: lgClock(e.sec) }));
}

function LgKv({ rows }) {
  return (
    <div className="lg-kv">
      {rows.filter(r => r && r[1] != null && r[1] !== '').map(([k, v], i) => (
        <div key={i} className="lg-kv-row"><span className="lg-kv-k mono">{k}</span><span className="lg-kv-v mono">{v}</span></div>
      ))}
    </div>
  );
}

function LgDetail({ e, onNav }) {
  const d = e.detail || {};
  if (d.kind === 'tool') {
    return (
      <div className="lg-detail">
        <LgKv rows={[['tool', d.name], ['outcome', d.status], ['latency', d.dur], ['namespace', d.ns]]} />
        {d.args && <div className="lg-block"><span className="lg-block-h">args</span><pre className="lg-code">{JSON.stringify(d.args, null, 1)}</pre></div>}
        {d.result && <div className="lg-block"><span className="lg-block-h">result</span><pre className="lg-code">{typeof d.result === 'string' ? d.result : JSON.stringify(d.result, null, 1)}</pre></div>}
      </div>
    );
  }
  if (d.kind === 'turn') {
    return <div className="lg-detail"><LgKv rows={[['model', d.model || '—'], ['tools_used', (d.tools || []).join(', ') || '—'], ['stop_reason', d.stop_reason], ['duration', d.dur]]} /></div>;
  }
  if (d.kind === 'lifecycle') {
    return <div className="lg-detail">
      <LgKv rows={[['from', d.from], ['to', d.to], ['trigger', d.trigger]]} />
      {d.gloss && <div className="lg-note">{d.gloss}</div>}
    </div>;
  }
  if (d.kind === 'approval') {
    return <div className="lg-detail">
      <LgKv rows={[['tool', d.tool], ['severity', d.sev], ['goal · job', [d.goal, d.job].filter(Boolean).join(' · ')]]} />
      {d.req && <div className="lg-note">“{d.req}”</div>}
      {d.detail && <div className="lg-note dim">{d.detail}</div>}
      <button className="lg-jump" onClick={() => onNav && onNav('approvals')}>Gate 큐 열기 →</button>
    </div>;
  }
  if (d.kind === 'broadcast') {
    return <div className="lg-detail">
      <LgKv rows={[['scope', d.scope], ['via', d.via]]} />
      <div className="lg-note">{d.note}</div>
      <div className="lg-recips">{(d.recipients || []).map((r, i) => <span key={i} className="lg-recip mono">{r}</span>)}</div>
    </div>;
  }
  return null;
}

function LogRow({ e, open, onToggle, onNav }) {
  const k = (window.KEEPERS || []).find(x => x.id === e.keeper);
  return (
    <div className={`lg-row ${open ? 'open' : ''}`} data-sev={e.sev} data-kind={e.kind}>
      <button className="lg-line" onClick={onToggle}>
        <span className="lg-time mono">{e.t}</span>
        <span className="lg-who">
          {k ? <SigilBadge k={k} size={18} /> : <span className="lg-nosig" />}
          <span className="lg-kid">{e.keeper}</span>
        </span>
        <span className="lg-kind" data-kind={e.kind}>{(LG_KIND[e.kind] || {}).lbl}</span>
        <span className="lg-msg">{e.msg}</span>
        <span className="lg-caret">{open ? '▾' : '▸'}</span>
      </button>
      {open && <LgDetail e={e} onNav={onNav} />}
    </div>
  );
}

const LG_FILTERS = [['all', '전체'], ['tool', 'Tool'], ['turn', 'Turn'], ['lifecycle', 'Lifecycle'], ['approval', 'Approval'], ['broadcast', 'Broadcast']];

function LogsSurface({ onNav }) {
  const all = useLgMemo(() => lgBuildEvents(), []);
  const [filter, setFilter] = useLgS('all');
  const [onlyErr, setOnlyErr] = useLgS(false);
  const [openId, setOpenId] = useLgS(null);

  const rows = useLgMemo(() => all.filter(e =>
    (filter === 'all' || e.kind === filter) && (!onlyErr || e.sev === 'bad' || e.sev === 'warn')
  ), [all, filter, onlyErr]);

  const stats = useLgMemo(() => {
    const tools = all.filter(e => e.kind === 'tool');
    const errs = all.filter(e => e.sev === 'bad').length;
    const keepers = new Set(all.map(e => e.keeper)).size;
    const rate = (all.length / 31).toFixed(1); // ~31 min window
    return { total: all.length, tools: tools.length, errs, errRate: ((errs / all.length) * 100).toFixed(1), keepers, rate };
  }, [all]);

  return (
    <main className="lg">
      <header className="lg-head">
        <div className="lg-head-l">
          <h1>이벤트 로그</h1>
        </div>
        <div className="lg-stats">
          <div className="lg-stat"><span className="k">이벤트/분</span><span className="v mono">{stats.rate}</span></div>
          <div className="lg-stat"><span className="k">오류율</span><span className={`v mono ${stats.errs ? 'bad' : ''}`}>{stats.errRate}%</span></div>
          <div className="lg-stat"><span className="k">tool 호출</span><span className="v mono">{stats.tools}</span></div>
          <div className="lg-stat"><span className="k">활성 keeper</span><span className="v mono">{stats.keepers}</span></div>
        </div>
      </header>

      <div className="lg-toolbar">
        <div className="lg-filters">
          {LG_FILTERS.map(([id, lbl]) => (
            <button key={id} className={`lg-fchip ${filter === id ? 'on' : ''}`} onClick={() => setFilter(id)}>{lbl}</button>
          ))}
        </div>
        <div className="lg-tb-spacer" />
        <button className={`lg-onlyerr ${onlyErr ? 'on' : ''}`} onClick={() => setOnlyErr(v => !v)}>주의·실패만</button>
        <span className="lg-live mono"><span className="dot" /> masc-mcp · WS open · 15δ/min</span>
      </div>

      <div className="lg-colhd">
        <span>시각</span><span>keeper</span><span>유형</span><span>이벤트</span><span />
      </div>
      <div className="lg-stream">
        {rows.map(e => (
          <LogRow key={e.id} e={e} open={openId === e.id} onToggle={() => setOpenId(o => o === e.id ? null : e.id)} onNav={onNav} />
        ))}
        {!rows.length && <div className="lg-empty">해당하는 이벤트 없음</div>}
      </div>
    </main>
  );
}

Object.assign(window, { LogsSurface });
