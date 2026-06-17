/* MASC v2 — Copilot Dock: global, co-view, streaming mini conversation.
   Exposes window.useDock (state + streaming), window.CopilotDock (panel),
   window.getSurfaceContext (the structured payload each surface shares). */
const { useState: useDS, useRef: useDRef, useEffect: useDEffect } = React;

const SPARK = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 3l1.7 4.8L18.5 9.5l-4.8 1.7L12 16l-1.7-4.8L5.5 9.5l4.8-1.7z" />
    <path d="M18.5 14l.9 2.4 2.4.9-2.4.9-.9 2.4-.9-2.4-2.4-.9 2.4-.9z" />
  </svg>
);

/* ── Structured context each surface exposes to the co-view ──
   This is the "Structured Output" each screen hands the agent so the
   conversation is grounded in what the operator is actually looking at. */
function getSurfaceContext(surface, keepers, selId) {
  const run = keepers.filter(k => k.status === 'run').length;
  const att = keepers.filter(k => k.att > 0).length;
  const live = keepers.filter(k => k.status === 'run');
  const avg = live.length ? Math.round(live.reduce((a, k) => a + k.ctx, 0) / live.length * 100) : 0;
  const traces = keepers.reduce((a, k) => a + k.traces, 0);
  const sel = keepers.find(k => k.id === selId);
  const MAP = {
    overview: { label: '운영 개요', route: '/overview', scene: '함대 전체 상태를 함께 보는 중',
      fields: [{ k: '실행', v: `${run}/${keepers.length}` }, { k: '주의', v: String(att), tone: 'bad' }, { k: 'ctx', v: avg + '%', tone: 'volt' }, { k: 'trace', v: traces.toLocaleString() }] },
    keepers: { label: 'Keeper 대화', route: '/keepers', scene: `${sel ? sel.kr : '선택한 keeper'}와 1:1 스레드`,
      fields: sel ? [{ k: 'state', v: sel.phase }, { k: 'ctx', v: Math.round(sel.ctx * 100) + '%', tone: sel.ctx >= 0.85 ? 'warn' : 'volt' }, { k: 'ns', v: sel.ns }] : [] },
    board: { label: '보드 · 전체 피드', route: '/board', scene: '네임스페이스 보드를 함께 보는 중',
      fields: [{ k: '포스트', v: '5' }, { k: '멘션', v: '3', tone: 'volt' }, { k: '모더', v: '1', tone: 'warn' }] },
    ide: { label: 'IDE · round.ml', route: '/ide', scene: 'fix/round-lock-reentry 브랜치를 함께 보는 중',
      fields: [{ k: 'PR', v: '#7741', tone: 'volt' }, { k: 'test', v: '84/84' }, { k: 'risk', v: '1', tone: 'bad' }] },
    connectors: { label: '커넥터 · Gate', route: '/connectors', scene: '외부 게이트 상태를 함께 보는 중',
      fields: [{ k: 'gate', v: '4' }, { k: 'active', v: '3', tone: 'volt' }, { k: 'stale', v: '1', tone: 'warn' }] },
    settings: { label: '설정', route: '/settings', scene: '런타임·정책 설정', fields: [] },
  };
  return MAP[surface] || MAP.overview;
}

const DOCK_STARTERS = {
  '/overview': ['주의 큐 4건 정리해줘', '평균 컨텍스트가 왜 높아?', '지금 가장 급한 건 뭐야?'],
  '/keepers': ['이 keeper 지금 뭐 하고 있어?', '소유 태스크 요약', '컨텍스트 압박 풀어줘'],
  '/board': ['멘션 인박스 정리해줘', 'drifter 상태 블록 뭐야?'],
  '/ide': ['이 lock 재진입 설명해줘', 'PR #7741 요약', '회귀 위험 어디야?'],
  '/connectors': ['stale 게이트 왜 그래?', '바인딩 현황 요약해줘'],
};

/* ── contextual streamed reply ── */
function buildReply(keeper, ctx) {
  if (ctx.route === '/overview') {
    return { body: `지금 **운영 개요**를 같이 보고 있네요. 실행 중 keeper와 주의 큐를 훑었어요.\n\n가장 급한 건 \`drifter\` — 컨텍스트가 **오버플로우**라 재시작이 필요합니다. \`nick0cave\`도 91%라 곧 compact가 걸릴 거예요.\n\n제가 ${keeper.kr}로서 주의 4건을 우선순위대로 정리해볼까요?`,
      sug: ['drifter 재시작 절차 보기', '주의 4건 한 번에 트리아지', 'nick0cave compact 미리 돌리기'] };
  }
  if (ctx.route === '/ide') {
    return { body: `\`round.ml\`의 lock 재진입 경로를 같이 보고 있어요. \`compact()\`가 라운드 락을 잡은 채 호출되는 **L93**이 의심됩니다.\n\nPR **#7741**은 테스트 84/84 통과지만 아직 리뷰 대기예요.`,
      sug: ['L93 FIXME 같이 보기', 'PR #7741 리뷰 코멘트 요약', 'sangsu에게 핸드오프'] };
  }
  if (ctx.route === '/board') {
    return { body: `**전체 피드**를 같이 보고 있어요. \`@operator\` 멘션 3건 중 \`drifter\`의 restart 승인 대기가 가장 급합니다.`,
      sug: ['멘션 인박스 정리', 'drifter 상태 블록 열기', 'scheduler 공지 스레드로'] };
  }
  if (ctx.route === '/connectors') {
    return { body: `**Gate** 상태를 같이 보고 있어요. iMessage 게이트가 **stale** — heartbeat 120s 초과로 응답이 지연되고 있어요.`,
      sug: ['stale 게이트 재연결', '바인딩 현황 요약', '최근 감사 로그 보기'] };
  }
  return { body: `\`${ctx.label}\` 화면을 같이 보고 있어요. \`${keeper.ns}\` 기준으로 관련 trace와 태스크를 모아둘게요. 무엇부터 볼까요?`,
    sug: ['이 화면 요약', '관련 태스크 보기', '다음 액션 추천'] };
}

function mdInline(s) {
  return s
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
}
function Para({ text }) {
  return (
    <React.Fragment>
      {text.split('\n\n').map((p, i) => <p key={i} dangerouslySetInnerHTML={{ __html: mdInline(p) }}></p>)}
    </React.Fragment>
  );
}

/* ── state + streaming hook ── */
function useDock() {
  const [state, setState] = useDS(() => {
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem('masc.dock') || '{}'); } catch (e) { /* noop */ }
    return { open: false, mode: 'dock', keeperId: 'masc-improver', x: null, y: null, ...saved };
  });
  const [threads, setThreads] = useDS({});
  const [streaming, setStreaming] = useDS(null); // { keeperId, shown, full, sug }
  const timer = useDRef(null);

  useDEffect(() => {
    const { open, mode, keeperId, x, y } = state;
    try { localStorage.setItem('masc.dock', JSON.stringify({ open, mode, keeperId, x, y })); } catch (e) { /* noop */ }
  }, [state]);

  useDEffect(() => () => clearInterval(timer.current), []);

  const patch = (p) => setState(s => ({ ...s, ...p }));

  const send = (text, keeper, ctx) => {
    if (!text.trim() || streaming) return;
    const kid = keeper.id;
    setThreads(prev => ({ ...prev, [kid]: [...(prev[kid] || []), { role: 'user', ts: nowHM(), text: text.trim() }] }));
    const { body, sug } = buildReply(keeper, ctx);
    setTimeout(() => {
      setStreaming({ keeperId: kid, shown: '', full: body, sug });
      const start = (typeof performance !== 'undefined' ? performance.now() : Date.now());
      const DUR = 900;
      clearInterval(timer.current);
      timer.current = setInterval(() => {
        const now = (typeof performance !== 'undefined' ? performance.now() : Date.now());
        const p = Math.min(1, (now - start) / DUR);
        if (p >= 1) {
          clearInterval(timer.current);
          setStreaming(null);
          setThreads(prev => ({ ...prev, [kid]: [...(prev[kid] || []), { role: 'assistant', ts: nowHM(), text: body, sug }] }));
        } else {
          const n = Math.max(1, Math.floor(body.length * p));
          setStreaming(s => (s && s.keeperId === kid ? { ...s, shown: body.slice(0, n) } : s));
        }
      }, 40);
    }, 220);
  };

  return {
    state, patch, threads, streaming, send,
    open: () => patch({ open: true }),
    close: () => patch({ open: false }),
    toggle: () => setState(s => ({ ...s, open: !s.open })),
    setMode: (mode) => patch({ mode }),
    setKeeper: (keeperId) => patch({ keeperId }),
  };
}

function DockMsg({ m, keeper, onPick }) {
  const isUser = m.role === 'user';
  return (
    <div className={`dmsg ${isUser ? 'user' : ''}`}>
      {isUser ? <div className="dmsg-av op">YOU</div> : <SigilBadge k={keeper} size={26} beat={keeper.status === 'run'} />}
      <div className="dmsg-col">
        <div className="dmsg-hd">
          <span className="who">{isUser ? 'operator' : keeper.kr}</span>
          <span className="ts mono">{m.ts}</span>
        </div>
        <div className={`dbubble ${isUser ? 'user' : ''}`}><Para text={m.text} /></div>
        {!isUser && m.sug && (
          <div className="dsug">
            {m.sug.map((s, i) => <button key={i} onClick={() => onPick(s)}><span className="pre">{'\u203A'}</span>{s}</button>)}
          </div>
        )}
      </div>
    </div>
  );
}

function CopilotDock({ dock, ctx, docked }) {
  const keeper = KEEPERS.find(k => k.id === dock.state.keeperId) || KEEPERS[0];
  const msgs = dock.threads[keeper.id] || [];
  const streaming = dock.streaming && dock.streaming.keeperId === keeper.id ? dock.streaming : null;
  const [val, setVal] = useDS('');
  const [focus, setFocus] = useDS(false);
  const [pickOpen, setPickOpen] = useDS(false);
  const taRef = useDRef(null);
  const threadRef = useDRef(null);
  const rootRef = useDRef(null);

  useDEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [msgs.length, streaming && streaming.shown, keeper.id]);

  const doSend = (text) => {
    const v = (text !== undefined ? text : val).trim();
    if (!v) return;
    dock.send(v, keeper, ctx);
    setVal('');
    if (taRef.current) taRef.current.style.height = 'auto';
  };
  const onKey = (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); doSend(); } };
  const grow = (e) => { setVal(e.target.value); e.target.style.height = 'auto'; e.target.style.height = Math.min(e.target.scrollHeight, 120) + 'px'; };

  const drag = (e) => {
    if (docked) return;
    const root = rootRef.current; if (!root) return;
    const r = root.getBoundingClientRect();
    const offx = e.clientX - r.left, offy = e.clientY - r.top;
    const move = (ev) => {
      dock.patch({
        x: Math.max(8, Math.min(window.innerWidth - r.width - 8, ev.clientX - offx)),
        y: Math.max(8, Math.min(window.innerHeight - r.height - 8, ev.clientY - offy)),
      });
    };
    const up = () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); };
    window.addEventListener('mousemove', move); window.addEventListener('mouseup', up);
  };

  const floatStyle = !docked ? {
    left: dock.state.x != null ? dock.state.x : 'auto',
    top: dock.state.y != null ? dock.state.y : 'auto',
    right: dock.state.x != null ? 'auto' : 22,
    bottom: dock.state.y != null ? 'auto' : 22,
  } : null;

  return (
    <aside ref={rootRef} className={`dock ${docked ? 'docked' : 'float'}`} style={floatStyle} data-screen-label="Copilot 도크">
      <div className={`dock-head ${docked ? '' : 'drag'}`} onMouseDown={docked ? undefined : drag}>
        <div className="dock-title"><span className="dock-spark">{SPARK}</span>Copilot</div>
        <div className="spacer"></div>
        <button className="dock-iconbtn" title={docked ? '플로팅으로 띄우기' : '오른쪽에 도킹'} onMouseDown={e => e.stopPropagation()} onClick={() => dock.setMode(docked ? 'float' : 'dock')}>{docked ? '\u29C9' : '\u2750'}</button>
        <button className="dock-iconbtn" title="닫기 (Esc)" onMouseDown={e => e.stopPropagation()} onClick={dock.close}>{'\u2715'}</button>
      </div>

      <div className="dock-idrow">
        <div className="dock-picker">
          <button className="dock-picker-btn" onMouseDown={e => e.stopPropagation()} onClick={() => setPickOpen(o => !o)}>
            <SigilBadge k={keeper} size={20} beat={keeper.status === 'run'} />
            <span className="nm">{keeper.kr}</span>
            <span className="cv">{'\u25BE'}</span>
          </button>
          {pickOpen && (
            <div className="dock-menu" onMouseDown={e => e.stopPropagation()}>
              {KEEPERS.map(k => (
                <div key={k.id} className={`dock-menu-row ${k.id === keeper.id ? 'on' : ''}`} onClick={() => { dock.setKeeper(k.id); setPickOpen(false); }}>
                  <SigilBadge k={k} size={26} beat={k.status === 'run'} />
                  <div className="minfo">
                    <div className="nm">{k.kr} <span className="h">{k.id}</span></div>
                    <div className="sub"><StatusDot status={k.status} pulse={k.status === 'run'} />{k.phase} · {k.ns}</div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
        <span className="dock-idrow-hint">와 대화 중 · <span className="mono">{keeper.ns}</span></span>
      </div>

      <div className="dock-coview">
        <div className="dock-coview-h"><span className="lbl">지금 함께 보는 화면 · {ctx.label}</span><span className="route mono">{ctx.route}</span></div>
        <div className="scene">{ctx.label}</div>
        {ctx.fields.length > 0 && (
          <div className="dock-coview-fields">
            {ctx.fields.map((f, i) => <span key={i} className={`dock-field ${f.tone || ''}`}><span className="k">{f.k}</span><span className="v">{f.v}</span></span>)}
          </div>
        )}
        <div className="sync"><span className="d"></span>{ctx.scene}</div>
      </div>

      <div className="dock-thread" ref={threadRef}>
        {msgs.length === 0 && !streaming ? (
          <div className="dock-empty">
            <div className="ico">{'\u25C8'}</div>
            <div className="t">{ctx.label}</div>
            <div className="s">이 화면에 대해 {keeper.kr}에게 바로 물어보세요. 같은 맥락을 보고 답합니다.</div>
            <div className="dsug" style={{ width: '100%' }}>
              {(DOCK_STARTERS[ctx.route] || ['이 화면 요약해줘', '다음 액션 추천']).map((s, i) => (
                <button key={i} onClick={() => doSend(s)}><span className="pre">{'\u203A'}</span>{s}</button>
              ))}
            </div>
          </div>
        ) : (
          <React.Fragment>
            {msgs.map((m, i) => <DockMsg key={i} m={m} keeper={keeper} onPick={doSend} />)}
            {streaming && (
              <div className="dmsg">
                <SigilBadge k={keeper} size={26} beat />
                <div className="dmsg-col">
                  <div className="dmsg-hd"><span className="who">{keeper.kr}</span><span className="ts mono">작성 중…</span></div>
                  <div className="dbubble"><Para text={streaming.shown} /><span className="dcaret"></span></div>
                </div>
              </div>
            )}
          </React.Fragment>
        )}
      </div>

      <div className="dock-composer">
        <div className={`dock-comp-box ${focus ? 'focus' : ''}`}>
          <textarea ref={taRef} rows={1} value={val} placeholder={`${keeper.kr}에게… (이 화면 기준)`}
            onChange={grow} onKeyDown={onKey} onFocus={() => setFocus(true)} onBlur={() => setFocus(false)} onMouseDown={e => e.stopPropagation()} />
          <button className="dock-send" disabled={!val.trim() || !!dock.streaming} onClick={() => doSend()}>{'\u2191'}</button>
        </div>
        <div className="dock-foot">
          <span>발신 <b>@operator</b></span>
          <span style={{ marginLeft: 'auto' }}><kbd>{'\u21B5'}</kbd> 전송 · <kbd>Esc</kbd> 닫기</span>
        </div>
      </div>
    </aside>
  );
}

Object.assign(window, { useDock, CopilotDock, getSurfaceContext, DOCK_SPARK: SPARK });
