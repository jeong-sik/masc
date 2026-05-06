(** Archive runs view — autoresearch loops list.

    Phase 2.C second tab ported. Fetches [/api/v1/autoresearch/loops]
    every 5 s. design_v2 IA의 "archive · autoresearch" 섹션. 각 row는
    한 번의 reinforced-write loop — goal / status / cycle progress /
    keeps·discards / elapsed. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .quiet {
    padding: 40px 20px;
    text-align: center;
    border: 1px dashed var(--color-border-default);
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--color-fg-muted);
  }

  .loop_list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .loop {
    display: grid;
    grid-template-columns: 90px 1fr 120px 140px 90px;
    gap: 14px;
    padding: 12px 16px;
    border: 1px solid var(--color-border-default);
    background: linear-gradient(180deg, color-mix(in oklab, var(--color-bg-surface) 70%, transparent), color-mix(in oklab, var(--color-bg-page) 85%, transparent));
    align-items: center;
    transition: border-color 120ms ease, background 120ms ease;
  }
  .loop:hover {
    border-color: var(--color-border-strong);
    background: linear-gradient(180deg, color-mix(in oklab, var(--color-bg-elevated) 80%, transparent), color-mix(in oklab, var(--color-bg-page) 90%, transparent));
  }

  .pill {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    padding: 4px 8px;
    text-align: center;
    border: 1px solid var(--color-border-default);
    font-variant-numeric: tabular-nums;
  }
  .pill_running {
    color: var(--color-status-ok);
    border-color: var(--color-status-ok);
    background: color-mix(in oklab, var(--color-status-ok) 12%, transparent);
  }
  .pill_completed {
    color: var(--color-accent-fg);
    border-color: var(--color-accent-fg);
    background: color-mix(in oklab, var(--color-accent-fg) 12%, transparent);
  }
  .pill_failed {
    color: var(--accent-blood);
    border-color: var(--accent-blood-dim);
    background: color-mix(in oklab, var(--accent-blood) 14%, transparent);
  }
  .pill_stopped {
    color: var(--color-fg-muted);
    border-color: var(--color-border-default);
  }
  .pill_paused {
    color: var(--color-status-warn);
    border-color: var(--color-status-warn);
    background: color-mix(in oklab, var(--color-accent-fg) 10%, transparent);
  }
  .pill_unknown {
    color: var(--color-fg-muted);
    border-color: var(--color-border-default);
  }

  .goal {
    font-family: 'EB Garamond', serif;
    font-size: 14px;
    color: var(--color-fg-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }
  .goal_id {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--color-fg-muted);
    letter-spacing: 0.06em;
    margin-right: 10px;
  }
  .goal_err {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--accent-viscera);
    letter-spacing: 0.02em;
    margin-left: 10px;
  }

  .cycle {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 12px;
    color: var(--text-bright);
    font-variant-numeric: tabular-nums;
    text-align: right;
  }
  .cycle_dim { color: var(--color-fg-muted); font-size: 11px; }

  .kd {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    color: var(--color-fg-primary);
    text-align: right;
  }
  .kd_keep { color: var(--color-status-ok); }
  .kd_slash { color: var(--color-fg-muted); margin: 0 4px; }
  .kd_disc { color: var(--accent-viscera); }

  .elapsed {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    color: var(--color-fg-muted);
    text-align: right;
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      transition-duration: 0.01ms !important;
    }
  }

  @media (max-width: 760px) {
    .loop {
      grid-template-columns: 1fr;
      gap: 8px;
    }
    .goal {
      min-width: 0;
    }
    .cycle, .kd, .elapsed {
      text-align: left;
    }
  }

  @media (prefers-contrast: more) {
    .goal { border-width: 2px; border-color: var(--text-bright); }
    .goal_header { border-bottom-width: 2px; border-color: var(--text-bright); }
    .k { color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .pill_running { color: Highlight; border-color: Highlight; }
    .pill_completed { color: ButtonText; border-color: ButtonText; }
    .pill_failed { color: MarkText; border-color: MarkText; }
    .pill_stopped { color: GrayText; border-color: GrayText; }
    .pill_paused { color: Mark; border-color: Mark; }
    .kd_keep { color: Highlight; }
  }
|}]

let pill_color : Archive_runs_types.status -> Pill.color = function
  | Running -> `Ok
  | Completed -> `Brass
  | Failed -> `Bad
  | Stopped -> `Paused
  | Paused -> `Warn
  | Unknown -> `Neutral
;;

let hhmmss_of_epoch (t : float) : string =
  if Float.(t <= 0.0)
  then "—"
  else (
    let seconds = Float.to_int t in
    let s = Printf.sprintf "%d" (seconds mod 60) in
    let m = Printf.sprintf "%d" (seconds / 60 mod 60) in
    let h = seconds / 3600 in
    if h > 0
    then Printf.sprintf "%dh %sm" h m
    else if (seconds / 60) > 0
    then Printf.sprintf "%sm %ss" m s
    else Printf.sprintf "%ss" s)
;;

let short_id (id : string) =
  if String.length id > 11
  then String.sub id ~pos:0 ~len:11
  else id
;;

let truncate_goal ~(max_len : int) (s : string) =
  if String.length s <= max_len
  then s
  else String.sub s ~pos:0 ~len:(max_len - 1) ^ "…"
;;

let view_loop (l : Archive_runs_types.loop) =
  let goal_text = truncate_goal ~max_len:120 l.goal in
  let cycle_str =
    Printf.sprintf
      "%d / %d"
      l.current_cycle
      (if l.max_cycles <= 0 then 0 else l.max_cycles)
  in
  let keeps = l.total_keeps in
  let discards = l.total_discards in
  Node.div
    ~attrs:
      [ Style.loop
      ; Attr.role "listitem"
      ; Attr.create
          "aria-label"
          (Archive_runs_types.status_label l.status
           ^ " · "
           ^ cycle_str
           ^ " · +"
           ^ Int.to_string keeps
           ^ " −"
           ^ Int.to_string discards
           ^ " · "
           ^ l.goal)
      ]
    [ Pill.view
        ~color:(pill_color l.status)
        ~label:(Archive_runs_types.status_label l.status)
        ()
    ; Node.div
        ~attrs:[ Style.goal ]
        (List.concat
           [ [ Node.span
                 ~attrs:[ Style.goal_id ]
                 [ Node.text (short_id l.loop_id) ]
             ; Node.text goal_text
             ]
           ; (match l.error with
              | Some e when String.length e > 0 ->
                [ Node.span
                    ~attrs:[ Style.goal_err ]
                    [ Node.text (truncate_goal ~max_len:60 e) ]
                ]
              | _ -> [])
           ])
    ; Node.div
        ~attrs:[ Style.cycle ]
        [ Node.text cycle_str
        ; Node.div
            ~attrs:[ Style.cycle_dim ]
            [ Node.text
                (if l.target_reached then "target ✓" else "cycles")
            ]
        ]
    ; Node.div
        ~attrs:[ Style.kd ]
        [ Node.span
            ~attrs:[ Style.kd_keep ]
            [ Node.text (Printf.sprintf "+%d" keeps) ]
        ; Node.span ~attrs:[ Style.kd_slash ] [ Node.text "·" ]
        ; Node.span
            ~attrs:[ Style.kd_disc ]
            [ Node.text (Printf.sprintf "−%d" discards) ]
        ]
    ; Node.div
        ~attrs:[ Style.elapsed ]
        [ Node.text (hhmmss_of_epoch l.elapsed_s) ]
    ]
;;

let view_meta_strip (r : Archive_runs_types.response) =
  let running =
    List.count r.loops ~f:(fun (l : Archive_runs_types.loop) ->
      match l.status with
      | Running -> true
      | Stopped | Paused | Failed | Completed | Unknown -> false)
  in
  let completed =
    List.count r.loops ~f:(fun (l : Archive_runs_types.loop) ->
      match l.status with
      | Completed -> true
      | Running | Stopped | Paused | Failed | Unknown -> false)
  in
  let failed =
    List.count r.loops ~f:(fun (l : Archive_runs_types.loop) ->
      match l.status with
      | Failed -> true
      | Running | Stopped | Paused | Completed | Unknown -> false)
  in
  let fetch_color =
    match r.fetch_status with
    | Archive_runs_types.Fetch_pending -> `Brass
    | Archive_runs_types.Fetch_fresh -> `Ok
    | Archive_runs_types.Fetch_stale _ -> `Blood
  in
  Meta.strip
    ~label:"Archive runs summary"
    [ Meta.cell ~color:fetch_color ~k:"feed"
        ~v:(Archive_runs_types.fetch_status_label r.fetch_status) ()
    ; Meta.cell ~k:"total" ~v:(Printf.sprintf "%d" r.total) ()
    ; Meta.cell ~color:`Ok ~k:"running" ~v:(Printf.sprintf "%d" running) ()
    ; Meta.cell ~k:"completed" ~v:(Printf.sprintf "%d" completed) ()
    ; Meta.cell ~color:`Blood ~k:"failed" ~v:(Printf.sprintf "%d" failed) ()
    ; Meta.cell ~k:"offset" ~v:(Printf.sprintf "%d" r.offset) ()
    ]
;;

let render ~(shell : Overview_types.response) (r : Archive_runs_types.response) : Node.t =
  let total = r.total in
  Shell_view.view
    ~shell
    ~active:Archive_runs
    [ Hero.view
        ~eyebrow:"archive · autoresearch"
        ~title:"archive runs"
        ~tail:(Printf.sprintf "· %d" total, `Brass)
        ~sub:
          "autoresearch의 reinforced-write loop 기록. 각 row는 \
           목표 · cycle progress · keeps/discards 의 총합. 실패한 \
           run은 error 사유를 함께 남긴다."
        ~sub_lang:"ko"
        ()
    ; view_meta_strip r
    ; (match r.loops with
       | [] ->
         Node.div
           ~attrs:[ Style.quiet; Attr.role "status"; Attr.create "aria-label" "No archive runs" ]
           [ Node.text "no runs recorded yet." ]
       | loops ->
         Node.div
           ~attrs:[ Style.loop_list; Attr.role "list"; Attr.create "aria-label" "Archive runs" ]
           (List.map loops ~f:view_loop))
    ]
;;

let component (_graph @ local) =
  Bonsai.map2
    (Bonsai.Expert.Var.value Archive_runs_var.var)
    (Bonsai.Expert.Var.value Overview_var.var)
    ~f:(fun runs shell -> render ~shell runs)
;;
