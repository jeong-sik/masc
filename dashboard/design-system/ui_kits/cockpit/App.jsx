/* global React, Topbar, Ticker, KpiStrip, Lifeline, Sidebar, Swimlanes, Deck, Rail, Composer, StatusBar,
          MASC_DATA, WorkPlane, CommsPlane, ObservePlane, CognitionPlane, IdePlane,
          ViewportBanner, useCockpitState, useLayoutProfile, Drawer */
const { useState, useCallback, useEffect } = React;

function App() {
  // sync mode/branch with the cockpit-state singleton (URL+localStorage).
  // If the hook is not available we surface that loudly: previously the
  // fallback was a silent stub which made cockpit state look functional
  // while every write was dropped on the floor.
  const [cs, setCs] = (() => {
    if (window.useCockpitState) return window.useCockpitState();
    console.error("[App] window.useCockpitState missing — cockpit state hook did not load; mode/branch changes will not persist");
    return [{}, () => {}];
  })();
  // run layout profile — auto-collapses chrome per mode
  if (window.useLayoutProfile) {
    window.useLayoutProfile();
  } else {
    console.error("[App] window.useLayoutProfile missing — layout auto-collapse disabled");
  }
  const [mode, setModeRaw] = useState(cs.mode || "Dashboard");
  const [density, setDensity] = useState("normal");
  const [selKeeper, setSelKeeper] = useState("nick0cave");
  const [selGoal, setSelGoal] = useState("goal-merge-blockers");
  const [branch, setBranchRaw] = useState(cs.branch || "main");
  const [selectedKeepers, setSelectedKeepers] = useState(new Set(["nick0cave","sangsu"]));

  // cs is the source of truth for mode/branch — mirror to local state for child props
  useEffect(() => {
    if (cs.mode && cs.mode !== mode) setModeRaw(cs.mode);
    if (cs.branch && cs.branch !== branch) setBranchRaw(cs.branch);
  }, [cs.mode, cs.branch]);

  const setMode = useCallback((m) => { setModeRaw(m); setCs({ mode: m }); }, [setCs]);
  const setBranch = useCallback((b) => { setBranchRaw(b); setCs({ branch: b }); }, [setCs]);

  const D = window.MASC_DATA;
  // Without the data layer the cockpit cannot render anything meaningful.
  // Show a visible error instead of crashing on D.goals.find below.
  if (!D || !Array.isArray(D.goals)) {
    return (
      <div className="app app-error" role="alert" data-error="missing-masc-data">
        <h1>Cockpit data unavailable</h1>
        <p>
          <code>window.MASC_DATA</code> is missing or malformed. Verify the data
          layer script loaded before App.jsx.
        </p>
      </div>
    );
  }
  const activeGoal = D.goals.find(g => g.id === selGoal) || D.goals[0];

  const toggleKeeper = useCallback((id) => {
    setSelectedKeepers(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }, []);

  const renderCenter = () => {
    if (mode === "Dashboard") {
      return (
        <div className="center">
          <Swimlanes keepers={D.keepers} laneEvents={D.laneEvents} />
          <Deck tasks={D.tasks} goals={D.goals} providers={D.providers} cascade={D.cascade} />
        </div>
      );
    }
    const ctx = { branch, keepers: selectedKeepers };
    if (mode === "Work")      return <div className="center"><WorkPlane {...ctx}/></div>;
    if (mode === "Comms")     return <div className="center"><CommsPlane {...ctx}/></div>;
    if (mode === "Observe")   return <div className="center"><ObservePlane {...ctx}/></div>;
    if (mode === "Cognition") return <div className="center"><CognitionPlane {...ctx}/></div>;
    if (mode === "IDE")       return <div className="center"><IdePlane {...ctx}/></div>;
    return <div className="center"></div>;
  };

  return (
    <div className="app" data-screen-label="MASC Cockpit" data-density={density}>
      {window.ViewportBanner ? <window.ViewportBanner/> : null}
      <Topbar goal={activeGoal} goals={D.goals} mode={mode} setMode={setMode}
              density={density} setDensity={setDensity}
              branch={branch} setBranch={setBranch} />
      <Ticker events={D.events} />
      <KpiStrip />
      <Lifeline />
      <Sidebar keepers={D.keepers} goals={D.goals}
               selKeeper={selKeeper} setSelKeeper={setSelKeeper}
               selGoal={selGoal} setSelGoal={setSelGoal}
               selectedKeepers={selectedKeepers} toggleKeeper={toggleKeeper} />
      {renderCenter()}
      <Rail events={D.events} cascade={D.cascade} />
      {window.Drawer ? <window.Drawer/> : null}
      <Composer selKeeper={selKeeper} />
      <StatusBar providers={D.providers} />
      {window.FocusToggle ? <window.FocusToggle/> : null}
      {window.StatusTray ? <window.StatusTray/> : null}
    </div>
  );
}

const root = ReactDOM.createRoot(document.getElementById("root"));

// pop-out: if URL has ?widget=<id>, render that widget solo
const __soloId = new URL(window.location.href).searchParams.get("widget");
if (__soloId && window.WidgetSolo) {
  root.render(<window.WidgetSolo id={__soloId} />);
} else {
  root.render(<App />);
}
