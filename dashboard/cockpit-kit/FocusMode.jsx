/* global React */
/* FocusMode — bottom-right control cluster.

   Click → small popover with:
     - toggle focus mode (also F11 / Cmd+\)
     - show/hide status tray
     - any future global toggles

   Focus mode hides all top chrome (topbar/ticker/kpi/lifeline) and the
   bottom status bar so the central plane goes full-bleed. State persists
   in localStorage via useCockpitState. */

const { useEffect: _fmUseEffect, useCallback: _fmUseCb, useState: _fmUseState, useRef: _fmUseRef } = React;

function FocusToggle() {
  const [cs, setCs] = (window.useCockpitState ? window.useCockpitState() : [{focus:false, trayHidden:false}, ()=>{}]);
  const focus = !!cs.focus;
  const trayHidden = !!cs.trayHidden;
  const [open, setOpen] = _fmUseState(false);
  const ref = _fmUseRef(null);

  const toggleFocus = _fmUseCb(() => {
    setCs({ focus: !focus });
  }, [focus, setCs]);

  // apply body class
  _fmUseEffect(() => {
    document.body.classList.toggle("focus-mode", focus);
    return () => document.body.classList.remove("focus-mode");
  }, [focus]);

  // keyboard shortcut for focus mode
  _fmUseEffect(() => {
    const onKey = (e) => {
      const isFocusKey =
        e.key === "F11" ||
        ((e.ctrlKey || e.metaKey) && e.key === "\\");
      if (isFocusKey && !e.shiftKey && !e.altKey) {
        const t = e.target;
        const tag = t && t.tagName;
        if (tag === "INPUT" || tag === "TEXTAREA" || (t && t.isContentEditable)) return;
        e.preventDefault();
        toggleFocus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggleFocus]);

  // outside click closes menu
  _fmUseEffect(() => {
    if (!open) return;
    const onDoc = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false);
    };
    const onKey = (e) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div className="focus-cluster" ref={ref}>
      {open && (
        <div className="focus-menu">
          <div className="focus-menu-h">view</div>
          <button className={"focus-menu-row" + (focus ? " on" : "")}
                  onClick={() => { toggleFocus(); }}>
            <span className="focus-menu-k">{focus ? "✓" : " "}</span>
            <span className="focus-menu-l">focus mode</span>
            <span className="focus-menu-sub">F11</span>
          </button>
          <button className={"focus-menu-row" + (!trayHidden ? " on" : "")}
                  onClick={() => setCs({ trayHidden: !trayHidden })}>
            <span className="focus-menu-k">{!trayHidden ? "✓" : " "}</span>
            <span className="focus-menu-l">status tray</span>
            <span className="focus-menu-sub">{trayHidden ? "hidden" : "shown"}</span>
          </button>
        </div>
      )}
      <button
        className={"focus-toggle " + (focus ? "on" : "") + (open ? " menu-open" : "")}
        onClick={() => setOpen(!open)}
        title="view options"
        aria-pressed={focus}
        aria-expanded={open}>
        <span className="focus-icon">⛶</span>
        <span className="focus-label">{focus ? "exit focus" : "focus"}</span>
      </button>
    </div>
  );
}

window.FocusToggle = FocusToggle;
