/* MASC v2 — Cockpit surface: Command Map (5 planes) + pocket-world visualizer + cognitive modes */
const { useState: useCpState, useMemo: useCpMemo } = React;

const CP_ICON = {
  work: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="12" r="2.5"/><path d="M6 8.5v7M8.4 6.6L15.6 11M8.4 17.4L15.6 13"/></svg>),
  comms: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5c0 4.1-4 7.5-9 7.5-1.2 0-2.4-.2-3.4-.6L3 20l1.6-3.8C3.6 14.9 3 13.3 3 11.5 3 7.4 7 4 12 4s9 3.4 9 7.5z"/></svg>),
  observe: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M2 12h4l3-8 4 16 3-8h6"/></svg>),
  cognition: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M12 4a5 5 0 0 1 5 5c0 1.2-.4 2.2-1 3l1.5 6-3.5-1.5A7 7 0 0 1 12 17a5 5 0 1 1 0-13z"/><path d="M9.5 9.5h.01M12.5 9.5h.01"/></svg>),
  ide: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M8 6l-5 6 5 6M16 6l5 6-5 6M13 4l-2 16"/></svg>),
};

/* deterministic pocket-world: keepers on concentric rings by status */
function worldPos(k, i, n) {
  const ring = k.status === 'run' ? 0.36 : k.status === 'pause' ? 0.62 : 0.86;
  const angle = (i / n) * Math.PI * 2 - Math.PI / 2 + (k.slot % 3) * 0.18;
  return { x: 50 + Math.cos(angle) * ring * 44, y: 50 + Math.sin(angle) * ring * 42 };
}

function PocketWorld({ keepers, onOpenKeeper }) {
  const run = keepers.filter(k => k.status === 'run').length;
  return (
    <aside className="cp-world">
      <div className="cp-world-title">
        <div className="t">Pocket World</div>
        <div className="s">주머니 속 작은 세상 — keeper {keepers.length}기</div>
      </div>
      <div className="cp-world-cv">
        {[0.36, 0.62, 0.86].map((r, i) => (
          <div key={i} className="cp-ring" style={{ width: `${r * 88}%`, paddingTop: `${r * 84}%` }}></div>
        ))}
        {keepers.map((k, i) => {
          const p = worldPos(k, i, keepers.length);
          return (
            <div key={k.id} className={`cp-node ${k.status === 'off' ? 'off' : ''}`}
              style={{ left: p.x + '%', top: p.y + '%' }}
              title={`${k.id} · ${k.phase} · ${k.ns}`} onClick={() => onOpenKeeper(k.id)}>
              <SigilBadge k={k} size={k.status === 'run' ? 26 : 20} beat={k.status === 'run'} />
              <span className="nm">{k.id}</span>
            </div>
          );
        })}
      </div>
      <div className="cp-world-foot">
        <div className="row"><span>안쪽 링 — 실행 중</span><b>{run}</b></div>
        <div className="row"><span>중간 링 — 대기·일시정지</span><b>{keepers.filter(k => k.status === 'pause').length}</b></div>
        <div className="row"><span>바깥 링 — 중지·종료</span><b>{keepers.filter(k => k.status === 'off').length}</b></div>
      </div>
    </aside>
  );
}

function CpPlane({ plane, routes, onRoute }) {
  const covered = routes.filter(r => r[2] === 'covered').length;
  const blocked = routes.length - covered;
  return (
    <section className="cp-plane">
      <div className="cp-plane-h">
        <div className="lft">
          <span className="cp-plane-ico">{CP_ICON[plane.id]}</span>
          <div style={{ minWidth: 0 }}>
            <h2>{plane.label}</h2>
            <div className="sum">{plane.sum}</div>
          </div>
        </div>
        <div className="chips">
          <span className="cp-cov ok">{covered} covered</span>
          {blocked > 0 && <span className="cp-cov blk">{blocked} blocked</span>}
        </div>
      </div>
      <div className="cp-routes">
        {routes.map((r, i) => (
          <button key={i} className="cp-route" title={r[1]} onClick={() => onRoute(plane.id, r)}>
            <div className="cp-route-top">
              <div style={{ minWidth: 0 }}>
                <div className="rl">{r[0]}</div>
                <div className="rc">{r[1]}</div>
              </div>
              <span className="arr">↗</span>
            </div>
            <span className={`cp-cov ${r[2] === 'covered' ? 'ok' : 'blk'}`}>{r[2]}</span>
          </button>
        ))}
      </div>
    </section>
  );
}

function CockpitSurface({ onNav, onOpenKeeper }) {
  const [mode, setMode] = useCpState('cockpit');

  const totals = useCpMemo(() => {
    let routes = 0, blocked = 0, top = CP_PLANES[0], topN = -1;
    CP_PLANES.forEach(p => {
      const rs = CP_ROUTES[p.id];
      routes += rs.length;
      blocked += rs.filter(r => r[2] !== 'covered').length;
      if (rs.length > topN) { topN = rs.length; top = p; }
    });
    return { routes, blocked, covered: routes - blocked, top, topN };
  }, []);

  const onRoute = (planeId, r) => {
    if (planeId === 'ide') onNav('ide');
    else if (planeId === 'comms') onNav('board');
    else if (r[0] === 'Keeper Cognition' || r[0] === 'Keeper BDI') onNav('keepers');
  };

  const disclosure = [
    { lvl: 'perceive', ttl: '라우트 커버리지', sum: `${totals.routes}개 라우트 · ${totals.covered} covered / ${totals.blocked} backend-blocked`, mtr: `${totals.routes} routes` },
    { lvl: 'comprehend', ttl: 'Plane 그룹핑', sum: `${totals.top.label} plane이 가장 많은 라우트(${totals.topN}) 보유`, mtr: `${CP_PLANES.length} planes` },
    { lvl: 'project', ttl: '라우트 갭', sum: totals.blocked > 0 ? `Work plane에 backend-blocked ${totals.blocked}건 — goal snapshot diff 백엔드 대기` : 'backend-blocked 라우트 없음', mtr: `${totals.blocked} gaps` },
  ];

  return (
    <main className="surf" data-screen-label="코크핏">
      <div className="cp-body">
        <PocketWorld keepers={KEEPERS} onOpenKeeper={onOpenKeeper} />
        <div className="cp-main">
          <div className="cp-inner">
            <header className="surf-head" style={{ marginBottom: 2 }}>
              <div>
                <div className="eyebrow">MASC Cockpit</div>
                <h1>Command Map</h1>
                <div className="surf-sub"><span className="mono">{totals.routes} routes</span> · {CP_PLANES.length} planes · 인지 모드 <b>{CP_MODES.find(m => m.id === mode).label}</b></div>
              </div>
              <div className="cp-modebar">
                {CP_MODES.map(m => (
                  <button key={m.id} className={`cp-mode ${mode === m.id ? 'on' : ''}`} title={`${m.load} · ${m.layout}`}
                    onClick={() => { setMode(m.id); if (m.id === 'code' || m.id === 'split') onNav('ide'); }}>
                    <span className="ml">{m.label}</span>
                    <span className="ms">{m.layout}</span>
                  </button>
                ))}
              </div>
            </header>

            <section className="cp-disc">
              <div className="cp-disc-h"><h3>Progressive Disclosure</h3></div>
              <div className="cp-disc-rows">
                {disclosure.map((d, i) => (
                  <div key={i} className="cp-disc-row">
                    <div className="lvl">{d.lvl}</div>
                    <div className="ttl">{d.ttl}</div>
                    <div className="sum">{d.sum}</div>
                    <span className="mtr">{d.mtr}</span>
                  </div>
                ))}
              </div>
            </section>

            {CP_PLANES.map(p => <CpPlane key={p.id} plane={p} routes={CP_ROUTES[p.id]} onRoute={onRoute} />)}
          </div>
        </div>
      </div>
    </main>
  );
}

Object.assign(window, { CockpitSurface });
