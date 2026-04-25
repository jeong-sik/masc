/* global React, Topbar, Ticker, KpiStrip, Lifeline, Sidebar, Swimlanes, Deck, Rail, Composer, StatusBar, MASC_DATA */
const { useState } = React;

function App() {
  const [mode, setMode] = useState("Dashboard");
  const [density, setDensity] = useState("normal");
  const [selKeeper, setSelKeeper] = useState("nick0cave");
  const [selGoal, setSelGoal] = useState("goal-merge-blockers");

  const D = window.MASC_DATA;
  const activeGoal = D.goals.find(g => g.id === selGoal) || D.goals[0];

  return (
    <div className="app" data-screen-label="MASC Cockpit" data-density={density}>
      <Topbar goal={activeGoal} goals={D.goals} mode={mode} setMode={setMode} density={density} setDensity={setDensity} />
      <Ticker events={D.events} />
      <KpiStrip />
      <Lifeline />
      <Sidebar keepers={D.keepers} goals={D.goals} selKeeper={selKeeper} setSelKeeper={setSelKeeper} selGoal={selGoal} setSelGoal={setSelGoal} />
      <div className="center">
        <Swimlanes keepers={D.keepers} laneEvents={D.laneEvents} />
        <Deck tasks={D.tasks} goals={D.goals} providers={D.providers} cascade={D.cascade} />
      </div>
      <Rail events={D.events} cascade={D.cascade} />
      <Composer selKeeper={selKeeper} />
      <StatusBar providers={D.providers} />
    </div>
  );
}

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(<App />);
