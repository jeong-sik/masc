/* MASC v2 — App shell: nav routing, top bar, keeper chat, collapsible rails, tweaks */
const { useState: useS, useRef, useEffect } = React;

function useIsMobile(bp = 760) {
  const [m, setM] = useS(() => typeof window !== 'undefined' && window.matchMedia(`(max-width:${bp}px)`).matches);
  useEffect(() => {
    const mq = window.matchMedia(`(max-width:${bp}px)`);
    const on = () => setM(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, [bp]);
  return m;
}

// live token throughput — gently fluctuates while the keeper is streaming
function LiveTps({ keeper }) {
  const live = keeper.status === 'run';
  const [v, setV] = useS(keeper.tps);
  useEffect(() => {
    setV(keeper.tps);
    if (keeper.status !== 'run') return;
    const id = setInterval(() => {
      setV(() => Math.max(8, Math.round(keeper.tps + (Math.random() * 2 - 1) * keeper.tps * 0.16)));
    }, 1100);
    return () => clearInterval(id);
  }, [keeper.id, keeper.status, keeper.tps]);
  if (!live) return (
    <span title="현재 스트리밍 없음"><span className="sub-k">tok/s</span><span className="mono">—</span></span>
  );
  return (
    <span className="tps-live" title="실시간 토큰 생성 속도 (tokens/sec)">
      <span className="tps-dot"></span><span className="sub-k">tok/s</span><span className="mono">{v}</span>
    </span>
  );
}

const ICON = {
  grid: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><rect x="3" y="3" width="7" height="7" rx="1.4"/><rect x="14" y="3" width="7" height="7" rx="1.4"/><rect x="3" y="14" width="7" height="7" rx="1.4"/><rect x="14" y="14" width="7" height="7" rx="1.4"/></svg>),
  users: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c0-3 2.6-5 5.5-5s5.5 2 5.5 5"/><path d="M16.5 6.2a3 3 0 0 1 0 5.6"/><path d="M18.5 19c0-2-.8-3.6-2-4.6"/></svg>),
  board: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"><rect x="3" y="4" width="5" height="16" rx="1.2"/><rect x="10" y="4" width="5" height="11" rx="1.2"/><rect x="17" y="4" width="4" height="14" rx="1.2"/></svg>),
  term: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="2.2"/><path d="M7 9l3 3-3 3"/><path d="M13 15h4"/></svg>),
  code: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M8 6l-5 6 5 6"/><path d="M16 6l5 6-5 6"/><path d="M13.5 4l-3 16"/></svg>),
  plug: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M9 3v5M15 3v5"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/></svg>),
  gear: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.1 5.1l2.1 2.1M16.8 16.8l2.1 2.1M18.9 5.1l-2.1 2.1M7.2 16.8l-2.1 2.1"/></svg>),
  target: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4"/><circle cx="12" cy="12" r="0.6" fill="currentColor"/></svg>),
};

const SURFACES = [
  ['overview', '개요', ICON.grid],
  ['work', '작업', ICON.target],
  ['keepers', 'Keepers', ICON.users],
  ['board', '보드', ICON.board],
  ['ide', 'IDE', ICON.code],
  ['connectors', '커넥터', ICON.plug],
];

const SURFACE_LABEL = Object.fromEntries(SURFACES.map(([id, lbl]) => [id, lbl]));

function NavRail({ active, onNav }) {
  return (
    <nav className="v2-nav">
      <div className="nav-brand" title="MASC — Multi-Agent Streaming Coordination">
        <div className="nav-home">M</div>
        <span className="nlbl">MASC</span>
      </div>
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
  "density": "spacious",
  "motion": "subtle",
  "bubbleStyle": "card",
  "fontScale": 1,
  "threadW": 980,
  "rosterOpen": true,
  "ctxOpen": true
}/*EDITMODE-END*/;

function TopBar({ surface, keeper, onToggleDock, dockOpen }) {
  return (
    <div className="v2-top">
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

function KeeperConfig({ keeper, onClose, onNav }) {
  const base = (window.PERSONAS && PERSONAS[keeper.id]) || DEFAULT_PERSONA;
  const kb = (window.KEEPER_BASE || { system: '', world: '' });
  const fillKB = (s) => (s || '').replace(/\{\{keeper\}\}/g, keeper.id).replace(/\{\{namespace\}\}/g, keeper.ns).replace(/\{\{runtime\}\}/g, keeper.runtime).replace(/\{\{model\}\}/g, keeper.model);
  const kbLine = (s) => fillKB(s).split('\n').find(l => l.trim()) || '';

  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  // delegate the whole drawer to the shared organism (window.KVO5),
  // keeping the app's prompt-fill + nav glue here.
  return React.createElement(window.KVO5.KeeperConfigPanel, {
    asOverlay: true, onClose,
    keeper,
    base: { persona: base.persona, instructions: base.instructions, traits: base.traits },
    inherit: [
      { tag: '① System', txt: kbLine(kb.system) },
      { tag: '② World', txt: kbLine(kb.world) },
    ],
    permissions: { '읽기': true, '쓰기': true, 'git': keeper.id === 'nick0cave' || keeper.id === 'sangsu', '외부 호출': false },
    onPromptsLink: () => { window.__nextSettingsSec = 'prompts'; onClose(); onNav && onNav('settings'); },
  });
}

function ChatHeader({ keeper, mobile, onBack, onOpenCtx, onOpenConfig }) {
  const pillTone = keeper.status === 'run' ? 'ok' : keeper.status === 'pause' ? 'warn' : 'neutral';
  return (
    <div className={`chat-head ${mobile ? 'is-mobile' : ''}`}>
      {mobile && <button className="chat-back" onClick={onBack} title="Keeper 목록">{'\u25C2'}</button>}
      <Avatar k={keeper} baseClass="chat-av" size={mobile ? 38 : 46} />
      <div className="chat-id">
        <div className="name-row">
          <h2>{keeper.id}</h2>
          <Pill tone={pillTone} dot={pillTone === 'neutral' ? 'idle' : pillTone} dotPulse={keeper.status === 'run'} title={PHASE_INFO[keeper.phase] || keeper.phase}>{keeper.phase}</Pill>
        </div>
        <div className="sub">
          <span title="이 keeper의 작업 범위 — namespace. 도구·태스크가 묶이는 스코프"><span className="mono">{keeper.ns}</span></span>
          <LiveTps keeper={keeper} />
        </div>
      </div>
      <div className="chat-actions">
        {keeper.status === 'run'
          ? <button className="act" title="일시정지 (Paused) — 슈퍼바이저가 잠시 멈춤. 컨텍스트·소유 태스크 보존, 즉시 재개 가능">{'\u23F8'} 일시정지</button>
          : <button className="act" title="재개 (Running) — 일시정지된 keeper를 멈춘 지점부터 다시 실행">{'\u25B6'} 재개</button>}
        <button className="act" title="핸드오프 (HandingOff) — 소유 태스크를 다른 keeper에게 인계하고 이 세션은 정리. keeper는 떠나도 작업은 계속됨">핸드오프</button>
        <button className="act icon" title="keeper 설정 — 성격·지침·모델·도구 권한" onClick={() => onOpenConfig(keeper)}>{'\u2699'}</button>
        <button className="act icon danger" title="중지 (Drain → Stopped) — 작업을 비우고 keeper 종료. 재개 아님, 새로 시작해야 함">{'\u23F9'}</button>
      </div>
      {mobile && <button className="chat-ctx-btn" onClick={onOpenCtx} title="컨텍스트·주의 패널">{'\u24D8'}</button>}
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

// Composer moved to composer.jsx (multimodal input). window.Composer.

function KeepersSurface({ t, setTweak, sel, setSel, threads, setThreads, typing, setTyping, isMobile, mobilePane, setMobilePane, ctxDrawer, setCtxDrawer, onConfig }) {
  const threadRef = useRef(null);
  const keeper = KEEPERS.find(k => k.id === sel);
  const msgs = threads[sel] || [];
  const rosterOpen = t.rosterOpen !== false;
  const ctxOpen = t.ctxOpen !== false;

  useEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [sel, msgs.length, typing]);

  const pushUser = (input) => {
    const blocks = typeof input === 'string'
      ? [{ t: 'p', html: input.replace(/</g, '&lt;') }]
      : (input && input.blocks);
    if (!blocks || !blocks.length) return;
    const um = { id: 'u' + Date.now(), role: 'user', source: 'dashboard', ts: nowHM(), blocks };
    setThreads(prev => ({ ...prev, [sel]: [...(prev[sel] || []), um] }));
    setTyping(true);
    setTimeout(() => {
      setTyping(false);
      setThreads(prev => ({ ...prev, [sel]: [...(prev[sel] || []), CANNED_REPLY(keeper)] }));
    }, 1400);
  };

  const selectKeeper = (id) => { setSel(id); if (isMobile) setMobilePane('chat'); };

  const regenerate = (mid) => {
    setThreads(prev => ({ ...prev, [sel]: (prev[sel] || []).filter(x => x.id !== mid) }));
    setTyping(true);
    setTimeout(() => {
      setTyping(false);
      setThreads(prev => ({ ...prev, [sel]: [...(prev[sel] || []), { ...CANNED_REPLY(keeper), regen: true }] }));
    }, 1300);
  };

  return (
    <React.Fragment>
      <Roster keepers={KEEPERS} selected={sel} onSelect={selectKeeper} mini={!rosterOpen && !isMobile} onConfig={onConfig} />
      <div className="chat-wrap" data-screen-label="Keeper 대화">
        {!isMobile && <button className="rail-toggle left" title={rosterOpen ? '로스터 접기' : '로스터 펼치기'}
          onClick={() => setTweak('rosterOpen', !rosterOpen)}>{rosterOpen ? '◂' : '▸'}</button>}
        <main className="chat">
          <ChatHeader keeper={keeper} mobile={isMobile}
            onBack={() => setMobilePane('roster')}
            onOpenCtx={() => setCtxDrawer(true)}
            onOpenConfig={onConfig} />
          <div className="thread" ref={threadRef}>
            {msgs.length === 0
              ? <EmptyThread />
              : (
                <div className="thread-inner">
                  <div className="daydiv">오늘</div>
                  {msgs.map(m => <Message key={m.id} m={m} keeper={keeper} onPickSuggestion={pushUser} onRegenerate={() => regenerate(m.id)} />)}
                  {typing && <TypingMessage keeper={keeper} />}
                </div>
              )}
          </div>
          <Composer keeper={keeper} onSend={pushUser} />
        </main>
        {!isMobile && <button className="rail-toggle right" title={ctxOpen ? '컨텍스트 레일 접기' : '컨텍스트 레일 펼치기'}
          onClick={() => setTweak('ctxOpen', !ctxOpen)}>{ctxOpen ? '▸' : '◂'}</button>}
      </div>
      {!isMobile && ctxOpen && <ContextRail keeper={keeper} />}
      {isMobile && ctxDrawer && (
        <div className="ctx-overlay" onClick={() => setCtxDrawer(false)}>
          <div className="ctx-drawer" onClick={(e) => e.stopPropagation()}>
            <button className="ctx-drawer-close" onClick={() => setCtxDrawer(false)} title="닫기">{'\u2715'}</button>
            <ContextRail keeper={keeper} />
          </div>
        </div>
      )}
    </React.Fragment>
  );
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [surface, setSurface] = useS('keepers');
  const [sel, setSel] = useS('masc-improver');
  const [threads, setThreads] = useS(() => JSON.parse(JSON.stringify(THREADS)));
  const [typing, setTyping] = useS(false);
  const dock = useDock();
  const isMobile = useIsMobile();
  const [mobilePane, setMobilePane] = useS('roster'); // roster | chat
  const [ctxDrawer, setCtxDrawer] = useS(false);
  const [configKeeper, setConfigKeeper] = useS(null);

  const keeper = KEEPERS.find(k => k.id === sel);
  const navTo = (s) => { setSurface(s); if (s === 'keepers') setMobilePane('roster'); setCtxDrawer(false); };
  const openKeeper = (id) => { setSel(id); setSurface('keepers'); setMobilePane('chat'); };
  const surfCtx = getSurfaceContext(surface, KEEPERS, sel);

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
  const cols = isMobile
    ? '1fr'
    : surface === 'keepers'
      ? `58px ${rosterOpen ? '286px' : '64px'} minmax(0,1fr) ${ctxOpen ? '312px' : '0px'}`
      : '58px minmax(0,1fr)';
  const mpane = isMobile && surface === 'keepers' ? mobilePane : null;

  return (
    <div className="v2-app" data-density={t.density} data-motion={t.motion} data-bubble={t.bubbleStyle} data-mobile={isMobile ? '1' : null} style={{ fontSize: (14 * t.fontScale) + 'px', '--thread-w': t.threadW + 'px' }}>
      <TopBar surface={surface} keeper={keeper} onToggleDock={dock.toggle} dockOpen={dock.state.open} />
      <div className="v2-stage">
        <div className="v2-body" data-mpane={mpane} style={{ gridTemplateColumns: cols }}>
          <NavRail active={surface} onNav={navTo} />
          {surface === 'keepers' && (
            <KeepersSurface t={t} setTweak={setTweak} sel={sel} setSel={setSel}
              threads={threads} setThreads={setThreads} typing={typing} setTyping={setTyping}
              isMobile={isMobile} mobilePane={mobilePane} setMobilePane={setMobilePane}
              ctxDrawer={ctxDrawer} setCtxDrawer={setCtxDrawer} onConfig={setConfigKeeper} />
          )}
          {surface === 'overview' && <Overview keepers={KEEPERS} onOpenKeeper={openKeeper} onNav={navTo} />}
          {surface === 'work' && <WorkSurface onOpenKeeper={openKeeper} onNav={navTo} />}
          {surface === 'board' && <BoardSurface />}
          {surface === 'ide' && <IdeSurface />}
          {surface === 'connectors' && <ConnectorsSurface onNav={navTo} />}
          {surface === 'settings' && <SettingsSurface onNav={navTo} />}
        </div>
        {dock.state.open && dock.state.mode === 'dock' && <CopilotDock dock={dock} ctx={surfCtx} docked />}
      </div>

      {dock.state.open && dock.state.mode === 'float' && <CopilotDock dock={dock} ctx={surfCtx} />}
      {!dock.state.open && (
        <button className="dock-fab" onClick={dock.open} title="Copilot (⌘J)">
          <span className="spark">{DOCK_SPARK}</span>Copilot<kbd>⌘J</kbd>
        </button>
      )}

      {configKeeper && <KeeperConfig keeper={configKeeper} onClose={() => setConfigKeeper(null)} onNav={navTo} />}

      <TweaksPanel>
        <TweakSection label="만듦새 · 기본 3축" />
        <TweakRadio label="밀도" value={t.density}
          options={[{ value: 'spacious', label: '여유' }, { value: 'regular', label: '균형' }, { value: 'compact', label: '압축' }]}
          onChange={(v) => setTweak('density', v)} />
        <TweakRadio label="모션" value={t.motion}
          options={[{ value: 'lively', label: '생동' }, { value: 'subtle', label: '절제' }, { value: 'off', label: '끕' }]}
          onChange={(v) => setTweak('motion', v)} />
        <TweakRadio label="메시지" value={t.bubbleStyle}
          options={[{ value: 'card', label: '카드' }, { value: 'flat', label: '플랫' }]}
          onChange={(v) => setTweak('bubbleStyle', v)} />
        <TweakSection label="브랜드 · Voltage" />
        <TweakRadio label="Voltage 컬러" value={t.volt} options={['brass', 'blood', 'ice']}
          onChange={(v) => { setTweak('volt', v); document.documentElement.setAttribute('data-volt', v); }} />
        <TweakSection label="레이아웃" />
        <TweakSlider label="대화 본문 폭" value={t.threadW} min={760} max={1320} step={20} unit="px" onChange={(v) => setTweak('threadW', v)} />
        <TweakToggle label="로스터 레일" value={rosterOpen} onChange={(v) => setTweak('rosterOpen', v)} />
        <TweakToggle label="컨텍스트 레일" value={ctxOpen} onChange={(v) => setTweak('ctxOpen', v)} />
        <TweakSection label="타이포" />
        <TweakSlider label="본문 배율" value={t.fontScale} min={0.9} max={1.2} step={0.05} unit="x" onChange={(v) => setTweak('fontScale', v)} />
      </TweaksPanel>
    </div>
  );
}

// keep data-volt in sync on load
document.documentElement.setAttribute('data-volt', TWEAK_DEFAULTS.volt);

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
