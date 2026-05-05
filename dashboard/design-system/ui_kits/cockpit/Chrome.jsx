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

function kpiArray(value) {
  return Array.isArray(value) ? value : [];
}

function kpiText(value) {
  return value === null || value === undefined ? "" : String(value);
}

function kpiNorm(value) {
  return kpiText(value).toLowerCase();
}

function kpiFirstArray() {
  for (let i = 0; i < arguments.length; i++) {
    const rows = kpiArray(arguments[i]);
    if (rows.length) return rows;
  }
  return [];
}

function kpiList(items, render, fallback) {
  const out = items.map(render).filter(Boolean).slice(0, 3);
  return out.length ? out.join(" · ") : fallback;
}

function kpiFixed(value, digits) {
  const s = value.toFixed(digits);
  return s.replace(/(\.\d*?)0+$/, "$1").replace(/\.$/, "");
}

function kpiEventText(ev) {
  return [
    ev && ev.kind,
    ev && ev.text,
    ev && ev.summary,
    ev && ev.msg,
    ev && ev.message,
  ].map(kpiText).join(" ");
}

function kpiIsFailureEvent(ev) {
  const kind = kpiNorm(ev && ev.kind);
  return ["fail", "failed", "err", "error"].indexOf(kind) >= 0 ||
    /\b(fail|failed|error|timeout)\b/i.test(kpiEventText(ev));
}

function kpiIsCascadeEvent(ev) {
  const kind = kpiNorm(ev && ev.kind);
  return kind === "cascade" || /\bcascade\b|hit@step|@step\s*=?\s*\d+/i.test(kpiEventText(ev));
}

function kpiPassFail(events) {
  let pass = 0;
  let fail = 0;
  events.forEach(ev => {
    const text = kpiEventText(ev);
    const failMatch = text.match(/(\d+)\s*(?:FAIL|FAILED|FAILS)\b/i);
    const passMatch = text.match(/(\d+)\s*(?:PASS|PASSED|PASSES)\b/i);
    if (failMatch) fail += Number(failMatch[1]);
    if (passMatch) pass += Number(passMatch[1]);
  });
  return { pass, fail, total: pass + fail };
}

function kpiCascadeStats(D, events) {
  const cascades = D.cascade ? (Array.isArray(D.cascade) ? D.cascade : [D.cascade]) : [];
  const hits = [];
  cascades.forEach(cascade => {
    const steps = kpiArray(cascade && cascade.steps);
    steps.forEach((step, idx) => {
      if (kpiNorm(step && step.status) === "hit") {
        hits.push({ provider: kpiText(step && step.provider) || "provider", step: idx + 1 });
      }
    });
    if (!steps.length && kpiNorm(cascade && cascade.status) === "hit") {
      hits.push({ provider: kpiText(cascade && cascade.provider) || "cascade", step: null });
    }
  });
  if (hits.length) {
    return {
      count: hits.length,
      note: kpiList(hits, hit => hit.provider + (hit.step ? " @step" + hit.step : ""), "structured cascade"),
    };
  }
  const eventHits = events.filter(kpiIsCascadeEvent);
  return {
    count: eventHits.length,
    note: eventHits.length
      ? kpiList(eventHits, ev => kpiText(ev && ev.keeper) || kpiText(ev && ev.t), "recent events")
      : "no cascade hits",
  };
}

function kpiCollect(D) {
  const empty = "—";
  const keepers = kpiArray(D.keepers);
  const goals = kpiArray(D.goals);
  const tasks = kpiArray(D.tasks);
  const providers = kpiArray(D.providers);
  const events = kpiArray(D.events);
  const prs = kpiFirstArray(D.prs, D.pullRequests, D.pull_requests);

  const activeKeepers = keepers.filter(k => ["active", "busy", "running", "working"].indexOf(kpiNorm(k && k.status)) >= 0);
  const stalledKeepers = keepers.filter(k => ["blocked", "stalled", "stuck"].indexOf(kpiNorm(k && k.status)) >= 0);
  const failedTasks = tasks.filter(t => ["err", "error", "fail", "failed", "stalled"].indexOf(kpiNorm(t && t.status)) >= 0);
  const failureEvents = events.filter(kpiIsFailureEvent);

  const testCounts = kpiPassFail(events);
  const terminalTasks = tasks.filter(t => ["done", "err", "error", "fail", "failed", "ok", "pass", "passed", "success"].indexOf(kpiNorm(t && t.status)) >= 0);
  const doneTasks = terminalTasks.filter(t => ["done", "ok", "pass", "passed", "success"].indexOf(kpiNorm(t && t.status)) >= 0);

  let passRateValue = empty;
  let passRateNote = "no pass/fail feed";
  if (testCounts.total > 0) {
    passRateValue = Math.round((testCounts.pass / testCounts.total) * 100);
    passRateNote = testCounts.pass + "/" + testCounts.total + " passed";
  } else if (terminalTasks.length) {
    passRateValue = Math.round((doneTasks.length / terminalTasks.length) * 100);
    passRateNote = doneTasks.length + "/" + terminalTasks.length + " terminal tasks";
  }

  const failureCount = testCounts.total > 0
    ? testCounts.fail
    : ((tasks.length || events.length) ? failedTasks.length + failureEvents.length : null);
  const failureValue = failureCount === null ? empty : failureCount;
  const failureUnit = testCounts.total > 0 ? "/" + testCounts.total : (tasks.length ? "/" + tasks.length : "");
  const failureNote = testCounts.total > 0
    ? testCounts.pass + " pass"
    : (failureCount > 0
      ? kpiList(failedTasks.concat(failureEvents), item => kpiText(item && item.id) || kpiText(item && item.keeper) || kpiText(item && item.t), "recent failures")
      : "no recent failures");

  const tpsValues = providers.map(p => Number(p && p.tps)).filter(Number.isFinite);
  const tpsTotal = tpsValues.reduce((sum, value) => sum + value, 0);
  const tps = {
    value: tpsValues.length ? kpiFixed(tpsTotal, 2) : empty,
    unit: tpsValues.length ? "tps" : "",
    note: tpsValues.length ? providers.length + " providers" : "no provider telemetry",
    live: tpsValues.length > 0,
  };

  const cascade = kpiCascadeStats(D, events);

  const openPrs = prs.filter(pr => {
    const state = kpiNorm(pr && (pr.state || pr.status));
    return state !== "closed" && state !== "done" && state !== "merged";
  });
  const prMetric = {
    value: prs.length ? openPrs.length : empty,
    note: prs.length
      ? kpiList(openPrs, pr => {
        if (!pr) return "";
        if (pr.number) return "#" + pr.number;
        return kpiText(pr.id || pr.title);
      }, "clear")
      : "no PR feed",
  };

  const goalDone = goals.reduce((sum, goal) => sum + (Number(goal && (goal.task_done_count ?? goal.progress)) || 0), 0);
  const goalTotal = goals.reduce((sum, goal) => sum + (Number(goal && (goal.task_count ?? goal.total)) || 0), 0);
  const goalMetric = {
    value: goalTotal ? goalDone : empty,
    unit: goalTotal ? "/" + goalTotal : "",
    note: goalTotal ? Math.round((goalDone / goalTotal) * 100) + "% · " + goals.length + " goals" : "no goal feed",
  };

  const activeMetric = {
    value: keepers.length ? activeKeepers.length : empty,
    unit: keepers.length ? "/" + keepers.length : "",
    note: activeKeepers.length ? kpiList(activeKeepers, k => kpiText(k && k.id), "active") : "no active keepers",
  };
  const stalledTaskFor = (keeperId) => tasks.find(t => t && t.keeper === keeperId && (kpiNorm(t && t.status) === "stalled" || kpiNorm(t && t.status) === "blocked"));
  const keeperStallNote = (k) => {
    const id = kpiText(k && k.id);
    if (k && k.t) return id + " · " + k.t;
    const linked = stalledTaskFor(k && k.id);
    return linked && linked.t ? id + " · " + linked.t : id;
  };
  const stalledMetric = {
    value: keepers.length ? stalledKeepers.length : empty,
    note: stalledKeepers.length ? kpiList(stalledKeepers, keeperStallNote, "stalled") : "clear",
  };

  let spot = { label: "Tokens/sec", value: tps.value, unit: tps.unit, tone: "brass", note: tps.note, urgent: false };
  if (failureCount > 0) {
    spot = { label: "Fails", value: failureValue, unit: failureUnit, tone: "err", note: failureNote, urgent: true };
  } else if (stalledKeepers.length > 0) {
    spot = { label: "Stalled", value: stalledKeepers.length, unit: "", tone: "stalled", note: stalledMetric.note, urgent: true };
  } else if (cascade.count > 0) {
    spot = { label: "Cascade Hits", value: cascade.count, unit: "", tone: "info", note: cascade.note, urgent: true };
  }

  return {
    spot,
    tps,
    passRate: { value: passRateValue, unit: passRateValue === empty ? "" : "%", note: passRateNote },
    fails: { value: failureValue, unit: failureUnit, note: failureNote },
    cascade,
    prs: prMetric,
    active: activeMetric,
    stalled: stalledMetric,
    goals: goalMetric,
    metricCount: 8,
  };
}

// ============== KPI Strip ==============
function KpiStrip() {
  const [col, toggle] = (window.useCollapsed ? window.useCollapsed("kpi") : [false, () => {}]);
  const stats = kpiCollect(window.MASC_DATA || {});
  const spot = stats.spot;
  return (
    <div className={"kpi" + (col ? " wx-collapsed" : "")}>
      <div
        className="kpi-collapse-tab"
        onClick={toggle}
        onKeyDown={(e) => {
          if (
            e.target !== e.currentTarget &&
            e.target.closest &&
            e.target.closest("a,button,input,textarea,select")
          ) return;
          if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
            e.preventDefault();
            toggle();
          }
        }}
        title={col ? "expand KPI" : "collapse KPI"}
        role="button"
        tabIndex={0}
        aria-expanded={!col}>
        {col ? "▸ KPI · " + (spot.urgent ? "⚠ " + spot.label : stats.metricCount + " metrics") : "▾"}
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
      <div className={"kpi-cell" + (stats.tps.live ? " live" : "")}>
        <span className="kpi-l">Tokens/sec</span>
        <span className="kpi-v brass">{stats.tps.value}{stats.tps.unit && <span className="u">{stats.tps.unit}</span>}</span>
        <span className="kpi-d">{stats.tps.note}</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Pass Rate</span>
        <span className="kpi-v ok">{stats.passRate.value}{stats.passRate.unit && <span className="u">{stats.passRate.unit}</span>}</span>
        <span className="kpi-d">{stats.passRate.note}</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Fails</span>
        <span className="kpi-v err">{stats.fails.value}{stats.fails.unit && <span className="u">{stats.fails.unit}</span>}</span>
        <span className="kpi-d">{stats.fails.note}</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Cascade Hits</span>
        <span className="kpi-v info">{stats.cascade.count}</span>
        <span className="kpi-d">{stats.cascade.note}</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Open PRs</span>
        <span className="kpi-v">{stats.prs.value}</span>
        <span className="kpi-d">{stats.prs.note}</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Active Keepers</span>
        <span className="kpi-v">{stats.active.value}{stats.active.unit && <span className="u">{stats.active.unit}</span>}</span>
        <span className="kpi-d">{stats.active.note}</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Stalled</span>
        <span className="kpi-v" style={{color:"var(--stalled-fg)"}}>{stats.stalled.value}</span>
        <span className="kpi-d">{stats.stalled.note}</span>
      </div>
      <div className="kpi-cell">
        <span className="kpi-l">Goal Progress</span>
        <span className="kpi-v">{stats.goals.value}{stats.goals.unit && <span className="u">{stats.goals.unit}</span>}</span>
        <span className="kpi-d">{stats.goals.note}</span>
      </div>
    </div>
  );
}

// ============== Lifeline ==============
function Lifeline() {
  const [col, toggleLife] = (window.useCollapsed ? window.useCollapsed("lifeline") : [false, () => {}]);
  // Build a heartbeat trace from real keeper events instead of pure sin wave.
  // Each event becomes a peak; baseline runs flat.
  // Map seed event kinds to lifeline peak levels:
  //   err → fail (y=2)  |  flag → cascade (y=4)
  //   note/tool → nudge (y=6)  |  verify → claim (y=8)
  const _kindMap = { err:"fail", flag:"cascade", note:"nudge", tool:"nudge", verify:"claim" };
  const D = window.MASC_DATA || {};
  const events = (D.events || []).slice(0, 24);
  const N = 120;
  const pts = [];
  // Map events to x positions (most recent on right).
  const eventX = events.map((e, i) => Math.floor(N - 1 - (i * (N-2) / Math.max(events.length-1,1))));
  const eventKind = {};
  events.forEach((e, i) => { eventKind[eventX[i]] = _kindMap[e.kind] || "nudge"; });
  for (let i = 0; i < N; i++) {
    const x = (i / (N-1)) * 600;
    const base = 12;
    let y = base + Math.sin(i * 0.18) * 0.5;
    const k = eventKind[i];
    if (k === "fail")     y = 2;
    else if (k === "cascade") y = 4;
    else if (k === "nudge")   y = 6;
    else if (k === "claim")   y = 8;
    pts.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  }
  const d = "M" + pts.join(" L");
  // Render event markers as small dots.
  const markers = events.slice(0, 8).map((e, i) => ({
    x: (eventX[i] / (N-1)) * 600,
    kind: _kindMap[e.kind] || "nudge",
    keeper: e.keeper,
  }));
  return (
    <div className={"life" + (col ? " wx-collapsed" : "")}>
      <button
        type="button"
        className="life-label"
        onClick={toggleLife}
        title={col ? "expand lifeline" : "collapse lifeline"}
        aria-expanded={!col}
        aria-controls="cockpit-lifeline-trace"
        style={{ cursor:"pointer", background:"none", border:0, padding:0 }}>
        {col ? "▸" : "▾"} Lifeline · 60s
      </button>
      <div className="life-trace" id="cockpit-lifeline-trace">
        <svg viewBox="0 0 600 20" preserveAspectRatio="none">
          <path d={d} stroke="var(--color-accent-fg)" strokeWidth="1" fill="none" />
          {markers.map((m, i) => (
            <circle key={i} cx={m.x}
              cy={m.kind === "fail" ? 2 : m.kind === "cascade" ? 4 : m.kind === "claim" ? 8 : 6} r="1.6"
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
