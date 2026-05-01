/* global React, MASC_DATA, useCockpitState */
/* Drawer.jsx — VSCode-style bottom drawer with Terminal / Output / Cascade / Audit / Cost
   - draggable grip on top edge (resize)
   - double-click grip = snap between 30vh and 60vh
   - tab click on closed drawer opens it
   - X closes
   - state synced via useCockpitState  → drawer: { open, height, tab }
*/
const { useState: dUseState, useEffect: dUseEffect, useRef: dUseRef, useCallback: dUseCallback, useMemo: dUseMemo } = React;

const DRAWER_TABS = [
  { id: "terminal", label: "Terminal", glyph: ">_", count: null },
  { id: "output",   label: "Output",   glyph: "⎯",  count: null },
  { id: "cascade",  label: "Cascade",  glyph: "⇢",  count: 5  },
  { id: "audit",    label: "Audit",    glyph: "§",  count: 12 },
  { id: "cost",     label: "Cost",     glyph: "¤",  count: null },
];

const DRAWER_DEFAULTS = { open: false, height: 280, tab: "terminal" };

// ─── Drawer state hook (lives on cockpit-state singleton) ───────
function useDrawerState() {
  const [s, set] = window.useCockpitState();
  const drawer = { ...DRAWER_DEFAULTS, ...(s.drawer || {}) };
  const setDrawer = dUseCallback((patch) => {
    const next = { ...drawer, ...patch };
    set({ drawer: next });
  }, [drawer]);
  return [drawer, setDrawer];
}

// ─── individual tab panels ──────────────────────────────────────
function TerminalPanel() {
  // mock terminal showing recent claim-loop activity
  const lines = [
    { t: "01:42:18", k: "tx", txt: "$ git fetch --all" },
    { t: "01:42:18", k: "ok", txt: "fetching origin (5 refs)" },
    { t: "01:42:19", k: "ok", txt: "From github.com:masc/runtime" },
    { t: "01:42:19", k: "info", txt: "  da11b063..a8c2e91d  main  →  origin/main" },
    { t: "01:42:20", k: "tx", txt: "$ python -m masc.eval --suite cascade-router --branches feat/keeper-clarity" },
    { t: "01:42:21", k: "info", txt: "→ loading 47 cases · seed=42" },
    { t: "01:42:24", k: "ok", txt: "  ✓ cascade.fanout.basic              (124ms)" },
    { t: "01:42:25", k: "ok", txt: "  ✓ cascade.fanout.with_fallback      (88ms)" },
    { t: "01:42:25", k: "err", txt: "  ✗ cascade.fanout.cycle_detection    (timeout)" },
    { t: "01:42:25", k: "err", txt: "        expected len=3, got len=4 (recursive include)" },
    { t: "01:42:26", k: "ok", txt: "  ✓ cascade.router.priority           (51ms)" },
    { t: "01:42:27", k: "warn", txt: "  ⚠ cascade.router.weighted          (slow: 412ms)" },
    { t: "01:42:28", k: "info", txt: "" },
    { t: "01:42:28", k: "info", txt: "─── 44 passed · 1 failed · 2 slow · 18.4s ────────" },
    { t: "01:42:29", k: "tx", txt: "$ █" },
  ];
  return (
    <div className="dr-term">
      {lines.map((l, i) => (
        <div key={i} className={"dr-term-l k-" + l.k}>
          <span className="t">{l.t}</span>
          <span className="x">{l.txt}</span>
        </div>
      ))}
    </div>
  );
}

function OutputPanel() {
  // pretend log channels — switchable
  const channels = ["claim-loop", "cascade-router", "keeper-shell", "tokens-build", "deploy"];
  const [ch, setCh] = dUseState("claim-loop");
  const lines = {
    "claim-loop": [
      { t: "01:38:00", lv: "info",  txt: "claim-loop tick #4128 · 9 keepers active" },
      { t: "01:38:00", lv: "info",  txt: "  → nick0cave   claim cb-group/i (held 2m12s)" },
      { t: "01:38:00", lv: "info",  txt: "  → sangsu      claim plane-cognition (held 5m04s)" },
      { t: "01:38:00", lv: "warn",  txt: "  ⚠ kraftwerk   stalled 22m04s on cascade.router.weighted" },
      { t: "01:38:01", lv: "info",  txt: "  → coltrane    idle (last seen 3m)" },
      { t: "01:38:02", lv: "info",  txt: "tick complete · 8.1ms" },
      { t: "01:38:30", lv: "info",  txt: "claim-loop tick #4129 · 9 keepers active" },
      { t: "01:38:30", lv: "warn",  txt: "  ⚠ kraftwerk   stalled 22m34s — escalation soon" },
      { t: "01:38:31", lv: "ok",    txt: "  ✓ nick0cave   released cb-group/i (changes pushed)" },
      { t: "01:38:32", lv: "info",  txt: "tick complete · 7.4ms" },
    ],
    "cascade-router": [
      { t: "01:39:14", lv: "info", txt: "router.dispatch  prompt-id=p_8821a1  primary=anthropic/claude-3.5" },
      { t: "01:39:14", lv: "info", txt: "  step 1  anthropic         200ms · 0.012$" },
      { t: "01:39:14", lv: "warn", txt: "  step 1  anthropic         RATE_LIMIT (60s)" },
      { t: "01:39:14", lv: "info", txt: "  step 2  moonshot          318ms · 0.004$" },
      { t: "01:39:15", lv: "ok",   txt: "  → resolved at step=2 (cascade hit, 5/47 today)" },
    ],
    "keeper-shell": [
      { t: "01:40:00", lv: "info", txt: "[nick0cave] shell open · branch=feat/keeper-clarity" },
      { t: "01:40:01", lv: "info", txt: "[nick0cave] $ make test" },
      { t: "01:40:18", lv: "ok",   txt: "[nick0cave] tests passed (44/47)" },
    ],
    "tokens-build": [
      { t: "01:30:01", lv: "info", txt: "tokens:build  target=cockpit/tokens.generated.css" },
      { t: "01:30:02", lv: "ok",   txt: "  3 themes × 142 tokens emitted" },
      { t: "01:30:02", lv: "ok",   txt: "  ✓ build complete · 1.1s" },
    ],
    "deploy": [
      { t: "00:42:00", lv: "info", txt: "deploy.runtime  stage=staging  rev=da11b063" },
      { t: "00:42:34", lv: "ok",   txt: "  ✓ image built · 312MB" },
      { t: "00:43:04", lv: "ok",   txt: "  ✓ rolled out · 0 errors" },
    ],
  }[ch] || [];
  return (
    <div className="dr-output">
      <div className="dr-output-bar">
        <span className="lbl">channel</span>
        <select className="chsel" value={ch} onChange={(e) => setCh(e.target.value)}>
          {channels.map(c => <option key={c} value={c}>{c}</option>)}
        </select>
        <span className="meta">{lines.length} lines · live</span>
      </div>
      <div className="dr-output-body">
        {lines.map((l, i) => (
          <div key={i} className={"dr-out-l lv-" + l.lv}>
            <span className="t">{l.t}</span>
            <span className="lv">{l.lv}</span>
            <span className="x">{l.txt}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function CascadePanel() {
  // Use MASC_P2.cascadeAudit (array of cascade runs with hops) rather than
  // MASC_DATA.cascade which is a single object without the required array shape.
  const cascades = ((window.MASC_P2 && window.MASC_P2.cascadeAudit) || []).slice(0, 6);
  return (
    <div className="dr-cascade">
      <div className="dr-cascade-bar">
        <span className="lbl">recent cascades</span>
        <span className="meta">{cascades.length} shown · 5/47 hit step≥2 today</span>
      </div>
      <div className="dr-cascade-body">
        {cascades.length === 0 && <div className="dr-empty">no cascades yet</div>}
        {cascades.map((c, i) => (
          <div key={i} className="dr-csc">
            <div className="dr-csc-h">
              <span className="id">{c.id || ("csc-" + i)}</span>
              <span className="prompt">{[c.cascade || "(unknown)", c.trigger].filter(Boolean).join(" · ")}</span>
              <span className={"out " + (c.outcome === "ok" ? "ok" : "fail")}>{c.outcome || "—"}</span>
            </div>
            <div className="dr-csc-hops">
              {(c.hops || []).map((h, hi) => (
                <span key={hi} className={"hop " + (h.status || "")}>
                  <span className="ix">{hi + 1}</span>
                  <span className="prov">{h.model || h.provider || h.name}</span>
                  <span className="ms">{h.ms || h.latency_ms || "—"}ms</span>
                </span>
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function AuditPanel() {
  // mock audit ledger
  const rows = [
    { t: "01:42:19", who: "nick0cave",   verdict: "merge", target: "PR #9712 · runtime", note: "ok-with-warnings" },
    { t: "01:38:04", who: "automation",  verdict: "block", target: "PR #9710 · runtime", note: "merge-blockers fail" },
    { t: "01:35:11", who: "sangsu",      verdict: "ack",   target: "ticket-3411",       note: "claim · plane-cognition" },
    { t: "01:30:00", who: "automation",  verdict: "log",   target: "tokens.generated",  note: "drift detected · auto-build" },
    { t: "01:22:48", who: "kraftwerk",   verdict: "release", target: "cb-group/i",      note: "stalled · auto-released" },
    { t: "01:18:02", who: "coltrane",    verdict: "ack",   target: "goal-merge-blockers", note: "claim" },
    { t: "01:12:00", who: "automation",  verdict: "block", target: "PR #9708 · dashboard", note: "type errors" },
    { t: "01:05:30", who: "nick0cave",   verdict: "merge", target: "PR #9706 · runtime", note: "ok" },
    { t: "00:58:14", who: "automation",  verdict: "log",   target: "deploy.runtime",    note: "rev=da11b063 → staging" },
    { t: "00:42:00", who: "automation",  verdict: "log",   target: "rotation.weekly",   note: "9 keepers eligible" },
  ];
  return (
    <div className="dr-audit">
      <div className="dr-audit-bar">
        <span className="lbl">audit · last 60m</span>
        <span className="meta">{rows.length} entries · signed</span>
      </div>
      <div className="dr-audit-body">
        <div className="dr-aud-row dr-aud-h">
          <span className="t">time</span>
          <span className="who">actor</span>
          <span className="vd">verdict</span>
          <span className="tg">target</span>
          <span className="nt">note</span>
        </div>
        {rows.map((r, i) => (
          <div key={i} className="dr-aud-row">
            <span className="t">{r.t}</span>
            <span className="who">{r.who}</span>
            <span className={"vd v-" + r.verdict}>{r.verdict}</span>
            <span className="tg">{r.target}</span>
            <span className="nt">{r.note}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function CostPanel() {
  // mock cost breakdown
  const providers = [
    { name: "anthropic",  used: 0.812, share: 0.42, calls: 1428, lat: 198 },
    { name: "moonshot",   used: 0.341, share: 0.18, calls: 612,  lat: 312 },
    { name: "openai",     used: 0.602, share: 0.31, calls: 891,  lat: 224 },
    { name: "openrouter", used: 0.171, share: 0.09, calls: 244,  lat: 401 },
  ];
  const total = providers.reduce((a, p) => a + p.used, 0);
  return (
    <div className="dr-cost">
      <div className="dr-cost-bar">
        <span className="lbl">spend · today</span>
        <span className="big">${total.toFixed(2)}</span>
        <span className="meta">budget $20 · 9.6% used · projection $4.84/24h</span>
      </div>
      <div className="dr-cost-body">
        <div className="dr-cost-bars">
          {providers.map(p => (
            <div key={p.name} className="dr-cost-row">
              <span className="nm">{p.name}</span>
              <span className="bar"><span className="fill" style={{ width: (p.share * 100).toFixed(1) + "%" }}></span></span>
              <span className="used">${p.used.toFixed(3)}</span>
              <span className="cl">{p.calls} calls</span>
              <span className="lat">{p.lat}ms p50</span>
            </div>
          ))}
        </div>
        <div className="dr-cost-foot">
          <span className="tip">Tip: anthropic at 42% share — cascade fallback to moonshot saved ~$0.18/h vs primary-only.</span>
        </div>
      </div>
    </div>
  );
}

// ─── main Drawer component ──────────────────────────────────────
function Drawer() {
  const [drawer, setDrawer] = useDrawerState();
  const dragRef = dUseRef(null);

  // expose programmatic toggles for keyboard / IDE hint
  dUseEffect(() => {
    window.__drawerToggle = () => setDrawer({ open: !drawer.open });
    window.__drawerSet = (patch) => setDrawer(patch);
    return () => { window.__drawerToggle = null; window.__drawerSet = null; };
  }, [drawer.open, setDrawer]);

  // apply CSS var --h-drawer to document root so the grid can read it
  dUseEffect(() => {
    // Keep the bar (26px) visible when closed so users can click tabs to open.
    const CLOSED_H = 26; // matches .drawer.closed min-height in drawer.css
    const h = drawer.open ? Math.max(120, Math.min(window.innerHeight * 0.8, drawer.height)) : CLOSED_H;
    document.documentElement.style.setProperty("--h-drawer", h + "px");
    document.body.classList.toggle("drawer-open", drawer.open);
  }, [drawer.open, drawer.height]);

  // drag handling on the grip — vertical resize
  const onDragStart = (e) => {
    e.preventDefault();
    const startY = e.clientY;
    const startH = drawer.height;
    const move = (ev) => {
      const dy = startY - ev.clientY;
      const next = Math.max(120, Math.min(window.innerHeight * 0.8, startH + dy));
      document.documentElement.style.setProperty("--h-drawer", next + "px");
    };
    const up = (ev) => {
      const dy = startY - ev.clientY;
      const next = Math.max(120, Math.min(window.innerHeight * 0.8, startH + dy));
      setDrawer({ height: next, open: true });
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", up);
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  };

  // double-click grip = snap toggle 30vh ↔ 60vh
  const onDblClick = () => {
    const vh = window.innerHeight;
    const cur = drawer.height;
    const target = Math.abs(cur - vh * 0.30) < Math.abs(cur - vh * 0.60)
      ? Math.round(vh * 0.60)
      : Math.round(vh * 0.30);
    setDrawer({ height: target, open: true });
  };

  // click tab — open if closed, switch if same
  const clickTab = (id) => {
    if (!drawer.open) setDrawer({ open: true, tab: id });
    else if (drawer.tab !== id) setDrawer({ tab: id });
    else setDrawer({ open: false });   // click active tab again → close
  };

  const close = () => setDrawer({ open: false });

  const Panel = dUseMemo(() => {
    if (drawer.tab === "terminal") return TerminalPanel;
    if (drawer.tab === "output")   return OutputPanel;
    if (drawer.tab === "cascade")  return CascadePanel;
    if (drawer.tab === "audit")    return AuditPanel;
    if (drawer.tab === "cost")     return CostPanel;
    return TerminalPanel;
  }, [drawer.tab]);

  return (
    <div className={"drawer " + (drawer.open ? "open" : "closed")}
         data-screen-label="Bottom Drawer">
      <div className="dr-grip" ref={dragRef}
           onMouseDown={drawer.open ? onDragStart : undefined}
           onDoubleClick={drawer.open ? onDblClick : undefined}
           title={drawer.open ? "drag to resize · double-click to snap" : ""}>
        <span className="dr-grip-bar"></span>
      </div>
      <div className="dr-bar">
        <div className="dr-tabs">
          {DRAWER_TABS.map(t => (
            <button key={t.id}
                    className={"dr-tab" + (drawer.tab === t.id && drawer.open ? " on" : "")}
                    onClick={() => clickTab(t.id)}
                    title={t.label}>
              <span className="g">{t.glyph}</span>
              <span className="l">{t.label}</span>
              {t.count != null && <span className="ct">{t.count}</span>}
            </button>
          ))}
        </div>
        <div className="dr-actions">
          {drawer.open && (
            <>
              <button className="dr-act"
                      onClick={() => {
                        const vh = window.innerHeight;
                        setDrawer({ height: Math.round(vh * 0.30) });
                      }}
                      title="snap 30%">▭</button>
              <button className="dr-act"
                      onClick={() => {
                        const vh = window.innerHeight;
                        setDrawer({ height: Math.round(vh * 0.60) });
                      }}
                      title="snap 60%">▣</button>
              <button className="dr-act"
                      onClick={() => {
                        const url = new URL(window.location.href);
                        url.searchParams.set("widget", "drawer-" + drawer.tab);
                        window.open(url.toString(), "_blank", "noopener");
                      }}
                      title="pop out to new tab">↗</button>
              <button className="dr-act dr-close" onClick={close} title="close">✕</button>
            </>
          )}
          {!drawer.open && (
            <span className="dr-hint">click a tab to open · ⌃` toggles</span>
          )}
        </div>
      </div>
      {drawer.open && (
        <div className="dr-body">
          <Panel />
        </div>
      )}
    </div>
  );
}

// ─── keyboard shortcut: Ctrl+` toggles ──────────────────────────
(function installDrawerHotkey() {
  if (window.__drawerHotkey) return;
  window.__drawerHotkey = true;

  const isEditableTarget = (target) => {
    const tag = target && target.tagName;
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" ||
      (target && target.isContentEditable) ||
      (target && target.closest && target.closest("[contenteditable]:not([contenteditable='false'])"));
  };

  // ctrl/cmd + ` toggles open/closed
  document.addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key === "`") {
      if (isEditableTarget(e.target)) return;
      e.preventDefault();
      window.dispatchEvent(new CustomEvent("masc-drawer-toggle"));
    }
  });

  // listen for programmatic events (from IDE's drawer hint button etc.)
  window.addEventListener("masc-drawer-toggle", () => {
    if (!window.useCockpitState) return;
    window.__drawerToggle?.();
  });
  window.addEventListener("masc-drawer-set", (e) => {
    if (window.__drawerSet) window.__drawerSet(e.detail || {});
  });
})();

window.Drawer = Drawer;
// expose individual panels for pop-out viewing
window.__DrawerPanel = function ({ kind }) {
  if (kind === "terminal") return <TerminalPanel/>;
  if (kind === "output")   return <OutputPanel/>;
  if (kind === "cascade")  return <CascadePanel/>;
  if (kind === "audit")    return <AuditPanel/>;
  if (kind === "cost")     return <CostPanel/>;
  return <div style={{padding:20}}>unknown drawer panel: {kind}</div>;
};
