/* global React, MASC_P2 */
const { useState, useMemo, useEffect, useRef } = React;

const PLANES = ["Dashboard", "Work", "Comms", "Observe", "Cognition", "IDE"];

// ============== Topbar ==============
function Topbar({ goal, goals, mode, setMode, density, setDensity, branch, setBranch }) {
  const [brOpen, setBrOpen] = useState(false);
  const branches = (window.MASC_P2 && window.MASC_P2.branches) || [];
  const cur = branches.find(b => b.name === branch) || branches[0] || { name:"main", ahead:0, behind:0, head:"—" };
  const popRef = useRef(null);

  useEffect(() => {
    if (!brOpen) return;
    const close = (e) => {
      if (popRef.current && !popRef.current.contains(e.target)) setBrOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [brOpen]);

  return (
    <div className="topbar" style={{position:"relative"}}>
      <div className="tb-brand">
        <span className="tb-dot"></span>
        <span className="tb-name">MASC</span>
      </div>
      <span className="tb-sep"></span>
      {window.RepoSelector ? <window.RepoSelector/> : null}
      <span className="tb-sep"></span>
      <div className="tb-branch" onClick={() => setBrOpen(o => !o)} title={`HEAD ${cur.head}`}>
        <span className="nm">{cur.name}</span>
        <span className="ahbh">
          <span className="ah">↑{cur.ahead}</span>
          <span className="bh">↓{cur.behind}</span>
        </span>
        <span className="chev">▾</span>
      </div>
      {brOpen && (
        <div className="tb-branch-pop" ref={popRef}>
          <div className="h">switch branch · {branches.length} known</div>
          {branches.map(b => (
            <div key={b.name}
                 className={"row " + (b.name === branch ? "on" : "")}
                 onClick={() => { setBranch(b.name); setBrOpen(false); }}>
              <span className="glyph">⎇</span>
              <span className="nm">{b.name}</span>
              <span className="ahbh"><span className="ah">↑{b.ahead}</span><span className="bh">↓{b.behind}</span></span>
              <span className={"st " + b.status}>{b.status}</span>
            </div>
          ))}
        </div>
      )}
      <span className="tb-sep"></span>
      <div className="tb-goal" title={goal.id}>
        <span className="chip active"><span className="d"></span>{goal.id.replace("goal-","")}</span>
        <span>{goal.title}</span>
        <span className="chev">▾</span>
      </div>
      <span className="tb-sep"></span>
      <div className="tb-modes">
        {PLANES.map(m => (
          <button key={m} className={"tb-mode" + (mode===m ? " active":"")} onClick={()=>setMode(m)}>{m}</button>
        ))}
      </div>
      <div className="tb-push"></div>
      <div className="tb-density">
        {["compact","normal","comfy"].map(d => (
          <button key={d} className={density===d ? "active":""} onClick={()=>setDensity(d)}>{d}</button>
        ))}
      </div>
      <span className="tb-build">v0.42.1 · build 2847 · {cur.name}@{cur.head.slice(0,7)}</span>
    </div>
  );
}

// ============== Ticker ==============
function Ticker({ events }) {
  const kmap = { "nick0cave":"brass","masc-improver":"ok","sangsu":"info","qa-king":"err","rama":"stalled","scholar":"idle" };
  const line = (ev, i) => (
    <span key={i} className="tk-ev">
      <span className="t">{ev.t}</span>
      <span className={"kn " + kmap[ev.keeper]} style={{color:"var(--"+ (kmap[ev.keeper]==="idle"?"fg-2":kmap[ev.keeper]==="brass"?"brass-1":kmap[ev.keeper]+"-fg") +")"}}>{ev.keeper}</span>
      <span className={"k "+ev.kind}>{ev.kind}</span>
      <span className="n">{ev.text}</span>
    </span>
  );
  const run = [...events, ...events].map((ev,i)=>(
    <React.Fragment key={i}>
      {line(ev,i)}
      <span className="tk-sep">·</span>
    </React.Fragment>
  ));
  return (
    <div className="ticker">
      <div className="ticker-run">{run}</div>
    </div>
  );
}

// ============== KPI Strip ==============
function KpiStrip() {
  const [col, toggle] = (window.useCollapsed ? window.useCollapsed("kpi") : [false, () => {}]);
  // "Spotlight" — surface the most urgent KPI as the first, larger cell.
  // Priority: cascade@step ≥ 2 > stalled keepers > failed tests > token velocity
  const D = window.MASC_DATA || {};
  const stalled = (D.keepers || []).filter(k => k.status === "stalled");
  const cascadeHits = 2; // mock seeded
  const fails = 3;
  let spot;
  if (cascadeHits >= 2) {
    spot = { label: "Cascade @step\u22652", value: cascadeHits, unit: "@step", tone: "info", note: "anthropic → moonshot", urgent: true };
  } else if (stalled.length > 0) {
    spot = { label: "Stalled", value: stalled.length, unit: "", tone: "stalled", note: stalled[0].id + " · 22m", urgent: true };
  } else if (fails > 0) {
    spot = { label: "Fails", value: fails, unit: "/47", tone: "err", note: "merge-blockers", urgent: true };
  } else {
    spot = { label: "Tokens/sec", value: "1.24", unit: "tps", tone: "brass", note: "▲ +0.10 · 5m", urgent: false };
  }
  return (
    <div className={"kpi" + (col ? " wx-collapsed" : "")}>
      <div className="kpi-collapse-tab" onClick={toggle} title={col ? "expand KPI" : "collapse KPI"}>
        {col ? "▸ KPI · " + (spot.urgent ? "⚠ " + spot.label : "8 metrics") : "▾"}
        {!col && (
          <a className="wx-popout"
             href="?widget=kpi"
             target="_blank" rel="noopener"
             onClick={(e)=>e.stopPropagation()}
             title="open KPI strip in new tab"
             style={{marginLeft:"auto"}}>↗</a>
        )}
      </div>
      <div className={"kpi-cell spotlight " + (spot.urgent ? "urgent" : "")}>
        <span className="kpi-l">◆ SPOTLIGHT · {spot.label}</span>
        <span className={"kpi-v " + spot.tone}>{spot.value}{spot.unit && <span className="u">{spot.unit}</span>}</span>
        <span className="kpi-d">{spot.note}</span>
      </div>
      <div className="kpi-cell live">
        <span className="kpi-l">Tokens/sec</span>
        <span className="kpi-v brass">1.24<span className="u">tps</span></span>
        <span className="kpi-d up">▲ +0.10 · 5m</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Pass Rate</span>
        <span className="kpi-v ok">87<span className="u">%</span></span>
        <span className="kpi-d up">▲ +2 · 1h</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Fails</span>
        <span className="kpi-v err">3<span className="u">/47</span></span>
        <span className="kpi-d dn">▼ −2 · 1h</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Cascade Hits</span>
        <span className="kpi-v info">2<span className="u">@step</span></span>
        <span className="kpi-d">anthropic → moonshot</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Open PRs</span>
        <span className="kpi-v">4</span>
        <span className="kpi-d">#9712 #9718 #9721 #9724</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Active Keepers</span>
        <span className="kpi-v">2<span className="u">/ 8</span></span>
        <span className="kpi-d">nick0cave · masc-improver</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Stalled</span>
        <span className="kpi-v" style={{color:"var(--stalled-fg)"}}>1</span>
        <span className="kpi-d">rama · 22m</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Goal Progress</span>
        <span className="kpi-v">14<span className="u">/24</span></span>
        <span className="kpi-d">58% · 4 goals</span>
      </div>
    </div>
  );
}

// ============== Lifeline ==============
function Lifeline() {
  const [col, toggleLife] = (window.useCollapsed ? window.useCollapsed("lifeline") : [false, () => {}]);
  // Build a heartbeat trace from real keeper events instead of pure sin wave.
  // Each event becomes a peak; baseline runs flat.
  const D = window.MASC_DATA || {};
  const events = (D.events || []).slice(0, 24);
  const N = 120;
  const pts = [];
  // Map events to x positions (most recent on right).
  const eventX = events.map((e, i) => Math.floor(N - 1 - (i * (N-2) / Math.max(events.length-1,1))));
  const eventKind = {};
  events.forEach((e, i) => { eventKind[eventX[i]] = e.kind; });
  for (let i = 0; i < N; i++) {
    const x = (i / (N-1)) * 600;
    const base = 12;
    let y = base + Math.sin(i * 0.18) * 0.5;
    const k = eventKind[i];
    if (k === "fail")     y = 2;
    else if (k === "cascade") y = 4;
    else if (k === "nudge")   y = 6;
    else if (k === "claim" || k === "verify") y = 8;
    pts.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  }
  const d = "M" + pts.join(" L");
  // Render event markers as small dots.
  const markers = events.slice(0, 8).map((e, i) => ({
    x: (eventX[i] / (N-1)) * 600,
    kind: e.kind,
    keeper: e.keeper,
  }));
  return (
    <div className={"life" + (col ? " wx-collapsed" : "")}>
      <span className="life-label" onClick={toggleLife} title={col ? "expand lifeline" : "collapse lifeline"} style={{cursor:"pointer"}}>
        {col ? "▸" : "▾"} Lifeline · 60s
      </span>
      <div className="life-trace">
        <svg viewBox="0 0 600 20" preserveAspectRatio="none">
          <path d={d} stroke="var(--color-accent-fg)" strokeWidth="1" fill="none" />
          {markers.map((m, i) => (
            <circle key={i} cx={m.x} cy={m.kind === "fail" ? 2 : m.kind === "cascade" ? 4 : 6} r="1.6"
              fill={m.kind === "fail" ? "var(--err-fg)" : m.kind === "cascade" ? "var(--info-fg)" : m.kind === "nudge" ? "var(--brass-1)" : "var(--ok-fg)"} />
          ))}
        </svg>
      </div>
      <span className="life-now">
        <span className="life-dot"></span> {events.length} events · NOW
        <a className="wx-popout"
           href="?widget=lifeline"
           target="_blank" rel="noopener"
           onClick={(e)=>e.stopPropagation()}
           title="open lifeline in new tab"
           style={{marginLeft:"8px"}}>↗</a>
      </span>
    </div>
  );
}

Object.assign(window, { Topbar, Ticker, KpiStrip, Lifeline });
