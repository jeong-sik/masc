/* global React */
// Planes.jsx — Phase 2 plane router for the cockpit center area.
// Each plane reuses the cb-group-* component-library zones (Phase 2)
// and renders them in a tabbed layout with branch/keeper context echoed.

const { useState: usePlaneState } = React;

// ─── shared header ───────────────────────────────────────────
function PlaneHeader({ title, subtitle, branch, keepers, popoutId }) {
  const sk = keepers || new Set();
  return (
    <div className="plane-hdr">
      <span className="ti">{title}</span>
      <span className="sub">· {subtitle}</span>
      <span className="ctx">
        <span>⎇ <span className="br">{branch || "main"}</span></span>
        <span>·</span>
        <span><span className="kp">{sk.size}</span> keepers selected</span>
        {popoutId && (
          <a className="wx-popout"
             href={"?widget=" + popoutId}
             target="_blank" rel="noopener"
             title="open plane in new tab"
             style={{marginLeft:"8px"}}>↗</a>
        )}
      </span>
    </div>
  );
}

// ─── shared tabbed shell ─────────────────────────────────────
function PlaneShell({ title, subtitle, branch, keepers, tabs, defaultTab, popoutId }) {
  const [tab, setTab] = usePlaneState(defaultTab || tabs[0].id);
  const cur = tabs.find(t => t.id === tab) || tabs[0];
  return (
    <div className="plane">
      <PlaneHeader title={title} subtitle={subtitle} branch={branch} keepers={keepers} popoutId={popoutId} />
      <div className="plane-tabs">
        {tabs.map(t => (
          <button key={t.id} className={tab === t.id ? "active" : ""} onClick={() => setTab(t.id)}>{t.label}</button>
        ))}
      </div>
      <div className="plane-body">
        {cur.render()}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════
// WORK PLANE — G1 Goal · G2 Task · G3 Accountability
// ═════════════════════════════════════════════════════════════
function WorkPlane({ branch, keepers }) {
  return (
    <PlaneShell
      title="Work Plane" subtitle="Goals · Tasks · Accountability"
      popoutId="plane-work"
      branch={branch} keepers={keepers}
      tabs={[
        { id:"goal-h",   label:"Goal · Horizon",     render: () => <window.GoalHorizonTrack/> },
        { id:"goal-t",   label:"Goal · Tree",        render: () => <window.GoalMetricTree/> },
        { id:"goal-d",   label:"Goal · Snapshot",    render: () => <window.GoalSnapshotDiff/> },
        { id:"task-bl",  label:"Task · Backlog",     render: () => <window.TaskBacklog/> },
        { id:"task-st",  label:"Task · Stale",       render: () => <window.TaskStaleAlert/> },
        { id:"task-w",   label:"Task · Wall",        render: () => <window.TaskWall/> },
        { id:"acc-led",  label:"Accountability · Ledger",  render: () => <window.AccountabilityLedger/> },
        { id:"acc-mtx",  label:"Accountability · Matrix",  render: () => <window.ResponsibilityMatrix/> },
      ]}
    />
  );
}

// ═════════════════════════════════════════════════════════════
// COMMS PLANE — C1 Board · C2 Messages · C3 Composer v2
// ═════════════════════════════════════════════════════════════
function CommsPlane({ branch, keepers }) {
  return (
    <PlaneShell
      title="Comms Plane" subtitle="Board · Messages · Composer v2"
      popoutId="plane-comms"
      branch={branch} keepers={keepers}
      tabs={[
        { id:"bd-feed", label:"Board · Feed",      render: () => <window.BoardFeed/> },
        { id:"bd-thr",  label:"Board · Thread",    render: () => <window.BoardThread/> },
        { id:"bd-tog",  label:"Board · direct/automation", render: () => <window.BoardHotAuto/> },
        { id:"ms-rm",   label:"Messages · Room",   render: () => <window.MessageRoomTimeline/> },
        { id:"ms-inb",  label:"Messages · Mention inbox",   render: () => <window.MentionInbox/> },
        { id:"ms-st",   label:"Messages · [STATE] block",   render: () => <window.StateBlockMessage/> },
        { id:"cm-bc",   label:"Composer · Broadcast",       render: () => <window.ComposerV2Broadcast/> },
        { id:"cm-mn",   label:"Composer · Mention",         render: () => <window.ComposerV2Mention/> },
        { id:"cm-st",   label:"Composer · [STATE]",         render: () => <window.ComposerV2State/> },
      ]}
    />
  );
}

// ═════════════════════════════════════════════════════════════
// OBSERVE PLANE — O1 Cascade · O2 Audit · O3 Safe Auto · O4 Cost · O5 Heuristic
// ═════════════════════════════════════════════════════════════
function ObservePlane({ branch, keepers }) {
  return (
    <PlaneShell
      title="Observability" subtitle="Cascade · Audit · Safe Autonomy · Cost · Heuristic"
      popoutId="plane-observe"
      branch={branch} keepers={keepers}
      tabs={[
        { id:"cs-list", label:"Cascade · List",       render: () => <window.CascadeList/> },
        { id:"cs-deep", label:"Cascade · Deep dive",  render: () => <window.CascadeDeepDive/> },
        { id:"cs-cmp",  label:"Cascade · Compare",    render: () => <window.CascadeCompare/> },
        { id:"au-led",  label:"Audit · Ledger",       render: () => <window.AuditLedger/> },
        { id:"au-act",  label:"Audit · By actor",     render: () => <window.AuditByActor/> },
        { id:"au-sum",  label:"Audit · Summary",      render: () => <window.AuditSummary/> },
        { id:"sa-dash", label:"Safe Auto · Dashboard",render: () => <window.SafeAutoDashboard/> },
        { id:"sa-kpr",  label:"Safe Auto · By keeper",render: () => <window.SafeAutoByKeeper/> },
        { id:"sa-trd",  label:"Safe Auto · Trend",    render: () => <window.SafeAutoTrend/> },
        { id:"ct-agt",  label:"Cost · Per agent",     render: () => <window.CostPerAgent/> },
        { id:"ct-mtx",  label:"Cost · Matrix",        render: () => <window.CostMatrix/> },
        { id:"ct-lat",  label:"Cost · Latency",       render: () => <window.CostLatency/> },
        { id:"hr-log",  label:"Heuristic · Log",      render: () => <window.HeuristicLog/> },
        { id:"hr-st",   label:"Stress · Board",       render: () => <window.StressBoard/> },
        { id:"hr-mod",  label:"Heuristic · By module",render: () => <window.HeuristicByModule/> },
      ]}
    />
  );
}

// ═════════════════════════════════════════════════════════════
// COGNITION PLANE — K1 Keeper · K2 Decisions · K3 Episodes · K4 Autoresearch
// ═════════════════════════════════════════════════════════════
function CognitionPlane({ branch, keepers }) {
  return (
    <PlaneShell
      title="Cognition" subtitle="Keeper Inspector · Decisions · Memory · Episodes · Autoresearch"
      popoutId="plane-cognition"
      branch={branch} keepers={keepers}
      tabs={[
        { id:"ki-bdi",  label:"Keeper · BDI",         render: () => <window.KeeperBDIPanel/> },
        { id:"ki-acc",  label:"Keeper · Tool access", render: () => <window.KeeperToolAccess/> },
        { id:"ki-stat", label:"Keeper · Token stats", render: () => <window.KeeperTokenStats/> },
        { id:"dc-str",  label:"Decisions · Stream",   render: () => <window.DecisionsStream/> },
        { id:"dc-mem",  label:"Memory · Entries",     render: () => <window.MemoryEntries/> },
        { id:"ep-card", label:"Episodes · Cards",     render: () => <window.EpisodeCards/> },
        { id:"ep-lrn",  label:"Episodes · Learnings", render: () => <window.EpisodeLearnings/> },
        { id:"ar-lst",  label:"AR · Loops",           render: () => <window.ARLoopList/> },
        { id:"ar-fnd",  label:"AR · Finding card",    render: () => <window.ARFindingCard/> },
        { id:"ar-flw",  label:"AR · Flow",            render: () => <window.ARHypothesisFlow/> },
      ]}
    />
  );
}

// ═════════════════════════════════════════════════════════════
// IDE PLANE — Phase 3 Code IDE v2 (re-designed in Phase B-C)
// - bottom terminal removed (use shared Drawer instead)
// - keeper chips removed (sidebar already shows fleet)
// - modebar: branch + mode tabs only (no terminal toggle)
// - wide modes (review/merge/graph/search) use full center; edit shows inspector right rail
// ═════════════════════════════════════════════════════════════
function IdePlane({ branch, keepers }) {
  const [mode, setMode] = usePlaneState("edit");
  const ctx = { branch, keepers };

  const center =
    mode === "review" ? <window.IxEditReview {...ctx}/> :
    mode === "merge"  ? <window.IxEditMerge {...ctx}/> :
    mode === "graph"  ? <window.IxGraphDag {...ctx}/> :
    mode === "search" ? <window.IxSearch {...ctx}/> :
    <window.IxEditAttrib {...ctx}/>;

  // edit mode shows inspector rail on right;
  // review/merge/graph/search use center wide
  const right =
    mode === "edit" ?
      <div className="ide-v2-right-stack">
        <window.IxPrHeader {...ctx}/>
        <window.IxPrChecks {...ctx}/>
      </div>
    : mode === "review" ? <window.IxPrThread {...ctx}/>
    : null;

  // open shared drawer with terminal tab as a hint
  const openTerminal = () => {
    window.dispatchEvent(new CustomEvent("masc-drawer-set", { detail: { open: true, tab: "terminal" } }));
  };

  const centerPanelId = `ide-v2-center-${mode}`;
  return (
    <div className="plane ide-v2 ide-v3" role="region" aria-label="IDE Plane">
      <PlaneHeader title="IDE" subtitle="tree · editor · PR · graph · search" branch={branch} keepers={keepers} popoutId="plane-ide" />
      <div className="ide-v2-modebar ide-v3-modebar">
        <div className="ide-v2-branch">
          <span className="lbl">branch</span>
          <span className="name">{branch || "main"}</span>
          <span className="meta">worktree active · 14 changed · 3 staged</span>
        </div>
        <div className="ide-v2-modes" role="tablist" aria-label="IDE mode">
          {["edit","review","merge","graph","search"].map(m => (
            <button key={m} type="button" role="tab"
                    id={`ide-v2-mode-${m}`} aria-selected={mode === m}
                    aria-controls={`ide-v2-center-${m}`}
                    tabIndex={mode === m ? 0 : -1}
                    className={mode === m ? "active" : ""}
                    onClick={() => setMode(m)}>{m}</button>
          ))}
        </div>
        <button type="button"
                className="ide-v3-drawer-hint"
                onClick={openTerminal}
                title="open shared bottom drawer (Terminal/Output/Cascade/Audit/Cost)">
          ⌃` drawer
        </button>
      </div>
      <div className={`ide-v2-body ide-v3-body ${right ? "" : "wide"}`}>
        <div className="ide-v2-tree" role="region" aria-label="File tree">
          <window.IxTreeDiff {...ctx}/>
        </div>
        <div className="ide-v2-center" role="tabpanel" id={centerPanelId} aria-labelledby={`ide-v2-mode-${mode}`}>{center}</div>
        {right && <div className="ide-v2-right" role="region" aria-label="Inspector rail">{right}</div>}
      </div>
    </div>
  );
}

Object.assign(window, { WorkPlane, CommsPlane, ObservePlane, CognitionPlane, IdePlane });
