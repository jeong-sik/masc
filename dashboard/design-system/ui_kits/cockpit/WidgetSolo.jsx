/* global React, ReactDOM, MASC_DATA,
          Topbar, Ticker, KpiStrip, Lifeline, Sidebar, Rail,
          Swimlanes, Deck, Composer, StatusBar,
          WorkPlane, CommsPlane, ObservePlane, CognitionPlane, IdePlane,
          Drawer */
/* WidgetSolo — full-viewport single-widget viewer, activated by ?widget=<id>.

   Lets users pop any cockpit widget into its own browser tab/window for
   focused work without the surrounding chrome. The widget is rendered with
   sensible defaults (sample data, sane selection state) so it stands alone.

   Supported ids:
     sidebar              the full Sidebar (Fleet/Filter/Goals)
     rail                 the full Rail (Activity/Nudges/Cascade)
     kpi                  KPI strip
     lifeline             Lifeline 60s trace
     deck                 Deck (board/cascade/providers/goals)
     swimlanes            Keeper swimlanes
     plane-work           Work plane
     plane-comms          Comms plane
     plane-observe        Observe plane
     plane-cognition      Cognition plane
     plane-ide            IDE plane
     plane-dashboard      Dashboard (swimlanes + deck)
     drawer-terminal      Terminal drawer panel
     drawer-output        Output drawer panel
     drawer-cascade       Cascade drawer panel
     drawer-audit         Audit drawer panel
     drawer-cost          Cost drawer panel
*/

const { useState: _wsUseState, useEffect: _wsUseEffect } = React;

const _WS_DEFS = {
  sidebar:    { name: "Sidebar",        kind: "sidebar"    },
  rail:       { name: "Rail",           kind: "rail"       },
  kpi:        { name: "KPI Strip",      kind: "kpi"        },
  lifeline:   { name: "Lifeline",       kind: "lifeline"   },
  deck:       { name: "Deck",           kind: "deck"       },
  swimlanes:  { name: "Swimlanes",      kind: "swimlanes"  },
  "plane-dashboard": { name: "Dashboard plane",  kind: "plane-dashboard"  },
  "plane-work":      { name: "Work plane",       kind: "plane-work"       },
  "plane-comms":     { name: "Comms plane",      kind: "plane-comms"      },
  "plane-observe":   { name: "Observe plane",    kind: "plane-observe"    },
  "plane-cognition": { name: "Cognition plane",  kind: "plane-cognition"  },
  "plane-ide":       { name: "IDE plane",        kind: "plane-ide"        },
  "drawer-terminal": { name: "Terminal drawer",  kind: "drawer", drawer: "terminal" },
  "drawer-output":   { name: "Output drawer",    kind: "drawer", drawer: "output"   },
  "drawer-cascade":  { name: "Cascade drawer",   kind: "drawer", drawer: "cascade"  },
  "drawer-audit":    { name: "Audit drawer",     kind: "drawer", drawer: "audit"    },
  "drawer-cost":     { name: "Cost drawer",      kind: "drawer", drawer: "cost"     },
};

function WidgetSolo({ id }) {
  // pull state hook to clear collapsed widgets for this solo view
  const [_cs, _setCs] = (window.useCockpitState ? window.useCockpitState() : [{collapsed:new Set()}, () => {}]);

  // mark body + title; clear collapsed set so widgets render expanded
  _wsUseEffect(() => {
    document.body.classList.add("widget-solo-mode");
    document.title = `MASC · ${id}`;
    if (_cs.collapsed && _cs.collapsed.size > 0) _setCs({ collapsed: new Set() });
    return () => { document.body.classList.remove("widget-solo-mode"); };
  }, [id]);

  const D = window.MASC_DATA || {};
  const def = _WS_DEFS[id];

  // unknown widget — show a friendly index
  if (!def) {
    return (
      <div className="ws-shell ws-empty ws-kind-empty">
        <div className="ws-bar">
          <span className="ws-dot"></span>
          <span className="ws-name">unknown widget</span>
          <span className="ws-id">id: {id || "(none)"}</span>
          <span className="ws-spc"></span>
          <a className="ws-act" href={window.location.pathname}>← cockpit</a>
        </div>
        <div className="ws-body">
          <div className="ws-empty-msg">
            <div>No widget registered for <code>?widget={id || "—"}</code>.</div>
            <ul>
              {Object.keys(_WS_DEFS).map(k => (
                <li key={k}>
                  <a href={"?widget=" + k}>?widget={k}</a>
                  <span className="dim"> — {_WS_DEFS[k].name}</span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>
    );
  }

  // shared selection defaults so widgets render usefully alone
  const dummyKeepers = new Set(["nick0cave", "sangsu"]);
  const ctx = { branch: "main", keepers: dummyKeepers };

  // render the body for the requested widget
  let body = null;
  switch (def.kind) {
    case "sidebar":
      body = (
        <window.Sidebar
          keepers={D.keepers || []}
          goals={D.goals || []}
          selKeeper="nick0cave"
          setSelKeeper={()=>{}}
          selGoal={(D.goals && D.goals[0] && D.goals[0].id) || ""}
          setSelGoal={()=>{}}
          selectedKeepers={dummyKeepers}
          toggleKeeper={()=>{}} />
      );
      break;
    case "rail":
      body = <window.Rail events={D.events || []} cascade={D.cascade || {steps:[],total_ms:0}} />;
      break;
    case "kpi":
      body = <window.KpiStrip />;
      break;
    case "lifeline":
      body = <window.Lifeline />;
      break;
    case "deck":
      body = (
        <window.Deck
          tasks={D.tasks || []}
          goals={D.goals || []}
          providers={D.providers || []}
          cascade={D.cascade || {steps:[],total_ms:0}} />
      );
      break;
    case "swimlanes":
      body = <window.Swimlanes keepers={D.keepers || []} laneEvents={D.laneEvents || {}} />;
      break;
    case "plane-dashboard":
      body = (
        <div className="center" style={{display:"flex",flexDirection:"column",height:"100%"}}>
          <window.Swimlanes keepers={D.keepers || []} laneEvents={D.laneEvents || {}} />
          <window.Deck tasks={D.tasks || []} goals={D.goals || []}
                       providers={D.providers || []} cascade={D.cascade || {steps:[],total_ms:0}} />
        </div>
      );
      break;
    case "plane-work":      body = <div className="center"><window.WorkPlane {...ctx}/></div>; break;
    case "plane-comms":     body = <div className="center"><window.CommsPlane {...ctx}/></div>; break;
    case "plane-observe":   body = <div className="center"><window.ObservePlane {...ctx}/></div>; break;
    case "plane-cognition": body = <div className="center"><window.CognitionPlane {...ctx}/></div>; break;
    case "plane-ide":       body = <div className="center"><window.IdePlane {...ctx}/></div>; break;
    case "drawer":
      body = window.__DrawerPanel
        ? <window.__DrawerPanel kind={def.drawer} />
        : <div className="ws-empty-msg">drawer renderer not loaded</div>;
      break;
    default:
      body = <div className="ws-empty-msg">renderer not wired</div>;
  }

  return (
    <div className={"ws-shell ws-kind-" + def.kind}>
      <div className="ws-bar">
        <span className="ws-dot"></span>
        <span className="ws-name">{def.name}</span>
        <span className="ws-id">{id}</span>
        <span className="ws-spc"></span>
        <a className="ws-act" href={window.location.pathname} title="back to full cockpit">← cockpit</a>
      </div>
      <div className="ws-body">{body}</div>
    </div>
  );
}

window.WidgetSolo = WidgetSolo;
