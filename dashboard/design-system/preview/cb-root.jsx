// cb-root.jsx — assembles the design canvas with all 11 components

const { DesignCanvas, DCSection, DCArtboard } = window;

function App() {
  return (
    <DesignCanvas title="MASC Cockpit — Component Library" subtitle="11 components · 2–3 variants each · interactive">

      <DCSection id="topbar" title="01 · Topbar" subtitle="Brand · goal · mode · density · stamp">
        <DCArtboard id="topbar-std" label="A · Standard" width={880} height={80}><TopbarStandard/></DCArtboard>
        <DCArtboard id="topbar-exp" label="B · With branch + fleet avatars" width={880} height={80}><TopbarExpanded/></DCArtboard>
        <DCArtboard id="topbar-min" label="C · Minimal (split-view chrome)" width={620} height={72}><TopbarMinimal/></DCArtboard>
      </DCSection>

      <DCSection id="ticker" title="02 · Ticker" subtitle="Fleet event tape. Animated; hover to inspect.">
        <DCArtboard id="tick-mar" label="A · Marquee" width={900} height={60}><TickerMarquee/></DCArtboard>
        <DCArtboard id="tick-chk" label="B · Chunked" width={900} height={60}><TickerChunks/></DCArtboard>
        <DCArtboard id="tick-ver" label="C · Vertical (side-rail)" width={560} height={120}><TickerVertical/></DCArtboard>
      </DCSection>

      <DCSection id="kpi" title="03 · KPI Strip" subtitle="Live cell pulses brass. Tabular nums.">
        <DCArtboard id="kpi-std" label="A · Standard (6-up + sparks)" width={900} height={100}><KpiStandard/></DCArtboard>
        <DCArtboard id="kpi-com" label="B · Compact" width={900} height={60}><KpiCompact/></DCArtboard>
        <DCArtboard id="kpi-stk" label="C · Stacked 3×2 (narrow)" width={480} height={120}><KpiStacked/></DCArtboard>
      </DCSection>

      <DCSection id="lifeline" title="04 · Lifeline" subtitle="60s heartbeat. Brass sweep + endpoint pulse.">
        <DCArtboard id="lif-beat" label="A · Single beat" width={700} height={72}><LifelineBeat/></DCArtboard>
        <DCArtboard id="lif-stack" label="B · Per-keeper stacked" width={560} height={140}><LifelineStacked/></DCArtboard>
      </DCSection>

      <DCSection id="sidebar" title="05 · Sidebar" subtitle="Fleet + goals. Click rows to select.">
        <DCArtboard id="sb-fleet" label="A · Fleet + Goals" width={280} height={420}><SidebarFleet/></DCArtboard>
        <DCArtboard id="sb-group" label="B · Active / Standby" width={280} height={420}><SidebarGrouped/></DCArtboard>
        <DCArtboard id="sb-icons" label="C · With role glyphs" width={280} height={420}><SidebarIcons/></DCArtboard>
      </DCSection>

      <DCSection id="swim" title="06 · Swimlanes" subtitle="Timeline × keepers. Brass 'now' column.">
        <DCArtboard id="sw-glyph" label="A · Glyphs (default)" width={720} height={240}><SwimlanesGlyph/></DCArtboard>
        <DCArtboard id="sw-dense" label="B · Dense (8 lanes)" width={720} height={280}><SwimlanesDense/></DCArtboard>
        <DCArtboard id="sw-bars" label="C · Aggregate bars" width={720} height={240}><SwimlanesBars/></DCArtboard>
      </DCSection>

      <DCSection id="deck" title="07 · Deck" subtitle="Tabbed center. Board / Tasks / Providers / Cascade.">
        <DCArtboard id="dk-tasks" label="A · Tasks table" width={900} height={380}><DeckTasks/></DCArtboard>
        <DCArtboard id="dk-kan"   label="B · Board (kanban)" width={900} height={380}><DeckKanban/></DCArtboard>
        <DCArtboard id="dk-prov"  label="C · Providers matrix" width={900} height={280}><DeckProviders/></DCArtboard>
      </DCSection>

      <DCSection id="rail" title="08 · Rail" subtitle="Right rail. Activity feed + cascade trace.">
        <DCArtboard id="rl-act"  label="A · Activity feed" width={340} height={460}><RailActivity/></DCArtboard>
        <DCArtboard id="rl-casc" label="B · Cascade + recent" width={340} height={360}><RailCascade/></DCArtboard>
      </DCSection>

      <DCSection id="composer" title="09 · Composer" subtitle="keeper.claim() prompt. Mono, terminal-style.">
        <DCArtboard id="co-pr" label="A · Prompt (typing)" width={700} height={120}><ComposerPrompt/></DCArtboard>
        <DCArtboard id="co-sg" label="B · With suggestions" width={700} height={240}><ComposerSuggest/></DCArtboard>
        <DCArtboard id="co-ml" label="C · Multi-line call" width={700} height={200}><ComposerMultiLine/></DCArtboard>
      </DCSection>

      <DCSection id="status" title="10 · Status Bar" subtitle="Build · providers · tps · clock.">
        <DCArtboard id="st-std" label="A · Standard" width={900} height={50}><StatusStandard/></DCArtboard>
        <DCArtboard id="st-com" label="B · Compact" width={560} height={50}><StatusCompact/></DCArtboard>
        <DCArtboard id="st-verb" label="C · Verbose (split mode)" width={900} height={60}><StatusVerbose/></DCArtboard>
      </DCSection>

      <DCSection id="drawer" title="11 · Drawer" subtitle="Right-side inspector. Task / Goal / Keeper.">
        <DCArtboard id="dr-task" label="A · Task inspector" width={360} height={520}><DrawerTask/></DCArtboard>
        <DCArtboard id="dr-goal" label="B · Goal inspector" width={360} height={520}><DrawerGoal/></DCArtboard>
        <DCArtboard id="dr-keep" label="C · Keeper inspector" width={360} height={520}><DrawerKeeper/></DCArtboard>
      </DCSection>

      {/* ════════ PHASE 2 · I0 · IDE BACKBONE (foundation) ════════ */}

      <DCSection id="ide-backbone" title="I0 · IDE Backbone" subtitle="Game-changer. Operator just observes & nudges; keepers do the work. Branch + keeper multi-select + nudge log.">
        <DCArtboard id="ib-br"  label="A · Branch selector (header + list)"     width={780} height={500}><BranchSelector/></DCArtboard>
        <DCArtboard id="ib-km"  label="B · Keeper multi-select (chip filter)"   width={780} height={300}><KeeperMultiSelect/></DCArtboard>
        <DCArtboard id="ib-nd"  label="C · Operator nudge log + compose"        width={780} height={500}><OperatorNudgeLog/></DCArtboard>
      </DCSection>

      {/* ════════ PHASE 2 · TRACK 1 · WORK PLANE ════════ */}

      <DCSection id="goal-zone" title="G1 · Goal Zone" subtitle="Real goals.json — horizon, phase, metric, parent tree, snapshot diff.">
        <DCArtboard id="gz-hor"  label="A · Horizon track (단/중/장)" width={920} height={420}><GoalHorizonTrack/></DCArtboard>
        <DCArtboard id="gz-tree" label="B · Metric tree (parent → child)" width={780} height={300}><GoalMetricTree/></DCArtboard>
        <DCArtboard id="gz-snap" label="C · Snapshot diff (yesterday → today)" width={780} height={360}><GoalSnapshotDiff/></DCArtboard>
      </DCSection>

      <DCSection id="task-zone" title="G2 · Task Zone" subtitle="Backlog / stale claims / per-keeper wall — claim_holder, drift, branch.">
        <DCArtboard id="tz-bl"   label="A · Backlog (filter chips)" width={1080} height={420}><TaskBacklog/></DCArtboard>
        <DCArtboard id="tz-st"   label="B · Stale-claim alert"      width={920}  height={300}><TaskStaleAlert/></DCArtboard>
        <DCArtboard id="tz-wall" label="C · Per-keeper task wall"   width={920}  height={400}><TaskWall/></DCArtboard>
      </DCSection>

      <DCSection id="account" title="G3 · Accountability" subtitle="Daily verdict ledger + keeper × scope responsibility matrix.">
        <DCArtboard id="ac-led" label="A · Daily ledger"           width={920} height={360}><AccountabilityLedger/></DCArtboard>
        <DCArtboard id="ac-mtx" label="B · Responsibility matrix"  width={920} height={420}><ResponsibilityMatrix/></DCArtboard>
      </DCSection>

      {/* ════════ PHASE 2 · TRACK 2 · COMMS PLANE ════════ */}

      <DCSection id="board-zone" title="C1 · Board Zone" subtitle="Real board_posts.jsonl — hearth groups, votes, kind=automation/direct.">
        <DCArtboard id="bd-feed" label="A · Feed (hearth-grouped)"  width={920} height={520}><BoardFeed/></DCArtboard>
        <DCArtboard id="bd-thr"  label="B · Single post + thread"   width={780} height={500}><BoardThread/></DCArtboard>
        <DCArtboard id="bd-tog"  label="C · direct vs automation"   width={780} height={460}><BoardHotAuto/></DCArtboard>
      </DCSection>

      <DCSection id="msgs" title="C2 · Messages / Broadcast" subtitle="Real messages/*_broadcast.json — seq, room, mentions, [STATE] blocks.">
        <DCArtboard id="ms-rm"   label="A · Room timeline"          width={920} height={500}><MessageRoomTimeline/></DCArtboard>
        <DCArtboard id="ms-inb"  label="B · Mention inbox (@nick0cave)" width={780} height={460}><MentionInbox/></DCArtboard>
        <DCArtboard id="ms-st"   label="C · [STATE] block focus"    width={780} height={420}><StateBlockMessage/></DCArtboard>
      </DCSection>

      <DCSection id="composer-v2" title="C3 · Composer v2" subtitle="Broadcast / mention autocomplete / structured [STATE] payload.">
        <DCArtboard id="cm-bc"   label="A · Broadcast"              width={780} height={220}><ComposerV2Broadcast/></DCArtboard>
        <DCArtboard id="cm-mn"   label="B · Mention autocomplete"   width={780} height={300}><ComposerV2Mention/></DCArtboard>
        <DCArtboard id="cm-st"   label="C · [STATE]-block compose"  width={780} height={280}><ComposerV2State/></DCArtboard>
      </DCSection>

      {/* ════════ PHASE 2 · TRACK 3 · OBSERVABILITY PLANE ════════ */}

      <DCSection id="cascade" title="O1 · Cascade Inspector" subtitle="cascade_audit.jsonl — hop-by-hop trace of model fallback chains.">
        <DCArtboard id="cs-list" label="A · Cascade list (multi-run)"     width={1080} height={520}><CascadeList/></DCArtboard>
        <DCArtboard id="cs-deep" label="B · Failed run · deep dive"        width={1080} height={360}><CascadeDeepDive/></DCArtboard>
        <DCArtboard id="cs-cmp"  label="C · Failure vs success compare"    width={1080} height={280}><CascadeCompare/></DCArtboard>
      </DCSection>

      <DCSection id="audit" title="O2 · Audit Ledger" subtitle="audit.jsonl — every tool/verdict/cascade/board/operator event, append-only.">
        <DCArtboard id="au-led" label="A · Streaming ledger"               width={1080} height={520}><AuditLedger/></DCArtboard>
        <DCArtboard id="au-act" label="B · Filtered by actor (sangsu)"     width={920}  height={360}><AuditByActor/></DCArtboard>
        <DCArtboard id="au-sum" label="C · Event-kind summary"             width={780}  height={420}><AuditSummary/></DCArtboard>
      </DCSection>

      <DCSection id="safe-auto" title="O3 · Safe Autonomy" subtitle="Cross-keeper audit — global score, findings, trend across runs.">
        <DCArtboard id="sa-dash" label="A · Score + findings"              width={1080} height={620}><SafeAutoDashboard/></DCArtboard>
        <DCArtboard id="sa-kpr"  label="B · Findings rolled up by keeper"  width={920}  height={420}><SafeAutoByKeeper/></DCArtboard>
        <DCArtboard id="sa-trd"  label="C · 15-run trend"                  width={780}  height={220}><SafeAutoTrend/></DCArtboard>
      </DCSection>

      <DCSection id="cost" title="O4 · Cost & Latency" subtitle="Per-agent token spend, provider×model heatmap, latency histogram.">
        <DCArtboard id="ct-agt" label="A · Per-agent table"                width={1080} height={460}><CostPerAgent/></DCArtboard>
        <DCArtboard id="ct-mtx" label="B · Provider × model heatmap"       width={920}  height={260}><CostMatrix/></DCArtboard>
        <DCArtboard id="ct-lat" label="C · Latency histogram + buckets"    width={920}  height={340}><CostLatency/></DCArtboard>
      </DCSection>

      <DCSection id="heur" title="O5 · Heuristic + Stress" subtitle="keeper_hooks_oas firing log + agent_stress.jsonl.">
        <DCArtboard id="hr-log" label="A · Heuristic firing log"           width={1080} height={420}><HeuristicLog/></DCArtboard>
        <DCArtboard id="hr-st"  label="B · Stress board (per-agent)"       width={920}  height={240}><StressBoard/></DCArtboard>
        <DCArtboard id="hr-mod" label="C · Firing rate by module"          width={920}  height={300}><HeuristicByModule/></DCArtboard>
      </DCSection>

      {/* ════════ PHASE 2 · TRACK 4 · COGNITION PLANE ════════ */}

      <DCSection id="keeper-v2" title="K1 · Keeper Inspector v2" subtitle="BDI (will/needs/desires) · tool access · token & handoff stats — real keepers/*.json">
        <DCArtboard id="ki-bdi"    label="A · BDI panel (will / needs / desires / goals)" width={920} height={400}><KeeperBDIPanel/></DCArtboard>
        <DCArtboard id="ki-acc"    label="B · Tool access + cascade config"                width={920} height={360}><KeeperToolAccess/></DCArtboard>
        <DCArtboard id="ki-stats"  label="C · Token / handoff stats (all keepers)"         width={920} height={360}><KeeperTokenStats/></DCArtboard>
      </DCSection>

      <DCSection id="decisions" title="K2 · Decisions / Memory" subtitle="decisions.jsonl + memory.jsonl — belief · intention · blocker · latency per turn">
        <DCArtboard id="dc-stream" label="A · Decisions stream (all keepers, filterable)"  width={1080} height={500}><DecisionsStream/></DCArtboard>
        <DCArtboard id="dc-mem"    label="B · Memory entries (verified / learned / plan)"  width={920}  height={320}><MemoryEntries/></DCArtboard>
      </DCSection>

      <DCSection id="episodes" title="K3 · Institution Episodes" subtitle="institution_episodes.jsonl — per-turn learning records, click to expand">
        <DCArtboard id="ep-cards" label="A · Turn cards (click to expand learnings)"       width={920}  height={480}><EpisodeCards/></DCArtboard>
        <DCArtboard id="ep-learn" label="B · Learnings extraction (all episodes grouped)"  width={920}  height={420}><EpisodeLearnings/></DCArtboard>
      </DCSection>

      <DCSection id="autoresearch" title="K4 · Autoresearch" subtitle="ar-* loops + findings.jsonl — hypothesis · evidence · conclusion · confidence">
        <DCArtboard id="ar-list"  label="A · Loop list (6 loops, open / closed)"           width={1080} height={380}><ARLoopList/></DCArtboard>
        <DCArtboard id="ar-find"  label="B · Finding card (select f-001/002/003)"          width={920}  height={500}><ARFindingCard/></DCArtboard>
        <DCArtboard id="ar-flow"  label="C · Hypothesis → evidence → conclusion flow"      width={780}  height={480}><ARHypothesisFlow/></DCArtboard>
      </DCSection>

    </DesignCanvas>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App/>);
