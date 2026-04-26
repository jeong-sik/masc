(** Phase 1 logs view — MASC Design System (dark-fantasy theme).

    Layout follows MASC's keeper-row grammar: hairline-separated rows, tight
    8-16 px padding, tiny 2-4 px radii, flat shadows. One brass accent
    (timestamps, header chrome). Level colors are the MASC status palette
    (bile / ember / blood) — not generic yellow/red. Body uses EB Garamond;
    timestamps, module, and source badges use JetBrains Mono or Noto Sans KR
    UI per the system's type stack.

    Tokens are inlined as literals because ppx_css has no access to the
    design system's [:root] variables yet. When [colors_and_type.css] is
    served from [assets/dashboard_bonsai/], the inline values become
    [var(--color-bg-page)] etc. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom
open Js_of_ocaml

module Style =
[%css
stylesheet
  {|
  .root {
    position: relative;
    min-height: 100vh;
    background:
      radial-gradient(circle at 88% 14%, color-mix(in oklab, var(--color-accent-fg) 10%, transparent), transparent 22%),
      radial-gradient(circle at 8% 88%, color-mix(in oklab, var(--accent-blood) 5%, transparent), transparent 28%),
      var(--color-bg-page);
    color: var(--color-fg-primary);
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-size: 15px;
    padding: 1.5rem calc(340px + 24px) 4rem 244px;
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
    isolation: isolate;
  }
  .skip_nav {
    position: absolute;
    left: -9999px;
    top: auto;
    width: 1px;
    height: 1px;
    overflow: hidden;
    z-index: 100;
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 13px;
    padding: 8px 16px;
    background: var(--color-bg-surface);
    color: var(--color-accent-fg);
    border: 2px solid var(--color-accent-fg);
    text-decoration: none;
  }
  .skip_nav:focus {
    position: fixed;
    top: 8px;
    left: 8px;
    width: auto;
    height: auto;
  }

  @media (max-width: 1280px) {
    .root { padding-right: 2.5rem; }
    .aside { display: none; }
  }
  @media (max-width: 880px) {
    .root { padding-left: 1.25rem; }
    .nav  { display: none; }
  }

  .root::before {
    content: "";
    position: absolute;
    inset: 0;
    pointer-events: none;
    z-index: -1;
    opacity: 0.28;
    background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='180' height='180'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='1.2' numOctaves='2' seed='3'/><feColorMatrix values='0 0 0 0 0.9  0 0 0 0 0.85  0 0 0 0 0.7  0 0 0 0.05 0'/></filter><rect width='100%25' height='100%25' filter='url(%23n)'/></svg>");
    mix-blend-mode: overlay;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 14px;
    padding-bottom: 1rem;
    border-bottom: 1px solid var(--color-border-default);
  }

  .rune {
    width: 22px;
    height: 22px;
    border: 1px solid var(--color-accent-fg);
    display: grid;
    place-items: center;
    color: var(--color-accent-fg);
    font-family: 'Cinzel', serif;
    font-size: 11px;
    transform: rotate(45deg);
  }

  .rune_inner {
    transform: rotate(-45deg);
  }

  .wordmark {
    font-family: 'Cinzel', serif;
    font-size: 13px;
    letter-spacing: 0.22em;
    color: var(--color-accent-fg);
    text-transform: uppercase;
  }

  .crumbs {
    margin-left: 14px;
    display: flex;
    align-items: center;
    gap: 10px;
    color: var(--color-fg-muted);
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.12em;
    text-transform: uppercase;
  }

  .crumbs_sep { color: var(--color-border-strong); }
  .crumbs_cur { color: var(--text-bright); letter-spacing: 0.14em; }
  .crumbs_room {
    color: var(--color-accent-fg);
    letter-spacing: 0.14em;
    font-variant-numeric: tabular-nums;
  }

  .pulse_slot { margin-left: auto; display: flex; align-items: center; gap: 8px; }

  .pulse {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-accent-fg);
    box-shadow: 0 0 8px color-mix(in oklab, var(--color-accent-fg) 55%, transparent);
    animation: pulse-beat 2.4s ease-in-out infinite;
  }

  @keyframes pulse-beat {
    0%, 100% { opacity: 0.55; }
    50% { opacity: 1; }
  }

  .pulse_label {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }

  .heartbeat {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 10px 14px 12px;
    background:
      linear-gradient(180deg, var(--color-bg-surface) 0%, var(--color-bg-page) 100%);
    border: 1px solid var(--color-border-default);
    border-radius: 2px;
    box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--color-accent-fg) 4%, transparent);
  }

  .heartbeat_head {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .heartbeat_eyebrow {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }

  .heartbeat_scale {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
    font-size: 11px;
    letter-spacing: 0.12em;
    color: var(--color-fg-muted);
  }

  .heartbeat_track {
    display: grid;
    grid-auto-flow: column;
    grid-auto-columns: 1fr;
    gap: 2px;
    height: 36px;
    align-items: end;
    padding: 0 1px;
    border-bottom: 1px solid var(--color-border-default);
  }

  .heartbeat_bar {
    min-width: 2px;
    background: var(--accent-mold);
    border-radius: 1px;
    opacity: 0.82;
  }

  .heartbeat_bar_warn  { background: linear-gradient(180deg, var(--color-status-warn) 0%, color-mix(in oklab, var(--color-status-warn) 40%, var(--color-bg-page)) 100%); }
  .heartbeat_bar_error { background: linear-gradient(180deg, var(--accent-blood) 0%, var(--accent-blood-dim) 100%); box-shadow: 0 0 6px color-mix(in oklab, var(--accent-blood) 45%, transparent); }
  .heartbeat_bar_idle  { background: var(--color-border-default); opacity: 0.6; }

  /* hud CSS → Hud 모듈로 이관 (shell 추출 Phase 2.A) */

  /* Moonrise strip — narrative interlude between the HUD readout and
     the filter toolbar. Reads as a quiet status bar that names the
     watch, the time of day, and who is at the helm. */
  .moonrise {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 8px 14px;
    background:
      linear-gradient(90deg,
        color-mix(in oklab, var(--color-accent-fg) 10%, transparent) 0%,
        transparent 45%,
        color-mix(in oklab, var(--accent-blood) 6%, transparent) 100%),
      var(--color-bg-page);
    border: 1px solid var(--color-border-default);
    border-radius: 2px;
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-variant: small-caps;
    letter-spacing: 0.08em;
    font-size: 12px;
    color: var(--color-fg-primary);
  }

  .moon_glyph {
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: radial-gradient(circle at 28% 28%, var(--text-bright) 0%, var(--color-accent-fg) 55%, var(--color-border-strong) 100%);
    box-shadow:
      0 0 10px color-mix(in oklab, var(--text-bright) 22%, transparent),
      inset 0 0 0 1px color-mix(in oklab, var(--text-bright) 12%, transparent);
    flex-shrink: 0;
  }

  .moon_lead {
    font-family: 'Cinzel', serif;
    font-variant: normal;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-bright);
    font-size: 11px;
  }

  .moon_sep {
    color: var(--color-border-strong);
    font-variant: normal;
  }

  .moon_mono {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
    font-size: 11px;
    font-variant: normal;
    letter-spacing: 0.04em;
    color: var(--color-accent-fg);
  }

  .moon_tail {
    margin-left: auto;
    color: var(--color-fg-muted);
    font-variant: normal;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
  }

  .toolbar {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 12px;
    background: var(--color-bg-surface);
    border: 1px solid var(--color-border-default);
    border-radius: 2px;
    flex-wrap: wrap;
  }

  .chip_group {
    display: inline-flex;
    gap: 4px;
    padding: 2px;
    border: 1px solid var(--color-border-default);
    border-radius: 999px;
    background: var(--color-bg-page);
  }

  .chip {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    padding: 7px 12px;
    border-radius: 999px;
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: background 0.18s, color 0.18s;
  }

  .chip:hover { color: var(--color-fg-primary); }
  .chip:focus-visible { outline: 2px solid var(--color-accent-fg); outline-offset: 1px; }
  .chip_active {
    color: var(--text-bright);
    background: color-mix(in oklab, var(--color-accent-fg) 14%, transparent);
    box-shadow: inset 0 0 0 1px var(--color-accent-fg);
  }

  /* Declarative active state for filter chips — theme chip 패턴과 동일.
     <html data-log-level="X"> 가 set되면 매칭되는 chip만 active 스타일.
     기본값 = info (data-log-level 속성 없는 초기 상태도 info chip이 활성). */
  html[data-log-level="debug"] .chip[data-filter-level="debug"],
  html[data-log-level="info"]  .chip[data-filter-level="info"],
  html[data-log-level="warn"]  .chip[data-filter-level="warn"],
  html[data-log-level="error"] .chip[data-filter-level="error"],
  html:not([data-log-level])   .chip[data-filter-level="info"] {
    color: var(--text-bright);
    background: color-mix(in oklab, var(--color-accent-fg) 14%, transparent);
    box-shadow: inset 0 0 0 1px var(--color-accent-fg);
  }

  .input_shell {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border: 1px solid var(--color-border-default);
    border-radius: 2px;
    background: var(--color-bg-page);
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    color: var(--color-fg-muted);
  }

  .input_shell_label { letter-spacing: 0.2em; text-transform: uppercase; color: var(--color-fg-muted); font-size: 11px; }
  .input_shell_value { font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace; font-size: 11px; color: var(--color-fg-primary); }

  .toolbar_spacer { flex: 1; }

  .btn_ghost {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    padding: 7px 12px;
    border: 1px solid var(--color-border-default);
    border-radius: 2px;
    background: transparent;
    color: var(--color-fg-primary);
    cursor: pointer;
    transition: color 0.18s, border-color 0.18s;
  }
  .btn_ghost:hover { color: var(--color-accent-fg); border-color: var(--color-border-strong); }
  .btn_ghost:focus-visible { outline: 2px solid var(--color-accent-fg); outline-offset: -2px; }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    border-bottom: 1px solid var(--color-border-default);
    padding-bottom: 0.75rem;
    gap: 1rem;
  }

  .header_lead { flex: 1; min-width: 0; }

  .eyebrow {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    margin: 0 0 0.25rem 0;
  }

  .title {
    font-family: 'Cinzel', serif;
    font-weight: 500;
    font-size: 1.25rem;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--text-bright);
    margin: 0;
    display: flex;
    align-items: baseline;
    gap: 6px;
  }

  .versal {
    font-family: 'EB Garamond', 'Cinzel', serif;
    font-size: 3.5rem;
    line-height: 0.82;
    font-weight: 600;
    letter-spacing: 0;
    text-transform: uppercase;
    background: linear-gradient(180deg, var(--text-bright) 0%, var(--color-accent-fg) 55%, var(--color-border-strong) 100%);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    text-shadow: 0 0 18px color-mix(in oklab, var(--color-accent-fg) 28%, transparent);
    margin-right: 4px;
    align-self: flex-start;
    padding-top: 6px;
  }

  .title_rest {
    font-family: 'Cinzel', serif;
    font-weight: 400;
    font-size: 1rem;
    letter-spacing: 0.3em;
    color: var(--color-fg-primary);
    text-transform: uppercase;
  }

  .title_rule {
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--color-border-strong) 0%, transparent 100%);
    margin-left: 10px;
    margin-right: 10px;
    align-self: center;
  }

  .folio {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 11px;
    letter-spacing: 0.08em;
    color: var(--color-border-strong);
    text-transform: none;
  }

  .meta {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 11px;
    letter-spacing: 0.1em;
    color: var(--color-accent-fg);
  }

  .tape {
    display: flex;
    flex-direction: column;
    position: relative;
    padding-left: 1.5rem;
    isolation: isolate;
  }

  /* Vertical brass thread running down the left margin — anchors the
     time gutter and reads as a continuous "spine" for the row sequence. */
  .tape::before {
    content: "";
    position: absolute;
    left: 0.6rem;
    top: 0;
    bottom: 0;
    width: 1px;
    background: linear-gradient(180deg,
      transparent 0%,
      var(--color-border-strong) 6%,
      var(--color-border-default) 92%,
      transparent 100%);
    pointer-events: none;
    z-index: 0;
  }

  /* Top fade — entries appear out of darkness as they scroll past the HUD. */
  .tape::after {
    content: "";
    position: absolute;
    left: 0;
    right: 0;
    top: 0;
    height: 28px;
    background: linear-gradient(180deg, var(--color-bg-page) 0%, transparent 100%);
    pointer-events: none;
    z-index: 2;
  }

  /* Symmetric bottom fade so old entries dissolve into the page floor
     before the roster strip. Sibling element (not pseudo) so it can sit
     after the row stream in DOM order without breaking sticky positioning. */
  .tape_end {
    position: relative;
    height: 32px;
    background: linear-gradient(180deg, transparent 0%, var(--color-bg-page) 100%);
    margin-top: -8px;
    pointer-events: none;
  }

  .row {
    display: grid;
    grid-template-columns: 1.75rem 10rem 5rem 9rem 7.5rem minmax(0, 1fr);
    gap: 1rem;
    padding: 0.625rem 0.75rem;
    border-bottom: 1px dashed var(--color-border-default);
    border-left: 2px solid var(--color-border-default);
    align-items: baseline;
    transition: background 0.18s ease, box-shadow 0.18s ease, border-left-color 0.18s ease;
  }

  .sigil {
    width: 22px;
    height: 22px;
    border-radius: 50%;
    border: 1px solid var(--color-accent-fg);
    background:
      radial-gradient(circle at 35% 30%, color-mix(in oklab, var(--text-bright) 18%, transparent), transparent 55%),
      var(--color-bg-surface);
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 11px;
    letter-spacing: 0;
    color: var(--color-accent-fg);
    text-transform: uppercase;
    box-shadow:
      inset 0 0 0 1px color-mix(in oklab, var(--text-bright) 6%, transparent),
      0 0 6px color-mix(in oklab, var(--color-accent-fg) 18%, transparent);
    align-self: center;
  }

  .sigil_warn  { color: var(--color-status-warn); border-color: var(--color-status-warn); box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--text-bright) 6%, transparent), 0 0 8px color-mix(in oklab, var(--color-accent-fg) 35%, transparent); }
  .sigil_error { color: var(--text-bright); border-color: var(--accent-blood); background: radial-gradient(circle at 35% 30%, color-mix(in oklab, var(--text-bright) 28%, transparent), transparent 55%), color-mix(in oklab, var(--accent-blood) 25%, var(--color-bg-page)); box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--text-bright) 8%, transparent), 0 0 10px color-mix(in oklab, var(--accent-blood) 45%, transparent); }

  .message_lead::first-letter {
    font-family: 'Cinzel', 'EB Garamond', serif;
    font-weight: 600;
    font-size: 2.4rem;
    line-height: 0.85;
    float: left;
    padding: 2px 8px 0 0;
    margin-top: 2px;
    background: linear-gradient(180deg, var(--text-bright) 0%, var(--color-accent-fg) 55%, var(--color-border-strong) 100%);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    text-shadow: 0 0 14px color-mix(in oklab, var(--color-accent-fg) 25%, transparent);
  }

  .row_debug { border-left-color: var(--color-status-idle); }
  .row_info  { border-left-color: var(--accent-mold); }

  .row:hover {
    background: linear-gradient(90deg, color-mix(in oklab, var(--color-accent-fg) 8%, transparent), transparent 70%);
    box-shadow: inset 1px 0 0 0 color-mix(in oklab, var(--color-accent-fg) 35%, transparent);
    border-left-color: var(--color-accent-fg);
  }

  .row_error {
    background: linear-gradient(90deg, color-mix(in oklab, var(--accent-blood) 8%, transparent) 0%, transparent 60%);
    border-left-color: var(--accent-blood);
  }

  .row_error:hover {
    background: linear-gradient(90deg, color-mix(in oklab, var(--accent-blood) 18%, transparent) 0%, transparent 65%);
    box-shadow: inset 1px 0 0 0 color-mix(in oklab, var(--accent-blood) 55%, transparent);
    border-left-color: var(--accent-viscera);
  }

  .row_warn {
    background: linear-gradient(90deg, color-mix(in oklab, var(--color-accent-fg) 6%, transparent) 0%, transparent 60%);
    border-left-color: var(--color-status-warn);
  }

  .row_warn:hover {
    background: linear-gradient(90deg, color-mix(in oklab, var(--color-accent-fg) 15%, transparent) 0%, transparent 65%);
    box-shadow: inset 1px 0 0 0 color-mix(in oklab, var(--color-accent-fg) 50%, transparent);
    border-left-color: var(--accent-ember);
  }

  .ts {
    display: flex;
    flex-direction: column;
    gap: 2px;
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 11px;
    color: var(--color-fg-muted);
  }

  .ts_rel {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }

  .level {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    font-weight: 500;
  }

  .level_debug { color: var(--color-fg-muted); }
  .level_info  { color: var(--color-fg-primary); }
  .level_warn  { color: var(--color-status-warn); }
  .level_error { color: var(--accent-blood); text-shadow: 0 0 12px color-mix(in oklab, var(--accent-blood) 32%, transparent); }

  .mod_col {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
  }

  .source_badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    padding: 3px 8px;
    border: 1px solid var(--color-border-default);
    border-radius: 999px;
    background: var(--color-bg-panel-alt);
    color: var(--color-fg-muted);
    width: fit-content;
    height: fit-content;
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-fg-muted);
    display: inline-block;
  }

  .dot_ok    { background: var(--color-status-ok); box-shadow: 0 0 6px var(--color-status-ok); }
  .dot_warn  { background: var(--color-status-warn); box-shadow: 0 0 6px var(--color-status-warn); }
  .dot_bad   { background: var(--accent-blood); box-shadow: 0 0 6px var(--accent-blood); }

  .message {
    color: var(--color-fg-primary);
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-size: 14px;
    line-height: 1.5;
    overflow-wrap: anywhere;
  }

  .details {
    color: var(--color-fg-muted);
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-size: 11px;
    line-height: 1.45;
    margin-top: 0.25rem;
    overflow-wrap: anywhere;
  }

  .empty {
    color: var(--color-fg-muted);
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    padding: 3rem 0 4rem;
    text-align: center;
    font-size: 1rem;
    line-height: 1.7;
  }

  .empty_attr {
    display: block;
    margin-top: 0.75rem;
    font-size: 11px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-style: normal;
    color: var(--color-fg-muted);
  }

  /* Wrapper kept for backward compatibility with the existing render
     code; the top fade now lives on .tape::after, so the old sticky
     pseudo is no longer needed. */
  .tape_fade {
    position: relative;
  }

  /* roster CSS → Roster 모듈로 이관 (shell 추출 Phase 2.A) */

  .signet {
    position: fixed;
    left: 1.75rem;
    bottom: 1.25rem;
    width: 56px;
    height: 56px;
    border-radius: 50%;
    background: radial-gradient(circle at 32% 28%, var(--accent-viscera) 0%, var(--accent-blood) 40%, color-mix(in oklab, var(--accent-blood) 50%, var(--color-bg-page)) 80%, color-mix(in oklab, var(--accent-blood) 20%, var(--color-bg-page)) 100%);
    border: 2px solid var(--color-accent-fg);
    box-shadow:
      inset 0 0 0 1px color-mix(in oklab, var(--text-bright) 18%, transparent),
      inset -6px -8px 14px color-mix(in oklab, var(--color-bg-page) 55%, transparent),
      inset 5px 4px 10px color-mix(in oklab, var(--text-bright) 15%, transparent),
      0 6px 14px color-mix(in oklab, var(--accent-blood) 35%, transparent),
      0 0 22px color-mix(in oklab, var(--color-accent-fg) 22%, transparent);
    transform: rotate(-14deg);
    z-index: 4;
    pointer-events: none;
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-weight: 600;
    color: var(--text-bright);
    font-size: 22px;
    letter-spacing: 0.04em;
    text-shadow: 0 1px 0 color-mix(in oklab, var(--color-bg-page) 60%, transparent), 0 0 8px color-mix(in oklab, var(--text-bright) 35%, transparent);
  }

  .signet::before {
    content: "";
    position: absolute;
    inset: 6px;
    border-radius: 50%;
    border: 1px dashed color-mix(in oklab, var(--text-bright) 22%, transparent);
    transform: rotate(14deg);
  }

  .signet::after {
    content: "masc · seal";
    position: absolute;
    top: calc(100% + 4px);
    left: 50%;
    transform: translateX(-50%) rotate(14deg);
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--color-border-strong);
    white-space: nowrap;
  }

  /* ─── left nav (220px, fixed) ───
     dashboard_v2 shell의 nav column을 fixed positioning으로 도입.
     scroll시 항상 보이고, root는 padding-left로 자리만 비워준다. */
  .nav {
    position: fixed;
    top: 0;
    left: 0;
    width: 220px;
    height: 100vh;
    padding: 18px 0 24px;
    background: linear-gradient(180deg, var(--color-bg-surface) 0%, var(--color-bg-page) 100%);
    border-right: 1px solid var(--color-border-default);
    box-shadow: inset -1px 0 0 color-mix(in oklab, var(--color-accent-fg) 8%, transparent);
    display: flex;
    flex-direction: column;
    overflow-y: auto;
    z-index: 5;
  }

  .nav_brand {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 4px 18px 18px;
    border-bottom: 1px solid var(--color-border-default);
    margin-bottom: 12px;
  }
  .nav_brand_rune {
    width: 18px;
    height: 18px;
    border: 1px solid var(--color-accent-fg);
    color: var(--color-accent-fg);
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 11px;
    transform: rotate(45deg);
  }
  .nav_brand_rune > span { transform: rotate(-45deg); display: block; }
  .nav_brand_word {
    font-family: 'Cinzel', serif;
    font-size: 12px;
    letter-spacing: 0.28em;
    color: var(--text-bright);
    text-transform: uppercase;
  }
  .nav_brand_blood { color: var(--accent-blood); }

  .nav_section {
    padding: 14px 18px 6px;
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .nav_section::after {
    content: "";
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--color-border-strong), transparent);
  }

  .nav_link {
    display: flex;
    align-items: center;
    gap: 11px;
    padding: 14px 18px;
    color: var(--color-fg-primary);
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.1em;
    text-decoration: none;
    border-left: 2px solid transparent;
    cursor: default;
    user-select: none;
  }
  .nav_link:hover {
    color: var(--color-accent-fg);
    background: color-mix(in oklab, var(--color-accent-fg) 5%, transparent);
  }
  .nav_link:focus-visible {
    outline: 2px solid var(--color-accent-fg);
    outline-offset: -2px;
  }
  .nav_link_active {
    color: var(--color-accent-fg);
    border-left-color: var(--color-accent-fg);
    background: linear-gradient(90deg, color-mix(in oklab, var(--color-accent-fg) 10%, transparent), transparent 70%);
  }
  .nav_link_glyph {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-border-strong);
    flex-shrink: 0;
  }
  .nav_link_active .nav_link_glyph {
    background: var(--color-accent-fg);
    box-shadow: 0 0 6px var(--color-accent-fg);
  }
  .nav_link_soon {
    color: var(--color-fg-muted);
    font-style: italic;
  }
  .nav_link_tail {
    margin-left: auto;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--accent-blood);
    font-variant-numeric: tabular-nums;
  }

  .nav_foot {
    margin-top: auto;
    padding: 14px 18px 0;
    border-top: 1px solid var(--color-border-default);
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.16em;
    color: var(--color-fg-muted);
    text-transform: uppercase;
  }
  .nav_foot_v { color: var(--color-fg-muted); }

  /* ─── theme chips ───
     클릭 시 location.hash 를 바꾸면 bin/main.ml 의 hashchange listener가
     <html data-theme="..."> 를 즉시 교체. URL이 SSOT이라 북마크/공유
     가능. active chip은 document.documentElement.dataset.theme 기준
     runtime JS가 칠하지 못해 정적으로는 강조 없음 — 추후 Var 연결 시
     active 스타일 추가. */
  .theme_chips {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin: 10px 18px 6px;
  }
  .theme_chip {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    padding: 7px 8px;
    background: var(--color-bg-surface);
    border: 1px solid var(--color-border-default);
    color: var(--color-fg-muted);
    cursor: pointer;
    user-select: none;
    border-radius: 1px;
  }
  .theme_chip:hover {
    border-color: var(--color-accent-fg-dim);
    color: var(--color-accent-fg);
  }
  .theme_chip:focus-visible { outline: 2px solid var(--color-accent-fg); outline-offset: 1px; }
  .theme_chip_active {
    border-color: var(--color-accent-fg);
    color: var(--color-accent-fg);
    background: linear-gradient(180deg, var(--color-bg-surface), var(--color-bg-page));
    box-shadow: 0 0 0 1px color-mix(in oklab, var(--color-accent-fg) 25%, transparent) inset;
  }

  /* active chip via declarative CSS only — listener가 <html data-theme>
     값을 세팅하면 cascading selector가 해당 chip에 active 스타일을 자동
     적용. Bonsai state 경유 없이도 동작한다. */
  html[data-theme="dark-fantasy"] .theme_chip[data-chip-theme="dark"],
  html[data-theme="cyberpunk"]    .theme_chip[data-chip-theme="cyber"],
  html[data-theme="terminal"]     .theme_chip[data-chip-theme="term"],
  html[data-theme="parchment"]    .theme_chip[data-chip-theme="parchment"],
  html[data-theme="paper"]        .theme_chip[data-chip-theme="paper"] {
    border-color: var(--color-accent-fg);
    color: var(--color-accent-fg);
    background: linear-gradient(180deg, var(--color-bg-surface), var(--color-bg-page));
    box-shadow: 0 0 0 1px color-mix(in oklab, var(--color-accent-fg) 25%, transparent) inset;
  }

  /* ─── right aside (340px, fixed) ───
     dashboard_v2 aside: focus card + watch evs stream.
     현재는 static skeleton. 추후 Var 연결. */
  .aside {
    position: fixed;
    top: 0;
    right: 0;
    width: 340px;
    height: 100vh;
    padding: 22px 18px 28px;
    background: linear-gradient(180deg, var(--color-bg-surface) 0%, var(--color-bg-page) 100%);
    border-left: 1px solid var(--color-border-default);
    box-shadow: inset 1px 0 0 color-mix(in oklab, var(--color-accent-fg) 6%, transparent);
    display: flex;
    flex-direction: column;
    gap: 22px;
    overflow-y: auto;
    z-index: 5;
  }

  .aside_h {
    font-family: 'Cinzel', serif;
    font-size: 11px;
    letter-spacing: 0.28em;
    color: var(--color-accent-fg);
    text-transform: uppercase;
    margin: 0 0 10px;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .aside_h::after {
    content: "";
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--color-border-strong), transparent);
  }
  .aside_h_tail {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
    margin-left: auto;
    font-variant-numeric: tabular-nums;
    letter-spacing: 0.04em;
    text-transform: none;
  }

  /* ─── focus card ─── */
  .focus {
    position: relative;
    padding: 16px 16px 14px;
    background: linear-gradient(180deg, var(--color-bg-panel-alt) 0%, var(--color-bg-surface) 100%);
    border: 1px solid var(--color-accent-fg-dim);
  }
  .focus::before {
    content: "";
    position: absolute;
    inset: 3px;
    border: 1px solid var(--color-border-strong);
    pointer-events: none;
  }
  .focus_who {
    position: relative;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .focus_portrait {
    width: 46px;
    height: 46px;
    border: 1px solid var(--color-accent-fg);
    background: linear-gradient(135deg, var(--color-bg-panel-alt), var(--color-bg-page));
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 18px;
    color: var(--color-accent-fg);
    flex-shrink: 0;
  }
  .focus_name_col { flex: 1; }
  .focus_name {
    font-family: 'Cinzel', serif;
    font-size: 16px;
    color: var(--color-accent-fg);
    letter-spacing: 0.16em;
    text-transform: uppercase;
  }
  .focus_role {
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    font-size: 11px;
    color: var(--color-fg-muted);
    margin-top: 2px;
  }

  .ctx_bar { margin-top: 14px; position: relative; }
  .ctx_lbl {
    display: flex;
    justify-content: space-between;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
    margin-bottom: 4px;
    font-variant-numeric: tabular-nums;
  }
  .ctx_lbl_v { color: var(--text-bright); }
  .vial {
    height: 8px;
    background: var(--color-bg-page);
    border: 1px solid var(--color-border-default);
    position: relative;
    overflow: hidden;
  }
  .vial_fill {
    display: block;
    height: 100%;
    width: 64%;
    background: linear-gradient(90deg, var(--color-accent-fg-dim), var(--color-accent-fg));
    box-shadow: 0 0 6px color-mix(in oklab, var(--color-accent-fg) 45%, transparent);
  }
  .vial::after {
    content: "";
    position: absolute;
    inset: 0;
    background-image: repeating-linear-gradient(90deg, transparent 0 19px, color-mix(in oklab, var(--color-bg-page) 50%, transparent) 19px 20px);
    pointer-events: none;
  }

  .focus_stats {
    position: relative;
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 8px 14px;
    margin-top: 14px;
  }
  .focus_stat_l {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.18em;
    color: var(--color-fg-muted);
    text-transform: uppercase;
  }
  .focus_stat_v {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 12px;
    color: var(--text-bright);
    margin-top: 2px;
    font-variant-numeric: tabular-nums;
  }

  /* ─── watch evs stream ─── */
  .evs { display: flex; flex-direction: column; }
  .evrow {
    display: grid;
    grid-template-columns: 52px 12px 1fr;
    gap: 10px;
    padding: 8px 0;
    border-bottom: 1px dashed var(--color-border-default);
    align-items: baseline;
  }
  .evrow:last-child { border-bottom: 0; }
  .evrow_t {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
    font-variant-numeric: tabular-nums;
  }
  .evrow_mk {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    align-self: center;
    justify-self: center;
    background: var(--color-accent-fg-dim);
  }
  .evrow_ok  .evrow_mk { background: var(--color-status-ok); box-shadow: 0 0 6px var(--color-status-ok); }
  .evrow_warn .evrow_mk { background: var(--color-accent-fg); box-shadow: 0 0 6px var(--color-accent-fg); }
  .evrow_bad  .evrow_mk { background: var(--accent-blood); box-shadow: 0 0 6px var(--accent-blood); }
  .evrow_b {
    font-family: 'EB Garamond', Georgia, serif;
    font-size: 12px;
    color: var(--color-fg-primary);
    line-height: 1.45;
  }
  .evrow_b_em { color: var(--text-bright); font-style: italic; }
  .evrow_b_code {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-accent-fg);
    background: color-mix(in oklab, var(--color-accent-fg) 8%, transparent);
    padding: 0 5px;
    border: 1px solid var(--color-border-default);
  }
  .evrow_bad .evrow_b_code {
    color: var(--accent-blood);
    background: color-mix(in oklab, var(--accent-blood) 8%, transparent);
  }

  /* ─── page-head (hero) ───
     dashboard_v2 "The Manor Under Storm" 톤의 hero 타이틀.
     moonrise 앞, HUD 뒤에 배치되어 "무엇을 보고 있는가"의 나레이티브
     선언이 된다. action buttons는 아직 기능 없고 cursor: default. */
  .page_head {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 24px;
    margin: 8px 0 4px;
  }
  .page_head_lead {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .page_tag {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .page_tag::after {
    content: "";
    flex: 0 0 40px;
    height: 1px;
    background: var(--color-border-strong);
  }
  .page_h1 {
    font-family: 'Cinzel', 'Noto Sans KR', serif;
    font-size: 36px;
    letter-spacing: 0.16em;
    color: var(--text-bright);
    text-transform: uppercase;
    margin: 6px 0 0;
    line-height: 1.1;
  }
  .page_h1_blood {
    color: var(--accent-blood);
    text-shadow: 0 0 18px color-mix(in oklab, var(--accent-blood) 32%, transparent);
  }
  .page_h1_brass {
    color: var(--color-accent-fg);
    text-shadow: 0 0 18px color-mix(in oklab, var(--color-accent-fg) 32%, transparent);
  }
  .page_h1_bright {
    color: var(--text-bright);
    text-shadow: 0 0 18px color-mix(in oklab, var(--color-fg-primary) 24%, transparent);
  }
  .page_sub {
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-style: italic;
    color: var(--color-fg-primary);
    margin-top: 6px;
    font-size: 14px;
    max-width: 540px;
    line-height: 1.55;
  }
  .page_actions {
    display: flex;
    gap: 8px;
    flex-shrink: 0;
  }
  .pbtn {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.24em;
    text-transform: uppercase;
    padding: 7px 12px;
    background: linear-gradient(180deg, var(--color-bg-panel-alt) 0%, var(--color-bg-surface) 100%);
    border: 1px solid var(--color-accent-fg-dim);
    color: var(--color-fg-primary);
    cursor: default;
    user-select: none;
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .pbtn:hover {
    border-color: var(--color-accent-fg);
    color: var(--color-accent-fg);
  }
  .pbtn:focus-visible { outline: 2px solid var(--color-accent-fg); outline-offset: -2px; }
  .pbtn_primary {
    background: linear-gradient(180deg, color-mix(in oklab, var(--color-accent-fg) 20%, var(--color-bg-surface)) 0%, color-mix(in oklab, var(--color-accent-fg) 10%, var(--color-bg-page)) 100%);
    border-color: var(--color-accent-fg);
    color: var(--color-accent-fg);
  }
  .pbtn_primary:hover {
    background: color-mix(in oklab, var(--color-accent-fg) 12%, transparent);
    color: var(--text-bright);
  }
  .pbtn_glyph {
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: currentColor;
  }

  /* ─── .sec section marker ───
     dashboard_v2 전역 section title 패턴 — 작은 lozenge 글리프 + Cinzel
     제목 + italic sub + hairline gradient + 우측 mono meta. page-head
     아래 각 섹션(tape, keepers, context pressure 등)에 등장해 "지금
     무엇을 보고 있는가"를 한 줄로 알린다. */
  .sec {
    display: flex;
    align-items: baseline;
    gap: 14px;
    margin: 8px 0 2px;
  }
  .sec_glyph {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-accent-fg);
    box-shadow: 0 0 6px color-mix(in oklab, var(--color-accent-fg) 35%, transparent);
    align-self: center;
  }
  .sec_h {
    font-family: 'Cinzel', serif;
    font-size: 12px;
    letter-spacing: 0.26em;
    color: var(--color-accent-fg);
    text-transform: uppercase;
    margin: 0;
  }
  .sec_sub {
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    color: var(--color-fg-muted);
    font-size: 12px;
  }
  .sec_hr {
    flex: 1;
    height: 1px;
    background: linear-gradient(
      90deg,
      var(--color-border-strong) 0%,
      var(--color-border-default) 60%,
      transparent 100%
    );
  }
  .sec_r {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
    font-variant-numeric: tabular-nums;
    letter-spacing: 0.04em;
  }
  .sec_r_v { color: var(--text-bright); }

  /* swimlane CSS → Swim 모듈로 이관 (shell 추출 Phase 2.A) */


  /* flame mini CSS → Flame 모듈로 이동 (shell 추출 Phase 2.A) */

  /* ─── tombstrip — 12-state keeper FSM tiles ───
     design_v2: Offline → Running → {Failing | Overflowed | Compacting |
     HandingOff | Draining} → Paused / Stopped / Crashed → Restarting → Dead.
     기본은 dim outline. active=brass glow, danger=blood(Crashed),
     dead=strikethrough with blood decoration. */
  .tombstrip {
    display: flex;
    flex-wrap: wrap;
    gap: 3px;
    padding: 6px 14px 12px;
  }
  .tomb {
    padding: 5px 8px;
    font-family: 'Cinzel', 'Cormorant SC', serif;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    border: 1px solid var(--color-border-default);
    background: var(--color-bg-panel-alt);
  }
  .tomb_active {
    color: var(--color-accent-fg);
    border-color: var(--color-accent-fg);
    background: linear-gradient(180deg, var(--color-bg-panel-alt), var(--color-bg-surface));
  }
  .tomb_danger {
    color: var(--accent-blood);
    border-color: color-mix(in oklab, var(--accent-blood) 50%, transparent);
  }
  .tomb_dead {
    color: var(--color-fg-muted);
    text-decoration: line-through;
    text-decoration-color: var(--accent-blood);
  }

  @media (max-width: 760px) {
    .row {
      grid-template-columns: 1.75rem minmax(0, 1fr);
      grid-template-rows: auto auto;
      gap: 4px 8px;
      padding: 0.5rem 0.5rem;
    }
    .ts, .level, .mod_col, .source_badge { font-size: 10px; }
    .message { font-size: 13px; }
    .filter_bar { flex-wrap: wrap; gap: 6px; }
  }

  @media (prefers-reduced-motion: reduce) {
    .pulse { animation: none; }
    *, *::before, *::after {
      transition-duration: 0.01ms !important;
    }
  }

  @media (prefers-contrast: more) {
    .row { border-bottom-width: 1px; border-bottom-color: var(--color-fg-muted); }
    .level, .source_badge { border-width: 2px; }
    .level_error { border-color: var(--accent-blood); }
    .level_warn  { border-color: var(--color-status-warn); }
    .filter_bar { border-width: 2px; border-color: var(--text-bright); }
    .search_input { border-width: 2px; border-color: var(--text-bright); }
    .chip, .btn_ghost { border-width: 2px; border-color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .level_error { color: MarkText; border-color: MarkText; text-shadow: none; }
    .level_warn { color: Mark; border-color: Mark; }
    .level_debug { color: GrayText; }
    .source_badge { border-color: GrayText; }
  }
|}]

let level_class level =
  match level with
  | "DEBUG" -> Style.level_debug
  | "WARN" -> Style.level_warn
  | "ERROR" -> Style.level_error
  | _ -> Style.level_info
;;

let row_tint level =
  match level with
  | "WARN" -> Some Style.row_warn
  | "ERROR" -> Some Style.row_error
  | "DEBUG" -> Some Style.row_debug
  | _ -> Some Style.row_info
;;

let dot_class level =
  match level with
  | "WARN" -> Style.dot_warn
  | "ERROR" -> Style.dot_bad
  | _ -> Style.dot_ok
;;

let sigil_class level =
  match level with
  | "WARN" -> Some Style.sigil_warn
  | "ERROR" -> Some Style.sigil_error
  | _ -> None
;;

let sigil_char source =
  match String.to_list source with
  | c :: _ -> String.of_char (Char.uppercase c)
  | [] -> "·"
;;

let view_entry ~is_first (e : Logs_types.entry) =
  let row_attrs =
    match row_tint e.normalized_level with
    | None -> [ Style.row; Attr.role "listitem"; Attr.create "aria-label" (e.normalized_level ^ " " ^ e.module_ ^ ": " ^ e.message) ]
    | Some tint -> [ Style.row; tint; Attr.role "listitem"; Attr.create "aria-label" (e.normalized_level ^ " " ^ e.module_ ^ ": " ^ e.message) ]
  in
  let sigil_attrs =
    match sigil_class e.normalized_level with
    | None -> [ Style.sigil; Attr.create "aria-hidden" "true" ]
    | Some c -> [ Style.sigil; c; Attr.create "aria-hidden" "true" ]
  in
  let message_attrs =
    if is_first then [ Style.message; Style.message_lead ] else [ Style.message ]
  in
  let message_block =
    match e.details with
    | None -> [ Node.div ~attrs:message_attrs [ Node.text e.message ] ]
    | Some details_raw ->
      [ Node.div ~attrs:message_attrs [ Node.text e.message ]
      ; Node.div ~attrs:[ Style.details ] [ Node.text details_raw ]
      ]
  in
  Node.div
    ~attrs:row_attrs
    [ Node.div ~attrs:sigil_attrs [ Node.text (sigil_char e.module_) ]
    ; Node.div
        ~attrs:[ Style.ts ]
        [ Node.span [ Node.text e.ts ]
        ; Node.span ~attrs:[ Style.ts_rel ] [ Node.text "just now" ]
        ]
    ; Node.div
        ~attrs:[ Style.level; level_class e.normalized_level ]
        [ Node.text e.normalized_level ]
    ; Node.div ~attrs:[ Style.mod_col ] [ Node.text e.module_ ]
    ; Node.div
        ~attrs:[ Style.source_badge ]
        [ Node.span ~attrs:[ Style.dot; dot_class e.normalized_level; Attr.create "aria-hidden" "true" ] []
        ; Node.text e.source
        ]
    ; Node.div message_block
    ]
;;

(* hud_cell → Hud.cell (shell 추출 Phase 2.A) *)

(* Heartbeat strip — 60 bars representing event density across recent cycles.
   Static shape for Phase 1; Phase 1c wires real per-minute buckets. *)
let heartbeat_bars : (int * [ `Info | `Warn | `Error | `Idle ]) list =
  [ 18, `Info; 22, `Info; 14, `Info; 8, `Idle; 24, `Info; 31, `Info; 28, `Info
  ; 16, `Info; 12, `Idle; 34, `Warn; 40, `Warn; 29, `Info; 22, `Info; 18, `Info
  ; 14, `Info; 6, `Idle; 9, `Idle; 22, `Info; 27, `Info; 33, `Info; 41, `Warn
  ; 52, `Warn; 38, `Warn; 24, `Info; 19, `Info; 12, `Idle; 27, `Info; 31, `Info
  ; 36, `Info; 44, `Warn; 58, `Warn; 72, `Error; 61, `Error; 49, `Warn
  ; 38, `Warn; 28, `Info; 22, `Info; 18, `Info; 14, `Idle; 11, `Idle
  ; 24, `Info; 31, `Info; 28, `Info; 22, `Info; 17, `Info; 12, `Idle
  ; 26, `Info; 34, `Info; 41, `Warn; 47, `Warn; 35, `Warn; 28, `Info
  ; 22, `Info; 19, `Info; 16, `Info; 14, `Info; 28, `Info; 44, `Warn
  ; 58, `Error; 82, `Error
  ]
;;

let heartbeat_bars_of_entries (entries : Logs_types.entry list)
  : (int * [ `Info | `Warn | `Error | `Idle ]) list
  =
  let level_of (e : Logs_types.entry) =
    match e.normalized_level with
    | "ERROR" -> `Error
    | "WARN" -> `Warn
    | "DEBUG" -> `Idle
    | _ -> `Info
  in
  let height_of (e : Logs_types.entry) =
    Int.clamp_exn (String.length e.message / 2) ~min:6 ~max:72
  in
  let take_last n xs =
    let total = List.length xs in
    if total <= n then xs else List.drop xs (total - n)
  in
  let selected = take_last 60 entries in
  let bars = List.map selected ~f:(fun e -> height_of e, level_of e) in
  let n = List.length bars in
  if n >= 60
  then bars
  else List.append (List.init (60 - n) ~f:(fun _ -> 6, `Idle)) bars
;;

let view_heartbeat ?(entries : Logs_types.entry list = []) () =
  let bars =
    match entries with
    | [] -> heartbeat_bars
    | _ -> heartbeat_bars_of_entries entries
  in
  let active = List.count ~f:(fun (_, l) -> l <> `Idle) bars in
  let max_height = List.fold bars ~init:0 ~f:(fun acc (h, _) -> Int.max acc h) in
  let aria_desc =
    Printf.sprintf
      "Cycle pulse: %d of 60 ticks active, peak density %d"
      active max_height
  in
  let bar i (height, level) =
    let cls =
      match level with
      | `Warn -> Some Style.heartbeat_bar_warn
      | `Error -> Some Style.heartbeat_bar_error
      | `Idle -> Some Style.heartbeat_bar_idle
      | `Info -> None
    in
    let level_name =
      match level with
      | `Warn -> "WARN"
      | `Error -> "ERROR"
      | `Idle -> "idle"
      | `Info -> "info"
    in
    let total = List.length bars in
    let t_ago = total - 1 - i in
    let tip =
      Printf.sprintf "t-%d · %s · ticks %d" t_ago level_name height
    in
    let base_attrs =
      match cls with
      | None -> [ Style.heartbeat_bar ]
      | Some c -> [ Style.heartbeat_bar; c ]
    in
    let h = Int.max 2 height in
    let style =
      Attr.style (Css_gen.create ~field:"height" ~value:(Printf.sprintf "%dpx" h))
    in
    let title_attr = Attr.create "title" tip in
    Node.div ~attrs:(Attr.create "aria-hidden" "true" :: title_attr :: style :: base_attrs) []
  in
  Node.div
    ~attrs:[ Style.heartbeat; Attr.role "img"; Attr.create "aria-label" aria_desc ]
    [ Node.div
        ~attrs:[ Style.heartbeat_head ]
        [ Node.span
            ~attrs:[ Style.heartbeat_eyebrow ]
            [ Node.text "cycle pulse · last 60 ticks" ]
        ; Node.span
            ~attrs:[ Style.heartbeat_scale ]
            [ Node.text "t-60 ·—· t0" ]
        ]
    ; Node.div
        ~attrs:[ Style.heartbeat_track ]
        (List.mapi ~f:bar bars)
    ]
;;

(* Keeper roster — sticky bottom strip. Four fixed keeper slots as a
   visual placeholder; Phase 1c wires this to a keeper_status Var so the
   state dot, last-heard timestamp, and presence reflect live telemetry. *)
(* roster → Roster 모듈로 이관 (shell 추출 Phase 2.A) *)



type tomb_level = [ `Base | `Active | `Danger | `Dead ]

let tomb_class = function
  | `Base -> Style.tomb
  | `Active -> Style.tomb_active
  | `Danger -> Style.tomb_danger
  | `Dead -> Style.tomb_dead
;;

(* 12-state keeper FSM per design_v2. active/danger/dead are mocked until
   keeper phase is wired through Keepers_types. *)
let keeper_fsm_states : (string * tomb_level) list =
  [ "Offline",    `Base
  ; "Running",    `Active
  ; "Failing",    `Base
  ; "Overflowed", `Base
  ; "Compacting", `Active
  ; "HandingOff", `Base
  ; "Draining",   `Base
  ; "Paused",     `Active
  ; "Stopped",    `Base
  ; "Crashed",    `Danger
  ; "Restarting", `Base
  ; "Dead",       `Dead
  ]
;;

let view_tombstrip ?(states = keeper_fsm_states) () =
  let tile (label, level) =
    Node.span
      ~attrs:[ Style.tomb; tomb_class level ]
      [ Node.text label ]
  in
  Node.div
    ~attrs:[ Style.tombstrip; Attr.create "aria-label" "Keeper FSM states" ]
    (List.map states ~f:tile)
;;


(* hhmmss_of_iso → Hud.hhmmss_of_iso (shell 추출 Phase 2.A) *)

let view_hud
      ?(keepers : Keepers_types.response = Keepers_types.fixture)
      (response : Logs_types.response) =
  let live_n, warn_n, dead_n =
    List.fold keepers.keepers ~init:(0, 0, 0)
      ~f:(fun (l, w, d) (k : Keepers_types.keeper) ->
        match k.status with
        | Live -> (l + 1, w, d)
        | Warn -> (l, w + 1, d)
        | Dead -> (l, w, d + 1))
  in
  let fleet_v, (fleet_cls : Hud.v_class) =
    if live_n = 0 && warn_n = 0 && dead_n = 0
    then "—", `Neutral
    else if dead_n > 0
    then Printf.sprintf "%dl %dw %dd" live_n warn_n dead_n, `Bad
    else if warn_n > 0
    then Printf.sprintf "%dl %dw" live_n warn_n, `Warn
    else Printf.sprintf "%dl" live_n, `Ok
  in
  let sync_v =
    match keepers.generated_at with
    | "" -> "—"
    | ts -> Printf.sprintf "%s UTC" (Hud.hhmmss_of_iso ts)
  in
  Hud.strip ~label:"Log controls"
    [ Hud.cell ~k:"Source" ~v:"Log.Ring" ()
    ; Hud.cell ~k:"Total" ~v:(Printf.sprintf "%d" response.total) ()
    ; Hud.cell ~k:"Level" ~v:"INFO+" ()
    ; Hud.cell ~v_class:`Ok ~k:"Refresh" ~v:"poll · 3s" ()
    ; Hud.cell ~k:"Limit" ~v:"200" ()
    ; Hud.cell ~v_class:`Ok ~k:"Link" ~v:"fetch · ok" ()
    ; Hud.cell ~v_class:fleet_cls ~k:"Fleet" ~v:fleet_v ()
    ; Hud.cell ~k:"Synced" ~v:sync_v ()
    ]
;;

(** Roman numeral for cycle counters. Only small integers (≤ 39) are
    expected for dashboard display; outside that range we fall back to the
    decimal form so very large cycles still render. *)
let roman_of_int (n : int) : string =
  if n <= 0 || n > 39
  then Printf.sprintf "%d" n
  else
    let pairs =
      [ 10, "x"; 9, "ix"; 5, "v"; 4, "iv"; 1, "i" ]
    in
    let buf = Buffer.create 8 in
    let rec go n = function
      | [] -> ()
      | (v, s) :: rest ->
        if n >= v
        then (Buffer.add_string buf s; go (n - v) ((v, s) :: rest))
        else go n rest
    in
    go n pairs;
    Buffer.contents buf
;;

(** Count keepers by status. *)
type fleet_tally = { live : int; warn : int; dead : int }

let tally_fleet (ks : Keepers_types.keeper list) : fleet_tally =
  List.fold ks ~init:{ live = 0; warn = 0; dead = 0 }
    ~f:(fun acc (k : Keepers_types.keeper) ->
      match k.status with
      | Live -> { acc with live = acc.live + 1 }
      | Warn -> { acc with warn = acc.warn + 1 }
      | Dead -> { acc with dead = acc.dead + 1 })
;;

(** Focus keeper — first entry of the live response, or [None] when empty
    (triggers the legacy static fallback inside [focus_card_of]). *)
let focus_keeper_of (k : Keepers_types.response) : Keepers_types.keeper option =
  match k.keepers with
  | [] -> None
  | head :: _ -> Some head
;;

(** Display name — capitalize first character of the registry nickname. *)
let display_name (s : string) : string =
  if String.length s = 0
  then s
  else
    let first = Char.to_string (Char.uppercase s.[0]) in
    let rest = String.sub s ~pos:1 ~len:(String.length s - 1) in
    first ^ rest
;;

let render_response
      ?(keepers : Keepers_types.response = Keepers_types.fixture)
      (response : Logs_types.response)
    : Node.t =
  let runtime_name =
    match keepers.room with
    | Some name when String.length name > 0 -> name
    | _ -> "local"
  in
  let runtime_badge_text = Printf.sprintf "runtime=%s" runtime_name in
  let snapshot_badge_text =
    match keepers.generated_at with
    | "" -> "snapshot · local"
    | ts -> Printf.sprintf "snapshot · %s UTC" (Hud.hhmmss_of_iso ts)
  in
  let tape =
    match response.entries with
    | [] ->
      Node.div
        ~attrs:[ Style.empty; Attr.role "status"; Attr.create "aria-label" "No log entries" ]
        [ Node.span ~attrs:[ Attr.create "lang" "ko" ] [ Node.text "저택은 조용하다. 아무도 아직 말하지 않았다." ]
        ; Node.span
            ~attrs:[ Style.empty_attr ]
            [ Node.text "log ring · empty" ]
        ]
    | entries ->
      let rendered =
        List.mapi entries ~f:(fun i e -> view_entry ~is_first:(i = 0) e)
      in
      Node.div
        ~attrs:[ Style.tape_fade ]
        [ Node.div ~attrs:[ Style.tape; Attr.role "log"; Attr.create "aria-live" "polite"; Attr.create "aria-label" "Log entries" ] rendered
        ; Node.div ~attrs:[ Style.tape_end ] []
        ]
  in
  let brand_row =
    Node.div
      ~attrs:[ Style.brand ]
      [ Node.div
          ~attrs:[ Style.rune ]
          [ Node.span ~attrs:[ Style.rune_inner ] [ Node.text "M" ] ]
      ; Node.span ~attrs:[ Style.wordmark ] [ Node.text "masc" ]
      ; Node.div
          ~attrs:[ Style.crumbs ]
          (let head =
             [ Node.span [ Node.text "runtime" ]
             ; Node.span ~attrs:[ Style.crumbs_sep ] [ Node.text "›" ]
             ]
           in
           let runtime_seg =
             [ Node.span ~attrs:[ Style.crumbs_room ] [ Node.text runtime_name ]
             ; Node.span ~attrs:[ Style.crumbs_sep ] [ Node.text "›" ]
             ]
           in
           let tail =
             [ Node.span ~attrs:[ Style.crumbs_cur ] [ Node.span ~attrs:[ Attr.create "lang" "ko" ] [ Node.text "저널" ] ]
             ]
           in
           head @ runtime_seg @ tail)
      ; Node.div
          ~attrs:[ Style.pulse_slot ]
          [ Node.span ~attrs:[ Style.pulse; Attr.create "aria-hidden" "true" ] []
          ; Node.span ~attrs:[ Style.pulse_label ] [ Node.text "live · 3s" ]
          ]
      ]
  in
  let toolbar =
    Node.div
      ~attrs:[ Style.toolbar; Attr.role "group"; Attr.create "aria-label" "Log controls" ]
      [ (let filter_chip ~level ~label =
           let fire () =
             Effect.of_sync_fun
               (fun () ->
                 let root = Dom_html.document##.documentElement in
                 root##setAttribute
                   (Js.string "data-log-level")
                   (Js.string level);
                 let update lvl =
                   Js.Opt.iter
                     (root##querySelector
                        (Js.string ("[data-filter-level=\"" ^ lvl ^ "\"]")))
                     (fun el ->
                        el##setAttribute
                          (Js.string "aria-pressed")
                          (Js.string (if lvl = level then "true" else "false")))
                 in
                 update "debug"; update "info"; update "warn"; update "error")
               ()
           in
           Node.span
             ~attrs:
               [ Style.chip
               ; Attr.create "data-filter-level" level
               ; Attr.role "button"
               ; Attr.create "aria-pressed" (if level = "info" then "true" else "false")
               ; Attr.tabindex 0
               ; Attr.on_click (fun _ev -> fire ())
               ; Attr.on_key_down (fun ev ->
                   let open Virtual_dom.Vdom.Event.Keyboard in
                   if Key.equal ev.key Key.Enter
                      || Key.equal ev.key (Key.of_string " ")
                   then fire ()
                   else Effect.of_sync_fun (fun () -> ()) ())
               ]
             [ Node.text label ]
         in
         Node.div
           ~attrs:[ Style.chip_group; Attr.role "group"; Attr.create "aria-label" "Log level filter" ]
           [ filter_chip ~level:"debug" ~label:"debug+"
           ; filter_chip ~level:"info" ~label:"info+"
           ; filter_chip ~level:"warn" ~label:"warn+"
           ; filter_chip ~level:"error" ~label:"error"
           ])
      ; Node.div
          ~attrs:[ Style.input_shell ]
          [ Node.span ~attrs:[ Style.input_shell_label ] [ Node.text "module" ]
          ; Node.span ~attrs:[ Style.input_shell_value ] [ Node.text "—" ]
          ]
      ; Node.div
          ~attrs:[ Style.input_shell ]
          [ Node.span ~attrs:[ Style.input_shell_label ] [ Node.text "limit" ]
          ; Node.span ~attrs:[ Style.input_shell_value ] [ Node.text "200" ]
          ]
      ; Node.div ~attrs:[ Style.toolbar_spacer ] []
      ; Node.button ~attrs:[ Style.btn_ghost; Attr.create "type" "button" ] [ Node.text "refresh" ]
      ]
  in
  let tally = tally_fleet keepers.keepers in
  let moon_lead_text =
    match tally with
    | { live = 0; warn = 0; dead = 0 } -> "the watch is on"
    | { dead; _ } when dead > 0 -> "the watch stands a casualty"
    | { warn; _ } when warn > 0 -> "the watch holds uneasy"
    | _ -> "the watch is on"
  in
  let fleet_mono_text =
    match tally with
    | { live = 0; warn = 0; dead = 0 } -> "fleet · —"
    | t ->
      Printf.sprintf "fleet · %dl / %dw / %dd" t.live t.warn t.dead
  in
  let moonrise =
    Node.div
      ~attrs:[ Style.moonrise; Attr.role "status"; Attr.create "aria-label" "Watch status" ]
      [ Node.span ~attrs:[ Style.moon_glyph; Attr.create "aria-hidden" "true" ] []
      ; Node.span ~attrs:[ Style.moon_lead ] [ Node.text moon_lead_text ]
      ; Node.span ~attrs:[ Style.moon_sep ] [ Node.text "·" ]
      ; Node.span [ Node.text "lit by a half moon" ]
      ; Node.span ~attrs:[ Style.moon_sep ] [ Node.text "·" ]
      ; Node.span
          ~attrs:
            [ Style.moon_mono
            ; Attr.create "data-moon-clock" ""
            ]
          [ Node.text "—:— local" ]
      ; Node.span ~attrs:[ Style.moon_sep ] [ Node.text "·" ]
      ; Node.span
          ~attrs:[ Style.moon_mono ]
          [ Node.text fleet_mono_text ]
      ; Node.span ~attrs:[ Style.moon_sep ] [ Node.text "·" ]
      ; Node.span
          ~attrs:[ Style.moon_mono ]
          [ Node.text runtime_badge_text ]
      ; Node.span ~attrs:[ Style.moon_tail ] [ Node.text snapshot_badge_text ]
      ]
  in
  let nav_section label =
    Node.div ~attrs:[ Style.nav_section ] [ Node.text label ]
  in
  let current_route =
    let path =
      Brr.Uri.path (Brr.Window.location Brr.G.window) |> Jstr.to_string
    in
    Route.of_path path
  in
  let nav_link ?tail (route : Route.t) =
    let active = Route.equal route current_route in
    let base = [ Style.nav_link ] in
    let base = if active then Style.nav_link_active :: base else base in
    let base = if active then Attr.create "aria-current" "page" :: base else base in
    let base =
      if not (Route.is_implemented route)
      then Style.nav_link_soon :: Attr.create "aria-disabled" "true" :: base
      else base
    in
    let tail_node =
      match tail with
      | None -> []
      | Some t -> [ Node.span ~attrs:[ Style.nav_link_tail ] [ Node.text t ] ]
    in
    Node.a
      ~attrs:(Attr.href (Route.path route) :: base)
      ([ Node.span ~attrs:[ Style.nav_link_glyph; Attr.create "aria-hidden" "true" ] []
       ; Node.text (Route.label route)
       ]
       @ tail_node)
  in
  let nav =
    Node.div
      ~attrs:[ Style.nav ]
      [ Node.div
          ~attrs:[ Style.nav_brand ]
          [ Node.div
              ~attrs:[ Style.nav_brand_rune ]
              [ Node.span [ Node.text "M" ] ]
          ; Node.span
              ~attrs:[ Style.nav_brand_word ]
              [ Node.text "ma"
              ; Node.span
                  ~attrs:[ Style.nav_brand_blood ]
                  [ Node.text "s" ]
              ; Node.text "c"
              ]
          ]
      ; nav_section "watch"
      ; nav_link Overview
      ; nav_link Logs
      ; nav_link Goals
      ; nav_section "runtime"
      ; (let tail =
           match keepers.keepers with
           | [] -> "—"
           | ks -> Printf.sprintf "%02d" (List.length ks)
         in
         nav_link Keepers ~tail)
      ; nav_link Observatory
      ; nav_link Intervene
      ; nav_section "lab"
      ; nav_link Tools
      ; nav_link Sessions
      ; nav_link Social_board
      ; nav_section "crypt"
      ; (let tail =
           match keepers.keepers with
           | [] -> "—"
           | ks ->
             let dead_n =
               List.count ks ~f:(fun (k : Keepers_types.keeper) ->
                 match k.status with
                 | Dead -> true
                 | _ -> false)
             in
             Printf.sprintf "%02d" dead_n
         in
         nav_link Dead_keepers ~tail)
      ; nav_link Archive_runs
      ; (let chip name label =
           let fire () =
             Effect.of_sync_fun
               (fun () ->
                 Dom_html.window##.location##.hash
                   := Js.string ("#" ^ name);
                 let root = Dom_html.document##.documentElement in
                 let update n =
                   Js.Opt.iter
                     (root##querySelector
                        (Js.string ("[data-chip-theme=\"" ^ n ^ "\"]")))
                     (fun el ->
                        el##setAttribute
                          (Js.string "aria-pressed")
                          (Js.string (if n = name then "true" else "false")))
                 in
                 update "dark"; update "cyber"; update "term";
                 update "parchment"; update "paper")
               ()
           in
           Node.div
             ~attrs:
               [ Style.theme_chip
               ; Attr.create "data-chip-theme" name
               ; Attr.role "button"
               ; Attr.create "aria-pressed" (if name = "dark" then "true" else "false")
               ; Attr.tabindex 0
               ; Attr.on_click (fun _ -> fire ())
               ; Attr.on_key_down (fun ev ->
                   let open Virtual_dom.Vdom.Event.Keyboard in
                   if Key.equal ev.key Key.Enter
                      || Key.equal ev.key (Key.of_string " ")
                   then fire ()
                   else Effect.of_sync_fun (fun () -> ()) ())
               ]
             [ Node.text label ]
         in
         Node.div
           ~attrs:[ Style.theme_chips; Attr.role "group"; Attr.create "aria-label" "Theme selector" ]
           [ chip "dark" "dark"
           ; chip "cyber" "cyber"
           ; chip "term" "term"
           ; chip "parchment" "parch"
           ; chip "paper" "paper"
           ])
      ; Node.div
          ~attrs:[ Style.nav_foot ]
          [ Node.text "preview · /b/ · "
          ; Node.span
              ~attrs:[ Style.nav_foot_v ]
              [ Node.text "runtime shell" ]
          ]
      ]
  in
  let aside_h ?tail label =
    let tail_node =
      match tail with
      | None -> []
      | Some t ->
        [ Node.span ~attrs:[ Style.aside_h_tail ] [ Node.text t ] ]
    in
    Node.div ~attrs:[ Style.aside_h ] (Node.text label :: tail_node)
  in
  let focus_stat l v =
    Node.div
      ~attrs:[]
      [ Node.div ~attrs:[ Style.focus_stat_l ] [ Node.text l ]
      ; Node.div ~attrs:[ Style.focus_stat_v ] [ Node.text v ]
      ]
  in
  let focus_k = focus_keeper_of keepers in
  let focus_name, focus_portrait, focus_role, focus_ctx_pct,
      focus_turn, focus_mem, focus_latency =
    match focus_k with
    | None ->
      ("Luna", "L", "dungeon master · alchemist", 64,
       "47 / 60", "128k", "812ms")
    | Some (k : Keepers_types.keeper) ->
      let portrait =
        if String.length k.name = 0
        then "·"
        else Char.to_string (Char.uppercase k.name.[0])
      in
      let role =
        match k.last_tool with
        | Some t -> Printf.sprintf "%s · %s" k.stat t
        | None -> k.stat
      in
      (display_name k.name, portrait, role, k.ctx_pct,
       Printf.sprintf "%d / %d" k.turn k.turn_cap,
       Printf.sprintf "%dk" k.mem_kb,
       Printf.sprintf "%dms" k.latency_ms)
  in
  let vial_style =
    Attr.create "style" (Printf.sprintf "width:%d%%" focus_ctx_pct)
  in
  let focus_card =
    Node.div
      ~attrs:[ Style.focus ]
      [ Node.div
          ~attrs:[ Style.focus_who ]
          [ Node.div ~attrs:[ Style.focus_portrait ] [ Node.text focus_portrait ]
          ; Node.div
              ~attrs:[ Style.focus_name_col ]
              [ Node.div ~attrs:[ Style.focus_name ] [ Node.text focus_name ]
              ; Node.div
                  ~attrs:[ Style.focus_role ]
                  [ Node.text focus_role ]
              ]
          ]
      ; Node.div
          ~attrs:[ Style.ctx_bar ]
          [ Node.div
              ~attrs:[ Style.ctx_lbl ]
              [ Node.span [ Node.text "context" ]
              ; Node.span
                  ~attrs:[ Style.ctx_lbl_v ]
                  [ Node.text (Printf.sprintf "%d%%" focus_ctx_pct) ]
              ]
          ; Node.div
              ~attrs:[ Style.vial ]
              [ Node.span ~attrs:[ Style.vial_fill; vial_style; Attr.create "aria-hidden" "true" ] [] ]
          ]
      ; Node.div
          ~attrs:[ Style.focus_stats ]
          [ focus_stat "turn" focus_turn
          ; focus_stat "heartbeat" "3s"
          ; focus_stat "mem" focus_mem
          ; focus_stat "latency" focus_latency
          ]
      ]
  in
  let ev ?(level = `Info) t body_inline =
    let attrs =
      match level with
      | `Info -> [ Style.evrow ]
      | `Ok -> [ Style.evrow; Style.evrow_ok ]
      | `Warn -> [ Style.evrow; Style.evrow_warn ]
      | `Bad -> [ Style.evrow; Style.evrow_bad ]
    in
    Node.div
      ~attrs
      [ Node.div ~attrs:[ Style.evrow_t ] [ Node.text t ]
      ; Node.div ~attrs:[ Style.evrow_mk ] []
      ; Node.div ~attrs:[ Style.evrow_b ] body_inline
      ]
  in
  (* live evs: WARN/ERROR만 필터, 최근 5개. mock→real 전환. *)
  let hhmm_of_ts (ts : string) : string =
    (* "2026-04-19T17:12:03Z" -> "17:12" *)
    if String.length ts >= 16
    then String.sub ts ~pos:11 ~len:5
    else ts
  in
  let ev_of_entry (e : Logs_types.entry) : Node.t =
    let level : [ `Info | `Ok | `Warn | `Bad ] =
      match e.normalized_level with
      | "ERROR" -> `Bad
      | "WARN" -> `Warn
      | _ -> `Info
    in
    let body =
      [ Node.text e.message
      ; Node.text " "
      ; Node.span ~attrs:[ Style.evrow_b_code ] [ Node.text e.module_ ]
      ]
    in
    ev ~level (hhmm_of_ts e.ts) body
  in
  let evs_stream =
    let filtered =
      List.filter response.entries ~f:(fun e ->
        match e.normalized_level with
        | "WARN" | "ERROR" -> true
        | _ -> false)
    in
    let top_five =
      match List.length filtered with
      | n when n <= 5 -> filtered
      | _ -> List.take filtered 5
    in
    match top_five with
    | [] ->
      Node.div
        ~attrs:[ Style.evs ]
        [ Node.div
            ~attrs:[ Style.evrow ]
            [ Node.div ~attrs:[ Style.evrow_t ] [ Node.text "—" ]
            ; Node.div ~attrs:[ Style.evrow_mk ] []
            ; Node.div
                ~attrs:[ Style.evrow_b ]
                [ Node.span ~attrs:[ Attr.create "lang" "ko" ] [ Node.text "조용하다 · 경고 없음" ] ]
            ]
        ]
    | rows -> Node.div ~attrs:[ Style.evs ] (List.map rows ~f:ev_of_entry)
  in
  let evs_tail =
    let total_alarms =
      List.count response.entries ~f:(fun e ->
        match e.normalized_level with
        | "WARN" | "ERROR" -> true
        | _ -> false)
    in
    Printf.sprintf "%d / ∞" total_alarms
  in
  let aside =
    Node.div
      ~attrs:[ Style.aside; Attr.role "complementary"; Attr.create "aria-label" "Keeper details" ]
      [ Node.div
          ~attrs:[]
          [ aside_h
              ~tail:(Printf.sprintf "ctx %d%%" focus_ctx_pct)
              "focus · keeper"
          ; focus_card
          ]
      ; Node.div
          ~attrs:[]
          [ aside_h ~tail:"mock · pending trace" "flame · last cycle"
          ; Flame.view_mini
              ~segments:
                [ `Llm, 42
                ; `Tool, 18
                ; `Think, 12
                ; `Wait, 20
                ; `Err, 8
                ]
          ]
      ; Node.div
          ~attrs:[]
          [ aside_h ~tail:evs_tail "runtime · recent"
          ; evs_stream
          ]
      ]
  in
  Node.div
    ~attrs:[ Style.root ]
    [ Node.a
        ~attrs:
          [ Style.skip_nav
          ; Attr.href "#main-content"
          ; Attr.create "aria-label" "Skip to main content"
          ]
        [ Node.text "Skip to main content" ]
    ; nav
    ; brand_row
    ; view_heartbeat ~entries:response.entries ()
    ; view_hud ~keepers response
    ; (let warn_n =
         List.count response.entries ~f:(fun e ->
           String.equal e.normalized_level "WARN")
       in
       let err_n =
         List.count response.entries ~f:(fun e ->
           String.equal e.normalized_level "ERROR")
       in
       let head_tally = tally_fleet keepers.keepers in
       let keeper_count = List.length keepers.keepers in
       let sub_text =
         match response.entries, keeper_count with
         | [], 0 ->
           "저택은 조용하다. 아무도 아직 말하지 않았고, 폭풍은 아직 문을 두드리지 않았다."
         | [], n ->
           Printf.sprintf
             "%d명의 키퍼가 홀을 지킨다. 저널은 아직 비어 있다 — 폭풍 전의 숨."
             n
         | _, 0 ->
           Printf.sprintf
             "저널이 마지막 %d행을 기억한다. 경보 %d · 경고 %d이 울렸으나, 키퍼는 아직 도착하지 않았다."
             response.total err_n warn_n
         | _, n ->
           Printf.sprintf
             "%d명의 키퍼가 홀을 지킨다. 저널은 마지막 %d행을 들었고, 경보 %d · 경고 %d이 울렸다."
             n response.total err_n warn_n
       in
       let h1_suffix, h1_suffix_class =
         match head_tally with
         | { dead; _ } when dead > 0 ->
           "under storm", Style.page_h1_blood
         | { warn; _ } when warn > 0 ->
           "under watch", Style.page_h1_brass
         | { live = 0; _ } ->
           "before dawn", Style.page_h1_bright
         | _ ->
           "in vigil", Style.page_h1_bright
       in
       Node.div
         ~attrs:[ Style.page_head; Attr.id "main-content" ]
         [ Node.div
             ~attrs:[ Style.page_head_lead ]
             [ Node.div
                 ~attrs:[ Style.page_tag ]
                 [ Node.text
                     (let cycle =
                        if keepers.cycle <= 0
                        then "—"
                        else roman_of_int keepers.cycle
                      in
                      Printf.sprintf "runtime · %s · cycle %s" runtime_name cycle) ]
             ; Node.h1
                 ~attrs:[ Style.page_h1 ]
                 [ Node.text "the watch "
                 ; Node.span
                     ~attrs:[ h1_suffix_class ]
                     [ Node.text h1_suffix ]
                 ]
             ; Node.p ~attrs:[ Style.page_sub ] [ Node.text sub_text ]
             ]
        ; Node.div
            ~attrs:[ Style.page_actions ]
            [ Node.button
                ~attrs:[ Style.pbtn; Attr.create "type" "button" ]
                [ Node.span
                    ~attrs:[ Style.pbtn_glyph; Attr.create "aria-hidden" "true" ]
                    []
                ; Node.text "preflight"
                ]
            ; Node.button
                ~attrs:[ Style.pbtn; Style.pbtn_primary; Attr.create "type" "button" ]
                [ Node.span
                    ~attrs:[ Style.pbtn_glyph; Attr.create "aria-hidden" "true" ]
                    []
                ; Node.text "advance round"
                ]
            ]
        ])
    ; moonrise
    ; toolbar
    ; Node.div
        ~attrs:[ Style.header ]
        [ Node.div
            ~attrs:[ Style.header_lead ]
            [ Node.p ~attrs:[ Style.eyebrow ] [ Node.text "log ring · in-memory" ]
            ; Node.h2
                ~attrs:[ Style.title ]
                [ Node.span ~attrs:[ Style.versal ] [ Node.text "J" ]
                ; Node.span ~attrs:[ Style.title_rest ] [ Node.text "ournal" ]
                ; Node.span ~attrs:[ Style.title_rule; Attr.create "aria-hidden" "true" ] []
                ; Node.span
                    ~attrs:[ Style.folio ]
                    [ Node.text "folio xii · recto" ]
                ]
            ]
        ; Node.span
            ~attrs:[ Style.meta ]
            [ Node.text (Printf.sprintf "seq up to %d" response.total) ]
        ]
    ; Node.div
        ~attrs:[ Style.sec ]
        [ Node.span ~attrs:[ Style.sec_glyph; Attr.create "aria-hidden" "true" ] []
        ; Node.div ~attrs:[ Style.sec_h ] [ Node.text "log ring" ]
        ; Node.span
            ~attrs:[ Style.sec_sub ]
            [ Node.text "in-memory journal · newest on top" ]
        ; Node.span ~attrs:[ Style.sec_hr; Attr.create "aria-hidden" "true" ] []
        ; Node.span
            ~attrs:[ Style.sec_r ]
            [ Node.text "rows "
            ; Node.span
                ~attrs:[ Style.sec_r_v ]
                [ Node.text
                    (Printf.sprintf "%d"
                       (List.length response.entries))
                ]
            ; Node.text " / total "
            ; Node.span
                ~attrs:[ Style.sec_r_v ]
                [ Node.text (Printf.sprintf "%d" response.total) ]
            ]
        ]
    ; tape
    ; Node.div
        ~attrs:[ Style.sec ]
        [ Node.span ~attrs:[ Style.sec_glyph; Attr.create "aria-hidden" "true" ] []
        ; Node.div ~attrs:[ Style.sec_h ] [ Node.text "keepers" ]
        ; Node.span
            ~attrs:[ Style.sec_sub ]
            [ Node.text "sorted by heartbeat · ctx spark = last 10 min" ]
        ; Node.span ~attrs:[ Style.sec_hr; Attr.create "aria-hidden" "true" ] []
        ; Node.span
            ~attrs:[ Style.sec_r ]
            [ Node.text "slot "
            ; Node.span
                ~attrs:[ Style.sec_r_v ]
                [ Node.text
                    (match keepers.keepers with
                     | [] -> "—"
                     | ks -> String.lowercase (roman_of_int (List.length ks)))
                ]
            ]
        ]
    ; Roster.view ~keepers ()
    ; Node.div
        ~attrs:[ Style.sec ]
        [ Node.span ~attrs:[ Style.sec_glyph; Attr.create "aria-hidden" "true" ] []
        ; Node.div ~attrs:[ Style.sec_h ] [ Node.text "cycle activity" ]
        ; Node.span
            ~attrs:[ Style.sec_sub ]
            [ Node.text "last 60 minutes · one lane per keeper" ]
        ; Node.span ~attrs:[ Style.sec_hr; Attr.create "aria-hidden" "true" ] []
        ; Node.span
            ~attrs:[ Style.sec_r ]
            [ Node.text "mock · trace endpoint "
            ; Node.span ~attrs:[ Style.sec_r_v ] [ Node.text "pending" ]
            ]
        ]
    ; Swim.view ~keepers ()
    ; Node.div
        ~attrs:[ Style.sec ]
        [ Node.span ~attrs:[ Style.sec_glyph; Attr.create "aria-hidden" "true" ] []
        ; Node.div ~attrs:[ Style.sec_h ] [ Node.text "context pressure" ]
        ; Node.span
            ~attrs:[ Style.sec_sub ]
            [ Node.text "60m rolling · % of window · warn 75 / danger 90" ]
        ; Node.span ~attrs:[ Style.sec_hr; Attr.create "aria-hidden" "true" ] []
        ; Node.span
            ~attrs:[ Style.sec_r ]
            [ Node.text "mock · keepers endpoint "
            ; Node.span ~attrs:[ Style.sec_r_v ] [ Node.text "pending" ]
            ]
        ]
    ; Ctx_chart.view ~keepers ()
    ; Node.div
        ~attrs:[ Style.sec ]
        [ Node.span ~attrs:[ Style.sec_glyph; Attr.create "aria-hidden" "true" ] []
        ; Node.div ~attrs:[ Style.sec_h ] [ Node.text "keeper rites · 12 states" ]
        ; Node.span
            ~attrs:[ Style.sec_sub ]
            [ Node.text "Offline → Running → {Failing · Overflowed · Compacting · Draining} → Paused / Stopped / Crashed → Restarting → Dead" ]
        ; Node.span ~attrs:[ Style.sec_hr; Attr.create "aria-hidden" "true" ] []
        ; Node.span
            ~attrs:[ Style.sec_r ]
            [ Node.text "mock · keeper phase wire "
            ; Node.span ~attrs:[ Style.sec_r_v ] [ Node.text "pending" ]
            ]
        ]
    ; view_tombstrip ()
    ; Node.div ~attrs:[ Style.signet ] [ Node.text "M" ]
    ; aside
    ]
;;

let component (_graph @ local) =
  Bonsai.map2
    (Bonsai.Expert.Var.value Logs_var.var)
    (Bonsai.Expert.Var.value Keepers_var.var)
    ~f:(fun logs_response keepers_response ->
      render_response ~keepers:keepers_response logs_response)
;;
