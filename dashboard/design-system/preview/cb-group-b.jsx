// cb-group-b.jsx — Sidebar, Swimlanes, Deck, Rail
const D2 = window.MASC_DATA;

function activateOnEnterOrSpace(handler) {
  return (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      handler();
    }
  };
}

// ─── SIDEBAR variants ──────────────────────────────────────────────
function SidebarFleet() {
  const [sel, setSel] = useState('nick0cave');
  return (
    <nav className="cb-sidebar" aria-label="Fleet sidebar">
      <SectionHeading title="FLEET" count={D2.keepers.length} />
      <div role="list" aria-label="Keepers">
        {D2.keepers.map(k => (
          <div key={k.id}
               role="listitem"
               aria-label={`${k.id} · ${k.task} · ${k.status}${sel===k.id ? ' · selected' : ''}`}
               aria-current={sel===k.id ? 'true' : undefined}
               tabIndex={0}
               onClick={()=>setSel(k.id)}
               onKeyDown={activateOnEnterOrSpace(()=>setSel(k.id))}
               className={`row ${sel===k.id?'sel':''} ${k.status==='idle'?'idle':''}`}>
            <KeeperBadge id={k.id} variant="sigil" size="sm" beat={k.status==='running'} />
            <span className="name" aria-hidden="true">{k.id}</span>
            <span className="meta" aria-hidden="true">{k.task}</span>
          </div>
        ))}
      </div>
      <SectionHeading title="GOALS" count={D2.goals.length} style={{marginTop:4}} />
      <div role="list" aria-label="Goals">
        {D2.goals.map(g => (
          <div key={g.id}
               role="listitem"
               aria-label={`${g.id} · ${g.title} · ${g.progress} of ${g.total} · priority ${g.priority}`}
               className="row goal-row">
            <div className="id" aria-hidden="true">{g.id}</div>
            <div className="title" aria-hidden="true">{g.title}</div>
            <div className="meta-row" aria-hidden="true">
              <span>{g.progress}/{g.total}</span>
              <span className="bar" style={{flex:1, height:3}}><span className="fill" style={{width:`${100*g.progress/g.total}%`}} /></span>
              <span>P{g.priority}</span>
            </div>
          </div>
        ))}
      </div>
    </nav>
  );
}

function SidebarGrouped() {
  const active = D2.keepers.filter(k=>k.status==='running'||k.status==='pending');
  const other = D2.keepers.filter(k=>!(k.status==='running'||k.status==='pending'));
  const [sel, setSel] = useState('nick0cave');
  return (
    <nav className="cb-sidebar" aria-label="Fleet sidebar (grouped)">
      <SectionHeading title="ACTIVE" count={active.length} />
      <div role="list" aria-label="Active keepers">
        {active.map(k => (
          <div key={k.id}
               role="listitem"
               aria-label={`${k.id} · ${k.t || k.task}${sel===k.id ? ' · selected' : ''}`}
               aria-current={sel===k.id ? 'true' : undefined}
               tabIndex={0}
               onClick={()=>setSel(k.id)}
               onKeyDown={activateOnEnterOrSpace(()=>setSel(k.id))}
               className={`row ${sel===k.id?'sel':''}`}>
            <KeeperBadge id={k.id} variant="sigil" size="sm" beat={k.status==='running'} />
            <span className="name" aria-hidden="true">{k.id}</span>
            <span className="meta" aria-hidden="true">{k.t || k.task}</span>
          </div>
        ))}
      </div>
      <SectionHeading title="STANDBY" count={other.length} />
      <div role="list" aria-label="Standby keepers">
        {other.map(k => (
          <div key={k.id} role="listitem" aria-label={`${k.id} · ${k.status}`} className="row idle">
            <Dot kind={k.status==='stalled'?'stalled':k.status==='fail'?'err':'idle'} size="sm" />
            <span className="name" aria-hidden="true">{k.id}</span>
            <span className="meta" aria-hidden="true">{k.status}</span>
          </div>
        ))}
      </div>
    </nav>
  );
}

function SidebarIcons() {
  const [sel, setSel] = useState('nick0cave');
  return (
    <nav className="cb-sidebar icons" aria-label="Fleet sidebar (icons)">
      <SectionHeading title="FLEET" count={D2.keepers.length} />
      <div role="list" aria-label="Keepers">
        {D2.keepers.map(k => (
          <div key={k.id}
               role="listitem"
               aria-label={`${k.role}: ${k.id} · ${k.task}${sel===k.id ? ' · selected' : ''}`}
               aria-current={sel===k.id ? 'true' : undefined}
               tabIndex={0}
               onClick={()=>setSel(k.id)}
               onKeyDown={activateOnEnterOrSpace(()=>setSel(k.id))}
               className={`row ${sel===k.id?'sel':''} ${k.status==='idle'?'idle':''}`}>
            <span className="icon" aria-hidden="true">{k.role[0]}</span>
            <KeeperBadge id={k.id} variant="sigil" size="sm" beat={k.status==='running'} />
            <span className="name" aria-hidden="true">{k.id}</span>
            <span className="meta" aria-hidden="true">{k.task}</span>
          </div>
        ))}
      </div>
    </nav>
  );
}

// ─── SWIMLANES variants ────────────────────────────────────────────
function SwimlanesGlyph() {
  const lanes = D2.keepers.slice(0,5);
  const [sel, setSel] = useState('nick0cave');
  const nowX = 0.78;
  return (
    <div className="cb-swim" role="region" aria-label="Fleet swimlanes · 60-second window">
      <div className="axis" aria-hidden="true">
        <span>-60s</span><span>-45s</span><span>-30s</span><span>-15s</span><span>NOW</span>
      </div>
      <div className="lanes-body" role="list" aria-label="Keeper timelines">
        {lanes.map(k => (
          <div key={k.id}
               role="listitem"
               aria-label={`${k.id} timeline${sel===k.id ? ' · selected' : ''}`}
               aria-current={sel===k.id ? 'true' : undefined}
               tabIndex={0}
               onClick={()=>setSel(k.id)}
               onKeyDown={activateOnEnterOrSpace(()=>setSel(k.id))}
               className={`lane ${sel===k.id?'sel':''}`}>
            <div className="lane-head">
              <KeeperBadge id={k.id} variant="sigil" size="sm" beat={k.status==='running'} />
              <span className="name" aria-hidden="true">{k.id}</span>
            </div>
            <div className="lane-track" aria-hidden="true">
              {(D2.laneEvents[k.id]||[]).map((e,i) => (
                <span key={i} className={`ev ev-${e.k}`} style={{left:`${e.x*100}%`}} />
              ))}
            </div>
          </div>
        ))}
        <div className="now" aria-hidden="true" style={{left:`calc(130px + ${nowX*100}% - ${nowX*130}px)`}}>
          <span className="head">NOW</span>
        </div>
      </div>
    </div>
  );
}
function SwimlanesDense() {
  const lanes = D2.keepers.slice(0,8);
  const nowX = 0.78;
  return (
    <div className="cb-swim dense" role="region" aria-label="Fleet swimlanes · dense, 60-second window">
      <div className="axis" aria-hidden="true">
        <span>-60s</span><span>-45s</span><span>-30s</span><span>-15s</span><span>NOW</span>
      </div>
      <div className="lanes-body" role="list" aria-label="Keeper timelines (dense)">
        {lanes.map(k => (
          <div key={k.id} role="listitem" aria-label={`${k.id} timeline`} className="lane">
            <div className="lane-head">
              <KeeperBadge id={k.id} variant="sigil" size="sm" beat={k.status==='running'} />
              <span className="name" aria-hidden="true">{k.id}</span>
            </div>
            <div className="lane-track" aria-hidden="true">
              {(D2.laneEvents[k.id]||[]).map((e,i) => (
                <span key={i} className={`ev ev-${e.k}`} style={{left:`${e.x*100}%`}} />
              ))}
            </div>
          </div>
        ))}
        <div className="now" aria-hidden="true" style={{left:`calc(130px + ${nowX*100}% - ${nowX*130}px)`}}>
          <span className="head">NOW</span>
        </div>
      </div>
    </div>
  );
}
function SwimlanesBars() {
  const lanes = D2.keepers.slice(0,5);
  const nowX = 0.78;
  const agg = {
    'nick0cave':     [{x:.05,w:.14},{x:.22,w:.22},{x:.60,w:.16}],
    'masc-improver': [{x:.08,w:.20},{x:.42,w:.28}],
    'sangsu':        [{x:.06,w:.12},{x:.28,w:.14},{x:.52,w:.14}],
    'qa-king':       [{x:.08,w:.18},{x:.36,w:.30}],
    'rama':          [{x:.06,w:.22}],
  };
  return (
    <div className="cb-swim bars" role="region" aria-label="Fleet swimlanes · aggregated bars, 60-second window">
      <div className="axis" aria-hidden="true">
        <span>-60s</span><span>-45s</span><span>-30s</span><span>-15s</span><span>NOW</span>
      </div>
      <div className="lanes-body" role="list" aria-label="Keeper aggregated timelines">
        {lanes.map(k => (
          <div key={k.id} role="listitem" aria-label={`${k.id} aggregated timeline`} className="lane">
            <div className="lane-head">
              <KeeperBadge id={k.id} variant="sigil" size="sm" beat={k.status==='running'} />
              <span className="name" aria-hidden="true">{k.id}</span>
            </div>
            <div className="lane-track" aria-hidden="true">
              {(agg[k.id]||[]).map((a,i) => (
                <span key={i} className="agg" style={{left:`${a.x*100}%`, width:`${a.w*100}%`}} />
              ))}
            </div>
          </div>
        ))}
        <div className="now" aria-hidden="true" style={{left:`calc(130px + ${nowX*100}% - ${nowX*130}px)`}}>
          <span className="head">NOW</span>
        </div>
      </div>
    </div>
  );
}

// ─── DECK variants ─────────────────────────────────────────────────
const TABS = [
  ['board','Board',0],['tasks','Tasks',7],['goals','Goals',4],
  ['ver','Verified',12],['prov','Providers',4],['sand','Sandbox',0],['casc','Cascade',3],
];

function DeckTabs({active, onSelect}) {
  return (
    <div className="tabs" role="tablist" aria-label="Deck sections">
      {TABS.map(([k,l,n]) => (
        <button key={k}
                type="button"
                role="tab"
                aria-selected={active===k}
                tabIndex={active===k ? 0 : -1}
                aria-label={n ? `${l}, ${n} items` : l}
                className={`tab ${active===k?'on':''}`}
                onClick={onSelect ? ()=>onSelect(k) : undefined}>
          {l}{n ? <span className="badge" aria-hidden="true">{n}</span> : null}
        </button>
      ))}
    </div>
  );
}

function DeckTasks() {
  const [tab, setTab] = useState('tasks');
  const [sel, setSel] = useState('t-9f2a');
  return (
    <div className="cb-deck">
      <DeckTabs active={tab} onSelect={setTab} />
      <div className="body" role="tabpanel" aria-label="Tasks">
        <table aria-label="Task list">
          <thead><tr><th scope="col">ID</th><th scope="col">Task</th><th scope="col">Keeper</th><th scope="col">Goal</th><th scope="col">Status</th><th scope="col">T</th></tr></thead>
          <tbody>
            {D2.tasks.map(t => (
              <tr key={t.id}
                  className={sel===t.id?'sel':''}
                  aria-current={sel===t.id ? 'true' : undefined}
                  tabIndex={0}
                  onClick={()=>setSel(t.id)}
                  onKeyDown={activateOnEnterOrSpace(()=>setSel(t.id))}>
                <td>{t.id}</td>
                <td className="title">{t.title}</td>
                <td><KeeperBadge id={t.keeper} variant="full" size="sm" /></td>
                <td>{t.goal}</td>
                <td><Pill kind={t.status==='running'?'running':t.status==='fail'?'err':t.status==='stalled'?'stalled':t.status==='pending'?'info':'paused'}>{t.status}</Pill></td>
                <td>{t.t}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function DeckKanban() {
  const cols = [
    ['Queued',   D2.tasks.filter(t=>t.status==='queued')],
    ['Running',  D2.tasks.filter(t=>t.status==='running')],
    ['Pending',  D2.tasks.filter(t=>t.status==='pending')],
    ['Blocked',  D2.tasks.filter(t=>t.status==='stalled'||t.status==='fail')],
  ];
  return (
    <div className="cb-deck">
      <DeckTabs active="board" />
      <div className="cb-kanban" role="tabpanel" aria-label="Kanban board">
        {cols.map(([title, items]) => (
          <div key={title} role="region" aria-label={`${title} · ${items.length} tasks`} className="col">
            <div className="col-h" role="heading" aria-level={4}>{title} <span className="ct" aria-hidden="true">{items.length}</span></div>
            <div role="list" aria-label={`${title} tasks`}>
              {items.map(t => (
                <div key={t.id}
                     role="listitem"
                     aria-label={`${t.id} · ${t.title} · ${t.keeper} · ${t.t}`}
                     className={`card ${t.status==='running'?'running':''} ${t.status==='fail'?'fail':''}`}>
                  <span className="id" aria-hidden="true">{t.id}</span>
                  <span className="title" aria-hidden="true">{t.title}</span>
                  <span className="foot" aria-hidden="true">
                    <KeeperBadge id={t.keeper} variant="full" size="sm" /> · {t.t}
                  </span>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function DeckProviders() {
  return (
    <div className="cb-deck">
      <DeckTabs active="prov" />
      <div className="cb-pmatrix" role="tabpanel" aria-label="Providers">
        <div role="table" aria-label="Provider capability matrix" aria-rowcount={D2.providers.length + 1}>
          <div className="row h" role="row" aria-rowindex={1} aria-hidden="true"><span>PROVIDER</span><span>MODEL</span><span style={{textAlign:'right'}}>TPS</span><span style={{textAlign:'right'}}>CAS</span><span>TREND</span><span style={{textAlign:'right'}}>ST</span></div>
          {D2.providers.map((p, i) => (
            <div key={p.id}
                 role="row"
                 aria-rowindex={i + 2}
                 aria-label={`${p.id} · ${p.model} · TPS ${p.tps} · cascade ${p.cascade} · status ${p.status}`}
                 className="row">
              <span className="pname" role="cell" aria-hidden="true">{p.id}</span>
              <span className="model" role="cell" aria-hidden="true">{p.model}</span>
              <span className="tps" role="cell" aria-hidden="true">{p.tps}</span>
              <span className="cas" role="cell" aria-hidden="true">@{p.cascade}</span>
              <span role="cell" aria-hidden="true"><Spark color={p.status==='ok'?'ok':p.status==='warn'?'warn':'brass'} bars={18} /></span>
              <span style={{textAlign:'right'}} role="cell" aria-hidden="true">
                <Chip kind={p.status==='ok'?'ok':p.status==='warn'?'warn':'ghost'}>{p.status.toUpperCase()}</Chip>
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── RAIL variants ────────────────────────────────────────────────
function RailActivity() {
  return (
    <aside className="cb-rail" aria-label="Activity rail">
      <div className="sec">
        <SectionHeading title="ACTIVITY" right="11 · 60s" />
        <div className="body" role="log" aria-live="polite" aria-label="Recent fleet events" style={{maxHeight:320, overflow:'auto'}}>
          {D2.events.map((e, i) => (
            <div key={i}
                 role="article"
                 aria-label={`${e.t.slice(0,8)} · ${e.keeper} ${e.kind}: ${e.text}`}
                 className={`ev ${e.kind}`}>
              <span className="t" aria-hidden="true">{e.t.slice(0,8)}</span>
              <span className="icon" aria-hidden="true"><KeeperBadge id={e.keeper} variant="sigil" size="sm" /></span>
              <span className="body" aria-hidden="true">
                <span className="who">{e.keeper}</span>
                <span className="text">{e.text}</span>
              </span>
            </div>
          ))}
        </div>
      </div>
    </aside>
  );
}

function RailCascade() {
  return (
    <aside className="cb-rail" aria-label="Cascade rail">
      <div className="sec">
        <SectionHeading title="CASCADE" right="cascade-3f19" />
        <div className="cb-cascade" role="region" aria-label={`Cascade trace cascade-3f19 · hit at step 2 · total ${D2.cascade.total_ms}ms`}>
          <span className="id" aria-hidden="true">trace · hit @step=2</span>
          <ol aria-label="Cascade steps" style={{listStyle:'none', margin:0, padding:0}}>
            {D2.cascade.steps.map((s, i) => (
              <li key={i}
                  className={`step ${s.status==='hit'?'hit':s.status==='miss'?'miss':'skip'}`}
                  aria-label={`Step ${i+1} · ${s.provider} · ${s.status}${s.ms ? ` · ${s.ms}ms` : ''}${s.reason ? ` · ${s.reason}` : ''}`}>
                <span className="ix" aria-hidden="true">{s.status==='hit'?'●':s.status==='miss'?'✕':'·'}</span>
                <span className="name" aria-hidden="true">{s.provider}</span>
                <span className="ms" aria-hidden="true">{s.ms ? `${s.ms}ms` : s.reason}</span>
              </li>
            ))}
          </ol>
          <div className="total" aria-hidden="true">total <span className="n">{D2.cascade.total_ms}ms</span> · hit@step 2</div>
        </div>
      </div>
      <div className="sec">
        <SectionHeading title="RECENT" right="3" />
        <div className="body" role="log" aria-live="polite" aria-label="Recent events">
          {D2.events.slice(0,3).map((e,i) => (
            <div key={i}
                 role="article"
                 aria-label={`${e.t.slice(0,8)} · ${e.keeper} ${e.kind}: ${e.text}`}
                 className={`ev ${e.kind}`}>
              <span className="t" aria-hidden="true">{e.t.slice(0,8)}</span>
              <span className="icon" aria-hidden="true"><KeeperBadge id={e.keeper} variant="sigil" size="sm" /></span>
              <span className="body" aria-hidden="true">
                <span className="who">{e.keeper}</span>
                <span className="text">{e.text}</span>
              </span>
            </div>
          ))}
        </div>
      </div>
    </aside>
  );
}

Object.assign(window, {
  SidebarFleet, SidebarGrouped, SidebarIcons,
  SwimlanesGlyph, SwimlanesDense, SwimlanesBars,
  DeckTasks, DeckKanban, DeckProviders,
  RailActivity, RailCascade,
});
