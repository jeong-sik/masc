// MASC seed data — derived from real keeper/goal/task names in .masc/

window.MASC_DATA = (function () {
  const keepers = [
    { id: "nick0cave",      role: "Captain",    color: "var(--brass-1)",    dotVar: "brass",    status: "running",  task: "t-9f2a", tool: "tool.write_file" },
    { id: "masc-improver",  role: "Improver",   color: "var(--ok-fg)",      dotVar: "ok",       status: "running",  task: "t-4b11", tool: "tool.read_file" },
    { id: "sangsu",         role: "Analyst",    color: "var(--info-fg)",    dotVar: "info",     status: "pending",  task: "t-7c03", tool: "review.drift" },
    { id: "qa-king",        role: "QA",         color: "var(--err-fg)",     dotVar: "err",      status: "fail",     task: "t-2e88", tool: "suite.run" },
    { id: "rama",           role: "Researcher", color: "var(--stalled-fg)", dotVar: "stalled",  status: "stalled",  task: "t-d551", tool: "(await analyst)" },
    { id: "scholar",        role: "Scholar",    color: "var(--fg-2)",       dotVar: "idle",     status: "idle",     task: "—",      tool: "—" },
    { id: "taskmaster",     role: "Orchestr.",  color: "var(--fg-2)",       dotVar: "idle",     status: "idle",     task: "—",      tool: "—" },
    { id: "velvet-hammer",  role: "Gatekeep.",  color: "var(--fg-2)",       dotVar: "idle",     status: "idle",     task: "—",      tool: "—" },
  ];

  const goals = [
    { id: "goal-merge-blockers",       title: "Merge-blocker 해결 및 CI 안정화",                   progress: 3, total: 3, priority: 1, status: "active" },
    { id: "goal-keeper-clarity",       title: "Keeper 활성화 및 선명성 파이프라인 개선",              progress: 4, total: 7, priority: 1, status: "active" },
    { id: "goal-masc-product",         title: "MASC 프로덕트 레벨 에이전트 생태계 완성",               progress: 2, total: 9, priority: 2, status: "active" },
    { id: "goal-dash-pr9712-followup", title: "Stabilize Goal Manager after PR #9712",           progress: 5, total: 5, priority: 3, status: "done" },
  ];

  const tasks = [
    { id: "t-9f2a", keeper: "nick0cave",     title: "Rebase PR #9712 + green CI",                 status: "running",  goal: "goal-merge-blockers",      t: "2m" },
    { id: "t-4b11", keeper: "masc-improver", title: "Refactor keeper.claim() for clarity",         status: "running",  goal: "goal-keeper-clarity",      t: "5m" },
    { id: "t-7c03", keeper: "sangsu",        title: "Drift audit — src/keeper/pipeline.ts L187",   status: "pending",  goal: "goal-keeper-clarity",      t: "8m" },
    { id: "t-2e88", keeper: "qa-king",       title: "suite-merge-blockers · 3 FAIL",               status: "fail",     goal: "goal-merge-blockers",      t: "12m" },
    { id: "t-d551", keeper: "rama",          title: "Research cascade regression @step=2",         status: "stalled",  goal: "goal-masc-product",        t: "22m" },
    { id: "t-c022", keeper: "nick0cave",     title: "Backport fix to release-0.42 branch",         status: "queued",   goal: "goal-merge-blockers",      t: "—"  },
    { id: "t-a9e1", keeper: "masc-improver", title: "Write keeper-clarity runbook",                status: "queued",   goal: "goal-keeper-clarity",      t: "—"  },
  ];

  const providers = [
    { id: "anthropic", model: "claude-haiku-4-5",   tps: 1.24, status: "ok",   cascade: 1 },
    { id: "moonshot",  model: "kimi-k2",            tps: 0.88, status: "ok",   cascade: 2 },
    { id: "openai",    model: "gpt-4o-mini",        tps: 1.02, status: "warn", cascade: 3 },
    { id: "xai",       model: "grok-2",             tps: 0.76, status: "idle", cascade: 4 },
  ];

  // Event stream for ticker and swimlanes
  const events = [
    { t: "16:32:45Z", keeper: "rama",          kind: "note",  text: "STALLED 12m — awaiting sangsu review" },
    { t: "16:32:18Z", keeper: "qa-king",       kind: "err",   text: "suite-merge-blockers · 3 FAIL / 47 PASS" },
    { t: "16:32:01Z", keeper: "masc-improver", kind: "tool",  text: "PR #9712 keeper-clarity 파이프라인 개선" },
    { t: "16:31:44Z", keeper: "sangsu",        kind: "flag",  text: "drift detected at pipeline.ts L187 (+2 replies)" },
    { t: "16:31:32Z", keeper: "nick0cave",     kind: "tool",  text: "tool.write_file +18 −4 · keeper.ts" },
    { t: "16:31:27Z", keeper: "nick0cave",     kind: "claim", text: "claimed t-9f2a (goal-merge-blockers)" },
    { t: "16:30:55Z", keeper: "masc-improver", kind: "tool",  text: "tool.grep 'claim(' → 14 hits" },
    { t: "16:30:40Z", keeper: "scholar",       kind: "note",  text: "indexed 82 files · cold-read done" },
    { t: "16:30:18Z", keeper: "nick0cave",     kind: "claim", text: "claimed t-c022 (backport)" },
    { t: "16:29:50Z", keeper: "sangsu",        kind: "flag",  text: "cascade hit@step=2 — 1.24s anthropic→moonshot" },
    { t: "16:29:22Z", keeper: "qa-king",       kind: "err",   text: "flake in test_cascade_retry · re-running" },
  ];

  // Swimlane events (for timeline) — normalized x 0..1
  const laneEvents = {
    "nick0cave":     [{x:.05,k:"text"},{x:.12,k:"tool"},{x:.22,k:"claim"},{x:.34,k:"tool"},{x:.44,k:"tool"},{x:.58,k:"text"},{x:.66,k:"tool"},{x:.72,k:"tool"}],
    "masc-improver": [{x:.08,k:"tool"},{x:.18,k:"tool"},{x:.30,k:"claim"},{x:.42,k:"tool"},{x:.55,k:"text"},{x:.68,k:"tool"}],
    "sangsu":        [{x:.06,k:"text"},{x:.16,k:"text"},{x:.28,k:"claim"},{x:.40,k:"flag"},{x:.52,k:"text"},{x:.64,k:"flag"}],
    "qa-king":       [{x:.10,k:"tool"},{x:.24,k:"err"}, {x:.38,k:"tool"},{x:.48,k:"err"}, {x:.62,k:"err"}],
    "rama":          [{x:.08,k:"text"},{x:.18,k:"text"},{x:.24,k:"text"}],
  };

  // cascade trace
  const cascade = {
    id: "cascade-3f19",
    steps: [
      { provider: "anthropic", status: "miss", ms: 820, reason: "rate-limit.soft" },
      { provider: "moonshot",  status: "hit",  ms: 420, reason: "ok" },
      { provider: "openai",    status: "—",    ms: 0,   reason: "skipped" },
    ],
    total_ms: 1240,
  };

  return { keepers, goals, tasks, providers, events, laneEvents, cascade };
})();
