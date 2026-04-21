(** Shared Bonsai shell for [/dashboard/b/*].

    This ports the Dashboard v2 design-system chrome into one Bonsai
    component: topbar, glyph-lit nav, HUD strip, main scroll area, and right
    observatory aside. Route views should provide only their page body. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .shell {
    position: relative;
    z-index: 1;
    display: grid;
    grid-template-columns: 220px minmax(0, 1fr) 340px;
    grid-template-rows: 52px 1fr;
    min-height: 100vh;
    color: var(--text-primary);
    background:
      radial-gradient(ellipse 60% 40% at 12% 8%, rgba(212,169,64,0.06), transparent 55%),
      radial-gradient(ellipse 40% 50% at 92% 95%, rgba(160,24,24,0.08), transparent 60%),
      linear-gradient(170deg, #0e0a08 0%, #140c08 60%, #080504 100%);
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
  }

  .topbar {
    grid-column: 1 / -1;
    display: flex;
    align-items: center;
    gap: 18px;
    padding: 0 22px;
    background: linear-gradient(180deg, #1a140e, #120b08);
    border-bottom: 1px solid var(--border-highlight);
    box-shadow: 0 2px 0 rgba(0,0,0,0.4), inset 0 -1px 0 rgba(212,169,64,0.12);
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
  }

  .brand_mark {
    width: 22px;
    height: 22px;
    border: 1px solid var(--accent-brass-dim);
    color: var(--accent-brass);
    display: grid;
    place-items: center;
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 12px;
    line-height: 1;
    transform: rotate(45deg);
  }

  .brand_mark > span { transform: rotate(-45deg); }

  .wordmark {
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 14px;
    letter-spacing: 0.28em;
    color: var(--text-bright);
    text-transform: uppercase;
  }

  .blood {
    color: var(--accent-blood);
    text-shadow: 0 0 18px var(--accent-blood-glow);
  }

  .crumbs {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
    color: var(--text-dim);
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 10px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    overflow: hidden;
    white-space: nowrap;
  }

  .crumbs_current {
    color: var(--accent-brass);
  }

  .sep { color: var(--border-highlight); }

  .top_right {
    margin-left: auto;
    display: flex;
    gap: 10px;
    align-items: center;
    flex-shrink: 0;
  }

  .clock {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 12px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
    letter-spacing: 0.08em;
  }

  .clock b {
    color: var(--text-bright);
    font-weight: 400;
  }

  .pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 9px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    padding: 4px 8px;
    border: 1px solid var(--border-main);
    color: var(--text-primary);
    background: #14100a;
    white-space: nowrap;
  }

  .pill_ok {
    color: var(--status-ok);
    border-color: color-mix(in oklab, var(--status-ok) 40%, transparent);
  }

  .pill_warn {
    color: var(--accent-brass);
    border-color: color-mix(in oklab, var(--accent-brass) 40%, transparent);
  }

  .pill_bad {
    color: var(--accent-blood);
    border-color: color-mix(in oklab, var(--accent-blood) 50%, transparent);
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: currentColor;
    box-shadow: 0 0 6px currentColor;
  }

  .nav {
    background: linear-gradient(180deg, #18110c, #0e0806);
    border-right: 1px solid var(--border-main);
    padding: 16px 0;
    display: flex;
    flex-direction: column;
    overflow: auto;
  }

  .nav_section {
    padding: 14px 18px 6px;
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
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
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    text-decoration: none;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    border-left: 2px solid transparent;
    position: relative;
  }

  .nav_link:hover {
    color: var(--accent-brass);
    background: rgba(212,169,64,0.05);
  }

  .nav_link_active {
    color: var(--accent-brass);
    border-left-color: var(--accent-brass);
    background: linear-gradient(90deg, rgba(212,169,64,0.1), transparent 70%);
  }

  .nav_link_active::after {
    content: "";
    position: absolute;
    right: 12px;
    top: 50%;
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: var(--accent-brass);
    box-shadow: 0 0 8px var(--accent-brass);
    transform: translateY(-50%);
  }

  .nav_link_soon {
    color: var(--text-dim);
    opacity: 0.62;
  }

  .nav_glyph {
    width: 14px;
    height: 14px;
    border: 1px solid currentColor;
    opacity: 0.55;
    transform: rotate(45deg);
    flex-shrink: 0;
  }

  .nav_link_active .nav_glyph {
    opacity: 1;
    box-shadow: 0 0 8px var(--accent-glow);
  }

  .tail {
    margin-left: auto;
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 10px;
    color: var(--accent-blood);
  }

  .main {
    min-width: 0;
    overflow: auto;
  }

  .hud {
    display: grid;
    grid-template-columns: repeat(6, minmax(0, 1fr));
    background: linear-gradient(180deg, #1a140e, #140d08);
    border-bottom: 1px solid var(--border-highlight);
  }

  .hud_cell {
    padding: 10px 14px;
    border-right: 1px solid var(--border-main);
    position: relative;
    min-width: 0;
  }

  .hud_cell:last-child { border-right: 0; }

  .hud_k {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 9px;
    letter-spacing: 0.28em;
    text-transform: uppercase;
    color: var(--text-dim);
  }

  .hud_v {
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 13px;
    letter-spacing: 0.14em;
    color: var(--text-bright);
    margin-top: 3px;
    text-transform: uppercase;
    font-variant-numeric: tabular-nums;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .hud_ok { color: var(--status-ok); }
  .hud_warn { color: var(--accent-brass); }
  .hud_bad { color: var(--accent-blood); }

  .page {
    padding: 22px 28px 60px;
    display: flex;
    flex-direction: column;
    gap: 22px;
  }

  .aside {
    background: linear-gradient(180deg, #16100a, #0e0806);
    border-left: 1px solid var(--border-main);
    padding: 18px 18px 30px;
    overflow: auto;
    display: flex;
    flex-direction: column;
    gap: 22px;
  }

  .aside_title {
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 11px;
    letter-spacing: 0.28em;
    color: var(--accent-brass);
    text-transform: uppercase;
    margin: 0 0 10px;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .aside_title::after {
    content: "";
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--border-highlight), transparent);
  }

  .aside_title .r {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 10px;
    color: var(--text-dim);
    margin-left: auto;
    font-variant-numeric: tabular-nums;
    letter-spacing: 0.04em;
    text-transform: none;
  }

  .focus {
    position: relative;
    padding: 16px 16px 14px;
    background: linear-gradient(180deg, #241a12, #14100a);
    border: 1px solid var(--accent-brass-dim);
  }

  .focus::before {
    content: "";
    position: absolute;
    inset: 3px;
    border: 1px solid var(--border-highlight);
    pointer-events: none;
  }

  .focus_inner {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .focus_row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .portrait {
    width: 46px;
    height: 46px;
    border: 1px solid var(--accent-brass);
    display: grid;
    place-items: center;
    color: var(--accent-brass);
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 20px;
    background:
      radial-gradient(circle at 35% 25%, rgba(212,169,64,0.16), transparent 38%),
      linear-gradient(180deg, #241a12, #100a07);
  }

  .focus_name {
    font-family: var(--font-display, 'Cinzel', serif);
    font-size: 16px;
    color: var(--accent-brass);
    letter-spacing: 0.16em;
    text-transform: uppercase;
  }

  .focus_role {
    font-family: var(--font-body, 'EB Garamond', serif);
    font-style: italic;
    font-size: 11px;
    color: var(--text-dim);
    margin-top: 2px;
  }

  .vial_lbl {
    display: flex;
    justify-content: space-between;
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 10px;
    color: var(--text-dim);
    margin-bottom: 4px;
    font-variant-numeric: tabular-nums;
  }

  .vial_lbl b {
    color: var(--text-bright);
    font-weight: 400;
  }

  .vial {
    height: 8px;
    background: #0a0604;
    border: 1px solid var(--border-main);
    position: relative;
    overflow: hidden;
  }

  .vial > span {
    display: block;
    height: 100%;
    width: 62%;
    background: linear-gradient(90deg, #3d6a28, #6a9a44);
    box-shadow: 0 0 6px rgba(106,154,68,0.35);
  }

  .vial::after {
    content: "";
    position: absolute;
    inset: 0;
    background-image: repeating-linear-gradient(90deg, transparent 0 19px, rgba(0,0,0,0.5) 19px 20px);
    pointer-events: none;
  }

  .stats {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 8px 14px;
  }

  .stat_l {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 9px;
    letter-spacing: 0.22em;
    color: var(--text-dim);
    text-transform: uppercase;
  }

  .stat_v {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 12px;
    color: var(--text-bright);
    margin-top: 2px;
    font-variant-numeric: tabular-nums;
  }

  .flame {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 10px;
    color: var(--text-bright);
    border: 1px solid rgba(120,100,80,0.14);
    background: #0c0806;
    padding: 1px;
  }

  .flame_row {
    display: flex;
    height: 16px;
    gap: 1px;
    margin-bottom: 1px;
  }

  .flame_row:last-child { margin-bottom: 0; }

  .flame_block {
    padding: 0 5px;
    display: flex;
    align-items: center;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    background: #2a2838;
    color: #b8c0e0;
  }

  .flame_plan { background: #2a3a2a; color: #c4dcb0; }
  .flame_exec { background: #3a2a2a; color: #e4b8b0; }
  .flame_wait { background: #1a1410; color: var(--text-dim); }
  .flame_err { background: #3a1010; color: #e0b8a8; }

  .events {
    display: flex;
    flex-direction: column;
  }

  .event {
    display: grid;
    grid-template-columns: 56px 14px 1fr;
    gap: 10px;
    padding: 8px 0;
    border-bottom: 1px dashed var(--border-main);
    align-items: baseline;
  }

  .event:last-child { border-bottom: 0; }

  .event_time {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 10px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }

  .event_mark {
    width: 10px;
    height: 10px;
    border: 1px solid var(--accent-brass-dim);
    transform: rotate(45deg);
  }

  .event_bad { border-color: var(--accent-blood); box-shadow: 0 0 5px var(--accent-blood-glow); }
  .event_ok { border-color: var(--status-ok); }

  .event_body {
    font-family: var(--font-body, 'EB Garamond', serif);
    font-size: 12px;
    color: var(--text-primary);
    line-height: 1.45;
  }

  .event_body code {
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 10px;
    color: var(--accent-brass);
    background: rgba(212,169,64,0.08);
    padding: 0 5px;
    border: 1px solid var(--border-main);
  }

  @media (max-width: 1180px) {
    .shell {
      grid-template-columns: 200px minmax(0, 1fr);
    }
    .aside {
      display: none;
    }
  }

  @media (max-width: 760px) {
    .shell {
      grid-template-columns: 1fr;
      grid-template-rows: auto auto 1fr;
    }
    .topbar {
      min-height: 52px;
      flex-wrap: wrap;
      padding: 10px 14px;
    }
    .nav {
      grid-row: 2;
      flex-direction: row;
      overflow-x: auto;
      border-right: 0;
      border-bottom: 1px solid var(--border-main);
      padding: 6px 0;
    }
    .nav_section {
      display: none;
    }
    .nav_link {
      flex: 0 0 auto;
      border-left: 0;
      border-bottom: 2px solid transparent;
      padding: 8px 12px;
    }
    .nav_link_active {
      border-bottom-color: var(--accent-brass);
    }
    .nav_link_active::after {
      display: none;
    }
    .main {
      grid-row: 3;
    }
    .hud {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .page {
      padding: 18px 16px 44px;
    }
  }
|}]

type tone =
  [ `Neutral
  | `Ok
  | `Warn
  | `Bad
  ]

let label (route : Route.t) = Route.label route

let section text =
  Node.div ~attrs:[ Style.nav_section ] [ Node.text text ]
;;

let route_tail = function
  | Route.Dead_keepers -> Some "03"
  | Keepers -> Some "IV"
  | Goals -> Some "07"
  | _ -> None
;;

let nav_link ~(active : Route.t) (route : Route.t) =
  let attrs =
    let base = [ Style.nav_link ] in
    let base = if Route.equal active route then Style.nav_link_active :: base else base in
    let base =
      if Route.is_implemented route then base else Style.nav_link_soon :: base
    in
    Attr.href (Route.path route) :: base
  in
  let tail =
    match route_tail route with
    | Some text -> [ Node.span ~attrs:[ Style.tail ] [ Node.text text ] ]
    | None -> []
  in
  Node.a
    ~attrs
    ([ Node.span ~attrs:[ Style.nav_glyph ] []
     ; Node.text (label route)
     ]
     @ tail)
;;

let nav ~(active : Route.t) =
  let lnk = nav_link ~active in
  Node.div
    ~attrs:[ Style.nav ]
    [ section "watch"
    ; lnk Overview
    ; lnk Logs
    ; lnk Goals
    ; section "runtime"
    ; lnk Keepers
    ; lnk Observatory
    ; lnk Intervene
    ; section "lab"
    ; lnk Tools
    ; lnk Sessions
    ; lnk Social_board
    ; section "crypt"
    ; lnk Dead_keepers
    ; lnk Archive_runs
    ]
;;

let pill ?(tone : tone = `Neutral) text =
  let attrs =
    match tone with
    | `Neutral -> [ Style.pill ]
    | `Ok -> [ Style.pill; Style.pill_ok ]
    | `Warn -> [ Style.pill; Style.pill_warn ]
    | `Bad -> [ Style.pill; Style.pill_bad ]
  in
  Node.span
    ~attrs
    [ Node.span ~attrs:[ Style.dot ] []
    ; Node.text text
    ]
;;

let topbar ~(active : Route.t) =
  Node.div
    ~attrs:[ Style.topbar ]
    [ Node.div
        ~attrs:[ Style.brand ]
        [ Node.div ~attrs:[ Style.brand_mark ] [ Node.span [ Node.text "M" ] ]
        ; Node.span
            ~attrs:[ Style.wordmark ]
            [ Node.text "MA"
            ; Node.span ~attrs:[ Style.blood ] [ Node.text "S" ]
            ; Node.text "C"
            ]
        ]
    ; Node.div
        ~attrs:[ Style.crumbs ]
        [ Node.span [ Node.text "Runtime" ]
        ; Node.span ~attrs:[ Style.sep ] [ Node.text "." ]
        ; Node.span [ Node.text "runtime bonsai" ]
        ; Node.span ~attrs:[ Style.sep ] [ Node.text "." ]
        ; Node.strong ~attrs:[ Style.crumbs_current ] [ Node.text (label active) ]
        ]
    ; Node.div
        ~attrs:[ Style.top_right ]
        [ Node.span
            ~attrs:[ Style.clock ]
            [ Node.text "Bonsai "
            ; Node.b [ Node.text "preview" ]
            ]
        ; pill ~tone:`Ok "sse live"
        ; pill "operator"
        ]
    ]
;;

let hud_cell ?(tone : tone = `Neutral) ~k ~v () =
  let v_attrs =
    match tone with
    | `Neutral -> [ Style.hud_v ]
    | `Ok -> [ Style.hud_v; Style.hud_ok ]
    | `Warn -> [ Style.hud_v; Style.hud_warn ]
    | `Bad -> [ Style.hud_v; Style.hud_bad ]
  in
  Node.div
    ~attrs:[ Style.hud_cell ]
    [ Node.div ~attrs:[ Style.hud_k ] [ Node.text k ]
    ; Node.div ~attrs:v_attrs [ Node.text v ]
    ]
;;

let default_hud ~(active : Route.t) =
  [ hud_cell ~k:"Runtime" ~v:"local" ()
  ; hud_cell ~tone:`Ok ~k:"Snapshot" ~v:"running" ()
  ; hud_cell ~k:"Surface" ~v:"bonsai" ()
  ; hud_cell ~tone:`Warn ~k:"Route" ~v:(label active) ()
  ; hud_cell ~k:"Base" ~v:"/dashboard/b" ()
  ; hud_cell ~tone:`Ok ~k:"Build" ~v:"js_of_ocaml" ()
  ]
;;

let hhmmss_of_iso ts =
  if String.length ts >= 19 then String.sub ts ~pos:11 ~len:8 else ts
;;

let short_commit c =
  if String.length c > 9 then String.sub c ~pos:0 ~len:9 else c
;;

let short_base path =
  if String.is_empty path then "—" else Filename.basename path
;;

let aside_title ?right text =
  Node.h4
    ~attrs:[ Style.aside_title ]
    ([ Node.text text ]
     @
     match right with
     | Some r -> [ Node.span ~attrs:[ Style.r ] [ Node.text r ] ]
     | None -> [])
;;

let focus_card ~(shell : Overview_types.response) ~(active : Route.t) =
  let project =
    if String.is_empty shell.status.project then "runtime" else shell.status.project
  in
  let cluster =
    if String.is_empty shell.status.cluster then "default" else shell.status.cluster
  in
  let portrait =
    let seed =
      if String.is_empty project then label active else project
    in
    Char.to_string (Char.uppercase seed.[0])
  in
  let snapshot_right =
    match shell.generated_at with
    | "" -> "shell pending"
    | ts -> Printf.sprintf "%s UTC" (hhmmss_of_iso ts)
  in
  let focus_role = Printf.sprintf "%s · %s" project cluster in
  let focus_meter_label, focus_pct, focus_detail =
    if shell.configured_keepers > 0
    then
      ( "Fleet"
      , Int.min 100 ((shell.counts.keepers * 100) / shell.configured_keepers)
      , Printf.sprintf
          " . %d / %d keepers"
          shell.counts.keepers
          shell.configured_keepers )
    else if String.is_empty shell.generated_at
    then "Snapshot", 0, " . pending"
    else "Snapshot", 100, " . ready"
  in
  let vial_style =
    Attr.style
      (Css_gen.create
         ~field:"width"
         ~value:(Printf.sprintf "%d%%" focus_pct))
  in
  let build_v =
    if not (String.is_empty shell.status.build.release_version)
    then shell.status.build.release_version
    else if not (String.is_empty shell.status.build.commit)
    then short_commit shell.status.build.commit
    else "—"
  in
  Node.div
    [ aside_title ~right:snapshot_right "Focus"
    ; Node.div
        ~attrs:[ Style.focus ]
        [ Node.div
            ~attrs:[ Style.focus_inner ]
            [ Node.div
                ~attrs:[ Style.focus_row ]
                [ Node.div ~attrs:[ Style.portrait ] [ Node.text portrait ]
                ; Node.div
                    [ Node.div ~attrs:[ Style.focus_name ] [ Node.text (label active) ]
                    ; Node.div
                        ~attrs:[ Style.focus_role ]
                        [ Node.text focus_role ]
                    ]
                ]
            ; Node.div
                [ Node.div
                    ~attrs:[ Style.vial_lbl ]
                    [ Node.span [ Node.text focus_meter_label ]
                    ; Node.span
                        [ Node.b [ Node.text (Printf.sprintf "%d%%" focus_pct) ]
                        ; Node.text focus_detail
                        ]
                    ]
                ; Node.div ~attrs:[ Style.vial ] [ Node.span ~attrs:[ vial_style ] [] ]
                ]
            ; Node.div
                ~attrs:[ Style.stats ]
                [ Node.div
                    [ Node.div ~attrs:[ Style.stat_l ] [ Node.text "Agents" ]
                    ; Node.div
                        ~attrs:[ Style.stat_v ]
                        [ Node.text (Printf.sprintf "%d" shell.counts.agents) ]
                    ]
                ; Node.div
                    [ Node.div ~attrs:[ Style.stat_l ] [ Node.text "Tasks" ]
                    ; Node.div
                        ~attrs:[ Style.stat_v ]
                        [ Node.text (Printf.sprintf "%d" shell.counts.tasks) ]
                    ]
                ; Node.div
                    [ Node.div ~attrs:[ Style.stat_l ] [ Node.text "Build" ]
                    ; Node.div ~attrs:[ Style.stat_v ] [ Node.text build_v ]
                    ]
                ; Node.div
                    [ Node.div ~attrs:[ Style.stat_l ] [ Node.text "Base" ]
                    ; Node.div
                        ~attrs:[ Style.stat_v ]
                        [ Node.text (short_base shell.base_path) ]
                    ]
                ]
            ]
        ]
    ]
;;

let flame_block ?(cls = Style.flame_block) ~flex text =
  Node.div
    ~attrs:
      [ cls
      ; Attr.style
          (Css_gen.create
             ~field:"flex-grow"
             ~value:(Float.to_string flex))
      ]
    [ Node.text text ]
;;

let flame () =
  Node.div
    [ aside_title ~right:"2.40s" "Last turn"
    ; Node.div
        ~attrs:[ Style.flame ]
        [ Node.div
            ~attrs:[ Style.flame_row ]
            [ flame_block ~flex:240. "bonsai.shell()" ]
        ; Node.div
            ~attrs:[ Style.flame_row ]
            [ flame_block ~cls:Style.flame_plan ~flex:40. "plan"
            ; flame_block ~cls:Style.flame_exec ~flex:160. "absorb"
            ; flame_block ~flex:40. "reflect"
            ]
        ; Node.div
            ~attrs:[ Style.flame_row ]
            [ flame_block ~cls:Style.flame_wait ~flex:40. "route"
            ; flame_block ~flex:70. "topbar"
            ; flame_block ~cls:Style.flame_exec ~flex:60. "nav"
            ; flame_block ~cls:Style.flame_err ~flex:30. "aside"
            ; flame_block ~cls:Style.flame_wait ~flex:40. "hud"
            ]
        ]
    ]
;;

let watch_feed () =
  let event ?(tone : tone = `Neutral) time body =
    let mark_attrs =
      match tone with
      | `Ok -> [ Style.event_mark; Style.event_ok ]
      | `Bad -> [ Style.event_mark; Style.event_bad ]
      | _ -> [ Style.event_mark ]
    in
    Node.div
      ~attrs:[ Style.event ]
      [ Node.span ~attrs:[ Style.event_time ] [ Node.text time ]
      ; Node.span ~attrs:mark_attrs []
      ; Node.span ~attrs:[ Style.event_body ] body
      ]
  in
  Node.div
    [ aside_title ~right:"live" "Watch"
    ; Node.div
        ~attrs:[ Style.events ]
        [ event ~tone:`Ok "now"
            [ Node.code [ Node.text "shell" ]
            ; Node.text " . dashboard_v2 chrome mounted."
            ]
        ; event "t-01"
            [ Node.text "Route body keeps its own projection and data fetch." ]
        ; event ~tone:`Bad "t-02"
            [ Node.text "Old two-column placeholder shell retired from active tabs." ]
        ; event "t-03"
            [ Node.text "Design tokens loaded from "
            ; Node.code [ Node.text "colors_and_type.css" ]
            ; Node.text "."
            ]
        ]
    ]
;;

let default_aside ~(shell : Overview_types.response) ~(active : Route.t) =
  Node.div
    ~attrs:[ Style.aside ]
    [ focus_card ~shell ~active
    ; flame ()
    ; watch_feed ()
    ]
;;

let view ?(shell = Overview_types.fixture) ?hud ?aside ~(active : Route.t) (children : Node.t list) =
  let hud_nodes =
    match hud with
    | Some nodes -> nodes
    | None -> default_hud ~active
  in
  let aside_node =
    match aside with
    | Some node -> node
    | None -> default_aside ~shell ~active
  in
  Node.div
    ~attrs:[ Style.shell ]
    [ topbar ~active
    ; nav ~active
    ; Node.div
        ~attrs:[ Style.main ]
        [ Node.div ~attrs:[ Style.hud ] hud_nodes
        ; Node.div ~attrs:[ Style.page ] children
        ]
    ; aside_node
    ]
;;
