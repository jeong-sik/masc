/* MASC v2 — Turn Inspector: the full detail surface for one keeper turn.
   Summary stats · token economics · turn waterfall · structured transcript
   with tool cards · copyable injected context. Opened from a message's
   "턴 상세" action. Reads globals: OWNED_TASKS, RECENT_TOOLS. */
const { useState: useTurnState, useEffect: useTurnEffect } = React;

/* ── helpers ──────────────────────────────────────────────────── */
function blocksToText(blocks) {
  if (!blocks) return '';
  return blocks.map(b => {
    if (b.t === 'p' || b.t === 'h4' || b.t === 'callout') return stripTags(b.html);
    if (b.t === 'ul') return b.items.map(it => '· ' + stripTags(it)).join('\n');
    if (b.t === 'table') {
      const head = b.head.map(h => (typeof h === 'object' ? h.v : h)).join('\t');
      const rows = b.rows.map(r => r.map(c => (typeof c === 'object' ? c.v : c)).join('\t')).join('\n');
      return head + '\n' + rows;
    }
    if (b.t === 'code') return stripTags(b.html);
    return '';
  }).filter(Boolean).join('\n\n');
}
function stripTags(html) {
  return String(html).replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}
function tiJsonHl(obj) {
  return JSON.stringify(obj, null, 2)
    .replace(/("[^"]+"):/g, '<span class="jk">$1</span>:')
    .replace(/: ("[^"]*")/g, ': <span class="js">$1</span>');
}
function approxTokens(str) { return Math.max(1, Math.round(String(str).length / 3.6)); }
function secOf(dur) { const m = String(dur || '').match(/([\d.]+)/); return m ? parseFloat(m[1]) : 0.5; }

function CopyBtn({ text, label = '복사' }) {
  const [done, setDone] = useTurnState(false);
  const onClick = (e) => {
    e.stopPropagation();
    try { navigator.clipboard && navigator.clipboard.writeText(text); } catch (_) {}
    setDone(true); setTimeout(() => setDone(false), 1200);
  };
  return (
    <button className={`ti-copy ${done ? 'done' : ''}`} onClick={onClick}>
      {done ? '\u2713 복사됨' : '\u2398 ' + label}
    </button>
  );
}

function CodeCard({ cap, text, html, tokens }) {
  return (
    <div className="ti-code">
      <div className="ti-code-h">
        <span className="cap">{cap}</span>
        {tokens != null && <span className="sz">~{tokens} tok</span>}
        <CopyBtn text={text} />
      </div>
      {html
        ? <pre dangerouslySetInnerHTML={{ __html: html }}></pre>
        : <pre>{text}</pre>}
    </div>
  );
}

/* ── turn model ───────────────────────────────────────────────── */
function buildTurn(keeper, m) {
  const traceId = 'trc_' + keeper.id.replace(/[^a-z0-9]/gi, '').slice(0, 5) + '_' + String(m.id).slice(-4);
  const tasks = (window.OWNED_TASKS && OWNED_TASKS[keeper.id]) || [];
  const trace = m.trace || (m.tools || []).map(t => ({ kind: 'tool', ...t }));
  const tools = trace.filter(s => s.kind === 'tool');
  const ctxPct = Math.round(keeper.ctx * 100);
  const tokIn = Math.round(2400 + keeper.ctx * 172000);
  const tokOut = 280 + (m.blocks ? m.blocks.length * 90 : 120);
  const cost = (tokIn * 3 + tokOut * 15) / 1e6;

  // waterfall phases — what actually ran in this turn, in order, with timings
  const phases = [{ label: '컨텍스트 조립', kind: 'ctx', dur: 0.16 }];
  const reasonN = trace.filter(s => s.kind === 'reason' || s.kind === 'think').length;
  if (reasonN) phases.push({ label: '추론 · 계획', kind: 'reason', dur: Math.round((0.6 + reasonN * 0.35) * 100) / 100 });
  tools.forEach(t => phases.push({ label: t.name, kind: 'tool', mono: true, status: t.status, dur: secOf(t.dur) }));
  const genSec = Math.max(0.4, Math.round((tokOut / 52) * 100) / 100);
  phases.push({ label: '응답 생성', kind: 'gen', dur: genSec });
  let acc = 0; const total = phases.reduce((s, p) => s + p.dur, 0);
  phases.forEach(p => { p.offset = acc; acc += p.dur; });

  const systemPrompt =
`당신은 MASC 코디네이션 서버의 keeper "${keeper.id}" 입니다.
namespace       : ${keeper.ns}
runtime · model : ${keeper.runtime} · ${keeper.model}
state(12-FSM)   : ${keeper.phase}

원칙
- 모든 작업은 trace 로 기록한다.
- 컨텍스트 사용량이 85% 를 넘으면 compact() 를 호출한다.
- 소유하지 않은 태스크는 핸드오프(HandingOff)로 넘긴다.
- 답변은 근거(도구 결과·trace)를 함께 제시한다.

available tools
  masc_amplitude_query · masc_trace_window · masc_board_metrics
  masc_git_blame · masc_handoff · masc_compact`;

  const injectedCtx =
`# namespace snapshot
namespace      = ${keeper.ns}
fsm.state      = ${keeper.phase}
ctx.window     = ${ctxPct}%   (${tokIn.toLocaleString()} / 200,000 tok)
owned.tasks    = ${tasks.length}

# owned tasks
${tasks.length ? tasks.map(t => `  - ${t.id}  ${t.title}  [${t.state}]`).join('\n') : '  (none)'}

# recent traces (last 30m)
${(window.RECENT_TOOLS || []).map(t => `  - ${t.name}  ${t.dur}  (${t.ago} ago)`).join('\n')}

# memory / pinned notes
  - retention 정의: D0 = 가입일, 첫 세션 기준
  - gp:center_type 분류 미정값 다수 (확인 필요)`;

  return { traceId, tasks, tools, ctxPct, tokIn, tokOut, cost, phases, total, systemPrompt, injectedCtx };
}

/* ── tabs ─────────────────────────────────────────────────────── */
function TimelineTab({ t }) {
  return (
    <div className="turn-sec">
      <div className="ti-sec-h">
        <h4>턴 워터폴</h4>
        <span className="n">{t.phases.length} 단계 · {t.total.toFixed(2)}s</span>
      </div>
      <div className="ti-wf">
        {t.phases.map((p, i) => (
          <div key={i} className="ti-wf-row">
            <div className="ti-wf-lbl">
              <span className={`ti-wf-ico ti-k-${p.kind}`}></span>
              <span className={`nm ${p.mono ? 'mono' : ''}`}>{p.label}</span>
            </div>
            <div className="ti-wf-track">
              <div className={`ti-wf-bar ti-k-${p.kind}`}
                style={{ left: (p.offset / t.total * 100) + '%', width: Math.max(0.6, p.dur / t.total * 100) + '%' }}></div>
            </div>
            <span className="ti-wf-dur">{p.dur.toFixed(2)}s</span>
          </div>
        ))}
      </div>
      <div className="ti-wf-foot">
        <div className="ti-wf-legend">
          <span><i className="ti-k-reason"></i>추론</span>
          <span><i className="ti-k-tool"></i>도구</span>
          <span><i className="ti-k-gen"></i>생성</span>
        </div>
        <span>총 소요 <b>{t.total.toFixed(2)}s</b></span>
      </div>
    </div>
  );
}

function MessagesTab({ keeper, m, t }) {
  let seq = 0;
  return (
    <div className="turn-sec">
      <div className="ti-sec-h">
        <h4>모델에 전달된 시퀀스</h4>
        <span className="n">{3 + t.tools.length + 1} 메시지</span>
      </div>
      <div className="ti-seq-rail">
        <div className="ti-msg">
          <div className="ti-msg-h"><span className="ti-msg-role system">system</span><span className="who">시스템 프롬프트</span><span className="seq">#{++seq}</span></div>
          <div className="ti-msg-b mono">{t.systemPrompt}</div>
        </div>
        <div className="ti-msg">
          <div className="ti-msg-h"><span className="ti-msg-role system">context</span><span className="who">주입 컨텍스트</span><span className="seq">#{++seq}</span></div>
          <div className="ti-msg-b mono">{t.injectedCtx}</div>
        </div>
        <div className="ti-msg">
          <div className="ti-msg-h"><span className="ti-msg-role user">user</span><span className="who">operator</span><span className="seq">#{++seq}</span></div>
          <div className="ti-msg-b">{m.promptEcho || '[직전 operator 요청 — 본 대화의 사용자 메시지]'}</div>
        </div>
        {t.tools.map((tool, i) => (
          <div key={i} className="ti-tool">
            <div className="ti-tool-h">
              <span className="seq">#{++seq}</span>
              <span className="tnm">{tool.name}</span>
              <span className={`pill ${tool.status === 'ok' ? 'ok' : 'bad'}`}>{tool.status === 'ok' ? 'success' : 'error'}</span>
              <span className="lat">{tool.dur}</span>
            </div>
            <div className="ti-tool-b">
              <CodeCard cap="요청 · args" text={JSON.stringify(tool.args, null, 2)} html={tiJsonHl(tool.args)} tokens={approxTokens(JSON.stringify(tool.args))} />
              <CodeCard cap="응답 · result" text={tool.result} html={String(tool.result).replace(/("[^"]+")/g, '<span class="js">$1</span>')} tokens={approxTokens(tool.result)} />
            </div>
          </div>
        ))}
        <div className="ti-msg">
          <div className="ti-msg-h"><span className="ti-msg-role assistant">assistant</span><span className="who">{keeper.id}</span><span className="seq">#{++seq}</span></div>
          <div className="ti-msg-b">{blocksToText(m.blocks)}</div>
        </div>
      </div>
    </div>
  );
}

function ContextTab({ t }) {
  return (
    <React.Fragment>
      <div className="turn-sec">
        <div className="ti-ctx-card">
          <div className="ti-ctx-h">
            <span className="t">시스템 프롬프트</span>
            <span className="tok">~{approxTokens(t.systemPrompt)} tok</span>
            <CopyBtn text={t.systemPrompt} />
          </div>
          <pre>{t.systemPrompt}</pre>
        </div>
      </div>
      <div className="turn-sec">
        <div className="ti-ctx-card">
          <div className="ti-ctx-h">
            <span className="t">주입 컨텍스트 · namespace · tasks · traces · memory</span>
            <span className="tok">~{approxTokens(t.injectedCtx)} tok</span>
            <CopyBtn text={t.injectedCtx} />
          </div>
          <pre>{t.injectedCtx}</pre>
        </div>
      </div>
    </React.Fragment>
  );
}

function MetaTab({ keeper, m, t }) {
  return (
    <div className="turn-sec">
      <div className="ti-sec-h"><h4>샘플링 파라미터</h4></div>
      <div className="ti-params">
        <span className="ti-param">temperature<b>0.3</b></span>
        <span className="ti-param">top_p<b>0.95</b></span>
        <span className="ti-param">max_tokens<b>4,096</b></span>
        <span className="ti-param">stop<b>—</b></span>
      </div>
      <div className="ti-sec-h" style={{ marginTop: '16px' }}><h4>실행 메타데이터</h4></div>
      <div className="turn-kv">
        <span className="k">model</span><span className="v">{keeper.model}</span>
        <span className="k">runtime</span><span className="v">{keeper.runtime}</span>
        <span className="k">namespace</span><span className="v">{keeper.ns}</span>
        <span className="k">fsm.state</span><span className="v">{keeper.phase}</span>
        <span className="k">input tokens</span><span className="v">{t.tokIn.toLocaleString()}</span>
        <span className="k">output tokens</span><span className="v">{t.tokOut.toLocaleString()}</span>
        <span className="k">ctx window</span><span className="v">{t.ctxPct}% / 200K</span>
        <span className="k">tool calls</span><span className="v">{t.tools.length}</span>
        <span className="k">duration</span><span className="v">{t.total.toFixed(2)}s</span>
        <span className="k">est. cost</span><span className="v">${t.cost.toFixed(3)}</span>
        <span className="k">finish_reason</span><span className="v">stop</span>
        <span className="k">verified</span><span className="v">{m.verified ? 'pass \u2713' : '—'}</span>
        <span className="k">source</span><span className="v">{m.source}</span>
      </div>
    </div>
  );
}

/* ── shell ────────────────────────────────────────────────────── */
function TurnInspector({ keeper, m, onClose }) {
  const [tab, setTab] = useTurnState('timeline');
  const t = buildTurn(keeper, m);

  useTurnEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer ti-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>턴 상세</h3>
          <span className="tid mono">{t.traceId}</span>
          <CopyBtn text={t.traceId} label="ID" />
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)" style={{ marginLeft: '8px' }}>{'\u2715'}</button>
        </div>

        <div className="ti-sub">
          <span className="ti-chip"><span className="sub-k">model</span>{keeper.model}</span>
          <span className="ti-chip ok"><StatusDot status="run" />stop</span>
          <span className="ti-chip"><span className="sub-k">runtime</span>{keeper.runtime.split('·')[0]}</span>
        </div>

        <div className="ti-summary">
          <div className="ti-stat"><div className="k">소요</div><div className="v">{t.total.toFixed(1)}<small>s</small></div></div>
          <div className="ti-stat"><div className="k">입력</div><div className="v">{(t.tokIn / 1000).toFixed(1)}<small>k</small></div></div>
          <div className="ti-stat"><div className="k">출력</div><div className="v volt">{t.tokOut.toLocaleString()}</div></div>
          <div className="ti-stat"><div className="k">도구</div><div className="v">{t.tools.length}</div></div>
          <div className="ti-stat"><div className="k">추정비용</div><div className="v ok">${t.cost.toFixed(2)}</div></div>
        </div>

        <div className="ti-tok">
          <div className="ti-tok-top">
            <span className="lbl">토큰 경제</span>
            <span className="ctxpct">컨텍스트 {t.ctxPct}% / 200K</span>
          </div>
          <div className="ti-tok-bar">
            <span className="seg-in" style={{ width: (t.tokIn / (t.tokIn + t.tokOut) * 100) + '%' }}></span>
            <span className="seg-out" style={{ width: (t.tokOut / (t.tokIn + t.tokOut) * 100) + '%' }}></span>
          </div>
          <div className="ti-tok-legend">
            <span className="in"><i></i>입력 <b>{t.tokIn.toLocaleString()}</b></span>
            <span className="out"><i></i>출력 <b>{t.tokOut.toLocaleString()}</b></span>
          </div>
        </div>

        <div className="turn-tabs">
          {[['timeline', '타임라인'], ['messages', '메시지'], ['context', '컨텍스트'], ['meta', '메타']].map(([id, lbl]) => (
            <button key={id} className={`turn-tab ${tab === id ? 'on' : ''}`} onClick={() => setTab(id)}>{lbl}</button>
          ))}
        </div>

        <div className="turn-body">
          {tab === 'timeline' && <TimelineTab t={t} />}
          {tab === 'messages' && <MessagesTab keeper={keeper} m={m} t={t} />}
          {tab === 'context' && <ContextTab t={t} />}
          {tab === 'meta' && <MetaTab keeper={keeper} m={m} t={t} />}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { TurnInspector });
