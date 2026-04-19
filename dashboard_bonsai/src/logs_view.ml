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
    [var(--bg-deep)] etc. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .root {
    position: relative;
    min-height: 100vh;
    background:
      radial-gradient(circle at 88% 14%, rgba(138, 106, 40, 0.10), transparent 22%),
      radial-gradient(circle at 8% 88%, rgba(160, 24, 24, 0.05), transparent 28%),
      var(--bg-deep);
    color: var(--text-primary);
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-size: 15px;
    padding: 1.5rem calc(340px + 24px) 4rem 244px;
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
    isolation: isolate;
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
    border-bottom: 1px solid var(--border-main);
  }

  .rune {
    width: 22px;
    height: 22px;
    border: 1px solid var(--accent-brass);
    display: grid;
    place-items: center;
    color: var(--accent-brass);
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
    color: var(--accent-brass);
    text-transform: uppercase;
  }

  .crumbs {
    margin-left: 14px;
    display: flex;
    align-items: center;
    gap: 10px;
    color: var(--text-dim);
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    letter-spacing: 0.12em;
    text-transform: uppercase;
  }

  .crumbs_sep { color: var(--border-highlight); }
  .crumbs_cur { color: var(--text-bright); letter-spacing: 0.14em; }

  .pulse_slot { margin-left: auto; display: flex; align-items: center; gap: 8px; }

  .pulse {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent-brass);
    box-shadow: 0 0 8px rgba(138, 106, 40, 0.55);
    animation: pulse-beat 2.4s ease-in-out infinite;
  }

  @keyframes pulse-beat {
    0%, 100% { opacity: 0.55; }
    50% { opacity: 1; }
  }

  .pulse_label {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 9px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .heartbeat {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 10px 14px 12px;
    background:
      linear-gradient(180deg, var(--bg-panel) 0%, #0f0b09 100%);
    border: 1px solid var(--border-main);
    border-radius: 2px;
    box-shadow: inset 0 0 0 1px rgba(196, 162, 101, 0.04);
  }

  .heartbeat_head {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .heartbeat_eyebrow {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 9px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .heartbeat_scale {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
    font-size: 9px;
    letter-spacing: 0.12em;
    color: #4a3a32;
  }

  .heartbeat_track {
    display: grid;
    grid-auto-flow: column;
    grid-auto-columns: 1fr;
    gap: 2px;
    height: 36px;
    align-items: end;
    padding: 0 1px;
    border-bottom: 1px solid var(--border-main);
  }

  .heartbeat_bar {
    min-width: 2px;
    background: #3a5a48;
    border-radius: 1px;
    opacity: 0.82;
  }

  .heartbeat_bar_warn  { background: linear-gradient(180deg, #a06a1a 0%, #6a3c10 100%); }
  .heartbeat_bar_error { background: linear-gradient(180deg, #e84848 0%, #8a1010 100%); box-shadow: 0 0 6px rgba(160, 24, 24, 0.45); }
  .heartbeat_bar_idle  { background: var(--border-main); opacity: 0.6; }

  .hud {
    position: sticky;
    top: 0;
    z-index: 3;
    display: grid;
    grid-template-columns: repeat(6, 1fr);
    gap: 1px;
    background: var(--border-main);
    border: 1px solid var(--border-highlight);
    border-radius: 2px;
    box-shadow:
      inset 0 0 0 1px rgba(196, 162, 101, 0.08),
      0 2px 12px rgba(0, 0, 0, 0.6),
      0 16px 24px -16px rgba(0, 0, 0, 0.9);
    backdrop-filter: blur(2px);
  }

  .hud::before,
  .hud::after {
    content: "";
    position: absolute;
    width: 14px;
    height: 14px;
    border: 1px solid var(--accent-brass);
    pointer-events: none;
    z-index: 1;
  }

  .hud::before {
    top: -1px;
    left: -1px;
    border-right: 0;
    border-bottom: 0;
  }

  .hud::after {
    bottom: -1px;
    right: -1px;
    border-left: 0;
    border-top: 0;
  }

  .hud_cell {
    background: var(--bg-panel);
    padding: 10px 14px;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .hud_k {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 9px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .hud_v {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 12px;
    color: var(--text-primary);
  }

  .hud_v_ok   { color: #5a7a3a; }
  .hud_v_warn { color: #a06a1a; }

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
        rgba(138, 106, 40, 0.10) 0%,
        transparent 45%,
        rgba(160, 24, 24, 0.06) 100%),
      #0f0b09;
    border: 1px solid var(--border-main);
    border-radius: 2px;
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-variant: small-caps;
    letter-spacing: 0.08em;
    font-size: 12px;
    color: var(--text-primary);
  }

  .moon_glyph {
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: radial-gradient(circle at 28% 28%, var(--text-bright) 0%, var(--accent-brass) 55%, var(--border-highlight) 100%);
    box-shadow:
      0 0 10px rgba(232, 216, 184, 0.22),
      inset 0 0 0 1px rgba(232, 216, 184, 0.12);
    flex-shrink: 0;
  }

  .moon_lead {
    font-family: 'Cinzel', serif;
    font-variant: normal;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-bright);
    font-size: 10px;
  }

  .moon_sep {
    color: var(--border-highlight);
    font-variant: normal;
  }

  .moon_mono {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
    font-size: 11px;
    font-variant: normal;
    letter-spacing: 0.04em;
    color: var(--accent-brass);
  }

  .moon_tail {
    margin-left: auto;
    color: var(--text-dim);
    font-variant: normal;
    font-size: 10px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
  }

  .toolbar {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 12px;
    background: var(--bg-panel);
    border: 1px solid var(--border-main);
    border-radius: 2px;
    flex-wrap: wrap;
  }

  .chip_group {
    display: inline-flex;
    gap: 4px;
    padding: 2px;
    border: 1px solid var(--border-main);
    border-radius: 999px;
    background: #0f0b09;
  }

  .chip {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 10px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    padding: 4px 12px;
    border-radius: 999px;
    color: var(--text-dim);
    cursor: pointer;
    transition: background 0.18s, color 0.18s;
  }

  .chip:hover { color: var(--text-primary); }
  .chip_active {
    color: var(--text-bright);
    background: rgba(138, 106, 40, 0.14);
    box-shadow: inset 0 0 0 1px var(--accent-brass);
  }

  .input_shell {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border: 1px solid var(--border-main);
    border-radius: 2px;
    background: #0f0b09;
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 11px;
    color: var(--text-dim);
  }

  .input_shell_label { letter-spacing: 0.25em; text-transform: uppercase; color: #4a3a32; font-size: 9px; }
  .input_shell_value { font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace; font-size: 11px; color: var(--text-primary); }

  .toolbar_spacer { flex: 1; }

  .btn_ghost {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 10px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    padding: 5px 12px;
    border: 1px solid var(--border-main);
    border-radius: 2px;
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    transition: color 0.18s, border-color 0.18s;
  }
  .btn_ghost:hover { color: var(--accent-brass); border-color: var(--border-highlight); }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    border-bottom: 1px solid var(--border-main);
    padding-bottom: 0.75rem;
    gap: 1rem;
  }

  .header_lead { flex: 1; min-width: 0; }

  .eyebrow {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 10px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
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
    background: linear-gradient(180deg, var(--text-bright) 0%, var(--accent-brass) 55%, var(--border-highlight) 100%);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    text-shadow: 0 0 18px rgba(138, 106, 40, 0.28);
    margin-right: 4px;
    align-self: flex-start;
    padding-top: 6px;
  }

  .title_rest {
    font-family: 'Cinzel', serif;
    font-weight: 400;
    font-size: 1rem;
    letter-spacing: 0.3em;
    color: var(--text-primary);
    text-transform: uppercase;
  }

  .title_rule {
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--border-highlight) 0%, transparent 100%);
    margin-left: 10px;
    margin-right: 10px;
    align-self: center;
  }

  .folio {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 10px;
    letter-spacing: 0.08em;
    color: var(--border-highlight);
    text-transform: none;
  }

  .meta {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 11px;
    letter-spacing: 0.1em;
    color: var(--accent-brass);
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
      var(--border-highlight) 6%,
      var(--border-main) 92%,
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
    background: linear-gradient(180deg, var(--bg-deep) 0%, rgba(10, 7, 6, 0) 100%);
    pointer-events: none;
    z-index: 2;
  }

  /* Symmetric bottom fade so old entries dissolve into the page floor
     before the roster strip. Sibling element (not pseudo) so it can sit
     after the row stream in DOM order without breaking sticky positioning. */
  .tape_end {
    position: relative;
    height: 32px;
    background: linear-gradient(180deg, rgba(10, 7, 6, 0) 0%, var(--bg-deep) 100%);
    margin-top: -8px;
    pointer-events: none;
  }

  .row {
    display: grid;
    grid-template-columns: 1.75rem 10rem 5rem 9rem 7.5rem minmax(0, 1fr);
    gap: 1rem;
    padding: 0.625rem 0.75rem;
    border-bottom: 1px dashed var(--border-main);
    border-left: 2px solid var(--border-main);
    align-items: baseline;
    transition: background 0.18s ease, box-shadow 0.18s ease, border-left-color 0.18s ease;
  }

  .sigil {
    width: 22px;
    height: 22px;
    border-radius: 50%;
    border: 1px solid var(--accent-brass);
    background:
      radial-gradient(circle at 35% 30%, rgba(232, 216, 184, 0.18), transparent 55%),
      var(--bg-panel);
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 10px;
    letter-spacing: 0;
    color: var(--accent-brass);
    text-transform: uppercase;
    box-shadow:
      inset 0 0 0 1px rgba(232, 216, 184, 0.06),
      0 0 6px rgba(138, 106, 40, 0.18);
    align-self: center;
  }

  .sigil_warn  { color: #a06a1a; border-color: #a06a1a; box-shadow: inset 0 0 0 1px rgba(232,216,184,0.06), 0 0 8px rgba(160, 106, 26, 0.35); }
  .sigil_error { color: var(--text-bright); border-color: var(--accent-blood); background: radial-gradient(circle at 35% 30%, rgba(232,216,184,0.28), transparent 55%), #3a1410; box-shadow: inset 0 0 0 1px rgba(232,216,184,0.08), 0 0 10px rgba(160, 24, 24, 0.45); }

  .message_lead::first-letter {
    font-family: 'Cinzel', 'EB Garamond', serif;
    font-weight: 600;
    font-size: 2.4rem;
    line-height: 0.85;
    float: left;
    padding: 2px 8px 0 0;
    margin-top: 2px;
    background: linear-gradient(180deg, var(--text-bright) 0%, var(--accent-brass) 55%, var(--border-highlight) 100%);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    text-shadow: 0 0 14px rgba(138, 106, 40, 0.25);
  }

  .row_debug { border-left-color: #4a3a32; }
  .row_info  { border-left-color: #3a5a48; }

  .row:hover {
    background: linear-gradient(90deg, rgba(138, 106, 40, 0.08), transparent 70%);
    box-shadow: inset 1px 0 0 0 rgba(138, 106, 40, 0.35);
    border-left-color: var(--accent-brass);
  }

  .row_error {
    background: linear-gradient(90deg, rgba(160, 24, 24, 0.08) 0%, transparent 60%);
    border-left-color: var(--accent-blood);
  }

  .row_error:hover {
    background: linear-gradient(90deg, rgba(160, 24, 24, 0.18) 0%, transparent 65%);
    box-shadow: inset 1px 0 0 0 rgba(160, 24, 24, 0.55);
    border-left-color: #c94a3a;
  }

  .row_warn {
    background: linear-gradient(90deg, rgba(160, 106, 26, 0.06) 0%, transparent 60%);
    border-left-color: #a06a1a;
  }

  .row_warn:hover {
    background: linear-gradient(90deg, rgba(160, 106, 26, 0.15) 0%, transparent 65%);
    box-shadow: inset 1px 0 0 0 rgba(160, 106, 26, 0.5);
    border-left-color: #c4461a;
  }

  .ts {
    display: flex;
    flex-direction: column;
    gap: 2px;
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 11px;
    color: var(--text-dim);
  }

  .ts_rel {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 9px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: #4a3a32;
  }

  .level {
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 10px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    font-weight: 500;
  }

  .level_debug { color: var(--text-dim); }
  .level_info  { color: var(--text-primary); }
  .level_warn  { color: #a06a1a; }
  .level_error { color: var(--accent-blood); text-shadow: 0 0 12px rgba(160, 24, 24, 0.32); }

  .mod_col {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-size: 11px;
    color: var(--text-dim);
  }

  .source_badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 9px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    padding: 3px 8px;
    border: 1px solid var(--border-main);
    border-radius: 999px;
    background: #1b1612;
    color: var(--text-dim);
    width: fit-content;
    height: fit-content;
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-dim);
    display: inline-block;
  }

  .dot_ok    { background: #5a7a3a; box-shadow: 0 0 6px #5a7a3a; }
  .dot_warn  { background: #a06a1a; box-shadow: 0 0 6px #a06a1a; }
  .dot_bad   { background: var(--accent-blood); box-shadow: 0 0 6px var(--accent-blood); }

  .message {
    color: var(--text-primary);
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-size: 14px;
    line-height: 1.5;
    overflow-wrap: anywhere;
  }

  .details {
    color: var(--text-dim);
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-size: 10px;
    margin-top: 0.25rem;
    opacity: 0.75;
  }

  .empty {
    color: var(--text-dim);
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
    font-size: 10px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-style: normal;
    color: #4a3a32;
  }

  /* Wrapper kept for backward compatibility with the existing render
     code; the top fade now lives on .tape::after, so the old sticky
     pseudo is no longer needed. */
  .tape_fade {
    position: relative;
  }

  .roster {
    position: sticky;
    bottom: 0;
    z-index: 3;
    margin-top: 1rem;
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 1px;
    background: var(--border-main);
    border: 1px solid #3a2a20;
    border-radius: 2px;
    box-shadow:
      inset 0 0 0 1px rgba(196, 162, 101, 0.06),
      0 -8px 24px -12px rgba(0, 0, 0, 0.85);
    backdrop-filter: blur(2px);
  }

  .roster_slot {
    background: var(--bg-panel);
    padding: 10px 14px;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .roster_sigil {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    border: 1px solid var(--accent-brass);
    background: radial-gradient(circle at 35% 30%, rgba(232, 216, 184, 0.22), transparent 55%), var(--bg-panel);
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 11px;
    color: var(--text-bright);
    text-transform: uppercase;
    box-shadow: inset 0 0 0 1px rgba(232, 216, 184, 0.08), 0 0 8px rgba(138, 106, 40, 0.22);
    flex-shrink: 0;
  }

  .roster_body {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .roster_name {
    font-family: 'Cinzel', serif;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--text-bright);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .roster_state {
    display: flex;
    align-items: center;
    gap: 6px;
    font-family: 'Noto Sans KR', -apple-system, sans-serif;
    font-size: 9px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .roster_dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: var(--text-dim);
  }

  .roster_dot_live     { background: #5a7a3a; box-shadow: 0 0 6px #5a7a3a; animation: pulse-beat 1.8s ease-in-out infinite; }
  .roster_dot_thinking { background: var(--accent-brass); box-shadow: 0 0 6px var(--accent-brass); animation: pulse-beat 1.2s ease-in-out infinite; }
  .roster_dot_idle     { background: #4a3a32; }
  .roster_dot_failed   { background: var(--accent-blood); box-shadow: 0 0 8px var(--accent-blood); }

  .roster_when {
    margin-left: auto;
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 10px;
    color: var(--text-dim);
    flex-shrink: 0;
  }

  .signet {
    position: fixed;
    left: 1.75rem;
    bottom: 1.25rem;
    width: 56px;
    height: 56px;
    border-radius: 50%;
    background: radial-gradient(circle at 32% 28%, #c94a3a 0%, var(--accent-blood) 40%, #5a0a0a 80%, #2a0404 100%);
    border: 2px solid var(--accent-brass);
    box-shadow:
      inset 0 0 0 1px rgba(232, 216, 184, 0.18),
      inset -6px -8px 14px rgba(0, 0, 0, 0.55),
      inset 5px 4px 10px rgba(232, 216, 184, 0.15),
      0 6px 14px rgba(160, 24, 24, 0.35),
      0 0 22px rgba(138, 106, 40, 0.22);
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
    text-shadow: 0 1px 0 rgba(0, 0, 0, 0.6), 0 0 8px rgba(232, 216, 184, 0.35);
  }

  .signet::before {
    content: "";
    position: absolute;
    inset: 6px;
    border-radius: 50%;
    border: 1px dashed rgba(232, 216, 184, 0.22);
    transform: rotate(14deg);
  }

  .signet::after {
    content: "masc · seal";
    position: absolute;
    top: calc(100% + 4px);
    left: 50%;
    transform: translateX(-50%) rotate(14deg);
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 8px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--border-highlight);
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
    background: linear-gradient(180deg, #18110c 0%, #0e0806 100%);
    border-right: 1px solid var(--border-main);
    box-shadow: inset -1px 0 0 rgba(138, 106, 40, 0.08);
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
    border-bottom: 1px solid var(--border-main);
    margin-bottom: 12px;
  }
  .nav_brand_rune {
    width: 18px;
    height: 18px;
    border: 1px solid var(--accent-brass);
    color: var(--accent-brass);
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 9px;
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
    font-size: 9px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .nav_section::after {
    content: "";
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--border-highlight), transparent);
  }

  .nav_link {
    display: flex;
    align-items: center;
    gap: 11px;
    padding: 8px 18px;
    color: var(--text-primary);
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.1em;
    text-decoration: none;
    border-left: 2px solid transparent;
    cursor: default;
    user-select: none;
  }
  .nav_link:hover {
    color: var(--accent-brass);
    background: rgba(138, 106, 40, 0.05);
  }
  .nav_link_active {
    color: var(--accent-brass);
    border-left-color: var(--accent-brass);
    background: linear-gradient(90deg, rgba(138, 106, 40, 0.10), transparent 70%);
  }
  .nav_link_glyph {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--border-highlight);
    flex-shrink: 0;
  }
  .nav_link_active .nav_link_glyph {
    background: var(--accent-brass);
    box-shadow: 0 0 6px var(--accent-brass);
  }
  .nav_link_tail {
    margin-left: auto;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 10px;
    color: var(--accent-blood);
    font-variant-numeric: tabular-nums;
  }

  .nav_foot {
    margin-top: auto;
    padding: 14px 18px 0;
    border-top: 1px solid var(--border-main);
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 9px;
    letter-spacing: 0.16em;
    color: var(--border-highlight);
    text-transform: uppercase;
  }
  .nav_foot_v { color: var(--text-dim); }

  /* ─── right aside (340px, fixed) ───
     dashboard_v2 aside: focus card + chronicle evs stream.
     현재는 static skeleton. 추후 Var 연결. */
  .aside {
    position: fixed;
    top: 0;
    right: 0;
    width: 340px;
    height: 100vh;
    padding: 22px 18px 28px;
    background: linear-gradient(180deg, #16100a 0%, #0e0806 100%);
    border-left: 1px solid var(--border-main);
    box-shadow: inset 1px 0 0 rgba(138, 106, 40, 0.06);
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
    color: var(--accent-brass);
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
    background: linear-gradient(90deg, var(--border-highlight), transparent);
  }
  .aside_h_tail {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 10px;
    color: var(--text-dim);
    margin-left: auto;
    font-variant-numeric: tabular-nums;
    letter-spacing: 0.04em;
    text-transform: none;
  }

  /* ─── focus card ─── */
  .focus {
    position: relative;
    padding: 16px 16px 14px;
    background: linear-gradient(180deg, #241a12 0%, #14100a 100%);
    border: 1px solid var(--accent-brass-dim);
  }
  .focus::before {
    content: "";
    position: absolute;
    inset: 3px;
    border: 1px solid var(--border-highlight);
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
    border: 1px solid var(--accent-brass);
    background: linear-gradient(135deg, #2a1f14, #0e0806);
    display: grid;
    place-items: center;
    font-family: 'Cinzel', serif;
    font-size: 18px;
    color: var(--accent-brass);
    flex-shrink: 0;
  }
  .focus_name_col { flex: 1; }
  .focus_name {
    font-family: 'Cinzel', serif;
    font-size: 16px;
    color: var(--accent-brass);
    letter-spacing: 0.16em;
    text-transform: uppercase;
  }
  .focus_role {
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    font-size: 11px;
    color: var(--text-dim);
    margin-top: 2px;
  }

  .ctx_bar { margin-top: 14px; position: relative; }
  .ctx_lbl {
    display: flex;
    justify-content: space-between;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 10px;
    color: var(--text-dim);
    margin-bottom: 4px;
    font-variant-numeric: tabular-nums;
  }
  .ctx_lbl_v { color: var(--text-bright); }
  .vial {
    height: 8px;
    background: #0a0604;
    border: 1px solid var(--border-main);
    position: relative;
    overflow: hidden;
  }
  .vial_fill {
    display: block;
    height: 100%;
    width: 64%;
    background: linear-gradient(90deg, #8a6a20, #d4a940);
    box-shadow: 0 0 6px rgba(138, 106, 40, 0.45);
  }
  .vial::after {
    content: "";
    position: absolute;
    inset: 0;
    background-image: repeating-linear-gradient(90deg, transparent 0 19px, rgba(0, 0, 0, 0.5) 19px 20px);
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
    font-size: 9px;
    letter-spacing: 0.22em;
    color: var(--text-dim);
    text-transform: uppercase;
  }
  .focus_stat_v {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 12px;
    color: var(--text-bright);
    margin-top: 2px;
    font-variant-numeric: tabular-nums;
  }

  /* ─── chronicle evs stream ─── */
  .evs { display: flex; flex-direction: column; }
  .evrow {
    display: grid;
    grid-template-columns: 52px 12px 1fr;
    gap: 10px;
    padding: 8px 0;
    border-bottom: 1px dashed var(--border-main);
    align-items: baseline;
  }
  .evrow:last-child { border-bottom: 0; }
  .evrow_t {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 10px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .evrow_mk {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    align-self: center;
    justify-self: center;
    background: var(--accent-brass-dim);
  }
  .evrow_ok  .evrow_mk { background: #5a7a3a; box-shadow: 0 0 6px #5a7a3a; }
  .evrow_warn .evrow_mk { background: var(--accent-brass); box-shadow: 0 0 6px var(--accent-brass); }
  .evrow_bad  .evrow_mk { background: var(--accent-blood); box-shadow: 0 0 6px var(--accent-blood); }
  .evrow_b {
    font-family: 'EB Garamond', Georgia, serif;
    font-size: 12px;
    color: var(--text-primary);
    line-height: 1.45;
  }
  .evrow_b_em { color: var(--text-bright); font-style: italic; }
  .evrow_b_code {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 10px;
    color: var(--accent-brass);
    background: rgba(138, 106, 40, 0.08);
    padding: 0 5px;
    border: 1px solid var(--border-main);
  }
  .evrow_bad .evrow_b_code {
    color: var(--accent-blood);
    background: rgba(160, 24, 24, 0.08);
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
    font-size: 10px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .page_tag::after {
    content: "";
    flex: 0 0 40px;
    height: 1px;
    background: var(--border-highlight);
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
    text-shadow: 0 0 18px rgba(201, 74, 58, 0.32);
  }
  .page_sub {
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    font-style: italic;
    color: var(--text-primary);
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
    font-size: 10px;
    letter-spacing: 0.24em;
    text-transform: uppercase;
    padding: 7px 12px;
    background: linear-gradient(180deg, #241a12 0%, #14100a 100%);
    border: 1px solid var(--accent-brass-dim);
    color: var(--text-primary);
    cursor: default;
    user-select: none;
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .pbtn:hover {
    border-color: var(--accent-brass);
    color: var(--accent-brass);
  }
  .pbtn_primary {
    background: linear-gradient(180deg, #3a2a16 0%, #241810 100%);
    border-color: var(--accent-brass);
    color: var(--accent-brass);
  }
  .pbtn_primary:hover {
    background: rgba(138, 106, 40, 0.12);
    color: var(--text-bright);
  }
  .pbtn_glyph {
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: currentColor;
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
    | None -> [ Style.row ]
    | Some tint -> [ Style.row; tint ]
  in
  let sigil_attrs =
    match sigil_class e.normalized_level with
    | None -> [ Style.sigil ]
    | Some c -> [ Style.sigil; c ]
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
        [ Node.span ~attrs:[ Style.dot; dot_class e.normalized_level ] []
        ; Node.text e.source
        ]
    ; Node.div message_block
    ]
;;

let hud_cell ?(v_class = None) ~k ~v () =
  let v_attrs =
    match v_class with
    | None -> [ Style.hud_v ]
    | Some c -> [ Style.hud_v; c ]
  in
  Node.div
    ~attrs:[ Style.hud_cell ]
    [ Node.div ~attrs:[ Style.hud_k ] [ Node.text k ]
    ; Node.div ~attrs:v_attrs [ Node.text v ]
    ]
;;

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

let view_heartbeat () =
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
    let total = List.length heartbeat_bars in
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
    Node.div ~attrs:(title_attr :: style :: base_attrs) []
  in
  Node.div
    ~attrs:[ Style.heartbeat ]
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
        (List.mapi ~f:bar heartbeat_bars)
    ]
;;

(* Keeper roster — sticky bottom strip. Four fixed keeper slots as a
   visual placeholder; Phase 1c wires this to a keeper_status Var so the
   state dot, last-heard timestamp, and presence reflect live telemetry. *)
type keeper_state = [ `Live | `Thinking | `Idle | `Failed ]

let view_roster () =
  let slot ~sigil ~name ~(state : keeper_state) ~state_label ~when_ =
    let dot_cls =
      match state with
      | `Live -> Style.roster_dot_live
      | `Thinking -> Style.roster_dot_thinking
      | `Idle -> Style.roster_dot_idle
      | `Failed -> Style.roster_dot_failed
    in
    Node.div
      ~attrs:[ Style.roster_slot ]
      [ Node.div ~attrs:[ Style.roster_sigil ] [ Node.text sigil ]
      ; Node.div
          ~attrs:[ Style.roster_body ]
          [ Node.span ~attrs:[ Style.roster_name ] [ Node.text name ]
          ; Node.div
              ~attrs:[ Style.roster_state ]
              [ Node.span ~attrs:[ Style.roster_dot; dot_cls ] []
              ; Node.text state_label
              ]
          ]
      ; Node.span ~attrs:[ Style.roster_when ] [ Node.text when_ ]
      ]
  in
  Node.div
    ~attrs:[ Style.roster ]
    [ slot ~sigil:"P" ~name:"keeper · poe" ~state:`Live
        ~state_label:"speaking" ~when_:"3s"
    ; slot ~sigil:"J" ~name:"janitor" ~state:`Thinking
        ~state_label:"thinking" ~when_:"12s"
    ; slot ~sigil:"G" ~name:"governance" ~state:`Idle
        ~state_label:"idle · ok" ~when_:"2m"
    ; slot ~sigil:"I" ~name:"improver" ~state:`Failed
        ~state_label:"paused · auth" ~when_:"7m"
    ]
;;

let view_hud (response : Logs_types.response) =
  Node.div
    ~attrs:[ Style.hud ]
    [ hud_cell ~k:"Source" ~v:"Log.Ring" ()
    ; hud_cell ~k:"Total" ~v:(Printf.sprintf "%d" response.total) ()
    ; hud_cell ~k:"Level" ~v:"INFO+" ()
    ; hud_cell ~v_class:(Some Style.hud_v_ok) ~k:"Refresh" ~v:"poll · 3s" ()
    ; hud_cell ~k:"Limit" ~v:"200" ()
    ; hud_cell ~v_class:(Some Style.hud_v_ok) ~k:"Link" ~v:"fetch · ok" ()
    ]
;;

let render_response (response : Logs_types.response) : Node.t =
  let tape =
    match response.entries with
    | [] ->
      Node.div
        ~attrs:[ Style.empty ]
        [ Node.text "저택은 조용하다. 아무도 아직 말하지 않았다."
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
        [ Node.div ~attrs:[ Style.tape ] rendered
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
          [ Node.span [ Node.text "observatory" ]
          ; Node.span ~attrs:[ Style.crumbs_sep ] [ Node.text "›" ]
          ; Node.span ~attrs:[ Style.crumbs_cur ] [ Node.text "logs · 저널" ]
          ]
      ; Node.div
          ~attrs:[ Style.pulse_slot ]
          [ Node.span ~attrs:[ Style.pulse ] []
          ; Node.span ~attrs:[ Style.pulse_label ] [ Node.text "live · 3s" ]
          ]
      ]
  in
  let toolbar =
    Node.div
      ~attrs:[ Style.toolbar ]
      [ Node.div
          ~attrs:[ Style.chip_group ]
          [ Node.span ~attrs:[ Style.chip ] [ Node.text "debug+" ]
          ; Node.span
              ~attrs:[ Style.chip; Style.chip_active ]
              [ Node.text "info+" ]
          ; Node.span ~attrs:[ Style.chip ] [ Node.text "warn+" ]
          ; Node.span ~attrs:[ Style.chip ] [ Node.text "error" ]
          ]
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
      ; Node.button ~attrs:[ Style.btn_ghost ] [ Node.text "refresh" ]
      ]
  in
  let moonrise =
    Node.div
      ~attrs:[ Style.moonrise ]
      [ Node.span ~attrs:[ Style.moon_glyph ] []
      ; Node.span ~attrs:[ Style.moon_lead ] [ Node.text "the watch is on" ]
      ; Node.span ~attrs:[ Style.moon_sep ] [ Node.text "·" ]
      ; Node.span [ Node.text "lit by a half moon" ]
      ; Node.span ~attrs:[ Style.moon_sep ] [ Node.text "·" ]
      ; Node.span ~attrs:[ Style.moon_mono ] [ Node.text "23:50 local" ]
      ; Node.span ~attrs:[ Style.moon_sep ] [ Node.text "·" ]
      ; Node.span
          ~attrs:[ Style.moon_mono ]
          [ Node.text "base=/tmp/masc-bonsai-dev" ]
      ; Node.span ~attrs:[ Style.moon_tail ] [ Node.text "operator · vincent" ]
      ]
  in
  let nav_section label =
    Node.div ~attrs:[ Style.nav_section ] [ Node.text label ]
  in
  let nav_link ?(active = false) ?tail label =
    let attrs =
      if active
      then [ Style.nav_link; Style.nav_link_active ]
      else [ Style.nav_link ]
    in
    let tail_node =
      match tail with
      | None -> []
      | Some t -> [ Node.span ~attrs:[ Style.nav_link_tail ] [ Node.text t ] ]
    in
    Node.div
      ~attrs
      ([ Node.span ~attrs:[ Style.nav_link_glyph ] []
       ; Node.text label
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
      ; nav_section "chronicle"
      ; nav_link "overview"
      ; nav_link ~active:true "logs · journal"
      ; nav_link "goals"
      ; nav_section "runtime"
      ; nav_link "keepers" ~tail:"04"
      ; nav_link "observatory"
      ; nav_link "intervene"
      ; nav_section "lab"
      ; nav_link "tools"
      ; nav_link "sessions"
      ; nav_link "social board"
      ; nav_section "crypt"
      ; nav_link "dead keepers" ~tail:"00"
      ; nav_link "archive runs"
      ; Node.div
          ~attrs:[ Style.nav_foot ]
          [ Node.text "phase 0 · /b/ · "
          ; Node.span
              ~attrs:[ Style.nav_foot_v ]
              [ Node.text "v0.18-pre" ]
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
  let focus_card =
    Node.div
      ~attrs:[ Style.focus ]
      [ Node.div
          ~attrs:[ Style.focus_who ]
          [ Node.div ~attrs:[ Style.focus_portrait ] [ Node.text "L" ]
          ; Node.div
              ~attrs:[ Style.focus_name_col ]
              [ Node.div ~attrs:[ Style.focus_name ] [ Node.text "Luna" ]
              ; Node.div
                  ~attrs:[ Style.focus_role ]
                  [ Node.text "dungeon master · alchemist" ]
              ]
          ]
      ; Node.div
          ~attrs:[ Style.ctx_bar ]
          [ Node.div
              ~attrs:[ Style.ctx_lbl ]
              [ Node.span [ Node.text "context" ]
              ; Node.span
                  ~attrs:[ Style.ctx_lbl_v ]
                  [ Node.text "64%" ]
              ]
          ; Node.div
              ~attrs:[ Style.vial ]
              [ Node.span ~attrs:[ Style.vial_fill ] [] ]
          ]
      ; Node.div
          ~attrs:[ Style.focus_stats ]
          [ focus_stat "turn" "47 / 60"
          ; focus_stat "heartbeat" "3s"
          ; focus_stat "mem" "128k"
          ; focus_stat "latency" "812ms"
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
                [ Node.text "조용하다 · 경고 없음" ]
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
      ~attrs:[ Style.aside ]
      [ Node.div
          ~attrs:[]
          [ aside_h ~tail:"ctx 64%" "focus · keeper"
          ; focus_card
          ]
      ; Node.div
          ~attrs:[]
          [ aside_h ~tail:evs_tail "chronicle · recent"
          ; evs_stream
          ]
      ]
  in
  Node.div
    ~attrs:[ Style.root ]
    [ nav
    ; brand_row
    ; view_heartbeat ()
    ; view_hud response
    ; (let warn_n =
         List.count response.entries ~f:(fun e ->
           String.equal e.normalized_level "WARN")
       in
       let err_n =
         List.count response.entries ~f:(fun e ->
           String.equal e.normalized_level "ERROR")
       in
       let sub_text =
         match response.entries with
         | [] ->
           "저택은 조용하다. 아무도 아직 말하지 않았고, 폭풍은 아직 문을 두드리지 않았다."
         | _ ->
           Printf.sprintf
             "네 명의 키퍼가 홀을 지킨다. 마지막 %d행을 들었고, 경보 %d · 경고 %d이 울렸다."
             response.total
             err_n
             warn_n
       in
       Node.div
         ~attrs:[ Style.page_head ]
         [ Node.div
             ~attrs:[ Style.page_head_lead ]
             [ Node.div
                 ~attrs:[ Style.page_tag ]
                 [ Node.text "chronicle · quiet fox · day iv" ]
             ; Node.h1
                 ~attrs:[ Style.page_h1 ]
                 [ Node.text "the watch "
                 ; Node.span
                     ~attrs:[ Style.page_h1_blood ]
                     [ Node.text "under storm" ]
                 ]
             ; Node.p ~attrs:[ Style.page_sub ] [ Node.text sub_text ]
             ]
        ; Node.div
            ~attrs:[ Style.page_actions ]
            [ Node.button
                ~attrs:[ Style.pbtn ]
                [ Node.span ~attrs:[ Style.pbtn_glyph ] []
                ; Node.text "preflight"
                ]
            ; Node.button
                ~attrs:[ Style.pbtn; Style.pbtn_primary ]
                [ Node.span ~attrs:[ Style.pbtn_glyph ] []
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
            ; Node.h1
                ~attrs:[ Style.title ]
                [ Node.span ~attrs:[ Style.versal ] [ Node.text "J" ]
                ; Node.span ~attrs:[ Style.title_rest ] [ Node.text "ournal" ]
                ; Node.span ~attrs:[ Style.title_rule ] []
                ; Node.span
                    ~attrs:[ Style.folio ]
                    [ Node.text "folio xii · recto" ]
                ]
            ]
        ; Node.span
            ~attrs:[ Style.meta ]
            [ Node.text (Printf.sprintf "seq up to %d" response.total) ]
        ]
    ; tape
    ; view_roster ()
    ; Node.div ~attrs:[ Style.signet ] [ Node.text "M" ]
    ; aside
    ]
;;

let component (_graph @ local) =
  Bonsai.map (Bonsai.Expert.Var.value Logs_var.var) ~f:render_response
;;
