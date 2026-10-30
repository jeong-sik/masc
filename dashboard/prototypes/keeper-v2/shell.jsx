// @ds-adherence-ignore -- v2 skin app chrome: nav rail, top bar, chat header, live throughput
/* ══════════════════════════════════════════════════════════════
   MASC v2 — App shell chrome
   The frame around every surface — extracted out of app.jsx so the
   root stays a thin composer. Everything here is bespoke to the v2
   shell (NOT the generic catalog molecules): the real NavRail/TopBar/
   ChatHeader the app actually renders.

     · useIsMobile      — ≤bp matchMedia hook
     · LiveTps          — streaming tok/s readout in the chat header
     · ICON / SURFACES  — nav icon set + surface registry (+ SURFACE_LABEL)
     · NavRail          — left surface rail
     · TopBar           — breadcrumb + live stat chips + Copilot toggle
     · ChatHeader       — keeper identity, FSM action buttons, mobile overflow
     · EmptyThread      — zero-state for an unstarted thread

   Top-level fn/var decls become globals (babel classic-script), so
   app.jsx references these bare — same contract as the rest of the tree.
   Load AFTER messages.jsx (StatusDot/Avatar), primitives (Pill), data.jsx
   (PHASE_x / FSM_ACTIONS) and dock.jsx (DOCK_SPARK); BEFORE app.jsx.
   ══════════════════════════════════════════════════════════════ */

const { useState: useShS, useEffect: useShEffect } = React;

// reactive viewport width (rAF-throttled) — drives the rail-yielding logic
function useViewportW() {
  const [w, setW] = useShS(() => typeof window !== 'undefined' ? window.innerWidth : 1440);
  useShEffect(() => {
    let raf = 0;
    const on = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(() => setW(window.innerWidth)); };
    window.addEventListener('resize', on);
    return () => { window.removeEventListener('resize', on); cancelAnimationFrame(raf); };
  }, []);
  return w;
}

function useIsMobile(bp = 900) {
  const [m, setM] = useShS(() => typeof window !== 'undefined' && window.matchMedia(`(max-width:${bp}px)`).matches);
  useShEffect(() => {
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
  const [v, setV] = useShS(keeper.tps);
  useShEffect(() => {
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
  shield: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3l7 3v5.5c0 4.3-3 7.3-7 8.5-4-1.2-7-4.2-7-8.5V6z"/><path d="M9.2 12l2 2 3.6-3.8"/></svg>),
  target: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4"/><circle cx="12" cy="12" r="0.6" fill="currentColor"/></svg>),
  monitor: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M3 12h3.5l2-6 4 13 2.2-7H21"/></svg>),
  logs: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M4 6h10M4 10h16M4 14h13M4 18h9"/></svg>),
  fusion: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="4.5" cy="5" r="1.7"/><circle cx="4.5" cy="12" r="1.7"/><circle cx="4.5" cy="19" r="1.7"/><path d="M6.2 5.4 11 11M6.2 12H11M6.2 18.6 11 13"/><circle cx="12.9" cy="12" r="2"/><path d="M14.9 12H19.5"/><circle cx="20" cy="12" r="1.6" fill="currentColor"/></svg>),
  clock: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>),
  layers: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3l8 4.2-8 4.2-8-4.2z"/><path d="M4 12l8 4.2 8-4.2"/><path d="M4 16.6l8 4.2 8-4.2"/></svg>),
  flask: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M9 3h6"/><path d="M10 3v5.2L5.4 17.2A2 2 0 0 0 7.2 20h9.6a2 2 0 0 0 1.8-2.8L14 8.2V3"/><path d="M7.4 14h9.2"/></svg>),
};

const SURFACES = [
  ['overview', '개요', ICON.grid],
  ['sep'],
  ['keepers', 'Keepers', ICON.users],
  ['registry', '레지스트리', ICON.layers],
  ['monitor', 'Monitor', ICON.monitor],
  ['sep'],
  ['work', '작업', ICON.target],
  ['approvals', 'Gate', ICON.shield],
  ['schedule', '예약', ICON.clock],
  ['sep'],
  ['board', '보드', ICON.board],
  ['fusion', 'Fusion', ICON.fusion],
  ['logs', '로그', ICON.logs],
  ['sep'],
  ['ide', 'IDE', ICON.code],
  ['connectors', '커넥터', ICON.plug],
  ['sep'],
  ['command', '명령', ICON.term],
  ['lab', 'Lab', ICON.flask],
];

const SURFACE_LABEL = Object.fromEntries(SURFACES.filter(s => s[0] !== 'sep').map(([id, lbl]) => [id, lbl]));

// On phones the rail collapses to a 5-slot bottom tab bar. The operator's
// daily loop (home / agents / work / approvals) gets first-class tabs; the
// rest live behind a 더보기 sheet so no tab drops below the 44px hit target.
const MOBILE_PRIMARY = ['overview', 'keepers', 'work', 'approvals'];
const ICON_MORE = (<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>);

function NavRail({ active, onNav, badges, live, mobile }) {
  const [moreOpen, setMoreOpen] = useShS(false);
  useShEffect(() => { setMoreOpen(false); }, [active]);

  if (mobile) {
    const byId = Object.fromEntries(SURFACES.filter(s => s[0] !== 'sep').map(s => [s[0], s]));
    const primary = MOBILE_PRIMARY.map(id => byId[id]).filter(Boolean);
    const hidden = SURFACES.filter(s => s[0] !== 'sep' && !MOBILE_PRIMARY.includes(s[0]));
    const moreActive = !MOBILE_PRIMARY.includes(active); // settings + every hidden surface
    const hiddenBadge = hidden.reduce((n, s) => n + ((badges && badges[s[0]]) || 0), 0);
    const Tab = (s) => {
      const [id, lbl, ic] = s;
      const badge = badges && badges[id];
      const liveN = live && live[id];
      return (
        <button key={id} className={`nav-item ${active === id ? 'on' : ''}`} onClick={() => onNav(id)} title={lbl}>
          {ic}<span className="nlbl">{lbl}</span>
          {badge ? <span className="nav-badge">{badge}</span> : null}
          {liveN ? <span className="nav-live" title={`${liveN}${id === 'fusion' ? '건 심의 진행 중' : '개 스트리밍 중'}`}></span> : null}
        </button>
      );
    };
    return (
      <React.Fragment>
        <nav className="v2-nav is-mnav">
          {primary.map(Tab)}
          <button className={`nav-item ${moreActive ? 'on' : ''}`} title="더보기" onClick={(e) => { e.stopPropagation(); setMoreOpen(o => !o); }}>
            {ICON_MORE}<span className="nlbl">더보기</span>
            {hiddenBadge ? <span className="nav-badge">{hiddenBadge}</span> : null}
          </button>
        </nav>
        {moreOpen && (
          <div className="mnav-back" onClick={() => setMoreOpen(false)}>
            <div className="mnav-sheet" onClick={(e) => e.stopPropagation()}>
              <div className="mnav-grip"></div>
              <div className="mnav-sheet-h">더보기</div>
              <div className="mnav-grid">
                {hidden.map(([id, lbl, ic]) => {
                  const badge = badges && badges[id];
                  return (
                    <button key={id} className={`mnav-tile ${active === id ? 'on' : ''}`} onClick={() => { onNav(id); setMoreOpen(false); }}>
                      <span className="mnav-ic">{ic}</span>
                      <span className="mnav-lbl">{lbl}</span>
                      {badge ? <span className="nav-badge">{badge}</span> : null}
                    </button>
                  );
                })}
                <button className={`mnav-tile ${active === 'settings' ? 'on' : ''}`} onClick={() => { onNav('settings'); setMoreOpen(false); }}>
                  <span className="mnav-ic">{ICON.gear}</span>
                  <span className="mnav-lbl">설정</span>
                </button>
              </div>
            </div>
          </div>
        )}
      </React.Fragment>
    );
  }

  return (
    <nav className="v2-nav">
      <div className="nav-brand" role="button" tabIndex={0} title="MASC · 개요(홈)로" style={{ cursor: 'pointer' }} onClick={() => onNav('overview')}>
        <div className="nav-home">M</div>
        <span className="nlbl">MASC</span>
      </div>
      {SURFACES.map(([id, lbl, ic, href], i) => {
        if (id === 'sep') return <div key={'sep' + i} className="nav-div"></div>;
        const badge = badges && badges[id];
        const liveN = live && live[id];
        return href
          ? <a key={id} className="nav-item" href={href} title={lbl}>{ic}<span className="nlbl">{lbl}</span></a>
          : <button key={id} className={`nav-item ${active === id ? 'on' : ''}`} onClick={() => onNav(id)} title={liveN ? `${lbl} · ${liveN}${id === 'fusion' ? '건 심의 진행 중' : '개 스트리밍 중'}` : lbl}>
              {ic}<span className="nlbl">{lbl}</span>
              {badge ? <span className="nav-badge">{badge}</span> : null}
              {liveN ? <span className="nav-live"></span> : null}
            </button>;
      })}
      <div className="nav-spacer"></div>
      <button className={`nav-item ${active === 'settings' ? 'on' : ''}`} title="설정" onClick={() => onNav('settings')}>{ICON.gear}<span className="nlbl">설정</span></button>
    </nav>
  );
}

function AttentionIndicator({ attention, onNav }) {
  const [open, setOpen] = useShS(false);
  useShEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    window.addEventListener('click', close);
    return () => window.removeEventListener('click', close);
  }, [open]);
  const a = attention || { total: 0 };
  const rows = [
    { k: 'approvals', n: a.approvals, lbl: 'Gate 대기', sev: 'bad', nav: 'approvals' },
    { k: 'keepers', n: a.keepers, lbl: '주의 keeper', sev: 'warn', nav: 'monitor' },
    { k: 'dead', n: a.dead, lbl: '죽음·넘침', sev: 'bad', nav: 'monitor' },
    { k: 'stale', n: a.stale, lbl: 'stale 게이트', sev: 'warn', nav: 'connectors' },
  ].filter(r => r.n > 0);
  if (!a.total) {
    return <span className="v2-statchip live" title="처리할 항목 없음">{'\u2713'} 정상</span>;
  }
  const tone = a.approvals > 0 || a.dead > 0 ? 'bad' : 'warn';
  return (
    <div className="attn-wrap" onClick={(e) => e.stopPropagation()}>
      <button className={`v2-statchip attn ${tone}`} onClick={() => setOpen(o => !o)} title="지금 나를 필요로 하는 것">
        {'\u2691'} 주의 <b>{a.total}</b>
      </button>
      {open && (
        <div className="attn-menu">
          <div className="attn-menu-h">지금 나를 필요로 하는 것</div>
          {rows.map(r => (
            <button key={r.k} className="attn-row" onClick={() => { setOpen(false); onNav && onNav(r.nav); }}>
              <span className={`dot2 ${r.sev}`}></span>
              <span className="attn-row-lbl">{r.lbl}</span>
              <span className="attn-row-n mono">{r.n}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function TopBar({ surface, keeper, onToggleDock, dockOpen, openApprovals, attention, onNav, sched }) {
  const s = sched || { pending: 0, due: 0, total: 0 };
  const schedWarn = s.pending > 0 || s.due > 0;
  return (
    <div className="v2-top">
      <div className="crumb">
        <span className={surface === 'keepers' ? '' : 'on'}>{SURFACE_LABEL[surface] || '설정'}</span>
        {surface === 'keepers' && <React.Fragment><span>/</span><span className="on">{keeper.id}</span></React.Fragment>}
      </div>
      <div className="v2-top-spacer"></div>
      <span className="v2-statchip live"><StatusDot status="run" pulse />4 실행 중</span>
      <AttentionIndicator attention={attention} onNav={onNav} />
      <button className={`v2-statchip attn ${schedWarn ? 'warn' : ''}`} onClick={() => onNav('schedule')} title="예약 자동화 큐 — keeper 예약 · operator 승인 (lib/schedule)">
        {'\u25F7'} 예약 {s.pending > 0 ? <b>승인 {s.pending}</b> : s.due > 0 ? <b>due {s.due}</b> : <b>정상</b>}
      </button>
      <button className={`topbar-copilot ${dockOpen ? 'on' : ''}`} onClick={onToggleDock} title="Chat 열기/닫기 (⌘J)">
        <span className="spark">{DOCK_SPARK}</span>Chat<kbd>⌘J</kbd>
      </button>
    </div>
  );
}

function ChatHeader({ keeper, mobile, onBack, onOpenCtx, onOpenConfig, onAction }) {
  const [ovf, setOvf] = useShS(false);
  const tone = PHASE_TONE[keeper.phase] || 'idle';
  const pulse = !!PHASE_PULSE[keeper.phase];
  const pillTone = tone === 'idle' ? 'neutral' : tone === 'busy' ? 'warn' : tone; // ok | warn | bad | neutral
  const actions = (window.FSM_ACTIONS && FSM_ACTIONS[keeper.phase]) || [];
  useShEffect(() => { setOvf(false); }, [keeper.id, keeper.phase]);
  useShEffect(() => {
    if (!ovf) return;
    const close = () => setOvf(false);
    window.addEventListener('click', close);
    return () => window.removeEventListener('click', close);
  }, [ovf]);
  const fire = (a) => { onAction && onAction(keeper.id, a); };
  return (
    <div className={`chat-head ${mobile ? 'is-mobile' : ''}`}>
      {mobile && <button className="chat-back" onClick={onBack} title="Keeper 목록">{'\u25C2'}</button>}
      <Avatar k={keeper} baseClass="chat-av" size={mobile ? 38 : 40} />
      <div className="chat-id">
        <div className="name-row">
          <h2>{keeper.id}</h2>
          <Pill tone={pillTone} dot={pillTone === 'neutral' ? 'idle' : pillTone} dotPulse={pulse} title={PHASE_INFO[keeper.phase] || keeper.phase}>{keeper.phase}</Pill>
        </div>
      </div>
      {!mobile && (
        <div className="chat-actions">
          {actions.map(a => (
            <button key={a.id} className={`act icon ${a.danger ? 'danger' : ''}`} title={`${a.label} — ${a.hint}`} onClick={() => fire(a)}>{a.glyph}</button>
          ))}
          {actions.length === 0 && <span className="act-quiet" title={PHASE_INFO[keeper.phase]}>{keeper.phase === 'Dead' ? '복구 불가' : '전이 중…'}</span>}
          <button className="act icon" title="keeper 설정 — 성격·지침·모델·도구 권한" onClick={() => onOpenConfig(keeper)}>{'\u2699'}</button>
        </div>
      )}
      {mobile && (
        <div className="chat-head-mob">
          <button className="chat-ovf" title="keeper 명령" onClick={(e) => { e.stopPropagation(); setOvf(o => !o); }}>{'\u22EF'}</button>
          <button className="chat-ctx-btn" onClick={onOpenCtx} title="컨텍스트·주의 패널">{'\u24D8'}</button>
          {ovf && (
            <div className="chat-ovf-menu" onClick={(e) => e.stopPropagation()}>
              {actions.map(a => (
                <button key={a.id} className={`kp-menu-i ${a.danger ? 'danger' : ''}`} onClick={() => { fire(a); setOvf(false); }}>{a.glyph} {a.label}</button>
              ))}
              {actions.length === 0 && <div className="kp-menu-note">{keeper.phase === 'Dead' ? '복구 불가 — 명령 없음' : '전이 중 — 잠시 후 가능'}</div>}
              <div className="kp-menu-sep"></div>
              <button className="kp-menu-i" onClick={() => { onOpenConfig(keeper); setOvf(false); }}>{'\u2699'} keeper 설정</button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function EmptyThread() {
  return (
    <div className="empty2">
      <div className="ico">{'\u25C8'}</div>
      <h3>대화를 시작하세요</h3>
      <div style={{ maxWidth: '320px', fontSize: '13px', lineHeight: 1.6 }}>
        질문하거나 작업을 위임하세요 — 도구 호출과 trace가 여기 기록됩니다.
      </div>
    </div>
  );
}
