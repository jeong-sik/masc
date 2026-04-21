(** Overview view — project vitals + stagnation.

    Phase 2.C 다섯 번째 탭. design_v2 IA의 "overview · at a glance"
    섹션. shell endpoint의 부분집합을 4 블록으로 배치:

    1. Hero: project · cluster · base_path
    2. Build strip: version + commit + uptime
    3. Fleet counts: agents / tasks / keepers (+configured)
    4. Meta-cognition: stagnation score + dominant belief

    [`/api/v1/dashboard/shell`] 5s 폴링. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .root {
    display: grid;
    grid-template-columns: 232px 1fr;
    min-height: 100vh;
    background:
      radial-gradient(ellipse 60% 40% at 12% 8%, rgba(138,106,40,0.06), transparent 55%),
      radial-gradient(ellipse 40% 50% at 92% 95%, rgba(58,58,90,0.06), transparent 60%),
      linear-gradient(170deg, #0e0a08 0%, #140c08 60%, #080504 100%);
    color: var(--text-primary);
    font-family: 'Noto Sans KR', 'EB Garamond', sans-serif;
  }

  .main {
    padding: 3rem 3rem 2rem;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    overflow: auto;
  }

  .eyebrow {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 10px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
    margin: 0;
  }

  .title {
    font-family: 'Cinzel', serif;
    font-size: 32px;
    letter-spacing: 0.16em;
    color: var(--text-bright);
    text-transform: uppercase;
    margin: 0;
  }
  .title_brass { color: var(--accent-brass); }

  .sub {
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-primary);
    margin: 0;
    max-width: 680px;
  }

  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 14px;
  }

  .panel {
    border: 1px solid var(--border-main);
    background: linear-gradient(180deg, rgba(28,18,14,0.7), rgba(14,10,8,0.85));
    padding: 18px 20px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .panel_title {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 10px;
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--text-dim);
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
    font-size: 10px;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--text-dim);
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
  .v_dim { color: var(--text-dim); }
  .v_brass { color: var(--accent-brass); }
  .v_ok { color: var(--status-ok); }
  .v_warn { color: var(--status-warn); }
  .v_bad { color: var(--accent-blood); }

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
    background: rgba(14,10,8,0.4);
    border: 1px solid var(--border-main);
    text-align: center;
  }
  .count_k {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 9px;
    letter-spacing: 0.28em;
    text-transform: uppercase;
    color: var(--text-dim);
  }
  .count_v {
    font-family: 'Cinzel', serif;
    font-size: 32px;
    letter-spacing: 0.05em;
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
  }

  .stag_bar {
    height: 6px;
    background: rgba(138,106,40,0.15);
    position: relative;
    margin-top: 6px;
  }
  .stag_fill {
    position: absolute;
    left: 0; top: 0; bottom: 0;
    background: var(--accent-brass);
  }
  .stag_fill_warn { background: var(--status-warn); }
  .stag_fill_bad { background: var(--accent-blood); }

  .belief {
    padding: 12px 14px;
    border: 1px dashed var(--border-main);
    font-family: 'EB Garamond', serif;
    font-size: 14px;
    color: var(--text-primary);
    font-style: italic;
  }
  .belief_tag {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 10px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--accent-brass);
    margin-right: 10px;
  }

  .empty {
    padding: 32px 16px;
    text-align: center;
    font-family: 'EB Garamond', serif;
    font-style: italic;
    color: var(--text-dim);
    border: 1px dashed var(--border-main);
  }

  @media (max-width: 920px) {
    .grid { grid-template-columns: 1fr; }
    .panel { min-width: 0; }
    .kv { grid-template-columns: 96px minmax(0, 1fr); }
    .counts { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .count_cell { padding: 12px 8px; }
    .count_v { font-size: 28px; }
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

let stag_color (score : float) =
  if Float.(score >= 0.75) then Style.stag_fill_bad
  else if Float.(score >= 0.5) then Style.stag_fill_warn
  else Style.stag_fill
;;

let paused_pill ~(paused : bool) =
  if paused
  then Node.span ~attrs:[ Style.v; Style.v_warn ] [ Node.text "paused" ]
  else Node.span ~attrs:[ Style.v; Style.v_ok ] [ Node.text "live" ]
;;

let view_hero_panel (r : Overview_types.response) =
  let s = r.status in
  Node.div
    ~attrs:[ Style.panel ]
    [ Node.p ~attrs:[ Style.panel_title ] [ Node.text "runtime · identity" ]
    ; Node.div
        ~attrs:[ Style.kv_row ]
        [ Node.div
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "project" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_brass ]
                [ Node.text (if String.is_empty s.project then "—" else s.project) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "cluster" ]
            ; Node.div
                ~attrs:[ Style.v ]
                [ Node.text (if String.is_empty s.cluster then "—" else s.cluster) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "base path" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_dim ]
                [ Node.text (if String.is_empty r.base_path then "—" else r.base_path) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "status" ]
            ; paused_pill ~paused:s.paused
            ]
        ; Node.div
            ~attrs:[ Style.kv ]
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
    ~attrs:[ Style.panel ]
    [ Node.p ~attrs:[ Style.panel_title ] [ Node.text "build · release" ]
    ; Node.div
        ~attrs:[ Style.kv_row ]
        [ Node.div
            ~attrs:[ Style.kv ]
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
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "commit" ]
            ; Node.div
                ~attrs:[ Style.v; Style.v_dim ]
                [ Node.text (short_commit b.commit) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "uptime" ]
            ; Node.div
                ~attrs:[ Style.v ]
                [ Node.text (hms_of_seconds b.uptime_seconds) ]
            ]
        ; Node.div
            ~attrs:[ Style.kv ]
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
    ~attrs:[ Style.panel ]
    [ Node.p ~attrs:[ Style.panel_title ] [ Node.text "fleet · counts" ]
    ; Node.div
        ~attrs:[ Style.counts ]
        [ Node.div
            ~attrs:[ Style.count_cell ]
            [ Node.div ~attrs:[ Style.count_k ] [ Node.text "keepers" ]
            ; Node.div
                ~attrs:[ Style.count_v ]
                [ Node.text keeper_label ]
            ]
        ; Node.div
            ~attrs:[ Style.count_cell ]
            [ Node.div ~attrs:[ Style.count_k ] [ Node.text "tasks" ]
            ; Node.div
                ~attrs:[ Style.count_v ]
                [ Node.text (Printf.sprintf "%d" c.tasks) ]
            ]
        ; Node.div
            ~attrs:[ Style.count_cell ]
            [ Node.div ~attrs:[ Style.count_k ] [ Node.text "agents" ]
            ; Node.div
                ~attrs:[ Style.count_v ]
                [ Node.text (Printf.sprintf "%d" c.agents) ]
            ]
        ]
    ]
;;

let view_meta_panel (r : Overview_types.response) =
  let m = r.meta_cognition in
  let pct = Int.of_float (Float.round_nearest (m.stagnation_score *. 100.0)) in
  let bar_style =
    Attr.create
      "style"
      (Printf.sprintf "width:%d%%" (Int.clamp_exn pct ~min:0 ~max:100))
  in
  let belief_node =
    match m.dominant_belief with
    | Some b ->
      Node.div
        ~attrs:[ Style.belief ]
        [ Node.span
            ~attrs:[ Style.belief_tag ]
            [ Node.text b.status ]
        ; Node.text (if String.is_empty b.claim then "—" else b.claim)
        ]
    | None ->
      Node.div
        ~attrs:[ Style.empty ]
        [ Node.text "no dominant belief recorded." ]
  in
  Node.div
    ~attrs:[ Style.panel ]
    [ Node.p
        ~attrs:[ Style.panel_title ]
        [ Node.text "meta · cognition" ]
    ; Node.div
        ~attrs:[ Style.kv_row ]
        [ Node.div
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "stagnation" ]
            ; Node.div
                ~attrs:[ Style.v ]
                [ Node.text (Printf.sprintf "%d%%" pct)
                ; Node.div
                    ~attrs:[ Style.stag_bar ]
                    [ Node.div
                        ~attrs:[ Style.stag_fill; stag_color m.stagnation_score; bar_style ]
                        []
                    ]
                ]
            ]
        ; Node.div
            ~attrs:[ Style.kv ]
            [ Node.div ~attrs:[ Style.k ] [ Node.text "beliefs" ]
            ; Node.div
                ~attrs:[ Style.v ]
                [ Node.text
                    (Printf.sprintf
                       "%d total · %d contested"
                       m.belief_count
                       m.contested_belief_count)
                ]
            ]
        ]
    ; belief_node
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
          "runtime snapshot — identity, build, fleet counts, \
           meta-cognition. shell endpoint의 압축 projection으로, \
           깊은 진단은 각 tab에서 확인."
        ()
    ; Node.div
        ~attrs:[ Style.grid ]
        [ view_hero_panel r
        ; view_build_panel r
        ; view_counts_panel r
        ; view_meta_panel r
        ]
    ]
;;

let component (_graph @ local) =
  Bonsai.map (Bonsai.Expert.Var.value Overview_var.var) ~f:render
;;
