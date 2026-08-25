/* MASC v2 — Overview surface: the operator's OPERATIONAL HOME.
   Not a fleet duplicate (that's Monitor) — this spans every surface:
   attention queue + cross-cutting KPIs + one summary card per domain
   (work · approvals · board · fusion · connectors · fleet), each a deep
   link into its surface. "지금 무엇이 나를 필요로 하나?" */
const { useMemo: useMemoOv } = React;

// derived attention reasons for keepers with att > 0
const ATTN_REASON = {
  'drifter':   { sev: 'bad',  text: '컨텍스트 오버플로우 — 재시작 필요', act: '재시작' },
  'analyst':   { sev: 'warn', text: '승인 대기 — search/index 재색인 권한', act: '승인 검토', nav: 'approvals' },
  'nick0cave': { sev: 'warn', text: 'provider overflow 복구 · 압축 진행 중', act: '대화 열기' },
  'qa-king':   { sev: 'warn', text: '핸드오프 승인 대기 — sangsu 인계', act: '승인 검토', nav: 'approvals' },
};

function Kpi({ k, v, sub, tone, onClick }) {
  const kb = onClick ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(); } } : undefined;
  return (
    <div className={`ov-kpi ${onClick ? 'link' : ''}`} onClick={onClick}
      role={onClick ? 'button' : undefined} tabIndex={onClick ? 0 : undefined} onKeyDown={kb}>
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

// a domain summary card — header (title + deep link) over compact body
function DomainCard({ title, count, tone, linkLabel, onNav, children }) {
  return (
    <section className="ov-dcard">
      <div className="ov-dcard-h">
        <h3>{title}</h3>
        {count != null && <span className={`ov-dcount ${tone || ''}`}>{count}</span>}
        <button className="ov-dlink" onClick={onNav}>{linkLabel} →</button>
      </div>
      <div className="ov-dcard-body">{children}</div>
    </section>
  );
}

const JOB_STATE_TONE = { done: 'ok', review: 'volt', 'in-progress': '', blocked: 'bad', todo: 'idle' };

function Overview({ keepers, onOpenKeeper, onNav }) {
  const stats = useMemoOv(() => {
    const run = keepers.filter(k => k.status === 'run').length;
    const att = keepers.filter(k => k.att > 0);
    const hot = keepers.filter(k => k.ctx >= 0.85).length;
    const traces = keepers.reduce((a, k) => a + k.traces, 0);
    const pause = keepers.filter(k => k.status === 'pause').length;
    const off = keepers.filter(k => k.status === 'off').length;
    return { run, att, hot, traces, pause, off, total: keepers.length };
  }, [keepers]);

  const attn = stats.att.slice().sort((a, b) => b.att - a.att);
  const bars = useMemoOv(() => telemetryBars(keepers), [keepers]);

  // cross-surface digests
  const goals = window.GOALS || [];
  const topGoals = goals.slice().sort((a, b) => (b.priority - a.priority)).slice(0, 3);
  const approvals = window.APPROVALS || [];
  // longest-waiting request surfaces first (no risk ranking — Gate modes are non-hierarchical)
  const urgent = approvals.slice().sort((a, b) => b.opened - a.opened)[0];
  const connectors = window.CONNECTORS || [];
  const cActive = connectors.filter(c => c.status === 'connected' && !c.stale).length;
  const cStale = connectors.filter(c => c.stale).length;
  const subs = window.SUB_BOARDS || [];
  const unreadBoards = subs.filter(s => s.unread).length;
  const mentions = (window.MENTIONS || []).length;
  const fusion = window.FUSION_RUNS || [];
  const fusRunning = fusion.filter(r => r.status === 'running').length;
  const fusDone = fusion.filter(r => r.status === 'done');
  const fusLatest = fusDone[0];
  const fusDec = fusLatest && fusLatest.judge && (window.FUSION_DECISION || {})[fusLatest.judge.decision];

  // schedule digest (lib/schedule) — keeper-scheduled automation awaiting operator
  const schedSum = window.schedSummary ? window.schedSummary({}) : { pending: 0, due: 0, scheduled: 0, running: 0, total: 0 };
  const schedList = window.schedEffective ? window.schedEffective({}) : [];
  const schedPendItems = schedList.filter(s => s.status === 'Pending_approval' || s.status === 'Due').slice(0, 3);

  return (
    <main className="ov">
      <div className="ov-scroll">
        <header className="ov-head">
          <div>
            <span className="ov-eyebrow">운영 홈</span>
            <h1>지금, 전체</h1>
            <p className="ov-sub">목표 · 승인 · 심의 · 연결</p>
          </div>
          <div className="ov-clock mono">{nowHM()} <span>KST</span></div>
        </header>

        <section className="ov-kpis">
          <Kpi k="실행 중 keeper" v={stats.run} sub={` / ${stats.total}`} tone="ok" onClick={() => onNav('monitor')} />
          <Kpi k="주의 필요" v={stats.att.length} tone={stats.att.length ? 'bad' : ''} onClick={() => onNav('monitor')} />
          <Kpi k="열린 Gate" v={approvals.length} tone={approvals.length ? 'warn' : ''} onClick={() => onNav('approvals')} />
          <Kpi k="최우선 목표" v={topGoals[0] ? (topGoals[0].due_date || 'P' + topGoals[0].priority) : '—'} tone="volt" onClick={() => onNav('work')} />
          <Kpi k="활성 커넥터" v={cActive} sub={` / ${connectors.length}`} tone={cStale ? 'warn' : ''} onClick={() => onNav('connectors')} />
          <Kpi k="예약 승인" v={schedSum.pending} sub={schedSum.due ? ` · due ${schedSum.due}` : ''} tone={schedSum.pending || schedSum.due ? 'warn' : ''} onClick={() => onNav('schedule')} />
          <Kpi k="진행 심의" v={fusRunning} sub={fusDone.length ? ` · 완료 ${fusDone.length}` : ''} tone={fusRunning ? 'volt' : ''} onClick={() => onNav('fusion')} />
        </section>

        <div className="ov-grid">
          <section className="ov-card ov-attn">
            <div className="ov-card-h">
              <h3>주의 필요 · 지금 손이 필요한 것</h3>
              <span className="ov-count">{attn.length}</span>
            </div>
            <div className="ov-attn-list">
              {attn.map(k => {
                const r = ATTN_REASON[k.id] || { sev: 'warn', text: '점검 필요', act: '대화 열기' };
                return (
                  <div key={k.id} className="ov-attn-row" role="button" tabIndex={0} onClick={() => onOpenKeeper(k.id)} onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onOpenKeeper(k.id); } }}>
                    <SigilBadge k={k} size={32} />
                    <div className="ov-attn-meta">
                      <div className="ov-attn-name">{k.id}</div>
                      <div className={`ov-attn-reason sev-${r.sev}`}><span className={`dot2 ${r.sev}`}></span>{r.text}</div>
                    </div>
                    <button className="ov-attn-act" onClick={(e) => { e.stopPropagation(); r.nav ? onNav(r.nav) : onOpenKeeper(k.id); }}>{r.act} →</button>
                  </div>
                );
              })}
              {!attn.length && <div className="ov-empty">모든 keeper 정상</div>}
            </div>
          </section>

          <section className="ov-card ov-telemetry">
            <div className="ov-card-h">
              <h3>텔레메트리</h3>
              <button className="ov-link" onClick={() => onNav('logs')}>로그 보기 →</button>
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

        <h2 className="ov-section-h">도메인 현황</h2>
        <div className="ov-domains">
          {/* WORK */}
          <DomainCard title="작업 · 목표" linkLabel="작업" onNav={() => onNav('work')}>
            {topGoals.map(g => {
              const live = g.tasks.filter(t => t.status !== 'cancelled');
              const done = live.filter(t => t.status === 'done').length;
              const pri = g.priority >= 7 ? 'high' : g.priority >= 4 ? 'normal' : 'low';
              return (
                <div key={g.id} className="ov-goal">
                  <div className="ov-goal-top">
                    <span className={`ov-goal-pri ${pri}`}></span>
                    <span className="ov-goal-title">{g.title}</span>
                    <span className="ov-goal-due mono">{g.due_date || ''}</span>
                  </div>
                  <div className="ov-goal-meter"><span style={{ width: Math.round(done / (live.length || 1) * 100) + '%' }}></span></div>
                  <div className="ov-goal-sub mono">{done}/{live.length} task</div>
                </div>
              );
            })}
          </DomainCard>

          {/* APPROVALS */}
          <DomainCard title="Gate 큐" count={approvals.length} tone={approvals.length ? 'warn' : ''} linkLabel="Gate" onNav={() => onNav('approvals')}>
            {urgent && (
              <div className="ov-urg">
                <div className="ov-urg-sev sev-warn">{((window.APPROVAL_KIND || {})[urgent.kind] || {}).lbl || urgent.kind}</div>
                <div className="ov-urg-title">{urgent.title}</div>
                <div className="ov-urg-by mono">{urgent.keeper} · {urgent.goal || '—'}</div>
              </div>
            )}
            <div className="ov-mini-list">
              {approvals.slice(0, 3).map(a => (
                <div key={a.id} className="ov-mini-row">
                  <span className="dot2 warn"></span>
                  <span className="ov-mini-txt">{a.title}</span>
                </div>
              ))}
            </div>
          </DomainCard>

          {/* SCHEDULE */}
          <DomainCard title="예약 · 자동화" count={schedSum.pending || null} tone={schedSum.pending || schedSum.due ? 'warn' : ''} linkLabel="예약" onNav={() => onNav('schedule')}>
            <div className="ov-mini-list">
              {schedPendItems.map(s => {
                const d = (window.SCHED_STATUS || {})[s.status] || {};
                return (
                  <div key={s.schedule_id} className="ov-mini-row">
                    <span className={`dot2 ${d.cls === 'ok' ? 'info' : d.cls || 'warn'}`}></span>
                    <span className="ov-mini-txt">{s.summary}</span>
                  </div>
                );
              })}
              {!schedPendItems.length && <div className="ov-mini-empty">대기 중 예약 없음</div>}
            </div>
            <div className="ov-stat-row"><span className="k">예약됨 · 실행</span><span className="v mono">{schedSum.scheduled + schedSum.running}</span></div>
          </DomainCard>

          {/* FUSION */}
          <DomainCard title="Fusion 심의" count={fusion.length} tone="volt" linkLabel="Fusion" onNav={() => onNav('fusion')}>            {fusLatest && (
              <div className="ov-fus">
                <div className="ov-fus-h">
                  <span className="ov-fus-run mono">{fusLatest.run_id}</span>
                  {fusDec && <span className={`fus-dec-badge ${fusDec.cls}`}>{fusDec.glyph} {fusDec.lbl}</span>}
                </div>
                <div className="ov-fus-by mono">{fusLatest.keeper} · 패널 {fusLatest.panel ? fusLatest.panel.length : '—'} + 심판</div>
              </div>
            )}
            <div className="ov-fus-foot">
              {fusRunning > 0 ? <span className="ov-fus-live"><span className="dot2 warn"></span>{fusRunning}건 심의 중</span> : <span className="ov-fus-idle">진행 중 심의 없음</span>}
            </div>
          </DomainCard>

          {/* BOARD */}
          <DomainCard title="보드" linkLabel="보드" onNav={() => onNav('board')}>
            <div className="ov-stat-row"><span className="k">미열람 서브보드</span><span className="v">{unreadBoards}</span></div>
            <div className="ov-stat-row"><span className="k">멘션 인박스</span><span className="v">{mentions}</span></div>
            <div className="ov-stat-row"><span className="k">전체 포스트</span><span className="v mono">{(window.BOARD_POSTS || []).length}</span></div>
          </DomainCard>

          {/* CONNECTORS */}
          <DomainCard title="커넥터" count={`${cActive}/${connectors.length}`} tone={cStale ? 'warn' : 'ok'} linkLabel="커넥터" onNav={() => onNav('connectors')}>
            <div className="ov-conn-row">
              {connectors.map(c => (
                <span key={c.id} className={`ov-conn-pill ${c.stale ? 'stale' : c.status === 'connected' ? 'ok' : 'off'}`} title={`${c.name} · ${c.stale ? 'stale' : c.status}`}>
                  <span className="g">{c.glyph}</span>{c.name}
                </span>
              ))}
            </div>
            {cStale > 0 && <div className="ov-conn-warn">{cStale}개 게이트 stale — 재연결 필요</div>}
          </DomainCard>

          {/* FLEET (one-line summary → Monitor) */}
          <DomainCard title="Fleet 요약" linkLabel="Monitor" onNav={() => onNav('monitor')}>
            <div className="ov-fleet-sum">
              <div className="ov-fleet-stat"><span className="v ok">{stats.run}</span><span className="k">실행</span></div>
              <div className="ov-fleet-stat"><span className="v warn">{stats.pause}</span><span className="k">정지</span></div>
              <div className="ov-fleet-stat"><span className="v">{stats.off}</span><span className="k">오프</span></div>
              <div className="ov-fleet-stat"><span className={`v ${stats.hot ? 'bad' : ''}`}>{stats.hot}</span><span className="k">압박</span></div>
            </div>
            <div className="ov-stat-row"><span className="k">전체 keeper</span><span className="v mono">{stats.total}</span></div>
          </DomainCard>
        </div>
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
