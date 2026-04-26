// cb-group-d.jsx — Track 1 · WORK PLANE
// G1 Goal Zone (3 variants) · G2 Task Zone (3 variants) · G3 Accountability (2 variants)

const P2 = window.MASC_P2;

// ─────────────────────────────────────────────────────────────────
// SHARED: zone header with branch + keeper context (IDE backbone)
// ─────────────────────────────────────────────────────────────────
function ZoneHeader({ title, branch = "main", keepers = [], meta, right }) {
  const headingId = `zh-${title.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`;
  return (
    <div className="ph" role="group" aria-labelledby={headingId}>
      <span className="ttl" id={headingId} role="heading" aria-level={3}>{title}</span>
      <span className="br-pill" aria-label={`Branch ${branch}`}>{branch}</span>
      {keepers.slice(0, 3).map(k => (
        <span key={k} className="kpr-pill" role="img" aria-label={`Keeper ${k}`}><span className="dot" aria-hidden="true" />{k}</span>
      ))}
      {keepers.length > 3 && <span className="kpr-pill" role="img" aria-label={`Plus ${keepers.length - 3} more keepers`}>+{keepers.length - 3}</span>}
      {meta && <span className="meta" style={{marginLeft: 8}}>{meta}</span>}
      <span className="grow" aria-hidden="true" />
      {right}
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// G1 · GOAL ZONE
// ═══════════════════════════════════════════════════════════════════

// G1-A · Horizon track (short / mid / long)
function GoalHorizonTrack() {
  const groups = [
    { hz: "short", label: "단기", note: "≤ 1 wk", goals: P2.goals.filter(g => g.horizon === "short") },
    { hz: "mid",   label: "중기", note: "≤ 1 mo", goals: P2.goals.filter(g => g.horizon === "mid") },
    { hz: "long",  label: "장기", note: "quarter", goals: P2.goals.filter(g => g.horizon === "long") },
  ];
  return (
    <section className="cbp" aria-label="Goal horizon track">
      <ZoneHeader
        title="GOAL · HORIZON"
        branch="main"
        keepers={["nick0cave","masc-improver","sangsu"]}
        meta={`${P2.goals.length} active · 4 done · 0 blocked`}
        right={<span className="meta">snapshot 16:32Z</span>}
      />
      <div className="body">
        {groups.map(g => (
          <div key={g.hz} className="gz-track" role="group" aria-label={`${g.label} horizon · ${g.note} · ${g.goals.length} goals`}>
            <div className="hz" aria-hidden="true">
              <span>{g.label}</span>
              <span className="n">{g.note}</span>
              <span className="n" style={{marginTop:'auto', color:'var(--brass-1)'}}>{g.goals.length}</span>
            </div>
            <div className="lst" role="list" aria-label={`${g.label} goals`}>
              {g.goals.length === 0 && <div className="cb-mute" role="listitem" style={{padding:'8px',fontFamily:'var(--font-mono)',fontSize:'10px'}}>— no goals at this horizon —</div>}
              {g.goals.map(go => (
                <div key={go.id}
                     role="listitem"
                     aria-label={`${go.id} · ${go.title} · phase ${go.phase} · ${go.progress} of ${go.total} (${Math.round(go.progress / go.total * 100)}%) · target ${go.target_value} ${go.metric}${go.status === 'done' ? ' · done' : ''}`}
                     className={`gz-card ${go.status === 'done' ? 'done' : ''} ${go.phase}`}>
                  <div className="top" aria-hidden="true">
                    <span className="id">{go.id} · <span style={{color:'var(--info-fg)'}}>{go.phase}</span></span>
                    <span className="ttl" title={go.title}>{go.title}</span>
                    <span className="met"><span>{go.metric}</span> · target <span className="v">{go.target_value}</span></span>
                  </div>
                  <div className="prog" aria-hidden="true">
                    <span className="pct">{Math.round(go.progress / go.total * 100)}%</span>
                    <span className="b"><i style={{width: `${go.progress / go.total * 100}%`}} /></span>
                    <span style={{color:'var(--color-fg-disabled)',fontSize:'9px'}}>{go.progress}/{go.total}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

// G1-B · Metric tree (parent → child)
function GoalMetricTree() {
  const roots = P2.goals.filter(g => !g.parent);
  return (
    <section className="cbp" aria-label="Goal metric tree">
      <ZoneHeader
        title="GOAL · TREE"
        branch="main"
        keepers={["nick0cave","masc-improver","sangsu"]}
        meta="parent → child"
      />
      <div className="body flat">
        <div className="gz-hdr" role="row" aria-hidden="true">
          <span style={{gridColumn:'1 / 2'}}>goal · metric</span>
          <span style={{textAlign:'right'}}>progress</span>
          <span style={{textAlign:'right'}}>phase</span>
        </div>
        <div role="tree" aria-label={`${roots.length} root goals`}>
          {roots.map(root => {
            const children = P2.goals.filter(g => g.parent === root.id);
            return (
              <React.Fragment key={root.id}>
                <div className="gz-tree-row"
                     role="treeitem"
                     aria-level={1}
                     aria-expanded={children.length > 0 ? 'true' : undefined}
                     aria-label={`${root.title} · ${root.id} · ${root.metric} · ${root.progress} of ${root.total} · phase ${root.status === 'done' ? 'done' : root.phase}`}>
                  <span className="ttl" aria-hidden="true">
                    {root.title}
                    <small>{root.id} · {root.metric}</small>
                  </span>
                  <span className="num" aria-hidden="true">{root.progress}/{root.total}</span>
                  <span className={`ph ${root.phase} ${root.status === 'done' ? 'done' : ''}`} aria-hidden="true" style={{textAlign:'right'}}>
                    {root.status === 'done' ? 'done' : root.phase}
                  </span>
                </div>
                {children.map(child => (
                  <div key={child.id}
                       className="gz-tree-row child"
                       role="treeitem"
                       aria-level={2}
                       aria-label={`${child.title} · ${child.id} · ${child.metric} · ${child.progress} of ${child.total} · phase ${child.status === 'done' ? 'done' : child.phase}`}>
                    <span className="ttl" aria-hidden="true">
                      {child.title}
                      <small>{child.id} · {child.metric}</small>
                    </span>
                    <span className="num" aria-hidden="true">{child.progress}/{child.total}</span>
                    <span className={`ph ${child.phase} ${child.status === 'done' ? 'done' : ''}`} aria-hidden="true" style={{textAlign:'right'}}>
                      {child.status === 'done' ? 'done' : child.phase}
                    </span>
                  </div>
                ))}
              </React.Fragment>
            );
          })}
        </div>
      </div>
    </section>
  );
}

// G1-C · Snapshot diff (yesterday → today)
function GoalSnapshotDiff() {
  return (
    <section className="cbp" aria-label="Goal snapshot diff (yesterday vs today)">
      <ZoneHeader
        title="GOAL · SNAPSHOT"
        branch="main"
        keepers={["scholar"]}
        meta="2026-04-22 → 2026-04-23"
        right={<span className="meta" style={{color:'var(--brass-1)'}}>{P2.goalSnapshots.length} drift</span>}
      />
      <div className="body">
        <div className="gz-snap" role="list" aria-label="Goal snapshot rows">
          {P2.goalSnapshots.map(s => {
            const g = P2.goals.find(x => x.id === s.goal);
            const yPct = Math.round(s.yesterday.progress / s.yesterday.total * 100);
            const tPct = Math.round(s.today.progress / s.today.total * 100);
            const phaseShifted = s.today.phase !== s.yesterday.phase;
            return (
              <div key={s.goal}
                   className="gz-snap-row"
                   role="listitem"
                   aria-label={`${g?.title || s.goal} · yesterday ${s.yesterday.progress} of ${s.yesterday.total} (${yPct}%), phase ${s.yesterday.phase} → today ${s.today.progress} of ${s.today.total} (${tPct}%), phase ${s.today.phase}${phaseShifted ? ', phase shift' : ''}`}>
                <div className="ttl" aria-hidden="true">
                  {g?.title || s.goal}
                  <span className="id">{s.goal}</span>
                </div>
                <div className="diff" aria-hidden="true">
                  <div className="y">
                    <span className="lbl">yesterday</span>
                    <span>progress: <span className="v" style={{color:'var(--color-fg-secondary)'}}>{s.yesterday.progress}/{s.yesterday.total}</span> · {yPct}%</span>
                    <br />
                    <span>phase: {s.yesterday.phase}</span>
                  </div>
                  <span className="arr">→</span>
                  <div className="t">
                    <span className="lbl">today</span>
                    <span>progress: <span className="v">{s.today.progress}/{s.today.total}</span> · {tPct}%</span>
                    <br />
                    <span>phase: {s.today.phase} {phaseShifted && <span style={{color:'var(--ok-fg)',marginLeft:6,fontSize:'9px'}}>↗ phase shift</span>}</span>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}

// ═══════════════════════════════════════════════════════════════════
// G2 · TASK ZONE
// ═══════════════════════════════════════════════════════════════════

// G2-A · Backlog table (queued / claimed / running / done / cancelled)
function TaskBacklog() {
  const [filter, setFilter] = useState('all');
  const filters = [
    { id:'all',     label:'all',     n:P2.tasks.length },
    { id:'running', label:'running', n:P2.tasks.filter(t=>t.status==='running').length },
    { id:'queued',  label:'queued',  n:P2.tasks.filter(t=>t.status==='queued'||t.status==='pending').length },
    { id:'fail',    label:'fail',    n:P2.tasks.filter(t=>t.status==='fail'||t.status==='stalled').length },
    { id:'done',    label:'done',    n:P2.tasks.filter(t=>t.status==='done'||t.status==='cancelled').length },
  ];
  const rows = P2.tasks.filter(t => {
    if (filter === 'all') return true;
    if (filter === 'queued') return t.status === 'queued' || t.status === 'pending';
    if (filter === 'fail')   return t.status === 'fail' || t.status === 'stalled';
    if (filter === 'done')   return t.status === 'done' || t.status === 'cancelled';
    return t.status === filter;
  });
  return (
    <section className="cbp" aria-label="Task backlog">
      <ZoneHeader
        title="TASK · BACKLOG"
        branch="main"
        keepers={["nick0cave","masc-improver","sangsu","qa-king"]}
        meta={`${P2.tasks.length} total`}
        right={
          <div className="filt" role="radiogroup" aria-label="Task status filter">
            {filters.map(f => (
              <button key={f.id} type="button" role="radio" aria-checked={filter===f.id} aria-label={`${f.label}, ${f.n} tasks`} className={filter===f.id ? 'on' : ''} onClick={()=>setFilter(f.id)}>{f.label} {f.n}</button>
            ))}
          </div>
        }
      />
      <div className="body flat" style={{overflow:'auto'}}>
        <table className="t" aria-label={`Task backlog · ${rows.length} rows`}>
          <thead>
            <tr>
              <th scope="col" style={{width:64}}>id</th>
              <th scope="col" style={{width:80}}>status</th>
              <th scope="col">title</th>
              <th scope="col" style={{width:130}}>branch</th>
              <th scope="col" style={{width:110}}>keeper</th>
              <th scope="col" style={{width:130}}>goal</th>
              <th scope="col" style={{width:60, textAlign:'right'}}>age</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(t => (
              <tr key={t.id} className="tz-row">
                <td className="id">{t.id}</td>
                <td>
                  <span className={`stat ${t.status}`}>{t.status}</span>
                  {t.drift && <span className="drift" aria-label="Drift detected">DRIFT</span>}
                </td>
                <td className="pri">{t.title}</td>
                <td className="mute" aria-label={`Branch ${t.branch}`}><span aria-hidden="true">⎇ </span>{t.branch}</td>
                <td>{t.keeper ? <span style={{color:'var(--brass-1)'}}>{t.keeper}</span> : <span className="mute" aria-label="No keeper">—</span>}</td>
                <td className="mute" title={t.goal}>{t.goal.replace('goal-','')}</td>
                <td className="num">{t.age}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

// G2-B · Stale-claim alert view
function TaskStaleAlert() {
  const stale = P2.tasks.filter(t => t.drift || (t.claim_age && t.claim_age !== '—' && (t.claim_age.endsWith('h') || parseInt(t.claim_age) > 10)));
  return (
    <section className="cbp" role="region" aria-label={`Task stale claims · ${stale.length} need attention`}>
      <ZoneHeader
        title="TASK · STALE CLAIMS"
        branch="main"
        keepers={["taskmaster","velvet-hammer"]}
        meta={`${stale.length} need attention · check age > 10m or drift=true`}
        right={<span className="meta" role="status" aria-live="polite" style={{color:'var(--err-fg)'}}><span aria-hidden="true">● </span>action required</span>}
      />
      <div className="body">
        <div className="tz-alert" role="list" aria-label={`${stale.length} stale claims requiring attention`}>
          {stale.map(t => (
            <div key={t.id}
                 className="row"
                 role="listitem"
                 aria-label={`${t.id} · ${t.title} · claimed ${t.claim_age} ago by ${t.keeper || 'nobody'}${t.drift ? ' · metadata drift' : ''}`}>
              <div className="who" aria-hidden="true">
                <span className="id">{t.id}</span> · {t.title}
                <span className="age">claimed {t.claim_age} ago by {t.keeper || 'nobody'}</span>
              </div>
              <div className="why" aria-hidden="true">
                {t.drift ? 'metadata_drift detected · backlog L42' : `claim_age > threshold · last activity ${t.age} ago`}
                <br />
                <span style={{color:'var(--color-fg-disabled)'}}>⎇ {t.branch} · {t.tools}</span>
              </div>
              <div className="acts" role="toolbar" aria-label={`Actions for ${t.id}`}>
                <button type="button">nudge</button>
                <button type="button" className="danger">force-release</button>
                <button type="button" className="primary">reassign</button>
              </div>
            </div>
          ))}
        </div>
        <div role="note" style={{marginTop:8, padding:'6px 8px', borderTop:'1px dashed var(--color-border-strong)', fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--color-fg-disabled)'}}>
          taskmaster cannot force-release others' claims · operator nudge channel: <span style={{color:'var(--brass-1)'}}>hint</span>
        </div>
      </div>
    </section>
  );
}

// G2-C · Per-keeper task wall
function TaskWall() {
  const keepers = ["nick0cave","masc-improver","sangsu","qa-king","ramarama","executor","issue_king","janitor"];
  return (
    <section className="cbp" aria-label="Task wall · per keeper">
      <ZoneHeader
        title="TASK · PER-KEEPER WALL"
        branch="main"
        keepers={["nick0cave","masc-improver","sangsu","qa-king"]}
        meta={`${keepers.length} keepers · grouped by owner`}
      />
      <div className="body">
        <div className="tz-wall" role="list" aria-label="Per-keeper task columns">
          {keepers.map(k => {
            const ts = P2.tasks.filter(t => t.keeper === k);
            return (
              <div key={k}
                   role="listitem"
                   className={`kpr ${ts.length === 0 ? 'empty' : ''}`}
                   aria-label={`${k} · ${ts.length} task${ts.length === 1 ? '' : 's'}${ts.some(t=>t.status==='running') ? ' · running' : ''}`}>
                <div className="h" aria-hidden="true">
                  <Dot kind={kClass(k)} size="sm" beat={ts.some(t=>t.status==='running')} />
                  <span className="nm">{k}</span>
                  <span className="cn">{ts.length}</span>
                </div>
                <div role="list" aria-label={`Tasks owned by ${k}`}>
                  {ts.length === 0
                    ? <div className="tk" role="listitem" aria-label="Idle">— idle —</div>
                    : ts.map(t => (
                        <div key={t.id} className={`tk ${t.status}`} role="listitem" aria-label={`${t.id} · ${t.title} · ${t.status}`}>
                          <span className="id" aria-hidden="true">{t.id.replace('task-','')}</span>
                          <span className="t" aria-hidden="true" title={t.title}>{t.title}</span>
                        </div>
                      ))
                  }
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}

// ═══════════════════════════════════════════════════════════════════
// G3 · ACCOUNTABILITY
// ═══════════════════════════════════════════════════════════════════

// G3-A · Daily ledger
function AccountabilityLedger() {
  return (
    <section className="cbp" aria-label="Accountability daily ledger">
      <ZoneHeader
        title="ACCOUNTABILITY · DAILY LEDGER"
        branch="main"
        keepers={["nick0cave","sangsu","velvet-hammer","taskmaster"]}
        meta="2026-04-25 · 7 verdicts"
        right={<span className="meta">approved 3 · flagged 2 · rejected 1 · deferred 1</span>}
      />
      <div className="body flat" style={{overflow:'auto'}}>
        <div role="log" aria-label="Daily verdict ledger" aria-live="polite" aria-relevant="additions">
          {P2.ledger.map((row, i) => (
            <article key={i}
                 className="ac-row"
                 aria-label={`${row.ts} · ${row.verdict} · ${row.subject} · evidence ${row.evidence} · signed by ${row.signed_by} · scope ${row.scope}`}>
              <span className="ts" aria-hidden="true">{row.ts}</span>
              <span className={`vd ${row.verdict}`} aria-hidden="true">{row.verdict}</span>
              <span className="sub" aria-hidden="true">
                {row.subject}
                <span className="ev">evidence: {row.evidence}</span>
              </span>
              <span className="sig" aria-hidden="true">
                {row.signed_by}
                <span className="scope">{row.scope}</span>
              </span>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

// G3-B · Responsibility matrix (keeper × scope)
function ResponsibilityMatrix() {
  const { rows, cols, grid } = P2.responsibility;
  const bucket = (n) => {
    if (n === 0) return 'z0';
    if (n <= 2) return 'z1';
    if (n <= 4) return 'z2';
    if (n <= 6) return 'z3';
    return 'z4';
  };
  return (
    <section className="cbp" aria-label="Responsibility matrix · keeper × scope">
      <ZoneHeader
        title="ACCOUNTABILITY · RESPONSIBILITY MATRIX"
        branch="main"
        keepers={rows.slice(0, 4)}
        meta={`${rows.length} keepers × ${cols.length} scopes · last 7 days`}
      />
      <div className="body" style={{overflow:'auto'}}>
        <table className="ac-mtx" aria-label={`Responsibility matrix · ${rows.length} keepers · ${cols.length} scopes`}>
          <thead>
            <tr>
              <th className="row-h" scope="col" style={{textAlign:'left'}}>keeper / scope</th>
              {cols.map(c => <th key={c} className="col-h" scope="col">{c}</th>)}
              <th scope="col" style={{width:32}}>Σ</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(r => {
              const total = grid[r].reduce((a,b)=>a+b, 0);
              return (
                <tr key={r}>
                  <th className="row-h" scope="row">{r}</th>
                  {grid[r].map((n, i) => (
                    <td key={i} className={bucket(n)} aria-label={`${r} × ${cols[i]}: ${n} verdicts`} title={`${r} × ${cols[i]}: ${n} verdicts`}>{n || '·'}</td>
                  ))}
                  <td style={{color:'var(--brass-1)', fontWeight:600}} aria-label={`${r} total: ${total} verdicts`}>{total}</td>
                </tr>
              );
            })}
            <tr style={{borderTop:'2px solid var(--brass-2)'}}>
              <th className="row-h" scope="row" style={{color:'var(--brass-1)'}}>Σ scope</th>
              {cols.map((_, i) => {
                const sum = rows.reduce((a, r) => a + grid[r][i], 0);
                return <td key={i} aria-label={`${cols[i]} total: ${sum} verdicts`} style={{color:'var(--brass-1)', fontWeight:600}}>{sum}</td>;
              })}
              <td aria-label={`Grand total verdicts`} style={{color:'var(--brass-1)', fontWeight:600}}>{rows.reduce((a, r) => a + grid[r].reduce((x,y)=>x+y, 0), 0)}</td>
            </tr>
          </tbody>
        </table>
        <div role="note" aria-label="Matrix density legend" style={{marginTop:8, padding:'6px 8px', fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--color-fg-disabled)', display:'flex', gap:8, alignItems:'center'}}>
          <span aria-hidden="true">density:</span>
          <span aria-hidden="true" style={{padding:'1px 6px', background:'var(--color-bg-page)', border:'1px solid var(--color-border-default)'}}>0</span>
          <span aria-hidden="true" style={{padding:'1px 6px', background:'rgb(var(--brass-glow)/.05)', color:'var(--color-fg-secondary)'}}>1–2</span>
          <span aria-hidden="true" style={{padding:'1px 6px', background:'rgb(var(--brass-glow)/.12)', color:'var(--color-fg-primary)'}}>3–4</span>
          <span aria-hidden="true" style={{padding:'1px 6px', background:'rgb(var(--brass-glow)/.22)', color:'var(--brass-1)'}}>5–6</span>
          <span aria-hidden="true" style={{padding:'1px 6px', background:'var(--brass-1)', color:'var(--color-bg-page)'}}>7+</span>
        </div>
      </div>
    </section>
  );
}

// ─── publish to window ───────────────────────────────────────────
Object.assign(window, {
  ZoneHeader,
  GoalHorizonTrack, GoalMetricTree, GoalSnapshotDiff,
  TaskBacklog, TaskStaleAlert, TaskWall,
  AccountabilityLedger, ResponsibilityMatrix,
});
