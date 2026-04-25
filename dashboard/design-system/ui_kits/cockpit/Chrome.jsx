/* global React */
const { useState, useMemo, useEffect } = React;

// ============== Topbar ==============
function Topbar({ goal, goals, mode, setMode, density, setDensity }) {
  return (
    <div className="topbar">
      <div className="tb-brand">
        <span className="tb-dot"></span>
        <span className="tb-name">MASC</span>
      </div>
      <span className="tb-sep"></span>
      <div className="tb-goal" title={goal.id}>
        <span className="chip active"><span className="d"></span>{goal.id.replace("goal-","")}</span>
        <span>{goal.title}</span>
        <span className="chev">▾</span>
      </div>
      <span className="tb-sep"></span>
      <div className="tb-modes">
        {["Dashboard","Split","Code"].map(m => (
          <button key={m} className={"tb-mode" + (mode===m ? " active":"")} onClick={()=>setMode(m)}>{m}</button>
        ))}
      </div>
      <div className="tb-push"></div>
      <div className="tb-density">
        {["compact","normal","comfy"].map(d => (
          <button key={d} className={density===d ? "active":""} onClick={()=>setDensity(d)}>{d}</button>
        ))}
      </div>
      <span className="tb-build">v0.42.1 · build 2847 · main@e81a7f</span>
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
  return (
    <div className="kpi">
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
  // Build a nice heartbeat trace (deterministic)
  const pts = [];
  const N = 120;
  for (let i=0;i<N;i++) {
    const x = (i/(N-1))*600;
    const base = 10;
    let y = base;
    if (i%14 === 2) y = 2;
    else if (i%14 === 3) y = 18;
    else if (i%14 === 4) y = 6;
    else if (i%14 === 10) y = 14;
    else y = base + (Math.sin(i*0.4)*1.5);
    pts.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  }
  const d = "M"+pts.join(" L");
  return (
    <div className="life">
      <span className="life-label">Lifeline · 60s</span>
      <div className="life-trace">
        <svg viewBox="0 0 600 20" preserveAspectRatio="none">
          <path d={d} stroke="var(--brass-1)" strokeWidth="1" fill="none" />
        </svg>
      </div>
      <span className="life-now"><span className="life-dot"></span> 1.24 TPS · NOW</span>
    </div>
  );
}

Object.assign(window, { Topbar, Ticker, KpiStrip, Lifeline });
