/* MASC v2 — Overview surface (operator console landing / "main menu").
   Fleet KPIs, attention queue, keeper fleet grid, telemetry strip. */
const { useMemo: useMemoOv } = React;

// derived attention reasons for keepers with att > 0
const ATTN_REASON = {
  'drifter':   { sev: 'bad',  text: '컨텍스트 오버플로우 — 재시작 필요', act: '재시작' },
  'analyst':   { sev: 'warn', text: '승인 대기 3건 (도구 권한)', act: '승인 검토' },
  'nick0cave': { sev: 'warn', text: '컨텍스트 91% · 압축 진행 중', act: '대화 열기' },
  'qa-king':   { sev: 'warn', text: '핸드오프 승인 대기', act: '대화 열기' },
};

function Kpi({ k, v, sub, tone }) {
  return (
    <div className="ov-kpi">
      <div className="ov-kpi-k">{k}</div>
      <div className={`ov-kpi-v ${tone || ''}`}>{v}{sub && <small>{sub}</small>}</div>
    </div>
  );
}

// deterministic 28-bar telemetry histogram
function telemetryBars(keepers) {
  const seed = keepers.reduce((a, k) => a + k.traces, 0);
  const bars = [];
  let s = seed;
  for (let i = 0; i < 28; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    const base = 0.25 + ((s >> 8) % 1000) / 1000 * 0.7;
    const spike = (i === 9 || i === 22) ? 1 : base;
    bars.push(Math.min(1, spike));
  }
  return bars;
}

function Overview({ keepers, onOpenKeeper, onNav }) {
  const stats = useMemoOv(() => {
    const run = keepers.filter(k => k.status === 'run').length;
    const att = keepers.filter(k => k.att > 0);
    const hot = keepers.filter(k => k.ctx >= 0.85).length;
    const traces = keepers.reduce((a, k) => a + k.traces, 0);
    const tasks = keepers.reduce((a, k) => a + k.tasks, 0);
    const liveCtx = keepers.filter(k => k.status === 'run');
    const avgCtx = liveCtx.length ? Math.round(liveCtx.reduce((a, k) => a + k.ctx, 0) / liveCtx.length * 100) : 0;
    return { run, att, hot, traces, tasks, avgCtx, total: keepers.length };
  }, [keepers]);

  const attn = stats.att.slice().sort((a, b) => b.att - a.att);
  const bars = useMemoOv(() => telemetryBars(keepers), [keepers]);

  return (
    <main className="ov">
      <div className="ov-scroll">
        <header className="ov-head">
          <div>
            <h1>운영 개요</h1>
            <p className="ov-sub"><span title="최상위 조정 범위 — 모든 room/keeper를 담는 root namespace">namespace <span className="mono">masc-mcp</span></span> · <span title="등록된 keeper 총 수">Keeper {stats.total}</span> · <span title="현재 토큰으로 로그인한 운영자 — 당신">operator <b>@operator</b></span></p>
          </div>
          <div className="ov-clock mono">{nowHM()} <span>KST</span></div>
        </header>

        <section className="ov-kpis">
          <Kpi k="실행 중" v={stats.run} sub={` / ${stats.total}`} tone="ok" />
          <Kpi k="주의 필요" v={stats.att.length} tone={stats.att.length ? 'bad' : ''} />
          <Kpi k="컨텍스트 압박" v={stats.hot} sub=" ≥85%" tone={stats.hot ? 'warn' : ''} />
          <Kpi k="평균 컨텍스트" v={stats.avgCtx + '%'} tone="volt" />
          <Kpi k="소유 태스크" v={stats.tasks} />
          <Kpi k="누적 trace" v={stats.traces.toLocaleString()} />
        </section>

        <div className="ov-grid">
          <section className="ov-card ov-attn">
            <div className="ov-card-h">
              <h3>주의 필요</h3>
              <span className="ov-count">{attn.length}</span>
            </div>
            <div className="ov-attn-list">
              {attn.map(k => {
                const r = ATTN_REASON[k.id] || { sev: 'warn', text: '점검 필요', act: '대화 열기' };
                return (
                  <div key={k.id} className="ov-attn-row" onClick={() => onOpenKeeper(k.id)}>
                    <SigilBadge k={k} size={32} />
                    <div className="ov-attn-meta">
                      <div className="ov-attn-name">{k.id}<span className="ov-attn-ns mono">{k.ns}</span></div>
                      <div className={`ov-attn-reason sev-${r.sev}`}><span className={`dot2 ${r.sev}`}></span>{r.text}</div>
                    </div>
                    <button className="ov-attn-act" onClick={(e) => { e.stopPropagation(); onOpenKeeper(k.id); }}>{r.act} →</button>
                  </div>
                );
              })}
              {!attn.length && <div className="ov-empty">모든 keeper 정상</div>}
            </div>
          </section>

          <section className="ov-card ov-telemetry">
            <div className="ov-card-h">
              <h3>텔레메트리</h3>
              <span className="ov-legend mono">trace / 5m · last 140m</span>
            </div>
            <div className="ov-bars">
              {bars.map((b, i) => (
                <span key={i} className={`ov-bar ${b >= 0.95 ? 'hot' : ''}`} style={{ height: (10 + b * 90) + '%' }}></span>
              ))}
            </div>
            <div className="ov-tel-foot">
              <div className="ov-tel-stat"><span className="k">피크</span><span className="v mono">112/5m</span></div>
              <div className="ov-tel-stat"><span className="k">평균</span><span className="v mono">47/5m</span></div>
              <div className="ov-tel-stat"><span className="k">오류율</span><span className="v mono" style={{ color: 'var(--status-ok)' }}>0.4%</span></div>
              <div className="ov-tel-stat"><span className="k">p95 지연</span><span className="v mono">1.8s</span></div>
            </div>
          </section>
        </div>

        <section className="ov-card ov-fleet">
          <div className="ov-card-h">
            <h3>Keeper 전체</h3>
            <button className="ov-link" onClick={() => onNav('keepers')}>전체 대화 보기 →</button>
          </div>
          <div className="ov-fleet-grid">
            {keepers.map(k => (
              <button key={k.id} className="ov-keeper" onClick={() => onOpenKeeper(k.id)}>
                <div className="ov-keeper-top">
                  <SigilBadge k={k} size={30} beat={k.status === 'run'} />
                  <div className="ov-keeper-id">
                    <div className="ov-keeper-name">{k.id}</div>
                    <div className="ov-keeper-state"><StatusDot status={k.status} pulse={k.status === 'run'} />{k.phase}</div>
                  </div>
                  {k.att > 0 && <span className="ov-keeper-att">{k.att}</span>}
                </div>
                <div className="ov-keeper-ns mono">{k.ns}</div>
                <div className="ov-keeper-foot">
                  <span className="mono">{k.model.replace('claude-', '')}</span>
                  <div className="ov-mini-meter"><span className={k.ctx >= 0.85 ? 'hot' : ''} style={{ width: Math.round(k.ctx * 100) + '%' }}></span></div>
                  <span className="mono ov-keeper-ctx">{Math.round(k.ctx * 100)}%</span>
                </div>
              </button>
            ))}
          </div>
        </section>
      </div>
    </main>
  );
}

function PlaceholderSurface({ surface }) {
  const map = { board: ['보드', '태스크 칸반 · 골 정렬 · 의존성'], connectors: ['커넥터', 'Slack · Discord · Amplitude · GitHub'], settings: ['설정', '런타임 · 승인 정책 · 모델 라우팅'] };
  const [title, desc] = map[surface] || [surface, ''];
  return (
    <main className="ov">
      <div className="empty2" style={{ height: '100%' }}>
        <div className="ico">◈</div>
        <h3>{title}</h3>
        <div style={{ maxWidth: 320, fontSize: 13, lineHeight: 1.6, color: 'var(--text-dim)' }}>{desc}<br />다음 단계에서 설계합니다.</div>
      </div>
    </main>
  );
}

Object.assign(window, { Overview, PlaceholderSurface });
