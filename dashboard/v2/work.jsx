/* MASC v2 — Work surface: goal tree → jobs → keeper.
   Goal 은 작업 위계의 꼭대기. 하나의 goal 이 여러 job 으로 쪼개지고, 각 job 을 keeper 가 소유한다. */
const { useState: useWkState } = React;

const JOB_STATE = {
  done:          { lbl: '완료',   cls: 'done' },
  'in-progress': { lbl: '진행 중', cls: 'wip' },
  review:        { lbl: '리뷰',   cls: 'review' },
  blocked:       { lbl: '막힘',   cls: 'blocked' },
  todo:          { lbl: '대기',   cls: 'todo' },
};
const WK_PRIORITY = {
  high:   { lbl: '높음', cls: 'high' },
  normal: { lbl: '보통', cls: 'normal' },
  low:    { lbl: '낮음', cls: 'low' },
};

function wkKeeper(id) { return (window.KEEPERS || []).find(k => k.id === id); }

function GoalProgress({ jobs }) {
  const n = jobs.length || 1;
  let done = 0, wip = 0, blocked = 0;
  jobs.forEach(j => {
    if (j.state === 'done') done++;
    else if (j.state === 'blocked') blocked++;
    else if (j.state === 'in-progress' || j.state === 'review') wip++;
  });
  const pct = (x) => (x / n) * 100;
  return (
    <div className="wk-prog">
      <span className="wk-seg done" style={{ width: pct(done) + '%' }}></span>
      <span className="wk-seg wip" style={{ width: pct(wip) + '%' }}></span>
      <span className="wk-seg blocked" style={{ width: pct(blocked) + '%' }}></span>
    </div>
  );
}

function GoalCard({ g, open, onToggle, onOpenKeeper }) {
  const lead = wkKeeper(g.lead);
  const done = g.jobs.filter(j => j.state === 'done').length;
  const blocked = g.jobs.filter(j => j.state === 'blocked').length;
  const pr = WK_PRIORITY[g.priority] || WK_PRIORITY.normal;
  return (
    <div className={`wk-goal ${open ? 'open' : ''} ${blocked ? 'has-block' : ''}`}>
      <button className="wk-goal-h" onClick={onToggle}>
        <span className="wk-caret">{open ? '\u25BE' : '\u25B8'}</span>
        <span className={`wk-pri ${pr.cls}`}>{pr.lbl}</span>
        <span className="wk-goal-id mono">{g.id}</span>
        <span className="wk-goal-title">{g.title}</span>
        <span className="wk-goal-ns mono">{g.ns}</span>
        <span className="wk-spacer"></span>
        {g.due && <span className="wk-due mono">{g.due}</span>}
        {lead && <span className="wk-lead" title={`리드 · ${lead.id}`}><SigilBadge k={lead} size={22} /></span>}
      </button>
      <div className="wk-goal-sub">
        <GoalProgress jobs={g.jobs} />
        <span className="wk-prog-lbl mono">{done}/{g.jobs.length}{blocked ? ` · 막힘 ${blocked}` : ''}</span>
        {g.metric && <span className="wk-metric mono" title="목표 지표">{g.metric}</span>}
      </div>
      {open && (
        <div className="wk-jobs">
          {g.note && <div className="wk-note">{g.note}</div>}
          {g.jobs.map(j => {
            const k = wkKeeper(j.keeper);
            const st = JOB_STATE[j.state] || JOB_STATE.todo;
            return (
              <div key={j.id} className={`wk-job ${st.cls}`}>
                <span className={`wk-job-dot ${st.cls}`}></span>
                <span className="wk-job-id mono">{j.id}</span>
                <span className="wk-job-title">{j.title}{j.blocker && <span className="wk-job-block">{'\u26A0'} {j.blocker}</span>}</span>
                <span className="wk-spacer"></span>
                <span className={`wk-job-state ${st.cls}`}>{st.lbl}</span>
                {k
                  ? <button className="wk-job-kp" onClick={() => onOpenKeeper(k.id)} title={`${k.id} 대화 열기`}><SigilBadge k={k} size={18} /><span className="mono">{k.id}</span></button>
                  : <span className="wk-job-kp none mono">미배정</span>}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function WorkSurface({ onOpenKeeper, onNav }) {
  const goals = window.GOALS || [];
  const [open, setOpen] = useWkState(() => new Set(goals.filter(g => g.priority === 'high' || g.jobs.some(j => j.state === 'blocked')).map(g => g.id)));
  const toggle = (id) => setOpen(prev => { const n = new Set(prev); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  const jobs = goals.reduce((a, g) => a + g.jobs.length, 0);
  const done = goals.reduce((a, g) => a + g.jobs.filter(j => j.state === 'done').length, 0);
  const blocked = goals.reduce((a, g) => a + g.jobs.filter(j => j.state === 'blocked').length, 0);

  return (
    <main className="ov">
      <div className="ov-scroll">
        <header className="ov-head">
          <div>
            <h1>작업 · 목표</h1>
            <p className="ov-sub"><span title="최상위 조정 범위">namespace <span className="mono">masc-mcp</span></span> · <span>목표 {goals.length}</span> · <span>job {jobs}</span> · <span>완료 {done}</span>{blocked ? <span> · <span className="wk-blk-n">막힘 {blocked}</span></span> : null}</p>
          </div>
          <button className="set-add wk-newgoal" title="새 목표 생성 — 다음 단계에서 설계">{'\uFF0B'} 새 목표</button>
        </header>

        <section className="ov-kpis" style={{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
          <div className="ov-kpi"><div className="ov-kpi-k">활성 목표</div><div className="ov-kpi-v volt">{goals.length}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">전체 job</div><div className="ov-kpi-v">{jobs}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">완료</div><div className="ov-kpi-v ok">{done}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">막힘</div><div className={`ov-kpi-v ${blocked ? 'bad' : ''}`}>{blocked}</div></div>
        </section>

        <div className="wk-list">
          {goals.map(g => (
            <GoalCard key={g.id} g={g} open={open.has(g.id)} onToggle={() => toggle(g.id)} onOpenKeeper={onOpenKeeper} />
          ))}
        </div>

        <div className="wk-foot mono">Goal → job → keeper · job 의 keeper 를 누르면 해당 keeper 대화로 이동</div>
      </div>
    </main>
  );
}

Object.assign(window, { WorkSurface });
