/* global React, MASC_EXT, MASC_P2 */
/* cockpit-ext.jsx — Phase 1 React extensions
   Loaded AFTER Chrome.jsx, exposes:
     - useCockpitState()        URL+localStorage hook
     - useCollapsed(id)         per-widget collapse state
     - <RepoSelector>           topbar repo picker w/ pin strip
     - <ViewportBanner>         1440/1920 hint + fullscreen
     - <WxHead>                 standard collapsible header
*/
const { useState: useStateExt, useEffect: useEffectExt, useRef: useRefExt, useCallback: useCallbackExt } = React;

// ── 1. global cockpit-state context (singleton) ────────────────
const _initial = (window.MASC_EXT && window.MASC_EXT.initialState()) || {
  repo: "runtime", branch: "main", mode: "Dashboard",
  collapsed: new Set(), bannerDismissed: false,
};
let _stateListeners = new Set();
let _state = _initial;
function _setState(patch) {
  _state = { ..._state, ...patch };
  if (window.MASC_EXT) window.MASC_EXT.persist(_state);
  _stateListeners.forEach(fn => fn(_state));
}
function useCockpitState() {
  const [, setTick] = useStateExt(0);
  useEffectExt(() => {
    const fn = () => setTick(t => t + 1);
    _stateListeners.add(fn);
    return () => _stateListeners.delete(fn);
  }, []);
  return [_state, _setState];
}

function useCollapsed(id) {
  const [s, set] = useCockpitState();
  const collapsed = s.collapsed.has(id);
  const toggle = useCallbackExt(() => {
    const next = new Set(s.collapsed);
    if (next.has(id)) next.delete(id); else next.add(id);
    set({ collapsed: next });
  }, [s.collapsed, id]);
  return [collapsed, toggle];
}

// ── 1c. Layout Profile per mode ───────────────────────────────
// Each mode has a recommended chrome state (which widgets collapse).
// On mode change, missing user-pinned overrides get the profile applied.
const LAYOUT_PROFILES = {
  Dashboard: { collapse: ["kpi","lifeline"], drawer: null },
  Work:      { collapse: ["kpi","lifeline"], drawer: null },
  Comms:     { collapse: ["kpi","lifeline"], drawer: null },
  Observe:   { collapse: ["lifeline","sidebar","rail"], drawer: null },
  Cognition: { collapse: ["kpi","lifeline"], drawer: null },
  IDE:       { collapse: ["kpi","lifeline","sidebar","rail"], drawer: { open: false, tab: "terminal" } },
};

// remember whether the user has manually overridden a widget's state
// per mode-session, so mode-switch profile doesn't fight them.
let _userOverrides = {};   // {mode: Set<widgetId>}

function useLayoutProfile() {
  const [s, set] = useCockpitState();
  const mode = s.mode || "Dashboard";

  // apply on mode change
  useEffectExt(() => {
    const prof = LAYOUT_PROFILES[mode];
    if (!prof) return;
    const overrides = _userOverrides[mode] || new Set();
    const next = new Set(s.collapsed);
    // first, clear any collapses that were set by a prior profile but not overridden by user
    Object.entries(LAYOUT_PROFILES).forEach(([m, p]) => {
      if (m === mode) return;
      p.collapse.forEach(id => {
        // only un-collapse if not in this mode's profile and not user-overridden
        if (!prof.collapse.includes(id) && !overrides.has(id)) {
          next.delete(id);
        }
      });
    });
    // then apply this profile's collapses (unless user explicitly un-collapsed)
    prof.collapse.forEach(id => {
      if (!overrides.has(id)) next.add(id);
    });
    // patch only if changed
    let changed = next.size !== s.collapsed.size;
    if (!changed) for (const id of next) if (!s.collapsed.has(id)) { changed = true; break; }
    if (changed) set({ collapsed: next });

    // drawer state — only auto-set on mode entry, don't override user
    if (prof.drawer && (!s.drawer || s.drawer.__autoMode !== mode)) {
      set({ drawer: { ...(s.drawer || {}), ...prof.drawer, __autoMode: mode } });
    }
  }, [mode]);

  return mode;
}

// expose for Sidebar/etc to mark user-driven collapse toggles
function markUserOverride(mode, widgetId) {
  if (!_userOverrides[mode]) _userOverrides[mode] = new Set();
  _userOverrides[mode].add(widgetId);
}


// ── 2. WxHead — standard collapsible header ───────────────────
function WxHead({ id, title, meta, actions, popoutId, children }) {
  const [collapsed, toggle] = useCollapsed(id);
  const popout = popoutId ? (
    <a className="wx-popout"
       href={"?widget=" + popoutId}
       target="_blank" rel="noopener"
       title="open this widget in a new tab"
       onClick={(e) => e.stopPropagation()}>↗</a>
  ) : null;
  return (
    <div className="wx-head" role="button" tabIndex={0}
         aria-expanded={!collapsed}
         onClick={(e) => {
           // ignore clicks inside action buttons
           if (e.target.closest(".wx-act") || e.target.closest(".wx-popout")) return;
           toggle();
         }}
         onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } }}>
      <span className="wx-chev">▾</span>
      <span className="wx-title">{title}</span>
      {meta != null && <span className="wx-meta">{meta}</span>}
      {(actions || popout) && <span className="wx-act">{actions}{popout}</span>}
      {children}
    </div>
  );
}

// ── 3. RepoSelector ───────────────────────────────────────────
function RepoSelector() {
  const [s, set] = useCockpitState();
  const [open, setOpen] = useStateExt(false);
  const popRef = useRefExt(null);
  const repos = (window.MASC_P2 && window.MASC_P2.repos) || [];
  const cur = repos.find(r => r.slug === s.repo) || repos[0];
  const pinned = repos.filter(r => r.pinned);

  useEffectExt(() => {
    if (!open) return;
    const close = (e) => { if (popRef.current && !popRef.current.contains(e.target)) setOpen(false); };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [open]);

  if (!cur) return null;

  const switchRepo = (slug) => {
    // when repo changes, reset branch to that repo's first known branch (or "main")
    const branches = (window.MASC_P2 && window.MASC_P2.branches) || [];
    const repoBranches = branches.filter(b => b.repo === slug);
    const newBranch = repoBranches.find(b => b.name === "main") ? "main"
                    : (repoBranches[0] && repoBranches[0].name) || "main";
    set({ repo: slug, branch: newBranch });
    setOpen(false);
  };

  const togglePin = (e, slug) => {
    e.stopPropagation();
    repos.forEach(r => { if (r.slug === slug) r.pinned = !r.pinned; });
    // force re-render via state ping
    set({});
  };

  return (
    <div className="tb-repo-pins-wrap" style={{ display: "inline-flex", alignItems: "center", gap: 6, position: "relative" }}>
      {pinned.length > 1 && (
        <div className="tb-repo-pins" aria-label="pinned repos">
          {pinned.map(r => (
            <button key={r.slug}
                    className={"tb-repo-pin" + (r.slug === s.repo ? " active" : "")}
                    title={`${r.owner}/${r.slug} · ${r.active_prs} PRs · ${r.dirty} dirty`}
                    onClick={() => switchRepo(r.slug)}>
              {r.slug.slice(0,2)}
              {r.active_prs > 0 && <span className="pin-badge">{r.active_prs}</span>}
            </button>
          ))}
        </div>
      )}
      <div className="tb-repo" onClick={() => setOpen(o => !o)}
           title={`${cur.owner}/${cur.slug} · HEAD ${cur.head}`}>
        <span className="tb-repo-glyph"></span>
        <span className="tb-repo-name">{cur.slug}</span>
        <span className="tb-repo-meta">
          {cur.active_prs}pr · {cur.dirty}d
        </span>
        <span className="chev">▾</span>
      </div>
      {open && (
        <div className="tb-repo-pop" ref={popRef}>
          <div className="h">workspace · {repos.length} repos</div>
          {repos.map(r => (
            <div key={r.slug}
                 className={"repo-row" + (r.slug === s.repo ? " on" : "")}
                 onClick={() => switchRepo(r.slug)}>
              <span className="glyph">⟢</span>
              <span className="nm"><span className="ow">{r.owner}/</span>{r.slug}</span>
              <span className="meta">
                <span className="pr">{r.active_prs}pr</span>
                <span>{r.openIssues}is</span>
                {r.dirty > 0 && <span className="dirty">{r.dirty}d</span>}
              </span>
              <button className={"pinbtn" + (r.pinned ? " on" : "")}
                      title={r.pinned ? "unpin" : "pin"}
                      onClick={(e) => togglePin(e, r.slug)}>
                {r.pinned ? "★" : "☆"}
              </button>
              <span className="desc">{r.desc} · {r.head}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ── 4. Viewport banner ────────────────────────────────────────
function ViewportBanner() {
  const [w, setW] = useStateExt(window.innerWidth);
  const [dismissed, setDismissed] = useStateExt(_state.bannerDismissed);
  useEffectExt(() => {
    const fn = () => setW(window.innerWidth);
    window.addEventListener("resize", fn);
    return () => window.removeEventListener("resize", fn);
  }, []);
  // Show only when viewport is meaningfully narrow.
  const show = !dismissed && w < 1400;
  useEffectExt(() => {
    document.body.classList.toggle("has-vp-banner", show);
    document.body.classList.toggle("compact-vp", w < 1400);
  }, [show, w]);

  if (!show) return null;

  const target = w < 1280 ? "1920px" : "1440px";
  const dismiss = () => {
    if (window.MASC_EXT) window.MASC_EXT.setBannerDismissed();
    _state.bannerDismissed = true;
    setDismissed(true);
  };
  const openFullscreen = () => {
    // Open this same page in a new tab — caller can resize freely.
    window.open(window.location.href, "_blank", "noopener");
  };
  return (
    <div className="vp-banner" role="status">
      <span className="vp-icon">⤢</span>
      <span className="vp-msg">
        Cockpit is built for <b>1440px+</b> (best at <b>1920px</b>).
        <span className="vp-cur">current: {w}px</span>
      </span>
      <button className="vp-fs" onClick={openFullscreen}>Open in new tab →</button>
      <button className="vp-close" onClick={dismiss} title="dismiss">✕</button>
    </div>
  );
}

// publish
Object.assign(window, { useCockpitState, useCollapsed, useLayoutProfile, markUserOverride, WxHead, RepoSelector, ViewportBanner });
