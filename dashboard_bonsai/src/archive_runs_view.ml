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
  .root {
    display: grid;
    grid-template-columns: 232px 1fr;
    min-height: 100vh;
    background:
      radial-gradient(ellipse 60% 40% at 12% 8%, rgba(212,169,64,0.05), transparent 55%),
      radial-gradient(ellipse 40% 50% at 92% 95%, rgba(58,90,72,0.06), transparent 60%),
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
    font-size: 11px;
    letter-spacing: 0.25em;
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

  .title_count { color: var(--accent-brass); }

  .sub {
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-primary);
    margin: 0;
    max-width: 620px;
  }

  .meta_strip {
    display: flex;
    flex-wrap: wrap;
    gap: 24px;
    padding: 12px 16px;
    border: 1px solid var(--border-main);
    background: linear-gradient(180deg, rgba(42,20,14,0.35), rgba(20,12,8,0.65));
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
  }
  .meta_item { display: flex; align-items: baseline; gap: 8px; }
  .meta_k {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 11px;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--text-dim);
  }
  .meta_v {
    font-variant-numeric: tabular-nums;
    color: var(--text-bright);
  }
  .meta_v_live { color: var(--status-ok); }
  .meta_v_fail { color: var(--accent-blood); }

  .quiet {
    padding: 40px 20px;
    text-align: center;
    border: 1px dashed var(--border-main);
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-dim);
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
    border: 1px solid var(--border-main);
    background: linear-gradient(180deg, rgba(28,18,14,0.7), rgba(14,10,8,0.85));
    align-items: center;
    transition: border-color 120ms ease, background 120ms ease;
  }
  .loop:hover {
    border-color: var(--border-highlight);
    background: linear-gradient(180deg, rgba(46,33,28,0.8), rgba(20,14,10,0.9));
  }

  .pill {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    padding: 4px 8px;
    text-align: center;
    border: 1px solid var(--border-main);
    font-variant-numeric: tabular-nums;
  }
  .pill_running {
    color: var(--status-ok);
    border-color: var(--status-ok);
    background: rgba(90,122,58,0.12);
  }
  .pill_completed {
    color: var(--accent-brass);
    border-color: var(--accent-brass);
    background: rgba(138,106,40,0.12);
  }
  .pill_failed {
    color: var(--accent-blood);
    border-color: var(--accent-blood-dim);
    background: rgba(232,80,80,0.14);
  }
  .pill_stopped {
    color: var(--text-dim);
    border-color: var(--border-main);
  }
  .pill_paused {
    color: var(--status-warn);
    border-color: var(--status-warn);
    background: rgba(160,106,26,0.10);
  }
  .pill_unknown {
    color: var(--text-dim);
    border-color: var(--border-main);
  }

  .goal {
    font-family: 'EB Garamond', serif;
    font-size: 14px;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }
  .goal_id {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
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
  .cycle_dim { color: var(--text-dim); font-size: 11px; }

  .kd {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    color: var(--text-primary);
    text-align: right;
  }
  .kd_keep { color: var(--status-ok); }
  .kd_slash { color: var(--text-dim); margin: 0 4px; }
  .kd_disc { color: var(--accent-viscera); }

  .elapsed {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    color: var(--text-dim);
    text-align: right;
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      transition-duration: 0.01ms !important;
    }
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
    ~attrs:[ Style.loop; Attr.role "listitem"; Attr.arialabel l.goal ]
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
  Meta.strip
    ~label:"Archive runs summary"
    [ Meta.cell ~k:"total" ~v:(Printf.sprintf "%d" r.total) ()
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
        ()
    ; view_meta_strip r
    ; (match r.loops with
       | [] ->
         Node.div
           ~attrs:[ Style.quiet; Attr.role "status"; Attr.arialabel "No archive runs" ]
           [ Node.text "no runs recorded yet." ]
       | loops ->
         Node.div
           ~attrs:[ Style.loop_list; Attr.role "list"; Attr.arialabel "Archive runs" ]
           (List.map loops ~f:view_loop))
    ]
;;

let component (_graph @ local) =
  Bonsai.map2
    (Bonsai.Expert.Var.value Archive_runs_var.var)
    (Bonsai.Expert.Var.value Overview_var.var)
    ~f:(fun runs shell -> render ~shell runs)
;;
