// cb-group-b.jsx — Sidebar, Swimlanes, Deck, Rail
const D2 = window.MASC_DATA;

// ─── SIDEBAR variants ──────────────────────────────────────────────
function SidebarFleet() {
  const [sel, setSel] = useState('nick0cave');
  return (
    <div className="cb-sidebar">
      <div className="sec-h">FLEET <span className="count">{D2.keepers.length}</span></div>
      {D2.keepers.map(k => (
        <div key={k.id} className={`row ${sel===k.id?'sel':''} ${k.status==='idle'?'idle':''}`} onClick={()=>setSel(k.id)}>
          <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
          <span className="name">{k.id}</span>
          <span className="meta">{k.task}</span>
        </div>
      ))}
      <div className="sec-h" style={{marginTop:4}}>GOALS <span className="count">{D2.goals.length}</span></div>
      {D2.goals.map(g => (
        <div key={g.id} className="row goal-row">
          <div className="id">{g.id}</div>
          <div className="title">{g.title}</div>
          <div className="meta-row">
            <span>{g.progress}/{g.total}</span>
            <span className="bar" style={{flex:1, height:3}}><span className="fill" style={{width:`${100*g.progress/g.total}%`}} /></span>
            <span>P{g.priority}</span>
          </div>
        </div>
      ))}
    </div>
  );
}

function SidebarGrouped() {
  const active = D2.keepers.filter(k=>k.status==='running'||k.status==='pending');
  const other = D2.keepers.filter(k=>!(k.status==='running'||k.status==='pending'));
  const [sel, setSel] = useState('nick0cave');
  return (
    <div className="cb-sidebar">
      <div className="sec-h">ACTIVE <span className="count">{active.length}</span></div>
      {active.map(k => (
        <div key={k.id} className={`row ${sel===k.id?'sel':''}`} onClick={()=>setSel(k.id)}>
          <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
          <span className="name">{k.id}</span>
          <span className="meta">{k.t || k.task}</span>
        </div>
      ))}
      <div className="sec-h">STANDBY <span className="count">{other.length}</span></div>
      {other.map(k => (
        <div key={k.id} className="row idle">
          <Dot kind={k.status==='stalled'?'stalled':k.status==='fail'?'err':'idle'} size="sm" />
          <span className="name">{k.id}</span>
          <span className="meta">{k.status}</span>
        </div>
      ))}
    </div>
  );
}

function SidebarIcons() {
  const [sel, setSel] = useState('nick0cave');
  return (
    <div className="cb-sidebar icons">
      <div className="sec-h">FLEET <span className="count">{D2.keepers.length}</span></div>
      {D2.keepers.map(k => (
        <div key={k.id} className={`row ${sel===k.id?'sel':''} ${k.status==='idle'?'idle':''}`} onClick={()=>setSel(k.id)}>
          <span className="icon">{k.role[0]}</span>
          <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
          <span className="name">{k.id}</span>
          <span className="meta">{k.task}</span>
        </div>
      ))}
    </div>
  );
}

// ─── SWIMLANES variants ────────────────────────────────────────────
function SwimlanesGlyph() {
  const lanes = D2.keepers.slice(0,5);
  const [sel, setSel] = useState('nick0cave');
  const nowX = 0.78;
  return (
    <div className="cb-swim">
      <div className="axis">
        <span>-60s</span><span>-45s</span><span>-30s</span><span>-15s</span><span>NOW</span>
      </div>
      <div className="lanes-body">
        {lanes.map(k => (
          <div key={k.id} className={`lane ${sel===k.id?'sel':''}`} onClick={()=>setSel(k.id)}>
            <div className="lane-head">
              <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
              <span className="name">{k.id}</span>
            </div>
            <div className="lane-track">
              {(D2.laneEvents[k.id]||[]).map((e,i) => (
                <span key={i} className={`ev ev-${e.k}`} style={{left:`${e.x*100}%`}} />
              ))}
            </div>
          </div>
        ))}
        <div className="now" style={{left:`calc(130px + ${nowX*100}% - ${nowX*130}px)`}}>
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
    <div className="cb-swim dense">
      <div className="axis">
        <span>-60s</span><span>-45s</span><span>-30s</span><span>-15s</span><span>NOW</span>
      </div>
      <div className="lanes-body">
        {lanes.map(k => (
          <div key={k.id} className="lane">
            <div className="lane-head">
              <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
              <span className="name">{k.id}</span>
            </div>
            <div className="lane-track">
              {(D2.laneEvents[k.id]||[]).map((e,i) => (
                <span key={i} className={`ev ev-${e.k}`} style={{left:`${e.x*100}%`}} />
              ))}
            </div>
          </div>
        ))}
        <div className="now" style={{left:`calc(130px + ${nowX*100}% - ${nowX*130}px)`}}>
          <span className="head">NOW</span>
        </div>
      </div>
    </div>
  );
}
function SwimlanesBars() {
  const lanes = D2.keepers.slice(0,5);
  const nowX = 0.78;
  // aggregate segments
  const agg = {
    'nick0cave':     [{x:.05,w:.14},{x:.22,w:.22},{x:.60,w:.16}],
    'masc-improver': [{x:.08,w:.20},{x:.42,w:.28}],
    'sangsu':        [{x:.06,w:.12},{x:.28,w:.14},{x:.52,w:.14}],
    'qa-king':       [{x:.08,w:.18},{x:.36,w:.30}],
    'rama':          [{x:.06,w:.22}],
  };
  return (
    <div className="cb-swim bars">
      <div className="axis">
        <span>-60s</span><span>-45s</span><span>-30s</span><span>-15s</span><span>NOW</span>
      </div>
      <div className="lanes-body">
        {lanes.map(k => (
          <div key={k.id} className="lane">
            <div className="lane-head">
              <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
              <span className="name">{k.id}</span>
            </div>
            <div className="lane-track">
              {(agg[k.id]||[]).map((a,i) => (
                <span key={i} className="agg" style={{left:`${a.x*100}%`, width:`${a.w*100}%`}} />
              ))}
            </div>
          </div>
        ))}
        <div className="now" style={{left:`calc(130px + ${nowX*100}% - ${nowX*130}px)`}}>
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
function DeckTasks() {
  const [tab, setTab] = useState('tasks');
  const [sel, setSel] = useState('t-9f2a');
  return (
    <div className="cb-deck">
      <div className="tabs">
        {TABS.map(([k,l,n]) => (
          <button key={k} className={`tab ${tab===k?'on':''}`} onClick={()=>setTab(k)}>
            {l}{n ? <span className="badge">{n}</span> : null}
          </button>
        ))}
      </div>
      <div className="body">
        <table>
          <thead><tr><th>ID</th><th>Task</th><th>Keeper</th><th>Goal</th><th>Status</th><th>T</th></tr></thead>
          <tbody>
            {D2.tasks.map(t => (
              <tr key={t.id} className={sel===t.id?'sel':''} onClick={()=>setSel(t.id)}>
                <td>{t.id}</td>
                <td className="title">{t.title}</td>
                <td><Dot kind={kClass(t.keeper)} size="sm" /> {t.keeper}</td>
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
      <div className="tabs">
        {TABS.map(([k,l,n]) => (
          <button key={k} className={`tab ${k==='board'?'on':''}`}>
            {l}{n ? <span className="badge">{n}</span> : null}
          </button>
        ))}
      </div>
      <div className="cb-kanban">
        {cols.map(([title, items]) => (
          <div key={title} className="col">
            <div className="col-h">{title} <span className="ct">{items.length}</span></div>
            {items.map(t => (
              <div key={t.id} className={`card ${t.status==='running'?'running':''} ${t.status==='fail'?'fail':''}`}>
                <span className="id">{t.id}</span>
                <span className="title">{t.title}</span>
                <span className="foot">
                  <Dot kind={kClass(t.keeper)} size="sm" /> {t.keeper} · {t.t}
                </span>
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

function DeckProviders() {
  return (
    <div className="cb-deck">
      <div className="tabs">
        {TABS.map(([k,l,n]) => (
          <button key={k} className={`tab ${k==='prov'?'on':''}`}>{l}{n?<span className="badge">{n}</span>:null}</button>
        ))}
      </div>
      <div className="cb-pmatrix">
        <div className="row h"><span>PROVIDER</span><span>MODEL</span><span style={{textAlign:'right'}}>TPS</span><span style={{textAlign:'right'}}>CAS</span><span>TREND</span><span style={{textAlign:'right'}}>ST</span></div>
        {D2.providers.map(p => (
          <div key={p.id} className="row">
            <span className="pname">{p.id}</span>
            <span className="model">{p.model}</span>
            <span className="tps">{p.tps}</span>
            <span className="cas">@{p.cascade}</span>
            <span><Spark color={p.status==='ok'?'ok':p.status==='warn'?'warn':'brass'} bars={18} /></span>
            <span style={{textAlign:'right'}}>
              <Chip kind={p.status==='ok'?'ok':p.status==='warn'?'warn':'ghost'}>{p.status.toUpperCase()}</Chip>
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─── RAIL variants ────────────────────────────────────────────────
function RailActivity() {
  return (
    <div className="cb-rail">
      <div className="sec">
        <div className="sec-h">ACTIVITY <span className="right">11 · 60s</span></div>
        <div className="body" style={{maxHeight:320, overflow:'auto'}}>
          {D2.events.map((e, i) => (
            <div key={i} className={`ev ${e.kind}`}>
              <span className="t">{e.t.slice(0,8)}</span>
              <span className="icon"><Dot kind={kClass(e.keeper)} size="sm" /></span>
              <span className="body">
                <span className="who">{e.keeper}</span>
                <span className="text">{e.text}</span>
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function RailCascade() {
  return (
    <div className="cb-rail">
      <div className="sec">
        <div className="sec-h">CASCADE <span className="right">cascade-3f19</span></div>
        <div className="cb-cascade">
          <span className="id">trace · hit @step=2</span>
          {D2.cascade.steps.map((s, i) => (
            <div key={i} className={`step ${s.status==='hit'?'hit':s.status==='miss'?'miss':'skip'}`}>
              <span className="ix">{s.status==='hit'?'●':s.status==='miss'?'✕':'·'}</span>
              <span className="name">{s.provider}</span>
              <span className="ms">{s.ms ? `${s.ms}ms` : s.reason}</span>
            </div>
          ))}
          <div className="total">total <span className="n">{D2.cascade.total_ms}ms</span> · hit@step 2</div>
        </div>
      </div>
      <div className="sec">
        <div className="sec-h">RECENT <span className="right">3</span></div>
        <div className="body">
          {D2.events.slice(0,3).map((e,i) => (
            <div key={i} className={`ev ${e.kind}`}>
              <span className="t">{e.t.slice(0,8)}</span>
              <span className="icon"><Dot kind={kClass(e.keeper)} size="sm" /></span>
              <span className="body">
                <span className="who">{e.keeper}</span>
                <span className="text">{e.text}</span>
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, {
  SidebarFleet, SidebarGrouped, SidebarIcons,
  SwimlanesGlyph, SwimlanesDense, SwimlanesBars,
  DeckTasks, DeckKanban, DeckProviders,
  RailActivity, RailCascade,
});
