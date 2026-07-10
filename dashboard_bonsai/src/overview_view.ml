(** Overview view — project vitals.

    Phase 2.C 다섯 번째 탭. design_v2 IA의 "overview · at a glance"
    섹션. shell endpoint의 부분집합을 3 블록으로 배치:

    1. Hero: project · cluster · base_path
    2. Build strip: version + commit + uptime
    3. Fleet counts: agents / tasks / keepers (+configured)

    [`/api/v1/dashboard/shell`] 5s 폴링. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 14px;
  }

  .panel {
    border: 1px solid var(--color-border-default);
    background: linear-gradient(180deg, color-mix(in oklab, var(--color-bg-surface) 70%, transparent), color-mix(in oklab, var(--color-bg-page) 85%, transparent));
    padding: 18px 20px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .panel_title {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.25em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    margin: 0;
  }

  .kv_row {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .kv {
    display: grid;
    grid-template-columns: 120px 1fr;
    gap: 14px;
    align-items: baseline;
  }
  .k {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }
  .v {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 13px;
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .v_dim { color: var(--color-fg-muted); }
  .v_brass { color: var(--color-accent-fg); }
  .v_ok { color: var(--color-status-ok); }
  .v_warn { color: var(--color-status-warn); }

  .counts {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 10px;
  }
  .count_cell {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 14px;
    background: color-mix(in oklab, var(--color-bg-page) 40%, transparent);
    border: 1px solid var(--color-border-default);
    text-align: center;
  }
  .count_k {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }
  .count_v {
    font-family: 'Cinzel', serif;
    font-size: 32px;
    letter-spacing: 0.05em;
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
  }

  @media (max-width: 920px) {
    .grid { grid-template-columns: 1fr; }
    .panel { min-width: 0; }
    .kv { grid-template-columns: 96px minmax(0, 1fr); }
    .counts { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .count_cell { padding: 12px 8px; }
    .count_v { font-size: 28px; }
  }

  @media (prefers-contrast: more) {
    .panel { border-width: 2px; border-color: var(--text-bright); }
    .panel_title { color: var(--text-bright); }
    .k { color: var(--text-bright); }
    .count_k { color: var(--text-bright); }
    .count_cell { border-width: 2px; border-color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .v_ok  { color: Highlight; }
    .v_warn { color: Mark; }
  }
|}]

let hms_of_seconds total =
  let s = total mod 60 in
  let m = (total / 60) mod 60 in
  let h = total / 3600 in
  if h > 0 then Printf.sprintf "%dh %dm" h m
  else if m > 0 then Printf.sprintf "%dm %ds" m s
  else Printf.sprintf "%ds" s
;;

let short_commit c =
  if String.length c > 9 then String.sub c ~pos:0 ~len:9 else c
;;

let paused_pill ~(paused : bool) =
  if paused
  then Node.span ~attrs:[ Style.v; Style.v_warn ] [ Node.text "paused" ]
  else Node.span ~attrs:[ Style.v; Style.v_ok ] [ Node.text "live" ]
;;

let view_hero_panel (r : Overview_types.response) =
  let s = r.status in
  Node.div
    ~attrs:[ Style.panel; Attr.role "group"; Attr.create "aria-label" "Runtime identity panel" ]
    [ Node.h2 ~attrs:[ Style.panel_title ] [ Node.text "runtime · identity" ]
    ; Node.div
        ~attrs:[ Style.kv_row; Attr.role "list"; Attr.create "aria-label" "Runtime identity" ]
        [ Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "project" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_brass ]
                [ Node.text (if String.is_empty s.project then "—" else s.project) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "cluster" ]
            ; Node.div
                ~attrs:[ Style.v ]
                [ Node.text (if String.is_empty s.cluster then "—" else s.cluster) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "base path" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_dim ]
                [ Node.text (if String.is_empty r.base_path then "—" else r.base_path) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "status" ]
            ; paused_pill ~paused:s.paused
            ]
        ; Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "tempo" ]
            ; Node.div
                ~attrs:[ Style.v ]
                [ Node.text
                    (Printf.sprintf
                       "%.0fs interval"
                       s.tempo_interval_s)
                ]
            ]
        ]
    ]
;;

let view_build_panel (r : Overview_types.response) =
  let b = r.status.build in
  Node.div
    ~attrs:[ Style.panel; Attr.role "group"; Attr.create "aria-label" "Build release panel" ]
    [ Node.h2 ~attrs:[ Style.panel_title ] [ Node.text "build · release" ]
    ; Node.div
        ~attrs:[ Style.kv_row; Attr.role "list"; Attr.create "aria-label" "Build and release" ]
        [ Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "version" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_brass ]
                [ Node.text
                    (if String.is_empty b.release_version
                     then r.status.version
                     else b.release_version)
                ]
            ]
        ; Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "commit" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_dim ]
                [ Node.text (short_commit b.commit) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "uptime" ]
            ; Node.div
                ~attrs:[ Style.v ]
                [ Node.text (hms_of_seconds b.uptime_seconds) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv; Attr.role "listitem" ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "started" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_dim ]
                [ Node.text
                    (if String.is_empty b.started_at then "—" else b.started_at)
                ]
            ]
        ]
    ]
;;

let view_counts_panel (r : Overview_types.response) =
  let c = r.counts in
  let keeper_label =
    if r.configured_keepers <= 0
    then Printf.sprintf "%d" c.keepers
    else Printf.sprintf "%d / %d" c.keepers r.configured_keepers
  in
  Node.div
    ~attrs:[ Style.panel; Attr.role "group"; Attr.create "aria-label" "Fleet counts panel" ]
    [ Node.h2 ~attrs:[ Style.panel_title ] [ Node.text "fleet · counts" ]
    ; Node.div
        ~attrs:[ Style.counts ]
        [ Node.div
            ~attrs:[ Style.count_cell; Attr.create "aria-label" ("keepers: " ^ keeper_label) ]
            [ Node.div ~attrs:[ Style.count_k ] [ Node.text "keepers" ]
            ; Node.div
                ~attrs:[ Style.count_v ]
                [ Node.text keeper_label ]
            ]
        ; Node.div
            ~attrs:[ Style.count_cell; Attr.create "aria-label" ("tasks: " ^ Printf.sprintf "%d" c.tasks) ]
            [ Node.div ~attrs:[ Style.count_k ] [ Node.text "tasks" ]
            ; Node.div
                ~attrs:[ Style.count_v ]
                [ Node.text (Printf.sprintf "%d" c.tasks) ]
            ]
        ; Node.div
            ~attrs:[ Style.count_cell; Attr.create "aria-label" ("agents: " ^ Printf.sprintf "%d" c.agents) ]
            [ Node.div ~attrs:[ Style.count_k ] [ Node.text "agents" ]
            ; Node.div
                ~attrs:[ Style.count_v ]
                [ Node.text (Printf.sprintf "%d" c.agents) ]
            ]
        ]
    ]
;;

let render (r : Overview_types.response) : Node.t =
  Shell_view.view
    ~shell:r
    ~active:Overview
    [ Hero.view
        ~eyebrow:"overview · at a glance"
        ~title:"overview"
        ~tail:(Printf.sprintf "· %s" r.status.cluster, `Brass)
        ~sub:
          "runtime snapshot — identity, build, fleet counts. \
           shell endpoint의 압축 projection으로, \
           깊은 진단은 각 tab에서 확인."
        ~sub_lang:"ko"
        ()
    ; Node.div
        ~attrs:[ Style.grid; Attr.role "region"; Attr.create "aria-label" "Overview panels" ]
        [ view_hero_panel r
        ; view_build_panel r
        ; view_counts_panel r
        ]
    ]
;;

let component (_graph @ local) =
  Bonsai.map (Bonsai.Expert.Var.value Overview_var.var) ~f:render
;;
