/* global React, MASC_DATA, WxHead, useCollapsed */
const { useState } = React;
const _Wx = (props) => (window.WxHead ? React.createElement(window.WxHead, props) : null);
const _useCol = (id) => (window.useCollapsed ? window.useCollapsed(id) : [false, () => {}]);
const _isToggleKey = (e) => e.key === "Enter" || e.key === " " || e.key === "Spacebar";
const _fromNestedControl = (e) =>
  e.target !== e.currentTarget &&
  e.target.closest &&
  e.target.closest("a,button,input,textarea,select");

const keeperTone = { "nick0cave":"brass", "masc-improver":"ok", "sangsu":"info", "qa-king":"err", "rama":"stalled", "scholar":"idle", "taskmaster":"idle", "velvet-hammer":"idle" };
const statusColor = s => ({ running:"running", ok:"ok", pending:"info", fail:"err", stalled:"stalled", idle:"idle", queued:"queued", done:"done", active:"active" }[s] || "idle");

// ============== Sidebar ==============
// Section header — collapsible per-section, no outer wx-head wrapper
function SideSectHead({ id, label, count, right, onCollapseAll, popoutId }) {
  const [col, toggle] = _useCol(id);
  const onKeyDown = (e) => {
    if (_fromNestedControl(e)) return;
    if (_isToggleKey(e)) {
      e.preventDefault();
      toggle();
    }
  };
  return (
    <div className="side-sect-h sx" onClick={toggle} onKeyDown={onKeyDown} role="button" tabIndex={0} aria-expanded={!col}>
      <span className="sx-chev">{col ? "▸" : "▾"}</span>
      <span className="sx-lbl">{label}</span>
      {count != null && <span className="count">{count}</span>}
      {right}
      {popoutId && (
        <a className="wx-popout"
           href={"?widget=" + popoutId}
           target="_blank" rel="noopener"
           onClick={(e)=>e.stopPropagation()}
           title="open in new tab">↗</a>
      )}
      {onCollapseAll && (
        <span className="sx-rail" onClick={(e)=>{ e.stopPropagation(); onCollapseAll(); }} title="collapse rail">«</span>
      )}
    </div>
  );
}
function SideSectBody({ id, children, style }) {
  const [col] = _useCol(id);
  if (col) return null;
  return <div className="side-sect-body" style={style}>{children}</div>;
}

function Sidebar({ keepers, goals, selKeeper, setSelKeeper, selGoal, setSelGoal, selectedKeepers, toggleKeeper }) {
  const sk = selectedKeepers || new Set();
  const [colSide, toggleSide] = _useCol("sidebar");
  if (colSide) {
    return (
      <aside
        className="side wx-collapsed"
        onClick={toggleSide}
        onKeyDown={(e) => {
          if (e.repeat) return;
          if (_isToggleKey(e)) {
            e.preventDefault();
            toggleSide();
          }
        }}
        role="button"
        tabIndex={0}
        title="expand sidebar"
        aria-label="expand sidebar">
        <div className="wx-rail-vlabel">FLEET · GOALS</div>
      </aside>
    );
  }
  return (
    <aside className="side">
      <div className="side-sect">
        <SideSectHead id="sidebar.fleet" label="Fleet"
          count={`${keepers.filter(k=>k.status!=="idle").length}/${keepers.length}`}
          popoutId="sidebar"
          onCollapseAll={toggleSide} />
        <SideSectBody id="sidebar.fleet">
          {keepers.map(k => (
            <div key={k.id}
                 className={"keeper-row " + (k.status==="idle"?"idle ":"") + (selKeeper===k.id?"selected":"")}
                 onClick={()=>setSelKeeper(k.id)}>
              <span className={"d " + k.status}></span>
              <span className="nm">{k.id}</span>
              <span className="meta">{k.task}</span>
            </div>
          ))}
        </SideSectBody>
      </div>
      <div className="side-sect">
        <SideSectHead id="sidebar.filter" label="Filter" count={`${sk.size}/${keepers.length}`} />
        <SideSectBody id="sidebar.filter" style={{paddingTop:0}}>
          <div className="side-keepers">
            <div className="chips">
              {keepers.map(k => {
                const on = sk.has(k.id);
                return (
                  <span key={k.id}
                        className={"ch " + (on ? "on" : "")}
                        onClick={() => toggleKeeper && toggleKeeper(k.id)}>
                    <span className={"d " + k.status}></span>
                    <span>{k.id}</span>
                  </span>
                );
              })}
            </div>
          </div>
        </SideSectBody>
      </div>
      <div className="side-sect side-sect-goals">
        <SideSectHead id="sidebar.goals" label="Goals" count={goals.length} />
        <SideSectBody id="sidebar.goals">
          {goals.map(g => (
            <div key={g.id}
                 className={"goal-row " + (g.status==="done"?"done ":"") + (selGoal===g.id?"selected":"")}
                 onClick={()=>setSelGoal(g.id)}>
              <div className="id">{g.id}</div>
              <div className="ti">{g.title}</div>
              <div className="bar"><div className="fill" style={{width: (g.progress/g.total*100)+"%"}}></div></div>
              <div className="mt">
                <span className={"chip "+statusColor(g.status)}><span className="d"></span>{g.status}</span>
                <span>{g.progress}/{g.total}</span>
                <span>·</span>
                <span>p{g.priority}</span>
              </div>
            </div>
          ))}
        </SideSectBody>
      </div>
    </aside>
  );
}

// ============== Swimlanes ==============
function Swimlanes({ keepers, laneEvents }) {
  const fleet = keepers.filter(k => k.status !== "idle");
  return (
    <div className="sw">
      <div className="sw-head">
        <h3>Swimlanes · last 6 min</h3>
        <span className="meta">6 lanes · 72% = NOW · brass column marks current tick</span>
      </div>
      <div className="sw-body">
        {fleet.map(k => (
          <div key={k.id} className="sw-lane">
            <span className="nm" style={{color:`var(--${keeperTone[k.id]==="brass" ? "brass-1" : keeperTone[k.id]+"-fg"})`}}>{k.id}</span>
            <div className="sw-track">
              {(laneEvents[k.id]||[]).map((e,i) => (
                <span key={i} className={"sw-ev "+e.k} style={{left: (e.x*100)+"%"}}></span>
              ))}
            </div>
          </div>
        ))}
        <div className="sw-now" style={{left: "calc(110px + (100% - 110px) * 0.72)"}}></div>
      </div>
    </div>
  );
}

// ============== Deck ==============
function Deck({ tasks, goals, providers, cascade }) {
  const [tab, setTab] = useState("board");
  const [colDeck] = _useCol("deck");
  const tabs = [
    { id:"board",     label:"Board",     ct: tasks.filter(t=>t.status!=="queued").length },
    { id:"tasks",     label:"Tasks",     ct: tasks.length },
    { id:"goals",     label:"Goals",     ct: goals.length },
    { id:"verified",  label:"Verified",  ct: 128 },
    { id:"providers", label:"Providers", ct: providers.length },
    { id:"cascade",   label:"Cascade",   ct: 2 },
    { id:"sandbox",   label:"Sandbox" },
  ];

  const statusCols = [
    { k:"running", label:"Running" },
    { k:"pending", label:"Pending / Stalled" },
    { k:"fail",    label:"Fail / Queued" },
  ];

  return (
    <div className={"deck" + (colDeck ? " wx-collapsed" : "")}>
      {_Wx({ id:"deck", title:"Deck", meta: `${tab} · ${tasks.length} tasks`, popoutId: "deck" })}
      <div className="deck-tabs">
        {tabs.map(t => (
          <button key={t.id} className={"deck-tab " + (tab===t.id?"active":"")} onClick={()=>setTab(t.id)}>
            {t.label}
            {t.ct != null && <span className="ct">{t.ct}</span>}
          </button>
        ))}
      </div>
      <div className="deck-body">

        {tab === "board" && (
          <div className="board">
            {statusCols.map(col => {
              const items = tasks.filter(t =>
                col.k === "running" ? t.status === "running"
                : col.k === "pending" ? (t.status === "pending" || t.status === "stalled")
                : (t.status === "fail" || t.status === "queued")
              );
              return (
                <div key={col.k} className="board-col">
                  <div className="board-col-h"><span>{col.label}</span><span className="ct">{items.length}</span></div>
                  {items.map(t => (
                    <div key={t.id} className={"card " + (t.status==="running" ? "running" : "")}>
                      <div className="top">
                        <span className="id">{t.id}</span>
                        <span className={"chip "+statusColor(t.status)}><span className="d"></span>{t.status}</span>
                      </div>
                      <div className="title">{t.title}</div>
                      <div className="meta">
                        <span style={{color:`var(--${keeperTone[t.keeper]==="brass" ? "brass-1" : keeperTone[t.keeper]+"-fg"})`, fontWeight:600}}>{t.keeper}</span>
                        <span>·</span>
                        <span>{t.goal.replace("goal-","")}</span>
                        <span style={{marginLeft:"auto"}}>{t.t}</span>
                      </div>
                    </div>
                  ))}
                </div>
              );
            })}
          </div>
        )}

        {tab === "tasks" && (
          <table className="tbl">
            <thead><tr>
              <th style={{width:80}}>ID</th>
              <th>Title</th>
              <th style={{width:130}}>Keeper</th>
              <th style={{width:130}}>Goal</th>
              <th style={{width:100}}>Status</th>
              <th style={{width:60}}>T</th>
            </tr></thead>
            <tbody>
              {tasks.map(t => (
                <tr key={t.id} className={t.status==="running" ? "running":""}>
                  <td style={{color:"var(--color-fg-muted)"}}>{t.id}</td>
                  <td>{t.title}</td>
                  <td style={{color:`var(--${keeperTone[t.keeper]==="brass" ? "brass-1" : keeperTone[t.keeper]+"-fg"})`}}>{t.keeper}</td>
                  <td style={{color:"var(--color-fg-muted)"}}>{t.goal.replace("goal-","")}</td>
                  <td><span className={"chip "+statusColor(t.status)}><span className="d"></span>{t.status}</span></td>
                  <td style={{color:"var(--color-fg-muted)"}}>{t.t}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {tab === "goals" && (
          <div style={{display:"flex",flexDirection:"column",gap:12}}>
            {goals.map(g => (
              <div key={g.id} className="card" style={{padding:"14px 16px",gap:8}}>
                <div className="top">
                  <span className="id">{g.id}</span>
                  <span className={"chip "+statusColor(g.status)}><span className="d"></span>{g.status}</span>
                </div>
                <div className="title" style={{fontSize:14}}>{g.title}</div>
                <div className="meta" style={{gap:14}}>
                  <span>priority {g.priority}</span>
                  <span>·</span>
                  <span>{g.progress} / {g.total} tasks</span>
                  <span style={{flex:1,marginLeft:10,height:4,background:"var(--color-bg-page)",border:"1px solid var(--color-border-default)",borderRadius:1,overflow:"hidden"}}>
                    <span style={{display:"block",height:"100%",width:(g.progress/g.total*100)+"%",background:g.status==="done"?"var(--ok-fg)":"var(--color-accent-fg)"}}></span>
                  </span>
                  <span>{Math.round(g.progress/g.total*100)}%</span>
                </div>
              </div>
            ))}
          </div>
        )}

        {tab === "verified" && (
          <table className="tbl">
            <thead><tr><th>PR</th><th>Title</th><th>Reviewers</th><th>Verified</th><th>Merged</th></tr></thead>
            <tbody>
              <tr><td>#9712</td><td>dashboard/goals: batch-rename backport</td><td>sangsu · nick0cave</td><td><span className="chip ok"><span className="d"></span>pass</span></td><td>3m ago</td></tr>
              <tr><td>#9718</td><td>keeper.claim() clarity refactor</td><td>sangsu</td><td><span className="chip ok"><span className="d"></span>pass</span></td><td>12m ago</td></tr>
              <tr><td>#9721</td><td>cascade retry @step=2 regression fix</td><td>sangsu · qa-king</td><td><span className="chip warn"><span className="d"></span>drift</span></td><td>32m ago</td></tr>
              <tr><td>#9724</td><td>suite-merge-blockers de-flake</td><td>qa-king</td><td><span className="chip err"><span className="d"></span>fail</span></td><td>—</td></tr>
            </tbody>
          </table>
        )}

        {tab === "providers" && (
          <div className="prov-list">
            {providers.map(p => (
              <div key={p.id} className="prov">
                <div className="n">{p.id}</div>
                <div className="m">{p.model}</div>
                <div className="t">{p.tps.toFixed(2)}<span className="u">tps</span></div>
                <div className={"chip "+statusColor(p.status)}><span className="d"></span>{p.status}</div>
                <div className="cascade-n">cascade #{p.cascade}</div>
              </div>
            ))}
          </div>
        )}

        {tab === "cascade" && (
          <div className="cascade">
            <div className="cascade-head"><h3>Cascade · {cascade.id}</h3><span className="tm">total {cascade.total_ms}ms</span></div>
            <div className="cascade-steps">
              {cascade.steps.map((s,i)=>(
                <div key={i} className={"cascade-step " + (s.status==="hit"?"hit":s.status==="miss"?"miss":"skip")}>
                  <span className="pv">{s.provider}</span>
                  <span className="st">{s.status}</span>
                  <span className="ms">{s.ms}ms · {s.reason}</span>
                </div>
              ))}
            </div>
            <div style={{font:"10px/1.5 var(--font-mono)",color:"var(--color-fg-muted)",paddingTop:4}}>
              Triggered by <span style={{color:"var(--color-accent-fg)"}}>nick0cave</span> on <span style={{color:"var(--color-fg-primary)"}}>t-9f2a</span> · soft rate-limit on anthropic → fell through to moonshot at step 2 · kimi-k2 responded in 420ms.
            </div>
          </div>
        )}

        {tab === "sandbox" && (
          <div style={{font:"12px/1.6 var(--font-mono)", color:"var(--color-fg-secondary)"}}>
            <div style={{color:"var(--color-fg-muted)",marginBottom:8}}>$ keeper.sandbox — ephemeral scratch env</div>
            <pre style={{margin:0,color:"var(--color-fg-primary)"}}>{
`> keeper.claim({ goal: "goal-merge-blockers", priority: 1 })
  ↳ task=t-9f2a assigned to nick0cave

> keeper.trace({ cascade: "cascade-3f19" })
  ↳ anthropic[miss 820ms] → moonshot[hit 420ms] · total 1240ms

> keeper.verify("suite-merge-blockers")
  ↳ 3 FAIL / 47 PASS
`
            }</pre>
          </div>
        )}
      </div>
    </div>
  );
}

// ============== Rail ==============
function RailSectHead({ id, label, count, right, onCollapseAll, popoutId }) {
  const [col, toggle] = _useCol(id);
  const onKeyDown = (e) => {
    if (_fromNestedControl(e)) return;
    if (_isToggleKey(e)) {
      e.preventDefault();
      toggle();
    }
  };
  return (
    <div className="rail-sect-h sx" onClick={toggle} onKeyDown={onKeyDown} role="button" tabIndex={0} aria-expanded={!col}>
      <span className="sx-chev">{col ? "▸" : "▾"}</span>
      <span className="sx-lbl">{label}</span>
      {count != null && <span className="count">{count}</span>}
      {right}
      {popoutId && (
        <a className="wx-popout"
           href={"?widget=" + popoutId}
           target="_blank" rel="noopener"
           onClick={(e)=>e.stopPropagation()}
           title="open in new tab">↗</a>
      )}
      {onCollapseAll && (
        <span className="sx-rail" onClick={(e)=>{ e.stopPropagation(); onCollapseAll(); }} title="collapse rail">»</span>
      )}
    </div>
  );
}
function RailSectBody({ id, children, style, className }) {
  const [col] = _useCol(id);
  if (col) return null;
  return <div className={"rail-sect-body " + (className||"")} style={style}>{children}</div>;
}

function Rail({ events, cascade }) {
  const nudges = (window.MASC_P2 && window.MASC_P2.nudges) || [];
  const [colRail, toggleRail] = _useCol("rail");
  if (colRail) {
    return (
      <aside
        className="rail wx-collapsed"
        onClick={toggleRail}
        onKeyDown={(e) => {
          if (e.repeat) return;
          if (_isToggleKey(e)) {
            e.preventDefault();
            toggleRail();
          }
        }}
        role="button"
        tabIndex={0}
        title="expand activity rail"
        aria-label="expand activity rail">
        <div className="wx-rail-vlabel">ACTIVITY · NUDGES</div>
      </aside>
    );
  }
  return (
    <aside className="rail">
      <div className="rail-sect flex">
        <RailSectHead id="rail.activity" label="Activity Feed" count={events.length} popoutId="rail" onCollapseAll={toggleRail} />
        <RailSectBody id="rail.activity">
          {events.map((ev,i) => (
            <div key={i} className="activity">
              <span className="t">{ev.t.slice(0,8)}</span>
              <span className={"d "+ev.kind}></span>
              <span className="tx">
                <span className={"kn "+keeperTone[ev.keeper]}>{ev.keeper}</span>
                {ev.text}
              </span>
            </div>
          ))}
        </RailSectBody>
      </div>
      <div className="rail-sect">
        <RailSectHead id="rail.nudges" label="Operator Nudges" count={`${nudges.filter(n => !n.ack).length}/${nudges.length}`} />
        <RailSectBody id="rail.nudges" className="rail-nudges">
          {nudges.slice(0, 5).map(n => (
            <div key={n.id} className="rail-nudge">
              <span className={"ch "+n.channel}>{n.channel}</span>
              <span className="body">
                {n.to.map(t => <span key={t} className="to">@{t}</span>)}
                {n.body}
                <span className="ts">{n.at.replace("Z","")}</span>
              </span>
              <span className={"ack "+(n.ack ? "y" : "n")}>{n.ack ? "✓" : "…"}</span>
            </div>
          ))}
        </RailSectBody>
      </div>
      <div className="rail-sect">
        <RailSectHead id="rail.cascade" label="Last Cascade" count={`${cascade.total_ms}ms`} />
        <RailSectBody id="rail.cascade" style={{padding:"0 var(--sp-3) var(--sp-3)"}}>
          {cascade.steps.map((s,i)=>(
            <div key={i} style={{
              display:"grid", gridTemplateColumns:"80px auto 1fr auto",
              gap:8, alignItems:"center",
              padding:"6px 0", borderBottom:"1px solid var(--color-border-default)",
              font:"10px/1 var(--font-mono)"
            }}>
              <span style={{color:"var(--color-fg-primary)",fontWeight:600}}>{s.provider}</span>
              <span className={"chip "+(s.status==="hit"?"ok":s.status==="miss"?"warn":"idle")}>
                <span className="d"></span>{s.status}
              </span>
              <span style={{color:"var(--color-fg-muted)"}}>{s.reason}</span>
              <span style={{color:"var(--color-fg-secondary)",fontVariantNumeric:"tabular-nums"}}>{s.ms}ms</span>
            </div>
          ))}
        </RailSectBody>
      </div>
    </aside>
  );
}

// ============== Composer ==============
function Composer({ selKeeper }) {
  const [val, setVal] = useState("");
  const [hist, setHist] = useState([
    { ts:"16:31", kp:"nick0cave", cmd:"keeper.claim(t-9f2a)",  ok:true  },
    { ts:"16:24", kp:"sangsu",    cmd:"keeper.trace(cascade-3f19)", ok:true },
    { ts:"16:18", kp:"qa-king",   cmd:"verify(suite-merge-blockers)", ok:false },
  ]);
  const ctxLabel = (window.MASC_P2 && window.MASC_P2.repos)
    ? `${selKeeper} → ${(window.MASC_EXT?.initialState?.().repo) || "runtime"} / ${(window.MASC_EXT?.initialState?.().branch) || "main"}`
    : selKeeper;
  const submit = () => {
    if (!val.trim()) return;
    setHist(h => [{ ts:"now", kp:selKeeper, cmd: val.trim(), ok:true }, ...h.slice(0,4)]);
    setVal("");
  };
  return (
    <div className="compose">
      <span className="compose-prompt" title={ctxLabel}>▸ {selKeeper}:</span>
      <input className="compose-input"
             value={val}
             onChange={(e)=>setVal(e.target.value)}
             onKeyDown={(e)=>{ if (e.key === "Enter") submit(); }}
             placeholder="keeper.claim(task) · keeper.trace(cascade_id) · /goal goal-keeper-clarity …" />
      <div className="compose-hist" title="recent commands">
        {hist.slice(0,3).map((h,i) => (
          <span key={i} className={"hb " + (h.ok?"ok":"err")}>
            <span className="ht">{h.ts}</span>
            <span className="hk">{h.kp}</span>
            <span className="hc">{h.cmd}</span>
          </span>
        ))}
      </div>
      <span className="compose-hint">⏎ run · ⌘K palette · ? help</span>
      <button className="compose-btn" onClick={submit}>Run</button>
    </div>
  );
}

// ============== Status Bar ==============
function StatusBar({ providers }) {
  return (
    <div className="status">
      <span>MASC · v0.42.1 · build 2847 · main@e81a7f</span>
      <span>· 8 keepers</span>
      <span>· 4 goals</span>
      <span>· 2 running</span>
      <span className="push"></span>
      {providers.map(p => (
        <span key={p.id} className="prov">
          <span className={"d "+p.status}></span>
          {p.id} {p.tps.toFixed(2)}
        </span>
      ))}
      <span>· UTC 16:33:02</span>
    </div>
  );
}

Object.assign(window, { Sidebar, Swimlanes, Deck, Rail, Composer, StatusBar });
