/* global React, MASC_DATA */
/* StatusTray — Slack-style bottom-left status dock.
   Always-visible row of compact dot indicators that summarize the chrome
   we hide in focus mode (kpi spotlight, lifeline pulse, latest ticker
   event, active keepers count, drawer state).

   Each dot is clickable → opens a small popover with the full widget
   inline. This way focus mode loses no information — just compresses it.

   Lives in bottom-left so it doesn't fight the FocusToggle (bottom-right)
   or the Composer (which is hidden in focus mode anyway). */

const { useState: _stUseState, useEffect: _stUseEffect, useRef: _stUseRef, useMemo: _stUseMemo } = React;

function _useTrayPop() {
  const [open, setOpen] = _stUseState(null); // 'kpi' | 'life' | 'ticker' | 'keepers' | null
  const ref = _stUseRef(null);
  _stUseEffect(() => {
    if (!open) return;
    const onDoc = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(null);
    };
    const onKey = (e) => { if (e.key === "Escape") setOpen(null); };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);
  return [open, setOpen, ref];
}

// Count events + keepers in a single pass each. The previous version
// iterated `events` and `keepers` four times and used `Array.filter` for
// pure counts; this version is allocation-free and easier to extend.
function _statusCounts(D) {
  const evs = (D && D.events) || [];
  let fails = 0;
  let cascades = 0;
  for (const e of evs) {
    if (!e) continue;
    if (e.kind === "fail") fails++;
    else if (e.kind === "cascade") cascades++;
  }
  const keepers = (D && D.keepers) || [];
  let active = 0;
  let stalled = 0;
  for (const k of keepers) {
    if (!k) continue;
    if (k.status !== "idle") active++;
    if (k.status === "stalled") stalled++;
  }
  return {
    fails,
    cascades,
    evCount: evs.length,
    lastEvent: evs.length > 0 ? evs[evs.length - 1] : null,
    keepersTotal: keepers.length,
    active,
    stalled,
  };
}

// Pick the dot to spotlight in the KPI slot. Only the urgent paths
// have real meaning today; for the calm path we expose the raw event
// count rather than a fabricated TPS number.
function _kpiSpotlight(counts) {
  if (counts.fails >= 3) return { l: "fails", v: counts.fails, t: "err", u: "", urgent: true };
  if (counts.cascades >= 2) return { l: "cascade", v: counts.cascades, t: "info", u: "" };
  return { l: "events", v: counts.evCount, t: "brass", u: "" };
}

function StatusTray() {
  const D = window.MASC_DATA || {};
  const [cs, setCs] = (window.useCockpitState ? window.useCockpitState() : [{trayHidden:false}, ()=>{}]);
  const hidden = !!cs.trayHidden;
  const [open, setOpen, ref] = _useTrayPop();
  const counts = _stUseMemo(() => _statusCounts(D), [D.events, D.keepers]);
  const spot = _kpiSpotlight(counts);
  const events = counts.lastEvent;
  const evCount = counts.evCount;
  const keepers = D.keepers || [];
  const activeK = counts.active;
  const stalled = counts.stalled;

  if (hidden) return null;

  const item = (id, dotClass, label, sub) => (
    <button className={"st-item" + (open === id ? " open" : "")}
            onClick={() => setOpen(open === id ? null : id)}
            title={label + (sub ? " · " + sub : "")}>
      <span className={"st-dot " + dotClass}></span>
      <span className="st-l">{label}</span>
      {sub != null && <span className="st-sub">{sub}</span>}
    </button>
  );

  return (
    <div className="status-tray" ref={ref}>
      {item("kpi",
            "k-" + spot.t + (spot.urgent ? " urgent" : ""),
            spot.l,
            spot.v + (spot.u || ""))}
      {item("life",
            "k-" + (spot.urgent ? "err" : "ok"),
            "lifeline",
            evCount + " ev")}
      {item("ticker",
            "k-info",
            "ticker",
            events ? (events.kind || "ev") : "—")}
      {item("keepers",
            stalled > 0 ? "k-warn" : "k-ok",
            "keepers",
            activeK + "/" + keepers.length)}
      <button className="st-close"
              onClick={() => setCs({ trayHidden: true })}
              title="hide status tray (re-enable from focus button menu)">×</button>

      {open && (
        <div className="st-pop" data-pop={open}>
          {open === "kpi" && window.KpiStrip && <window.KpiStrip />}
          {open === "life" && window.Lifeline && <window.Lifeline />}
          {open === "ticker" && (
            <div className="st-list">
              <div className="st-list-h">recent activity</div>
              {(D.events || []).slice(-12).reverse().map((e, i) => (
                <div className="st-list-row" key={i}>
                  <span className={"st-dot k-" + (e.kind === "fail" ? "err" : e.kind === "cascade" ? "info" : "ok")}></span>
                  <span className="st-list-keeper">{e.keeper || "system"}</span>
                  <span className="st-list-kind">{e.kind}</span>
                  <span className="st-list-msg">{e.summary || e.msg || ""}</span>
                </div>
              ))}
            </div>
          )}
          {open === "keepers" && (
            <div className="st-list">
              <div className="st-list-h">fleet · {activeK}/{keepers.length} active</div>
              {keepers.map(k => (
                <div className="st-list-row" key={k.id}>
                  <span className={"st-dot k-" + (k.status === "stalled" ? "warn" : k.status === "idle" ? "ok" : "info")}></span>
                  <span className="st-list-keeper">{k.id}</span>
                  <span className="st-list-kind">{k.status}</span>
                  <span className="st-list-msg">{k.last_action || ""}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

window.StatusTray = StatusTray;
