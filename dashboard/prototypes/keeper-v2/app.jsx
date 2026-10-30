/* MASC v2 — App root: state, routing, lifecycle FSM, dock + tweaks.
   Chrome (NavRail/TopBar/ChatHeader/…) lives in shell.jsx; the Keepers
   surface lives in keepers.jsx. This file just composes them. */
const { useState: useS, useRef, useEffect } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "volt": "brass",
  "theme": "dark",
  "density": "spacious",
  "motion": "subtle",
  "bubbleStyle": "card",
  "fontScale": 1,
  "threadW": 980,
  "rosterOpen": true,
  "ctxOpen": true,
  "rosterW": 286,
  "ctxW": 312
}/*EDITMODE-END*/;

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  // re-apply persisted brand attrs on mount (defaults set pre-React in the inline script)
  useEffect(() => {
    document.documentElement.setAttribute('data-volt', t.volt);
    document.documentElement.setAttribute('data-theme', t.theme === 'paper' ? 'paper' : '');
  }, [t.volt, t.theme]);
  // deep-link: Keeper Fleet (and other surfaces) link in via ?keeper=<id>
  const deep = (() => {
    try {
      const id = new URLSearchParams(window.location.search).get('keeper');
      if (id && KEEPERS.some(k => k.id === id)) return id;
    } catch (e) {}
    return null;
  })();
  const deepSurface = (() => {
    try {
      const s = new URLSearchParams(window.location.search).get('surface');
      if (s && SURFACES.some(x => x[0] === s && !x[3])) return s;
    } catch (e) {}
    return null;
  })();
  const [surface, setSurface] = useS(deep ? 'keepers' : (deepSurface || 'keepers'));
  const [sel, setSel] = useS(deep || 'masc-improver');
  const [threads, setThreads] = useS(() => JSON.parse(JSON.stringify(THREADS)));
  const [keepers, setKeepers] = useS(() => KEEPERS.map(k => ({ ...k })));
  const [typing, setTyping] = useS(false);
  const fsmTimers = useRef({});
  const dock = useDock();
  const isMobile = useIsMobile();
  const vw = useViewportW();
  const [mobilePane, setMobilePane] = useS(deep ? 'chat' : 'roster'); // roster | chat
  const [ctxDrawer, setCtxDrawer] = useS(false);
  const [configKeeper, setConfigKeeper] = useS(null);
  const [apprStatus, setApprStatus] = useS({}); // approval id → 'approved'|'denied'|'deferred'|'open'
  const [schedStatus, setSchedStatus] = useS({}); // schedule_id → overlay { status, grant|rejected|cancelled }
  const [paletteOpen, setPaletteOpen] = useS(false);
  const [fusionWant, setFusionWant] = useS(null);
  const [workWant, setWorkWant] = useS(null);
  const [keeperOrigin, setKeeperOrigin] = useS(null);
  const openApprovals = (window.APPROVALS || []).filter(a => (apprStatus[a.id] || 'open') === 'open').length;  // schedule (lib/schedule) — operator acts on keeper-scheduled automation
  const schedSum = window.schedSummary ? window.schedSummary(schedStatus) : { pending: 0, due: 0, scheduled: 0, running: 0, total: 0 };
  const onSchedule = (id, action, reason) => {
    const at = window.nowHM ? window.nowHM() : '';
    setSchedStatus(prev => {
      const n = { ...prev };
      if (action === 'approve') n[id] = { status: 'Scheduled', grant: { by: 'operator', at } };
      else if (action === 'reject') n[id] = { status: 'Rejected', rejected: { by: 'operator', at, reason: reason || '사유 없음' } };
      else if (action === 'cancel') n[id] = { status: 'Cancelled', cancelled: { by: 'operator', at } };
      return n;
    });
    if (window.pushToast) {
      const lbl = action === 'approve' ? '승인 — grant 발급' : action === 'reject' ? '거부' : '취소';
      const tone = action === 'approve' ? 'ok' : action === 'reject' ? 'bad' : 'warn';
      window.pushToast({ tone, msg: `예약 ${lbl}`, sub: id });
    }
  };

  const resolveApproval = (id, status) => {
    setApprStatus(prev => {
      const n = { ...prev };
      if (status === 'open') delete n[id]; else n[id] = status;
      return n;
    });
    if (status !== 'open' && window.pushToast) {
      const a = (window.APPROVALS || []).find(x => x.id === id);
      const lbl = status === 'approved' ? '승인' : status === 'denied' ? '거부' : '보류';
      const tone = status === 'approved' ? 'ok' : status === 'denied' ? 'bad' : 'warn';
      const ORIGIN_LBL = { discord: 'Discord', slack: 'Slack', telegram: 'Telegram', imessage: 'iMessage', dashboard: '대시보드' };
      // RFC-0320 — resolving a HITL wakes the keeper on its originating connector
      const resume = (status !== 'deferred' && a && a.origin && a.origin !== 'dashboard') ? ` · ↩ ${a.keeper} ${ORIGIN_LBL[a.origin]}에서 재개` : '';
      window.pushToast({ tone, assertive: status === 'denied', msg: `${lbl}됨 · ${a ? a.title : id}`, sub: (a ? `${a.keeper} · ${a.id}` : id) + resume, undo: () => resolveApproval(id, 'open') });
    }
  };

  // aggregate "지금 나를 필요로 하는 것" for the persistent topbar indicator
  const attention = {
    approvals: openApprovals,
    keepers: keepers.filter(k => k.att > 0).length,
    stale: (window.CONNECTORS || []).filter(c => c.stale).length,
    dead: keepers.filter(k => ['Overflowed', 'Crashed', 'Dead'].includes(k.phase)).length,
  };
  attention.total = attention.approvals + attention.keepers + attention.stale + attention.dead;

  const keeper = keepers.find(k => k.id === sel);
  // operator-issued lifecycle transition. `act` from FSM_ACTIONS[phase].
  // A `via` action shows a transient phase, then auto-advances to `to`.
  const keeperAction = (id, act) => {
    if (!act) return;
    const setPhase = (phase) => setKeepers(prev => prev.map(k => k.id === id ? { ...k, phase, status: phaseStatus(phase) } : k));
    if (act.via) {
      setPhase(act.via);
      clearTimeout(fsmTimers.current[id]);
      fsmTimers.current[id] = setTimeout(() => setPhase(act.to), act.ms || 1500);
    } else {
      setPhase(act.to);
    }
    if (window.pushToast) window.pushToast({ tone: act.danger ? 'warn' : 'info', msg: `${id} · ${act.label || act.to}`, sub: `→ ${act.to}` });
    // route consequential transitions through the alarm engine (respects Notify settings)
    if (window.fireAlarm) {
      if (['Overflowed', 'Crashed', 'Dead'].includes(act.to)) {
        window.fireAlarm('keeper crash/dead', { tone: 'bad', assertive: true, msg: `${id} · ${act.to}`, sub: '복구 조치 필요' });
      } else if (act.to === 'Stopped' && act.via === 'HandingOff') {
        window.fireAlarm('핸드오프 완료', { tone: 'ok', msg: `${id} 핸드오프 완료`, sub: '소유 태스크 인계됨' });
      }
    }
  };
  const navTo = (s) => { setSurface(s); if (s === 'keepers') setMobilePane('roster'); setCtxDrawer(false); };
  const navFusion = (runId) => { setFusionWant(runId); setSurface('fusion'); setCtxDrawer(false); };
  const navWork = (goalId) => { setWorkWant(goalId ? { id: goalId, at: Date.now() } : null); setSurface('work'); setCtxDrawer(false); };
  useEffect(() => { window.__navFusion = navFusion; window.__navWork = navWork; }, []);
  const openKeeper = (id) => { if (!keepers.some(k => k.id === id)) return; setKeeperOrigin(surface !== 'keepers' ? surface : null); setSel(id); setSurface('keepers'); setMobilePane('chat'); };
  const backToOrigin = () => { const o = keeperOrigin; setKeeperOrigin(null); if (o) navTo(o); };

  useEffect(() => {
    const onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'j' || e.key === 'J')) { e.preventDefault(); dock.toggle(); }
      else if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) { e.preventDefault(); setPaletteOpen(o => !o); }
      else if (e.key === 'Escape' && dock.state.open) { dock.close(); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [dock.state.open]);
  const surfCtx = getSurfaceContext(surface, keepers, sel);

  const rosterOpen = t.rosterOpen !== false;
  const ctxOpen = t.ctxOpen !== false;
  // Below 1180px the context rail folds into a drawer so the chat keeps room;
  // the roster also yields if the rails would squeeze the chat under MIN_CHAT
  // (e.g. after the user has dragged the rails wider on a smaller screen).
  const compactCtx = !isMobile && vw <= 1180;
  const ctxTrack = (!isMobile && !compactCtx && ctxOpen) ? (t.ctxW || 312) : 0;
  const MIN_CHAT = 400;
  let rosterTrack = rosterOpen ? (t.rosterW || 286) : 64;
  if (!isMobile && rosterOpen) {
    const maxRoster = vw - 58 - ctxTrack - MIN_CHAT;
    if (rosterTrack > maxRoster) rosterTrack = Math.max(200, maxRoster);
  }
  const cols = isMobile
    ? '1fr'
    : surface === 'keepers'
      ? `58px ${rosterOpen ? rosterTrack + 'px' : '64px'} minmax(0,1fr)${compactCtx ? '' : ` ${ctxTrack}px`}`
      : '58px minmax(0,1fr)';
  const mpane = isMobile && surface === 'keepers' ? mobilePane : null;

  return (
    <div className="v2-app" data-surface={surface} data-density={t.density} data-motion={t.motion} data-bubble={t.bubbleStyle} data-mobile={isMobile ? '1' : null} data-reading={isMobile && surface === 'keepers' && mobilePane === 'chat' ? '1' : null} style={{ fontSize: (15 * t.fontScale) + 'px', '--thread-w': t.threadW + 'px' }}>
      <TopBar surface={surface} keeper={keeper} onToggleDock={dock.toggle} dockOpen={dock.state.open} openApprovals={openApprovals} attention={attention} onNav={navTo} sched={schedSum} />
      <div className="v2-stage">
        <div className="v2-body" data-mpane={mpane} style={{ gridTemplateColumns: cols }}>
          <NavRail active={surface} onNav={navTo} badges={{ approvals: openApprovals, schedule: schedSum.pending }} live={{ keepers: keepers.filter(k => k.status === 'run').length, fusion: (window.FUSION_RUNS || []).filter(r => r.status === 'running').length }} mobile={isMobile} />
          {surface === 'keepers' && (
            <KeepersSurface t={t} setTweak={setTweak} sel={sel} setSel={setSel}
              keepers={keepers} onAction={keeperAction}
              threads={threads} setThreads={setThreads} typing={typing} setTyping={setTyping}
              isMobile={isMobile} mobilePane={mobilePane} setMobilePane={setMobilePane}
              ctxDrawer={ctxDrawer} setCtxDrawer={setCtxDrawer} onConfig={setConfigKeeper} drawerCtx={compactCtx}
              backTo={keeperOrigin} onBackTo={backToOrigin} onNav={navTo} apprStatus={apprStatus} />
          )}
          {surface === 'overview' && <Overview keepers={keepers} onOpenKeeper={openKeeper} onNav={navTo} />}
          {surface === 'registry' && <RegistrySurface onNav={navTo} />}
          {surface === 'work' && <WorkSurface onOpenKeeper={openKeeper} onNav={navTo} wantGoal={workWant} />}
          {surface === 'approvals' && <ApprovalsSurface statusMap={apprStatus} onResolve={resolveApproval} onOpenKeeper={openKeeper} onNav={navTo} />}          {surface === 'schedule' && <ScheduleSurface statusMap={schedStatus} onSchedule={onSchedule} onOpenKeeper={openKeeper} onNav={navTo} />}
          {surface === 'board' && <BoardSurface onOpenKeeper={openKeeper} />}
          {surface === 'fusion' && <FusionSurface onOpenKeeper={openKeeper} onNav={navTo} wantRun={fusionWant} />}
          {surface === 'ide' && <IdeSurface />}
          {surface === 'monitor' && <FleetSurface />}
          {surface === 'command' && window.CommandSurface && <window.CommandSurface onNav={navTo} openApprovals={openApprovals} />}
          {surface === 'lab' && window.LabSurface && <window.LabSurface />}
          {surface === 'logs' && <LogsSurface onNav={navTo} />}
          {surface === 'connectors' && <ConnectorsSurface onNav={navTo} onOpenKeeper={openKeeper} />}
          {surface === 'settings' && <SettingsSurface onNav={navTo} />}
        </div>
        {dock.state.open && dock.state.mode === 'dock' && <CopilotDock dock={dock} ctx={surfCtx} docked />}
      </div>

      {dock.state.open && dock.state.mode === 'float' && <CopilotDock dock={dock} ctx={surfCtx} />}
      {!dock.state.open && (
        <button className="dock-fab" onClick={dock.open} title="Chat (⌘J)">
          <span className="spark">{DOCK_SPARK}</span>Chat<kbd>⌘J</kbd>
        </button>
      )}

      {configKeeper && <KeeperConfig keeper={configKeeper} onClose={() => setConfigKeeper(null)} onNav={navTo} />}

      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)}
        keepers={keepers} onNav={navTo} onOpenKeeper={openKeeper}
        onToggleDock={dock.toggle} openApprovals={openApprovals} apprStatus={apprStatus} />

      <ToastHost />
      {window.AlarmEngine ? <AlarmEngine /> : null}

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
        <TweakRadio label="테마" value={t.theme}
          options={[{ value: 'dark', label: '다크' }, { value: 'paper', label: '페이퍼' }]}
          onChange={(v) => { setTweak('theme', v); document.documentElement.setAttribute('data-theme', v === 'paper' ? 'paper' : ''); }} />
        <TweakRadio label="Voltage 컬러" value={t.volt} options={['brass', 'blood', 'ice']}
          onChange={(v) => { setTweak('volt', v); document.documentElement.setAttribute('data-volt', v); }} />
        <TweakSection label="레이아웃" />
        <TweakSlider label="대화 본문 폭" value={t.threadW} min={760} max={1320} step={20} unit="px" onChange={(v) => setTweak('threadW', v)} />
        <TweakToggle label="로스터 레일" value={rosterOpen} onChange={(v) => setTweak('rosterOpen', v)} />
        <TweakToggle label="컨텍스트 레일" value={ctxOpen} onChange={(v) => setTweak('ctxOpen', v)} />
        <TweakSection label="타이포" />
        <TweakSlider label="가독성 · 본문 배율" value={t.fontScale} min={0.9} max={1.4} step={0.05} unit="x" onChange={(v) => setTweak('fontScale', v)} />
      </TweaksPanel>
    </div>
  );
}

// keep data-volt in sync on load
document.documentElement.setAttribute('data-volt', TWEAK_DEFAULTS.volt);
document.documentElement.setAttribute('data-theme', TWEAK_DEFAULTS.theme === 'paper' ? 'paper' : '');

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
