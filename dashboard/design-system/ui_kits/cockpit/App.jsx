/* global React, Topbar, Ticker, KpiStrip, Lifeline, Sidebar, Swimlanes, Deck, Rail, Composer, StatusBar,
          MASC_DATA, WorkPlane, CommsPlane, ObservePlane, CognitionPlane, IdePlane */
const { useState, useCallback } = React;

function App() {
  const [mode, setMode] = useState("Dashboard");
  const [density, setDensity] = useState("normal");
  const [selKeeper, setSelKeeper] = useState("nick0cave");
  const [selGoal, setSelGoal] = useState("goal-merge-blockers");
  const [branch, setBranch] = useState("main");
  const [selectedKeepers, setSelectedKeepers] = useState(new Set(["nick0cave","sangsu"]));

  const D = window.MASC_DATA;
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
      <Composer selKeeper={selKeeper} />
      <StatusBar providers={D.providers} />
    </div>
  );
}

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(<App />);
