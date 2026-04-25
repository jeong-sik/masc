// preview/cb-group-k.jsx
// Phase 3 · Code IDE v2 E3/E4/E5 surfaces.

const P3K = window.MASC_P3;
const P2K = window.MASC_P2 || {};

function k3Keeper(id) {
  return (P3K.keepers || []).find(k => k.id === id) || { id, initials: id.slice(0, 2), color: "var(--idle)" };
}

function k3KeeperIds(keepers) {
  if (!keepers) return P3K.keepers.map(k => k.id);
  if (keepers instanceof Set) return Array.from(keepers);
  if (Array.isArray(keepers)) return keepers;
  return [keepers].filter(Boolean);
}

function K3Header({ title, meta, right }) {
  return (
    <div className="ix-head">
      <span className="ix-head-title">{title}</span>
      <span className="ix-head-meta">{meta}</span>
      {right && <span className="ix-head-right">{right}</span>}
    </div>
  );
}

function K3Status({ status }) {
  const kind = status === "pass" || status === "approved" ? "ok" : status === "fail" || status === "changes" || status === "flagged" ? "err" : status === "running" || status === "requested" ? "warn" : "idle";
  return <span className={`ix-status ${kind}`}>{status}</span>;
}

// ═════════════════════════════════════════════════════════════════
// E3 · PR INSPECTOR
// ═════════════════════════════════════════════════════════════════

function IxPrHeader({ branch = "main", keepers }) {
  const pr = P3K.pr;
  const selected = k3KeeperIds(keepers);
  const pass = pr.checks.filter(c => c.status === "pass").length;
  return (
    <div className="ix-pr">
      <K3Header title="E3-A · PR header" meta={`${branch} · source to base`} right={`${pass}/${pr.checks.length} passing`} />
      <div className="ix-pr-head">
        <div className="ix-pr-title">
          <span className={`ix-pr-state ${pr.state}`}>{pr.state}</span>
          <span className="num">#{pr.number}</span>
          <span>{pr.title}</span>
        </div>
        <div className="ix-pr-branches"><span>{pr.source}</span><b>→</b><span>{pr.base}</span><em>{selected.length} keepers selected</em></div>
        <div className="ix-pr-labels">{pr.labels.map(l => <span key={l}>{l}</span>)}</div>
        <div className="ix-pr-reviewers">
          {pr.reviewers.map(r => {
            const k = k3Keeper(r.name);
            return <span key={r.name} className={r.status}><i style={{ background: k.color }}>{k.initials}</i><b>{r.name}</b><K3Status status={r.status} /></span>;
          })}
        </div>
        <div className="ix-pr-merge"><span>merge blocked</span><button disabled>WAITING FOR SAFEAUTO</button></div>
      </div>
    </div>
  );
}

function IxPrFiles({ branch = "main" }) {
  const [sort, setSort] = useState("review");
  const [open, setOpen] = useState(new Set(["lib/dashboard/dashboard_fleet_fsm.ml"]));
  const toggle = (path) => {
    const next = new Set(open);
    next.has(path) ? next.delete(path) : next.add(path);
    setOpen(next);
  };
  const rows = [...P3K.prFiles].sort((a, b) => {
    if (sort === "alpha") return a.path.localeCompare(b.path);
    if (sort === "size") return (b.adds + b.dels) - (a.adds + a.dels);
    return a.review.localeCompare(b.review);
  });
  return (
    <div className="ix-pr">
      <K3Header title="E3-B · files changed" meta={`${branch} · ${rows.length} files`} right={<span className="ix-sort">{["review", "alpha", "size"].map(s => <button key={s} className={sort === s ? "on" : ""} onClick={() => setSort(s)}>{s}</button>)}</span>} />
      <div className="ix-pr-files">
        {rows.map(file => (
          <div key={file.path} className="ix-pr-file">
            <div className="row" onClick={() => toggle(file.path)}>
              <span className="tw">{open.has(file.path) ? "▾" : "▸"}</span>
              <span className="path">{file.path}</span>
              <span className={`st ${file.status}`}>{file.status}</span>
              <span className="diff">+{file.adds} −{file.dels}</span>
              <span className={`rv ${file.review}`}>{file.review}</span>
            </div>
            {open.has(file.path) && (
              <pre className="ix-pr-diff">{`@@ -181,7 +181,10 @@
- | Missing -> Unknown
+ | Missing -> Missing_runtime_signal
+ | Loaded stale -> Runtime_stall stale
+ | Blocked reason -> Operator_visible_blocker reason
  | Running -> No_issue`}</pre>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

function IxPrThread({ branch = "main" }) {
  const [resolved, setResolved] = useState(false);
  return (
    <div className="ix-pr">
      <K3Header title="E3-C · comment thread" meta={`${branch} · lib/dashboard/dashboard_fleet_fsm.ml:L183`} right={<button onClick={() => setResolved(v => !v)}>{resolved ? "resolved" : "open"}</button>} />
      <div className={`ix-pr-thread ${resolved ? "resolved" : ""}`}>
        {P3K.comments.map((c, i) => (
          <div key={`${c.by}-${i}`} className={`msg ${c.nested ? "nested" : ""}`}>
            <div className="h"><span className="by">@{c.by}</span><span className="at">{c.at}</span><K3Status status={c.verdict} /></div>
            <div className="body">{c.body}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

function IxPrChecks({ branch = "main" }) {
  const [safeOpen, setSafeOpen] = useState(true);
  return (
    <div className="ix-pr">
      <K3Header title="E3-D · CI checks panel" meta={`${branch} · SafeAuto + test gates`} right={`${P3K.pr.checks.length} checks`} />
      <div className="ix-pr-checks">
        {P3K.pr.checks.map(check => (
          <div key={check.name} className="ix-pr-check">
            <div className="row" onClick={() => check.name === "SafeAuto" && setSafeOpen(v => !v)}>
              <span className="name">{check.name}</span>
              <K3Status status={check.status} />
              <span className="dur">{check.duration}</span>
              <span className="log">log</span>
            </div>
            {check.name === "SafeAuto" && safeOpen && (
              <div className="findings">
                {check.details.map(d => <span key={d}>{d}</span>)}
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// E4 · BRANCH / GIT GRAPH
// ═════════════════════════════════════════════════════════════════

function IxGraphDag({ branch = "main" }) {
  const nodes = [
    { x: 40, y: 32, keeper: "nick0cave", hash: "1014c9", label: "main" },
    { x: 120, y: 32, keeper: "nick0cave", hash: "7afa7d", label: "" },
    { x: 200, y: 74, keeper: "masc-improver", hash: "918fd2", label: "feat/keeper-clarity" },
    { x: 280, y: 74, keeper: "masc-improver", hash: "1c5fb3", label: "" },
    { x: 360, y: 118, keeper: "sangsu", hash: "e45f2e", label: "oas-label" },
    { x: 440, y: 118, keeper: "rama", hash: "44a1b9", label: "ar-93ff2489" },
    { x: 520, y: 32, keeper: "qa-king", hash: "717da6", label: "merge" },
    { x: 600, y: 32, keeper: "nick0cave", hash: "da11b0", label: "tag v0.42" },
  ];
  return (
    <div className="ix-graph">
      <K3Header title="E4-A · branch DAG" meta={`${branch} · svg topology`} right="4 branches · 1 merge" />
      <svg className="ix-graph-dag" viewBox="0 0 680 170">
        <path d="M40 32 C160 32 240 32 360 32 C440 32 500 32 600 32" />
        <path d="M120 32 C160 42 168 74 200 74 L280 74 C320 74 330 118 360 118 L440 118 C480 118 490 48 520 32" />
        {nodes.map(n => {
          const k = k3Keeper(n.keeper);
          return (
            <g key={n.hash} className={n.label === branch || n.label === "main" ? "active" : ""}>
              <circle cx={n.x} cy={n.y} r="7" fill={k.color} />
              <text x={n.x + 12} y={n.y + 4}>{n.hash}</text>
              {n.label && <text className="label" x={n.x + 12} y={n.y - 10}>{n.label}</text>}
            </g>
          );
        })}
      </svg>
    </div>
  );
}

function IxGraphCommits({ branch = "main", keepers }) {
  const [filter, setFilter] = useState("all");
  const selected = k3KeeperIds(keepers);
  const rows = P3K.commits.filter(c => (filter === "all" || c.keeper === filter) && (selected.length === 0 || selected.includes(c.keeper)));
  return (
    <div className="ix-graph">
      <K3Header title="E4-B · commit list" meta={`${branch} · keeper attribution`} right={`${rows.length} commits`} />
      <div className="ix-graph-filters">
        {["all", ...P3K.keepers.map(k => k.id)].map(k => <button key={k} className={filter === k ? "on" : ""} onClick={() => setFilter(k)}>{k}</button>)}
      </div>
      <div className="ix-commits">
        {rows.map(c => {
          const k = k3Keeper(c.keeper);
          return (
            <div key={c.hash} className="ix-commit-row">
              <span className="hash">{c.hash}</span><span className="keeper" style={{ color: k.color }}>{c.keeper}</span><span className="subj">{c.subject}</span><span className="branch">{c.branch}</span><span className="age">{c.age}</span><span className="diff">+{c.adds} −{c.dels}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function IxGraphWorktrees({ branch = "main" }) {
  return (
    <div className="ix-graph">
      <K3Header title="E4-C · worktree picker" meta={`${branch} · active sandboxes`} right={`${P3K.worktrees.length} worktrees`} />
      <div className="ix-worktrees">
        {P3K.worktrees.map(w => (
          <div key={w.path} className={`ix-worktree-card ${w.status}`}>
            <div className="path">{w.path}</div>
            <div className="branch">{w.branch}</div>
            <div className="keepers">{w.keepers.map(k => <span key={k}>@{k}</span>)}</div>
            <div className="ft"><K3Status status={w.status} /><span>{w.touched}</span><button>switch</button><button>open</button></div>
          </div>
        ))}
      </div>
    </div>
  );
}

function IxGraphStashes({ branch = "main" }) {
  const [open, setOpen] = useState("stash@{0}");
  return (
    <div className="ix-graph">
      <K3Header title="E4-D · stash list" meta={`${branch} · recover keeper work`} right={`${P3K.stashes.length} stashes`} />
      <div className="ix-stashes">
        {P3K.stashes.map(s => (
          <div key={s.id} className="ix-stash-row">
            <div className="row" onClick={() => setOpen(open === s.id ? null : s.id)}>
              <span className="id">{s.id}</span><span className="branch">{s.branch}</span><span className="keeper">@{s.keeper}</span><span className="sum">{s.summary}</span><span className="age">{s.age}</span><span>{s.files} files</span>
            </div>
            {open === s.id && <div className="detail">inspect · apply · pop · drop <span>+{s.adds} −{s.dels}</span></div>}
          </div>
        ))}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// E5 · TERMINAL / SEARCH
// ═════════════════════════════════════════════════════════════════

function IxTerm({ branch = "main" }) {
  const cascade = (P2K.cascadeAudit && P2K.cascadeAudit[1]) || null;
  return (
    <div className="ix-term">
      <K3Header title="E5-A · cascade-aware terminal" meta={`${branch} · PWD .worktrees/${branch}`} right="history 8 · cascade trace inline" />
      <div className="ix-term-body">
        {[
          "$ git status --short",
          " M dashboard/design-system/preview/cb-group-j.jsx",
          "$ masc keeper claim task-4012 --keeper sangsu",
          "claim accepted · task-4012 · branch=codex/design-system-phase3-ide-v2",
        ].map((line, i) => <div key={i} className={`ix-term-line ${line.startsWith("$") ? "prompt" : ""}`}>{line}</div>)}
        {cascade && (
          <div className="cb-cascade">
            <div className="id">{cascade.id} · {cascade.cascade} · {cascade.trigger}</div>
            {cascade.hops.map(h => (
              <div key={h.i} className={`step ${h.status}`}>
                <span className="ix">{h.i}</span><span className="name">{h.model}</span><span className="ms">{h.ms}ms</span>
              </div>
            ))}
            <div className="total">total <span className="n">{cascade.total_ms}ms</span> · {cascade.outcome}</div>
          </div>
        )}
        {[
          "$ pnpm run typecheck",
          "typecheck passed · dashboard · 2m11s",
          "$ rg runtime_cause dashboard lib test",
          "6 matches · open with E5-B search",
        ].map((line, i) => <div key={`b-${i}`} className={`ix-term-line ${line.startsWith("$") ? "prompt" : ""}`}>{line}</div>)}
      </div>
    </div>
  );
}

function IxSearch({ branch = "main" }) {
  const [q, setQ] = useState("runtime");
  const [regex, setRegex] = useState(false);
  const [word, setWord] = useState(false);
  const rows = P3K.searchResults.filter(r => r.text.toLowerCase().includes(q.toLowerCase()) || r.file.toLowerCase().includes(q.toLowerCase()));
  const grouped = rows.reduce((acc, r) => {
    acc[r.file] = acc[r.file] || [];
    acc[r.file].push(r);
    return acc;
  }, {});
  return (
    <div className="ix-search">
      <K3Header title="E5-B · project search" meta={`${branch} · rg-style`} right={`${rows.length} matches`} />
      <div className="ix-search-bar">
        <input value={q} onChange={e => setQ(e.target.value)} />
        <button className={regex ? "on" : ""} onClick={() => setRegex(v => !v)}>regex</button>
        <button className={word ? "on" : ""} onClick={() => setWord(v => !v)}>whole word</button>
        <input readOnly value="*.{ml,ts,tsx,md,sh}" />
      </div>
      <div className="ix-search-results">
        {Object.entries(grouped).map(([file, items]) => (
          <div key={file} className="ix-search-file">
            <div className="file">{file} <span>{items.length}</span></div>
            {items.map(item => <div key={`${file}-${item.line}`} className="hit"><span>{item.line}</span><code>{item.text.split(q).map((p, i) => <React.Fragment key={i}>{i > 0 && <mark>{q}</mark>}{p}</React.Fragment>)}</code></div>)}
          </div>
        ))}
      </div>
    </div>
  );
}

function IxFindReplace({ branch = "main" }) {
  const [find, setFind] = useState("runtime");
  const [replace, setReplace] = useState("execution");
  const matches = P3K.editorLines.filter(l => l.text.toLowerCase().includes(find.toLowerCase()));
  return (
    <div className="ix-search ix-find-wrap">
      <K3Header title="E5-C · find / replace" meta={`${branch} · current editor`} right={`${matches.length ? 1 : 0} of ${matches.length}`} />
      <div className="ix-find">
        <input value={find} onChange={e => setFind(e.target.value)} />
        <input value={replace} onChange={e => setReplace(e.target.value)} />
        <button>prev</button><button>next</button><button>replace</button><button>replace all</button><button>selection</button>
      </div>
      <div className="ix-edit-code">
        {P3K.editorLines.slice(0, 8).map(line => (
          <div key={line.n} className={`ix-edit-line ${line.text.toLowerCase().includes(find.toLowerCase()) ? "review-hot" : ""}`}>
            <span className="ix-edit-num">{line.n}</span>
            <span className="ix-edit-src">{line.text}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

Object.assign(window, {
  IxPrHeader, IxPrFiles, IxPrThread, IxPrChecks,
  IxGraphDag, IxGraphCommits, IxGraphWorktrees, IxGraphStashes,
  IxTerm, IxSearch, IxFindReplace,
});
