/* cockpit-ext.js — Phase 1 enhancements (loaded BEFORE React/Babel scripts)
   - Augments window.MASC_P2 with multi-repo metadata
   - Provides window.MASC_EXT helpers (state, repo lookup)
   No React here — plain JS so it can run before babel transform. */
(function () {
  // ── 1. multi-repo seed ─────────────────────────────────────────
  // Repos referenced in data.js / data-p2.js (tasks[].pr.repo).
  const REPOS = [
    { slug: "runtime",   owner: "masc",   pinned: true,  active_prs: 3, openIssues: 12, dirty: 1, head: "da11b063", desc: "claim-loop, cascade router, keeper shell" },
    { slug: "dashboard", owner: "masc",   pinned: true,  active_prs: 2, openIssues: 4,  dirty: 2, head: "51f062b9", desc: "cockpit UI, tokens, swimlanes" },
    { slug: "viewer",    owner: "masc",   pinned: false, active_prs: 0, openIssues: 1,  dirty: 0, head: "c0e814e2", desc: "scene viewer, 3D fleet map" },
    { slug: "mood",      owner: "masc",   pinned: false, active_prs: 1, openIssues: 2,  dirty: 0, head: "918fd2c0", desc: "mood seed, ambient signals" },
    { slug: "eval",      owner: "masc",   pinned: false, active_prs: 1, openIssues: 0,  dirty: 0, head: "44a1b903", desc: "eval harness, regression suite" },
  ];

  // Map each known branch to a primary repo (best-effort, derived from data).
  const BRANCH_TO_REPO = {
    "main":                "runtime",
    "release-0.42":        "runtime",
    "feat/keeper-clarity": "runtime",
    "fix/dashboard-9712":  "dashboard",
    "wt/sangsu-smoke":     "viewer",
    "ar-93ff2489":         "runtime",
    "ar-aadab70d":         "mood",
  };

  // Inject repo metadata into MASC_P2 once it exists.
  function applyRepoMeta() {
    if (!window.MASC_P2) return false;
    if (window.MASC_P2.__repoMetaApplied) return true;
    window.MASC_P2.repos = REPOS;
    if (Array.isArray(window.MASC_P2.branches)) {
      window.MASC_P2.branches = window.MASC_P2.branches.map(b => ({
        ...b,
        repo: b.repo || BRANCH_TO_REPO[b.name] || "runtime",
      }));
    }
    window.MASC_P2.__repoMetaApplied = true;
    return true;
  }
  // Try now; if MASC_P2 not ready yet, retry on DOMContentLoaded.
  if (!applyRepoMeta()) {
    document.addEventListener("DOMContentLoaded", applyRepoMeta, { once: true });
  }

  // ── 2. cockpit state helpers (URL hash + localStorage) ─────────
  const STORAGE_KEY = "masc.cockpit.state.v1";
  function readHash() {
    const h = (window.location.hash || "").replace(/^#/, "");
    if (!h) return {};
    const out = {};
    h.split("&").forEach(kv => {
      if (!kv) return;
      const [k, v] = kv.split("=");
      if (k) out[decodeURIComponent(k)] = v == null ? true : decodeURIComponent(v);
    });
    return out;
  }
  function readStorage() {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}"); }
    catch (e) { return {}; }
  }
  function writeHash(state) {
    // Only write a small allow-list to URL — collapse map + active repo + mode.
    const allow = ["repo", "branch", "mode", "collapsed"];
    const parts = [];
    allow.forEach(k => {
      if (state[k] == null) return;
      if (k === "collapsed") {
        // serialize Set/array of collapsed widget ids
        const arr = state[k] instanceof Set ? [...state[k]] : state[k];
        if (!arr || !arr.length) return;
        parts.push("collapsed=" + encodeURIComponent(arr.join(",")));
      } else {
        parts.push(k + "=" + encodeURIComponent(state[k]));
      }
    });
    const h = parts.join("&");
    const newUrl = window.location.pathname + window.location.search + (h ? "#" + h : "");
    history.replaceState(null, "", newUrl);
  }
  function writeStorage(state) {
    try {
      const out = { ...state };
      if (out.collapsed instanceof Set) out.collapsed = [...out.collapsed];
      localStorage.setItem(STORAGE_KEY, JSON.stringify(out));
    } catch (e) {}
  }

  // initial state — URL > localStorage > defaults
  function initialState() {
    const url = readHash();
    const ls = readStorage();
    const collapsedRaw = url.collapsed != null ? url.collapsed : ls.collapsed;
    let collapsed = [];
    if (Array.isArray(collapsedRaw)) collapsed = collapsedRaw;
    else if (typeof collapsedRaw === "string" && collapsedRaw) collapsed = collapsedRaw.split(",");
    return {
      repo: url.repo || ls.repo || "runtime",
      branch: url.branch || ls.branch || "main",
      mode: url.mode || ls.mode || "Dashboard",
      collapsed: new Set(collapsed),
      bannerDismissed: !!ls.bannerDismissed,
    };
  }

  window.MASC_EXT = {
    REPOS,
    BRANCH_TO_REPO,
    initialState,
    writeHash,
    writeStorage,
    persist(state) { writeHash(state); writeStorage(state); },
    setBannerDismissed() {
      const ls = readStorage();
      ls.bannerDismissed = true;
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify(ls)); } catch (e) {}
    },
  };
})();
