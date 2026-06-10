/* MASC v2 — App shell: nav routing, top bar, keeper chat, collapsible rails, tweaks */
const { useState: useS, useRef, useEffect } = React;

const ICON = {
  grid: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><rect x="3" y="3" width="7" height="7" rx="1.4"/><rect x="14" y="3" width="7" height="7" rx="1.4"/><rect x="3" y="14" width="7" height="7" rx="1.4"/><rect x="14" y="14" width="7" height="7" rx="1.4"/></svg>),
  users: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c0-3 2.6-5 5.5-5s5.5 2 5.5 5"/><path d="M16.5 6.2a3 3 0 0 1 0 5.6"/><path d="M18.5 19c0-2-.8-3.6-2-4.6"/></svg>),
  board: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"><rect x="3" y="4" width="5" height="16" rx="1.2"/><rect x="10" y="4" width="5" height="11" rx="1.2"/><rect x="17" y="4" width="4" height="14" rx="1.2"/></svg>),
  term: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="2.2"/><path d="M7 9l3 3-3 3"/><path d="M13 15h4"/></svg>),
  code: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M8 6l-5 6 5 6"/><path d="M16 6l5 6-5 6"/><path d="M13.5 4l-3 16"/></svg>),
  plug: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M9 3v5M15 3v5"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/></svg>),
  gear: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.1 5.1l2.1 2.1M16.8 16.8l2.1 2.1M18.9 5.1l-2.1 2.1M7.2 16.8l-2.1 2.1"/></svg>),
};

const SURFACES = [
  ['overview', '개요', ICON.grid],
  ['keepers', 'Keepers', ICON.users],
  ['board', '보드', ICON.board],
  ['cockpit', '코크핏', ICON.term],
  ['ide', 'IDE', ICON.code],
  ['connectors', '커넥터', ICON.plug],
];

const SURFACE_LABEL = Object.fromEntries(SURFACES.map(([id, lbl]) => [id, lbl]));

function NavRail({ active, onNav }) {
  return (
    <nav className="v2-nav">
      <div className="nav-home" title="개요" onClick={() => onNav('overview')}>M</div>
      {SURFACES.map(([id, lbl, ic]) => (
        <button key={id} className={`nav-item ${active === id ? 'on' : ''}`} onClick={() => onNav(id)} title={lbl}>
          {ic}<span className="nlbl">{lbl}</span>
        </button>
      ))}
      <div className="nav-spacer"></div>
      <button className={`nav-item ${active === 'settings' ? 'on' : ''}`} title="설정" onClick={() => onNav('settings')}>{ICON.gear}<span className="nlbl">설정</span></button>
    </nav>
  );
}

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "volt": "brass",
  "density": "regular",
  "bubbleStyle": "card",
  "fontScale": 1,
  "threadW": 980,
  "rosterOpen": true,
  "ctxOpen": true
}/*EDITMODE-END*/;

function TopBar({ surface, keeper, onToggleDock, dockOpen }) {
  return (
    <div className="v2-top">
      <div className="v2-wordmark">
        <b>MASC</b><span className="ver">v2</span>
      </div>
      <div className="crumb">
        <span className={surface === 'keepers' ? '' : 'on'}>{SURFACE_LABEL[surface] || '설정'}</span>
        {surface === 'keepers' && <React.Fragment><span>/</span><span className="on">{keeper.id}</span></React.Fragment>}
      </div>
      <div className="v2-top-spacer"></div>
      <span className="v2-statchip live"><StatusDot status="run" pulse />4 실행 중</span>
      <span className="v2-statchip warn">{'\u26A0'} 주의 3</span>
      <span className="v2-statchip">스케줄러 <b>정상</b></span>
      <button className={`topbar-copilot ${dockOpen ? 'on' : ''}`} onClick={onToggleDock} title="Copilot 열기/닫기 (⌘J)">
        <span className="spark">{DOCK_SPARK}</span>Copilot<kbd>⌘J</kbd>
      </button>
    </div>
  );
}

function ChatHeader({ keeper }) {
  const pillCls = keeper.status === 'run' ? 'run' : keeper.status === 'pause' ? 'pause' : 'off';
  const pillLbl = keeper.status === 'run' ? '실행 중' : keeper.status === 'pause' ? '일시정지' : '중지됨';
  return (
    <div className="chat-head">
      <Avatar k={keeper} baseClass="chat-av" size={46} />
      <div className="chat-id">
        <div className="name-row">
          <h2>{keeper.kr}</h2>
          <SigilChip k={keeper} />
          <span className={`state-pill ${pillCls}`}><StatusDot status={keeper.status} pulse={keeper.status === 'run'} />{pillLbl}</span>
          <span className="fsm-chip">{keeper.phase}</span>
        </div>
        <div className="sub">
          <span>역할 <b style={{ color: 'var(--text-mid)' }}>{keeper.role}</b></span>
          <span>·</span>
          <span className="mono" title="대상 네임스페이스(room)">{'⌗'} {keeper.ns}</span>
        </div>
      </div>
      <div className="chat-actions">
        {keeper.status === 'run'
          ? <button className="act">{'\u23F8'} 일시정지</button>
          : <button className="act">{'\u25B6'} 재개</button>}
        <button className="act">핸드오프</button>
        <button className="act icon" title="컨텍스트 압축">{'\u29C9'}</button>
        <button className="act icon danger" title="중지">{'\u23F9'}</button>
      </div>
    </div>
  );
}

function MetaStrip({ keeper }) {
  const cells = [
    ['세션', 'sess_8a4f', false],
    ['모델', keeper.model, true],
    ['런타임', keeper.runtime, false],
    ['턴', '12', false],
    ['가동', keeper.uptime, false],
    ['도구권한', '읽기·쓰기·git', false],
  ];
  return (
    <div className="chat-meta">
      {cells.map(([k, v, volt], i) => (
        <div key={i} className="meta-cell">
          <span className="k">{k}</span>
          <span className={`v ${volt ? 'volt' : ''}`}>{v}</span>
        </div>
      ))}
    </div>
  );
}

function EmptyThread() {
  return (
    <div className="empty2">
      <div className="ico">{'\u25C8'}</div>
      <h3>대화를 시작하세요</h3>
      <div style={{ maxWidth: '320px', fontSize: '13px', lineHeight: 1.6 }}>
        이 Keeper에게 질문하거나 작업을 위임하면, 도구 호출과 trace가 이 화면에 기록됩니다.
      </div>
    </div>
  );
}

function Composer({ keeper, onSend }) {
  const [val, setVal] = useS('');
  const [focus, setFocus] = useS(false);
  const ref = useRef(null);

  const send = () => {
    const v = val.trim();
    if (!v) return;
    onSend(v);
    setVal('');
    if (ref.current) ref.current.style.height = 'auto';
  };
  const onKey = (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
  };
  const grow = (e) => {
    setVal(e.target.value);
    e.target.style.height = 'auto';
    e.target.style.height = Math.min(e.target.scrollHeight, 160) + 'px';
  };

  return (
    <div className="composer">
      <div className="composer-inner">
        <div className={`composer-box ${focus ? 'focus' : ''}`}>
          <textarea
            ref={ref} rows={1} value={val} placeholder={`${keeper.id} 에게 메시지…  (⌘+Enter 전송)`}
            onChange={grow} onKeyDown={onKey}
            onFocus={() => setFocus(true)} onBlur={() => setFocus(false)} />
          <div className="composer-tools">
            <button className="ctool" title="첨부">{'\u2295'}</button>
            <button className="ctool" title="도구 선택">{'\u2699'}</button>
            <button className="send" disabled={!val.trim()} onClick={send}>전송 {'\u2191'}</button>
          </div>
        </div>
        <div className="composer-foot">
          <span className="as">발신 <b>@operator</b> · 대상 keeper <b>{keeper.id}</b></span>
          <span className="hint"><kbd>⌘</kbd> <kbd>↵</kbd> 전송 · <kbd>/</kbd> 도구</span>
        </div>
      </div>
    </div>
  );
}

function KeepersSurface({ t, setTweak, sel, setSel, keepers, threads, setThreads, typing, setTyping }) {
  const threadRef = useRef(null);
  const keeper = keepers.find(k => k.id === sel) || KEEPERS.find(k => k.id === sel);
  const msgs = threads[sel] || [];
  const rosterOpen = t.rosterOpen !== false;
  const ctxOpen = t.ctxOpen !== false;

  useEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [sel, msgs.length, typing]);

  // Dynamic message sending with real-time stream feedback
  const pushUser = async (text) => {
    const um = { 
      id: 'u' + Date.now(), 
      role: 'user', 
      source: 'dashboard', 
      ts: nowHM(), 
      blocks: [{ t: 'p', html: text.replace(/</g, '&lt;').replace(/\n/g, '<br />') }] 
    };
    
    // 1. Add user message
    setThreads(prev => ({ ...prev, [sel]: [...(prev[sel] || []), um] }));
    setTyping(true);

    const streamMsgId = 'stream_' + Date.now();
    const assistantMsg = {
      id: streamMsgId,
      role: 'assistant',
      source: 'dashboard',
      ts: nowHM(),
      blocks: [{ t: 'p', html: '' }]
    };

    // 2. Insert blank streaming message placeholder
    setThreads(prev => ({ ...prev, [sel]: [...(prev[sel] || []), assistantMsg] }));

    // 3. Call streaming API
    await window.API.sendMessageToKeeperStream(
      sel, 
      text,
      (accumulatedText) => {
        // On each text chunk, update the assistant message content
        setThreads(prev => {
          const currentList = prev[sel] || [];
          return {
            ...prev,
            [sel]: currentList.map(m => {
              if (m.id === streamMsgId) {
                return {
                  ...m,
                  blocks: [{ t: 'p', html: accumulatedText.replace(/</g, '&lt;').replace(/\n/g, '<br />') }]
                };
              }
              return m;
            })
          };
        });
      },
      (finalText) => {
        // Stream completed
        setTyping(false);
      },
      (err) => {
        // On error, show failure feedback
        setTyping(false);
        setThreads(prev => {
          const currentList = prev[sel] || [];
          return {
            ...prev,
            [sel]: currentList.map(m => {
              if (m.id === streamMsgId) {
                return {
                  ...m,
                  blocks: [{ t: 'p', html: `<span style="color: var(--status-fail)">전송 실패: ${err.message || err}</span>` }]
                };
              }
              return m;
            })
          };
        });
      }
    );
  };

  return (
    <React.Fragment>
      <Roster keepers={keepers} selected={sel} onSelect={setSel} mini={!rosterOpen} />
      <div className="chat-wrap" data-screen-label="Keeper 대화">
        <button className="rail-toggle left" title={rosterOpen ? '로스터 접기' : '로스터 펼치기'}
          onClick={() => setTweak('rosterOpen', !rosterOpen)}>{rosterOpen ? '◂' : '▸'}</button>
        <main className="chat">
          <ChatHeader keeper={keeper} />
          <MetaStrip keeper={keeper} />
          <div className="thread" ref={threadRef}>
            {msgs.length === 0
              ? <EmptyThread />
              : (
                <div className="thread-inner">
                  <div className="daydiv">오늘</div>
                  {msgs.map(m => <Message key={m.id} m={m} keeper={keeper} onPickSuggestion={pushUser} />)}
                  {typing && <TypingMessage keeper={keeper} />}
                </div>
              )}
          </div>
          <Composer keeper={keeper} onSend={pushUser} />
        </main>
        <button className="rail-toggle right" title={ctxOpen ? '컨텍스트 레일 접기' : '컨텍스트 레일 펼치기'}
          onClick={() => setTweak('ctxOpen', !ctxOpen)}>{ctxOpen ? '▸' : '◂'}</button>
      </div>
      {ctxOpen && <ContextRail keeper={keeper} />}
    </React.Fragment>
  );
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [surface, setSurface] = useS('keepers');
  const [sel, setSel] = useS('masc-improver');
  const [keepers, setKeepers] = useS(KEEPERS);
  const [threads, setThreads] = useS(() => JSON.parse(JSON.stringify(THREADS)));
  const [typing, setTyping] = useS(false);
  const dock = useDock();

  const keeper = keepers.find(k => k.id === sel) || KEEPERS.find(k => k.id === sel);
  const openKeeper = (id) => { setSel(id); setSurface('keepers'); };
  const surfCtx = getSurfaceContext(surface, keepers, sel);

  // Sync configured/running keepers list on mount
  const syncKeepers = async () => {
    const shellData = await window.API.fetchDashboardShell();
    if (shellData && shellData.runtime_resolution) {
      const activeResolutions = shellData.runtime_resolution.keeper_runtime || [];
      
      setKeepers(prev => {
        return prev.map(k => {
          const matched = activeResolutions.find(r => r.name === k.id || r.keeper_name === k.id);
          if (matched) {
            // map runtime fields into UI roster properties
            const uptimeSec = matched.uptime_seconds || 0;
            const h = Math.floor(uptimeSec / 3600);
            const m = Math.floor((uptimeSec % 3600) / 60);
            const uptimeStr = h > 0 ? `${h}h ${m}m` : `${m}m`;
            
            return {
              ...k,
              status: matched.is_running ? 'run' : matched.is_paused ? 'pause' : 'off',
              phase: matched.phase || k.phase,
              runtime: matched.runtime_id || k.runtime,
              uptime: uptimeStr,
              last: '방금',
              model: matched.model || k.model,
              traces: matched.traces || k.traces,
              tasks: matched.tasks || k.tasks,
            };
          }
          return k;
        });
      });
    }
  };

  useEffect(() => {
    syncKeepers();
    // Set up polling for static status updates
    const timer = setInterval(syncKeepers, 5000);

    // Subscribe to SSE EventSource for real-time telemetry updates
    const disconnectSSE = window.API.connectDashboardSSE((event) => {
      console.debug('[SSE Event Received]', event);
      // Automatically refresh keepers on presence or state update events
      if (
        event.type === 'agent_bound' || 
        event.type === 'agent_unbound' || 
        event.type === 'task_update' ||
        event.type.startsWith('oas:')
      ) {
        syncKeepers();
      }
    });

    return () => {
      clearInterval(timer);
      disconnectSSE();
    };
  }, []);

  // Sync selected keeper's chat history on switch
  useEffect(() => {
    const loadHistory = async () => {
      const history = await window.API.fetchKeeperHistory(sel);
      if (history && history.length > 0) {
        setThreads(prev => ({ ...prev, [sel]: history }));
      }
    };
    loadHistory();
  }, [sel]);

  useEffect(() => {
    const onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'j' || e.key === 'J')) { e.preventDefault(); dock.toggle(); }
      else if (e.key === 'Escape' && dock.state.open) { dock.close(); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [dock.state.open]);

  const rosterOpen = t.rosterOpen !== false;
  const ctxOpen = t.ctxOpen !== false;
  const cols = surface === 'keepers'
    ? `58px ${rosterOpen ? '286px' : '64px'} minmax(0,1fr) ${ctxOpen ? '312px' : '0px'}`
    : '58px minmax(0,1fr)';

  return (
    <div className="v2-app" data-density={t.density} style={{ fontSize: (14 * t.fontScale) + 'px', '--thread-w': t.threadW + 'px' }}>
      <TopBar surface={surface} keeper={keeper} onToggleDock={dock.toggle} dockOpen={dock.state.open} />
      <div className="v2-stage">
        <div className="v2-body" style={{ gridTemplateColumns: cols }}>
          <NavRail active={surface} onNav={setSurface} />
          {surface === 'keepers' && (
            <KeepersSurface t={t} setTweak={setTweak} sel={sel} setSel={setSel} keepers={keepers}
              threads={threads} setThreads={setThreads} typing={typing} setTyping={setTyping} />
          )}
          {surface === 'overview' && <Overview keepers={keepers} onOpenKeeper={openKeeper} onNav={setSurface} />}
          {surface === 'board' && <BoardSurface />}
          {surface === 'cockpit' && <CockpitSurface onNav={setSurface} onOpenKeeper={openKeeper} />}
          {surface === 'ide' && <IdeSurface />}
          {surface === 'connectors' && <ConnectorsSurface />}
          {surface === 'settings' && <PlaceholderSurface surface="settings" />}
        </div>
        {dock.state.open && dock.state.mode === 'dock' && <CopilotDock dock={dock} ctx={surfCtx} docked />}
      </div>

      {dock.state.open && dock.state.mode === 'float' && <CopilotDock dock={dock} ctx={surfCtx} />}
      {!dock.state.open && (
        <button className="dock-fab" onClick={dock.open} title="Copilot (⌘J)">
          <span className="spark">{DOCK_SPARK}</span>Copilot<kbd>⌘J</kbd>
        </button>
      )}

      <TweaksPanel>
        <TweakSection label="브랜드 · Voltage" />
        <TweakRadio label="Voltage 컬러" value={t.volt} options={['brass', 'blood', 'ice']}
          onChange={(v) => { setTweak('volt', v); document.documentElement.setAttribute('data-volt', v); }} />
        <TweakSection label="레이아웃" />
        <TweakSlider label="대화 본문 폭" value={t.threadW} min={760} max={1320} step={20} unit="px" onChange={(v) => setTweak('threadW', v)} />
        <TweakToggle label="로스터 레일" value={rosterOpen} onChange={(v) => setTweak('rosterOpen', v)} />
        <TweakToggle label="컨텍스트 레일" value={ctxOpen} onChange={(v) => setTweak('ctxOpen', v)} />
        <TweakRadio label="밀도" value={t.density} options={['compact', 'regular']} onChange={(v) => setTweak('density', v)} />
        <TweakSection label="타이포" />
        <TweakSlider label="본문 배율" value={t.fontScale} min={0.9} max={1.2} step={0.05} unit="x" onChange={(v) => setTweak('fontScale', v)} />
      </TweaksPanel>
    </div>
  );
}

// keep data-volt in sync on load
document.documentElement.setAttribute('data-volt', TWEAK_DEFAULTS.volt);

ReactDOM.createRoot(document.getElementById('root')).render(<App />);

