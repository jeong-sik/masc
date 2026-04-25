// preview/cb-group-j.jsx
// Phase 3 · Code IDE v2 seed data + E1/E2 surfaces.

window.MASC_P3 = (function () {
  const keepers = [
    { id: "nick0cave", initials: "NC", role: "captain", color: "var(--brass-1)" },
    { id: "masc-improver", initials: "MI", role: "improver", color: "var(--ok)" },
    { id: "sangsu", initials: "SG", role: "analyst", color: "var(--info)" },
    { id: "qa-king", initials: "QA", role: "qa", color: "var(--err)" },
    { id: "rama", initials: "RA", role: "research", color: "var(--stalled)" },
  ];

  const files = [
    { path: "lib/keeper/keeper_runtime_trust_snapshot.ml", kind: "file", ext: ".ml", owners: ["nick0cave", "sangsu"], status: "modified", adds: 18, dels: 4, recent: true, pinned: true, touched: "2m", branch: "main" },
    { path: "lib/dashboard/dashboard_fleet_fsm.ml", kind: "file", ext: ".ml", owners: ["masc-improver"], status: "modified", adds: 42, dels: 9, recent: true, pinned: false, touched: "8m", branch: "main" },
    { path: "dashboard/src/components/FleetFSMPanel.tsx", kind: "file", ext: ".tsx", owners: ["sangsu", "masc-improver"], status: "added", adds: 126, dels: 0, recent: true, pinned: true, touched: "11m", branch: "feat/keeper-clarity" },
    { path: "dashboard/src/styles/mission.css", kind: "file", ext: ".css", owners: ["qa-king"], status: "modified", adds: 17, dels: 12, recent: false, pinned: false, touched: "24m", branch: "fix/dashboard-9712" },
    { path: "docs/COMMAND-PLANE-RUNBOOK.md", kind: "file", ext: ".md", owners: ["nick0cave", "rama", "sangsu"], status: "modified", adds: 31, dels: 8, recent: true, pinned: false, touched: "27m", branch: "main" },
    { path: "scripts/harness_trpg_agent_env.sh", kind: "file", ext: ".sh", owners: ["qa-king"], status: "deleted", adds: 0, dels: 77, recent: false, pinned: false, touched: "41m", branch: "wt/sangsu-smoke" },
    { path: "test/test_goal_fsm.ml", kind: "file", ext: ".ml", owners: ["qa-king", "sangsu"], status: "modified", adds: 64, dels: 21, recent: true, pinned: true, touched: "53m", branch: "main" },
    { path: "memory/handoff-2026-04-25-fsm.md", kind: "file", ext: ".md", owners: ["rama"], status: "added", adds: 22, dels: 0, recent: false, pinned: false, touched: "1h", branch: "ar-93ff2489" },
    { path: ".github/workflows/ci.yml", kind: "file", ext: ".yml", owners: ["nick0cave", "qa-king"], status: "modified", adds: 9, dels: 3, recent: false, pinned: false, touched: "2h", branch: "main" },
    { path: "lib/cascade/cascade_profile.ml", kind: "file", ext: ".ml", owners: ["sangsu", "rama"], status: "unchanged", adds: 0, dels: 0, recent: false, pinned: false, touched: "3h", branch: "ar-aadab70d" },
  ];

  const editorLines = [
    { n: 181, keeper: "sangsu", hash: "51f062", age: "2m", text: "let runtime_cause snapshot =", tokens: [["tok-key", "let"], ["", " runtime_cause snapshot ="]] },
    { n: 182, keeper: "sangsu", hash: "51f062", age: "2m", text: "  match snapshot.fsm_signal with", tokens: [["tok-key", "  match"], ["", " snapshot."], ["tok-prop", "fsm_signal"], ["tok-key", " with"]] },
    { n: 183, keeper: "nick0cave", hash: "da11b0", age: "7m", text: "  | Loaded { stale_for_sec; source } when stale_for_sec > 420 ->", tokens: [["", "  | "], ["tok-fn", "Loaded"], ["", " { stale_for_sec; source } "], ["tok-key", "when"], ["", " stale_for_sec > "], ["tok-str", "420"], ["", " ->"]] },
    { n: 184, keeper: "nick0cave", hash: "da11b0", age: "7m", text: "      Runtime_stall { source; stale_for_sec }", tokens: [["", "      "], ["tok-fn", "Runtime_stall"], ["", " { source; stale_for_sec }"]] },
    { n: 185, keeper: "masc-improver", hash: "918fd2", age: "18m", text: "  | Blocked reason -> Operator_visible_blocker reason", tokens: [["", "  | "], ["tok-fn", "Blocked"], ["", " reason -> "], ["tok-fn", "Operator_visible_blocker"], ["", " reason"]] },
    { n: 186, keeper: "qa-king", hash: "f20b81", age: "31m", text: "  | Running -> No_issue", tokens: [["", "  | "], ["tok-fn", "Running"], ["", " -> "], ["tok-fn", "No_issue"]] },
    { n: 187, keeper: "sangsu", hash: "51f062", age: "2m", text: "  | Missing -> Missing_runtime_signal", tokens: [["", "  | "], ["tok-fn", "Missing"], ["", " -> "], ["tok-fn", "Missing_runtime_signal"]] },
    { n: 188, keeper: "rama", hash: "44a1b9", age: "1h", text: "  | Unknown raw -> Unknown_runtime_state raw", tokens: [["", "  | "], ["tok-fn", "Unknown"], ["", " raw -> "], ["tok-fn", "Unknown_runtime_state"], ["", " raw"]] },
    { n: 189, keeper: "masc-improver", hash: "918fd2", age: "18m", text: "", tokens: [["", ""]] },
    { n: 190, keeper: "nick0cave", hash: "da11b0", age: "7m", text: "let render_receipt cause =", tokens: [["tok-key", "let"], ["", " "], ["tok-fn", "render_receipt"], ["", " cause ="]] },
    { n: 191, keeper: "nick0cave", hash: "da11b0", age: "7m", text: "  Receipt.with_signal ~kind:\"fleet_fsm\" cause", tokens: [["", "  "], ["tok-fn", "Receipt.with_signal"], ["", " ~kind:"], ["tok-str", "\"fleet_fsm\""], ["", " cause"]] },
    { n: 192, keeper: "qa-king", hash: "f20b81", age: "31m", text: "  |> Receipt.assert_operator_visible", tokens: [["", "  |> "], ["tok-fn", "Receipt.assert_operator_visible"]] },
  ];

  const splitLines = [
    { n: 18, text: "export function FleetFSMPanel({ snapshot }) {" },
    { n: 19, text: "  const cause = snapshot.runtime_cause" },
    { n: 20, text: "  return <RuntimeCause cause={cause} />" },
    { n: 21, text: "}" },
  ];

  const mergeHunks = [
    { id: "h1", file: "dashboard/src/store.ts", line: 442, ours: "dashboardLoading.value = false", theirs: "runtimeTruthLoading.value = false", base: "loading.value = false" },
    { id: "h2", file: "lib/dashboard/dashboard_fleet_fsm.ml", line: 187, ours: "| Missing -> Missing_runtime_signal", theirs: "| Missing -> Runtime_stall { source = \"fsm\"; stale_for_sec = 0 }", base: "| Missing -> Unknown" },
    { id: "h3", file: "docs/COMMAND-PLANE-RUNBOOK.md", line: 91, ours: "Fleet FSM stalls are surfaced in the cockpit.", theirs: "Fleet FSM stalls are operator-visible receipts.", base: "Fleet FSM stalls are logged." },
  ];

  const reviewThreads = [
    { id: "r1", line: 183, keeper: "qa-king", verdict: "flag", body: "stale_for_sec threshold needs test coverage", replies: 2 },
    { id: "r2", line: 187, keeper: "sangsu", verdict: "approve", body: "Missing state now has explicit runtime cause", replies: 1 },
    { id: "r3", line: 191, keeper: "masc-improver", verdict: "defer", body: "receipt kind should stay aligned with dashboard schema", replies: 0 },
  ];

  const pr = {
    number: 10310,
    title: "fix(dashboard): surface fleet FSM runtime causes",
    state: "open",
    source: "codex/fleet-fsm-runtime-cause",
    base: "main",
    author: "nick0cave",
    labels: ["dashboard", "runtime-trust", "human-approved-ready"],
    reviewers: [
      { name: "sangsu", status: "approved" },
      { name: "qa-king", status: "changes" },
      { name: "masc-improver", status: "requested" },
      { name: "rama", status: "approved" },
      { name: "velvet-hammer", status: "flagged" },
    ],
    checks: [
      { name: "SafeAuto", status: "fail", duration: "41s", details: ["runtime cause evidence lacks source path", "one stale FSM fixture missing timestamp", "review thread unresolved at L183"] },
      { name: "keeper-test-suite", status: "pass", duration: "8m 22s" },
      { name: "merge-blocker tests", status: "pass", duration: "3m 18s" },
      { name: "cascade-replay", status: "running", duration: "1m 04s" },
      { name: "type-check", status: "pass", duration: "2m 11s" },
      { name: "lint", status: "pass", duration: "46s" },
    ],
  };

  const prFiles = [
    { path: "lib/dashboard/dashboard_fleet_fsm.ml", status: "modified", adds: 42, dels: 9, review: "approved", expanded: true },
    { path: "dashboard/src/components/FleetFSMPanel.tsx", status: "added", adds: 126, dels: 0, review: "viewed" },
    { path: "dashboard/src/store.ts", status: "modified", adds: 17, dels: 4, review: "needed" },
    { path: "docs/COMMAND-PLANE-RUNBOOK.md", status: "modified", adds: 31, dels: 8, review: "none" },
    { path: "scripts/fleet-fsm-fixture.sh", status: "renamed", adds: 8, dels: 3, review: "viewed" },
    { path: "test/test_dashboard_fsm.ml", status: "deleted", adds: 0, dels: 77, review: "needed" },
  ];

  const comments = [
    { by: "qa-king", at: "9m", verdict: "flag", body: "L183 threshold changed without negative fixture. Add one stale snapshot with source path." },
    { by: "nick0cave", at: "7m", verdict: "reply", body: "Fixture added locally. Keeping threshold as runtime-trust default." },
    { by: "sangsu", at: "3m", verdict: "approve", body: "Data lineage is now explicit enough for cockpit display.", nested: true },
  ];

  const commits = [
    { hash: "1014c9", keeper: "nick0cave", branch: "main", subject: "fix(dashboard): surface fleet FSM runtime causes", age: "2m", adds: 112, dels: 21 },
    { hash: "7afa7d", keeper: "masc-improver", branch: "feat/keeper-clarity", subject: "refactor keeper claim decision tree", age: "14m", adds: 88, dels: 43 },
    { hash: "e45f2e", keeper: "sangsu", branch: "feat/oas-error-cascade-name-label-10285", subject: "label cascade mismatch errors", age: "24m", adds: 31, dels: 6 },
    { hash: "35e89b", keeper: "rama", branch: "diag/personality-resync-fields-10269", subject: "trace resync fields through keeper manifest", age: "38m", adds: 42, dels: 10 },
    { hash: "717da6", keeper: "qa-king", branch: "feat/auth-rotate-shared-tokens-10304", subject: "add auth rotation regression case", age: "41m", adds: 53, dels: 18 },
    { hash: "5c89fb", keeper: "sangsu", branch: "codex/git-access-risk-policy-20260424", subject: "tighten git access risk policy", age: "1h", adds: 21, dels: 8 },
    { hash: "1c5fb3", keeper: "masc-improver", branch: "chore/tool-access-policy-immutable-dedupe", subject: "dedupe immutable tool access policy", age: "2h", adds: 64, dels: 55 },
    { hash: "b61067", keeper: "nick0cave", branch: "feat/cascade-trust-observability", subject: "surface cascade trust receipts", age: "2h", adds: 119, dels: 44 },
    { hash: "c5ad9c", keeper: "qa-king", branch: "auto-provision-sandbox", subject: "sandbox provisioning smoke", age: "3h", adds: 27, dels: 12 },
    { hash: "44a1b9", keeper: "rama", branch: "ar-93ff2489", subject: "record autoresearch cascade conclusion", age: "4h", adds: 18, dels: 2 },
    { hash: "918fd2", keeper: "masc-improver", branch: "feat/keeper-clarity", subject: "split invocation from candidacy scoring", age: "4h", adds: 80, dels: 34 },
    { hash: "da11b0", keeper: "nick0cave", branch: "main", subject: "merge PR 9712 follow-up", age: "5h", adds: 12, dels: 1 },
  ];

  const worktrees = [
    { path: ".worktrees/design-system-phase3-ide-v2", branch: "codex/design-system-phase3-ide-v2", keepers: ["nick0cave", "sangsu"], status: "dirty", touched: "now" },
    { path: ".worktrees/feat/oas-error-cascade-name-label-10285", branch: "feat/oas-error-cascade-name-label-10285", keepers: ["sangsu"], status: "clean", touched: "24m" },
    { path: ".worktrees/worktree-sangsu-smoke", branch: "wt/sangsu-smoke", keepers: ["sangsu", "qa-king"], status: "dirty", touched: "53m" },
    { path: ".worktrees/ar-93ff2489", branch: "ar-93ff2489", keepers: ["rama"], status: "stale", touched: "4h" },
  ];

  const stashes = [
    { id: "stash@{0}", branch: "feat/keeper-clarity", keeper: "masc-improver", summary: "WIP keeper.claim() split", age: "18m", files: 4, adds: 44, dels: 19 },
    { id: "stash@{1}", branch: "wt/sangsu-smoke", keeper: "sangsu", summary: "debug cascade auth payload", age: "1h", files: 7, adds: 72, dels: 12 },
    { id: "stash@{2}", branch: "fix/dashboard-9712", keeper: "nick0cave", summary: "temporary dashboard fixture", age: "3h", files: 2, adds: 18, dels: 4 },
    { id: "stash@{3}", branch: "ar-93ff2489", keeper: "rama", summary: "research note + trace digest", age: "6h", files: 3, adds: 29, dels: 0 },
  ];

  const searchResults = [
    { file: "lib/dashboard/dashboard_fleet_fsm.ml", line: 187, text: "| Missing -> Missing_runtime_signal", ext: ".ml" },
    { file: "dashboard/src/components/FleetFSMPanel.tsx", line: 42, text: "const cause = snapshot.runtime_cause", ext: ".tsx" },
    { file: "dashboard/src/store.ts", line: 442, text: "runtimeTruthLoading.value = false", ext: ".ts" },
    { file: "docs/COMMAND-PLANE-RUNBOOK.md", line: 91, text: "Fleet FSM stalls are operator-visible receipts.", ext: ".md" },
    { file: "test/test_goal_fsm.ml", line: 63, text: "assert_runtime_cause Missing_runtime_signal", ext: ".ml" },
    { file: "scripts/harness_dashboard_execution_smoke.sh", line: 210, text: "assert_json_has runtime_cause", ext: ".sh" },
  ];

  return {
    keepers, files, editorLines, splitLines, mergeHunks, reviewThreads,
    pr, prFiles, comments, commits, worktrees, stashes, searchResults,
  };
})();

const P3J = window.MASC_P3;

function p3Keeper(id) {
  return P3J.keepers.find(k => k.id === id) || P3J.keepers[0];
}

function p3KeeperIds(keepers) {
  if (!keepers) return P3J.keepers.map(k => k.id);
  if (keepers instanceof Set) return Array.from(keepers);
  if (Array.isArray(keepers)) return keepers;
  return [keepers].filter(Boolean);
}

function P3Header({ title, meta, right }) {
  return (
    <div className="ix-head">
      <span className="ix-head-title">{title}</span>
      <span className="ix-head-meta">{meta}</span>
      {right && <span className="ix-head-right">{right}</span>}
    </div>
  );
}

function P3KeeperDots({ ids, compact }) {
  return (
    <span className={`ix-kdots ${compact ? "compact" : ""}`}>
      {ids.map(id => <span key={id} title={id} style={{ background: p3Keeper(id).color }} />)}
    </span>
  );
}

function P3CodeLine({ line, activeKeeper, reviewLine }) {
  const k = p3Keeper(line.keeper);
  return (
    <div role="listitem" aria-label={`Line ${line.n}, last touched by ${k.id} ${line.age} ago`} className={`ix-edit-line ${activeKeeper === line.keeper ? "spot" : ""} ${reviewLine === line.n ? "review-hot" : ""}`}>
      <span className="ix-edit-attrib" aria-hidden="true" style={{ borderColor: k.color, color: k.color }}>{k.initials}</span>
      <span className="ix-edit-num" aria-hidden="true">{line.n}</span>
      <span className="ix-edit-src">
        {line.tokens.map((part, i) => <span key={i} className={part[0]}>{part[1]}</span>)}
      </span>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// E1 · FILE TREE EXPLORER
// ═════════════════════════════════════════════════════════════════

function IxTreeAllowed({ branch = "main", keepers }) {
  const [focus, setFocus] = useState(null);
  const selected = p3KeeperIds(keepers);
  const rows = P3J.files.filter(f => !focus || f.owners.includes(focus));
  return (
    <div className="ix-tree" role="region" aria-label="File tree with allowed_paths overlay">
      <P3Header title="E1-A · allowed_paths overlay" meta={`${branch} · ${selected.length} keeper scope`} right="hover keeper chip to spotlight" />
      <div className="ix-tree-keepers" role="toolbar" aria-label="Spotlight keeper" onMouseLeave={() => setFocus(null)}>
        {P3J.keepers.map(k => (
          <button key={k.id} type="button" onMouseEnter={() => setFocus(k.id)} onFocus={() => setFocus(k.id)} aria-pressed={focus === k.id} className={focus === k.id ? "on" : ""}>
            <span aria-hidden="true" style={{ background: k.color }} />{k.id}
          </button>
        ))}
      </div>
      <div className="ix-tree-list" role="tree" aria-label={`${rows.length} files, owned by ${selected.length} keepers`}>
        {rows.map(file => (
          <div key={file.path} role="treeitem" aria-level="1" aria-label={`${file.path}, ${file.status}, +${file.adds} −${file.dels}`} tabIndex={-1} className={`ix-tree-row ${file.status} ${focus && !file.owners.includes(focus) ? "dim" : ""}`}>
            <span className="ix-tree-icon" aria-hidden="true">{file.path.includes("/") ? "▸" : "·"}</span>
            <span className="ix-tree-path">{file.path}</span>
            <P3KeeperDots ids={file.owners} />
            <span className="ix-tree-diff">+{file.adds} −{file.dels}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function IxTreeFilter({ branch = "main", keepers }) {
  const [q, setQ] = useState("dashboard");
  const [ext, setExt] = useState("all");
  const [recent, setRecent] = useState(false);
  const selected = p3KeeperIds(keepers);
  const rows = P3J.files.filter(f => {
    const qOk = f.path.toLowerCase().includes(q.toLowerCase());
    const extOk = ext === "all" || f.ext === ext;
    const recentOk = !recent || f.recent;
    const keeperOk = selected.length === 0 || f.owners.some(o => selected.includes(o));
    return qOk && extOk && recentOk && keeperOk;
  });
  return (
    <div className="ix-tree" role="region" aria-label="File tree with live filters">
      <P3Header title="E1-B · filter bar" meta={`${branch} · live path/ext/keeper filters`} right={`${rows.length} visible`} />
      <div className="ix-tree-filter" role="search">
        <input value={q} onChange={e => setQ(e.target.value)} placeholder="path glob / search" aria-label="Filter file paths" />
        <span role="radiogroup" aria-label="File extension filter" style={{display:"contents"}}>
          {["all", ".ml", ".tsx", ".ts", ".md"].map(x => (
            <button key={x} type="button" role="radio" aria-checked={ext === x} className={ext === x ? "on" : ""} onClick={() => setExt(x)}>{x}</button>
          ))}
        </span>
        <button type="button" aria-pressed={recent} className={recent ? "on" : ""} onClick={() => setRecent(v => !v)}>recent</button>
      </div>
      <div className="ix-tree-list" role="tree" aria-label={`${rows.length} files match filters`}>
        {rows.map(file => (
          <div key={file.path} role="treeitem" aria-level="1" aria-label={`${file.path}, touched ${file.touched}`} tabIndex={-1} className={`ix-tree-row ${file.status}`}>
            <span className="ix-tree-icon" aria-hidden="true">{file.ext}</span>
            <span className="ix-tree-path">{file.path}</span>
            <P3KeeperDots ids={file.owners} />
            <span className="ix-tree-age">{file.touched}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function IxTreeTabs({ branch = "main" }) {
  const [tab, setTab] = useState("recent");
  const rows = {
    recent: P3J.files.filter(f => f.recent),
    pinned: P3J.files.filter(f => f.pinned),
    changed: P3J.files.filter(f => f.status !== "unchanged"),
    search: P3J.files.filter(f => f.path.includes("fsm") || f.path.includes("keeper")),
  }[tab];
  const panelId = `ix-tree-tabs-panel-${tab}`;
  return (
    <div className="ix-tree" role="region" aria-label="File memory tabs (recent / pinned / changed / search)">
      <P3Header title="E1-C · recent / pinned / changed / search" meta={`${branch} · file memory`} right={`${rows.length} rows`} />
      <div className="ix-tree-tabs" role="tablist" aria-label="File memory category">
        {["recent", "pinned", "changed", "search"].map(t => (
          <button key={t} type="button" role="tab" id={`ix-tree-tabs-tab-${t}`} aria-selected={tab === t} aria-controls={`ix-tree-tabs-panel-${t}`} tabIndex={tab === t ? 0 : -1} className={tab === t ? "on" : ""} onClick={() => setTab(t)}>{t}</button>
        ))}
      </div>
      <div className="ix-tree-list" role="tabpanel" id={panelId} aria-labelledby={`ix-tree-tabs-tab-${tab}`}>
        {rows.map(file => (
          <div key={file.path} role="treeitem" aria-level="1" aria-label={`${file.path}, ${file.status}, touched ${file.touched}`} tabIndex={-1} className={`ix-tree-row ${file.status}`}>
            <span className="ix-tree-icon" aria-hidden="true">{file.pinned ? "◆" : "·"}</span>
            <span className="ix-tree-path">{file.path}</span>
            <span className={`ix-tree-status ${file.status}`}>{file.status}</span>
            <span className="ix-tree-age">{file.touched}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function IxTreeDiff({ branch = "main", keepers }) {
  const selected = p3KeeperIds(keepers);
  const dirs = {};
  P3J.files.forEach(f => {
    const dir = f.path.split("/")[0];
    dirs[dir] = dirs[dir] || { adds: 0, dels: 0, n: 0 };
    dirs[dir].adds += f.adds;
    dirs[dir].dels += f.dels;
    dirs[dir].n += 1;
  });
  return (
    <div className="ix-tree" role="region" aria-label="Diff annotated file tree">
      <P3Header title="E1-D · diff annotated tree" meta={`${branch} · ${selected.length} keepers`} right="+/- rolled up by directory" />
      <div className="ix-tree-list" role="tree" aria-label={`${P3J.files.length} files across ${Object.keys(dirs).length} directories`}>
        {Object.entries(dirs).map(([dir, d]) => (
          <div key={dir} role="treeitem" aria-level="1" aria-expanded="true" aria-label={`Directory ${dir}, ${d.n} files, +${d.adds} −${d.dels}`} tabIndex={-1} className="ix-tree-row dir">
            <span className="ix-tree-icon" aria-hidden="true">▾</span>
            <span className="ix-tree-path">{dir}/ <span className="muted">{d.n} files</span></span>
            <span className="ix-tree-diff">+{d.adds} −{d.dels}</span>
          </div>
        ))}
        {P3J.files.map(file => (
          <div key={file.path} role="treeitem" aria-level="2" aria-label={`${file.path}, ${file.status}, +${file.adds} −${file.dels}`} tabIndex={-1} className={`ix-tree-row ${file.status}`}>
            <span className="ix-tree-icon" aria-hidden="true">·</span>
            <span className="ix-tree-path">{file.path}</span>
            <span className={`ix-tree-status ${file.status}`}>{file.status}</span>
            <span className="ix-tree-diff">+{file.adds} −{file.dels}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// E2 · EDITOR SURFACES
// ═════════════════════════════════════════════════════════════════

function IxEditAttrib({ branch = "main", keepers }) {
  const [active, setActive] = useState(null);
  const selected = p3KeeperIds(keepers);
  return (
    <div className="ix-edit" role="region" aria-label="Editor with keeper attribution gutter">
      <P3Header title="E2-A · attribution gutter" meta={`${branch} · ${selected.length} keeper scope`} right={active || "hover a keeper"} />
      <div className="ix-edit-keepers" role="toolbar" aria-label="Spotlight keeper" onMouseLeave={() => setActive(null)}>
        {P3J.keepers.map(k => (
          <button key={k.id} type="button" onMouseEnter={() => setActive(k.id)} onFocus={() => setActive(k.id)} aria-pressed={active === k.id} className={active === k.id ? "on" : ""}>
            <span aria-hidden="true" style={{ background: k.color }} />{k.id}
          </button>
        ))}
      </div>
      <div className="ix-edit-code" role="list" aria-label={`${P3J.editorLines.length} editor lines`}>
        {P3J.editorLines.map(line => <P3CodeLine key={line.n} line={line} activeKeeper={active} />)}
      </div>
    </div>
  );
}

function IxEditSplit({ branch = "main" }) {
  const [sync, setSync] = useState(true);
  const leftRef = useRef(null);
  const rightRef = useRef(null);
  const onScroll = (from) => {
    if (!sync) return;
    const src = from === "left" ? leftRef.current : rightRef.current;
    const dst = from === "left" ? rightRef.current : leftRef.current;
    if (src && dst) dst.scrollTop = src.scrollTop;
  };
  return (
    <div className="ix-edit ix-edit-split" role="region" aria-label="Two-pane split editor">
      <P3Header title="E2-B · split 2-pane" meta={`${branch} · prod vs feature`} right={<button type="button" aria-pressed={sync} onClick={() => setSync(v => !v)}>{sync ? "sync scroll on" : "sync scroll off"}</button>} />
      <div className="ix-edit-split-grid">
        <div className="ix-edit-pane" role="region" aria-label="Left pane: main · dashboard_fleet_fsm.ml">
          <div className="ix-edit-bc">main · dashboard_fleet_fsm.ml</div>
          <div ref={leftRef} onScroll={() => onScroll("left")} className="ix-edit-scroll" role="list" aria-label="Left pane lines">
            {P3J.editorLines.slice(0, 8).map(line => <P3CodeLine key={line.n} line={line} />)}
          </div>
        </div>
        <div className="ix-edit-pane" role="region" aria-label="Right pane: feature · FleetFSMPanel.tsx">
          <div className="ix-edit-bc">feature · FleetFSMPanel.tsx</div>
          <div ref={rightRef} onScroll={() => onScroll("right")} className="ix-edit-scroll" role="list" aria-label="Right pane lines">
            {P3J.splitLines.concat(P3J.splitLines).map((line, i) => (
              <div key={`${line.n}-${i}`} role="listitem" className="ix-edit-line">
                <span className="ix-edit-num" aria-hidden="true">{line.n + i}</span>
                <span className="ix-edit-src">{line.text}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function IxEditMerge({ branch = "main" }) {
  const [choice, setChoice] = useState({ h1: "ours", h2: "manual", h3: "theirs" });
  const pick = (id, v) => setChoice(prev => ({ ...prev, [id]: v }));
  const resolved = Object.values(choice).filter(Boolean).length;
  return (
    <div className="ix-edit ix-edit-merge" role="region" aria-label={`3-way merge resolver, ${resolved} of ${P3J.mergeHunks.length} hunks resolved`}>
      <P3Header title="E2-C · 3-way merge resolver" meta={`${branch} · ${resolved}/${P3J.mergeHunks.length} resolved`} right="base · ours · theirs · result" />
      <div className="ix-merge-grid ix-merge-hdr" role="presentation"><span>base</span><span>ours</span><span>theirs</span><span>result</span></div>
      <div role="list" aria-label="Merge hunks">
        {P3J.mergeHunks.map(h => (
          <div key={h.id} role="listitem" aria-label={`Hunk ${h.file}:${h.line}, resolved as ${choice[h.id]}`} className="ix-merge-block">
            <div className="ix-merge-file">{h.file}:{h.line}</div>
            <div className="ix-merge-grid">
              <pre>{h.base}</pre>
              <pre>{h.ours}</pre>
              <pre>{h.theirs}</pre>
              <pre className="result">{choice[h.id] === "ours" ? h.ours : choice[h.id] === "theirs" ? h.theirs : `${h.ours}\n${h.theirs}`}</pre>
            </div>
            <div className="ix-merge-actions" role="radiogroup" aria-label={`Resolution for ${h.file}:${h.line}`}>
              {["ours", "theirs", "manual"].map(v => <button key={v} type="button" role="radio" aria-checked={choice[h.id] === v} className={choice[h.id] === v ? "on" : ""} onClick={() => pick(h.id, v)}>{v}</button>)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function IxEditReview({ branch = "main" }) {
  const [hot, setHot] = useState(null);
  return (
    <div className="ix-edit ix-edit-review" role="region" aria-label="Inline code review">
      <P3Header title="E2-D · inline review" meta={`${branch} · ${P3J.reviewThreads.length} threads`} right="line-pinned comments" />
      <div className="ix-review-grid">
        <div className="ix-edit-code" role="list" aria-label="Editor lines under review">
          {P3J.editorLines.map(line => <P3CodeLine key={line.n} line={line} reviewLine={hot} />)}
        </div>
        <div className="ix-review-side" role="list" aria-label={`${P3J.reviewThreads.length} review threads`}>
          {P3J.reviewThreads.map(t => (
            <div key={t.id} role="listitem" tabIndex={0} aria-label={`Review on line ${t.line} by ${t.keeper}, verdict ${t.verdict}, ${t.replies} replies`} className={`ix-review-thread ${t.verdict}`} onMouseEnter={() => setHot(t.line)} onMouseLeave={() => setHot(null)} onFocus={() => setHot(t.line)} onBlur={() => setHot(null)}>
              <div className="h"><span className="ln">L{t.line}</span><span className="who">@{t.keeper}</span><span className={`chip is-${t.verdict === "approve" ? "ok" : t.verdict === "flag" ? "warn" : "idle"}`}>{t.verdict}</span></div>
              <div className="body">{t.body}</div>
              <div className="ft" aria-hidden="true">↩ {t.replies} replies · resolve</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function IxEditBlame({ branch = "main" }) {
  return (
    <div className="ix-edit ix-edit-blame" role="region" aria-label="Blame gutter editor">
      <P3Header title="E2-E · blame gutter" meta={`${branch} · hash · keeper · age`} right="hover rows for commit metadata" />
      <div className="ix-edit-code" role="list" aria-label={`${P3J.editorLines.length} lines with blame metadata`}>
        {P3J.editorLines.map(line => {
          const k = p3Keeper(line.keeper);
          return (
            <div key={line.n} role="listitem" aria-label={`Line ${line.n}, commit ${line.hash} by ${line.keeper} ${line.age} ago`} className={`ix-edit-line age-${line.age.endsWith("m") ? "fresh" : "old"}`} title={`${line.hash} · ${line.keeper} · ${line.age} · ${line.text}`}>
              <span className="ix-blame-cell" aria-hidden="true"><b>{line.hash}</b><i style={{ color: k.color }}>{k.initials}</i><em>{line.age}</em></span>
              <span className="ix-edit-num" aria-hidden="true">{line.n}</span>
              <span className="ix-edit-src">{line.tokens.map((part, i) => <span key={i} className={part[0]}>{part[1]}</span>)}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

Object.assign(window, {
  IxTreeAllowed, IxTreeFilter, IxTreeTabs, IxTreeDiff,
  IxEditAttrib, IxEditSplit, IxEditMerge, IxEditReview, IxEditBlame,
});
