/* global React, MASC_DATA */
/* StatusTray — Slack-style bottom-left status dock.
   Always-visible row of compact dot indicators that summarize the chrome
   we hide in focus mode (kpi spotlight, lifeline pulse, latest ticker
   event, active keepers count, drawer state).

   Each dot is clickable → opens a small popover with the full widget
   inline. This way focus mode loses no information — just compresses it.

   Lives in bottom-left so it doesn't fight the FocusToggle (bottom-right)
   or the Composer (which is hidden in focus mode anyway). */

const { useState: _stUseState, useEffect: _stUseEffect, useRef: _stUseRef } = React;

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

function _kpiSpotlight(D) {
  const evs = (D && D.events) || [];
  const fails = evs.filter(e => e.kind === "fail").length;
  const cascades = evs.filter(e => e.kind === "cascade").length;
  if (fails >= 3) return { l: "Fails", v: fails, t: "err",  u: "/47", urgent: true };
  if (cascades >= 2) return { l: "Cascade", v: cascades, t: "info", u: "@step" };
  return { l: "tps", v: "1.24", t: "brass", u: "tps" };
}

function StatusTray() {
  const D = window.MASC_DATA || {};
  const [cs, setCs] = (window.useCockpitState ? window.useCockpitState() : [{trayHidden:false}, ()=>{}]);
  const hidden = !!cs.trayHidden;
  const [open, setOpen, ref] = _useTrayPop();
  const spot = _kpiSpotlight(D);
  const events = (D.events || []).slice(-1)[0];
  const evCount = (D.events || []).length;
  const keepers = (D.keepers || []);
  const activeK = keepers.filter(k => k.status !== "idle").length;
  const stalled = keepers.filter(k => k.status === "stalled").length;

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
