(** Goals view — config-driven goal tree.

    Phase 2.C 네 번째 탭. design_v2 IA의 "goals · convergence" 섹션.
    Recursive tree — 각 node는 goal + 직속 task list + child goals.

    [`/api/v1/dashboard/goals`] 10s 폴링. Summary strip (total / active /
    tasks done / convergence) + 접힌 tree. *)

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
    border: 1px dashed var(--border-main);
    font-family: 'EB Garamond', serif;
    font-style: italic;
    font-size: 14px;
    color: var(--text-dim);
  }

  .tree {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .goal {
    border: 1px solid var(--border-main);
    background: linear-gradient(180deg, color-mix(in oklab, var(--bg-panel) 70%, transparent), color-mix(in oklab, var(--bg-deep) 85%, transparent));
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .goal_indent { margin-left: 24px; border-left: 1px dashed var(--border-main); padding-left: 16px; }

  .goal_head {
    display: grid;
    grid-template-columns: 1fr 160px 120px;
    gap: 14px;
    align-items: baseline;
  }

  .goal_title {
    font-family: 'Cinzel', serif;
    font-size: 16px;
    font-weight: normal;
    letter-spacing: 0.08em;
    color: var(--text-bright);
    text-transform: uppercase;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin: 0;
  }
  .goal_horizon {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
    letter-spacing: 0.14em;
    text-transform: uppercase;
  }

  .goal_meta {
    display: flex;
    flex-wrap: wrap;
    gap: 18px;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
  }
  .goal_meta_v { color: var(--text-bright); font-variant-numeric: tabular-nums; }
  .goal_meta_v_ok { color: var(--status-ok); font-variant-numeric: tabular-nums; }

  .conv_bar_wrap {
    text-align: right;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .conv_bar {
    margin-top: 4px;
    height: 4px;
    background: color-mix(in oklab, var(--status-ok) 12%, transparent);
    position: relative;
  }
  .conv_bar_fill {
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    background: var(--status-ok);
  }


  .tasks {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
  }
  .task {
    display: flex;
    align-items: baseline;
    gap: 6px;
  }
  .task_dot { color: var(--text-dim); }
  .task_dot_done { color: var(--status-ok); }
  .task_dot_run { color: var(--status-warn); }
  .task_title { color: var(--text-primary); }

  .blocker {
    border: 1px solid color-mix(in oklab, var(--accent-brass) 28%, transparent);
    background: color-mix(in oklab, var(--accent-brass) 8%, transparent);
    padding: 8px 10px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .blocker_k {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--status-warn);
  }

  .blocker_v {
    font-family: 'Noto Sans KR', sans-serif;
    font-size: 12px;
    line-height: 1.45;
    color: var(--text-primary);
  }

  .blocker_meta {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    color: var(--text-dim);
  }

  @media (max-width: 760px) {
    .goal_head {
      grid-template-columns: 1fr;
      gap: 8px;
    }
    .goal_horizon { text-align: left; }
    .conv_bar_wrap { text-align: left; }
    .goal_indent { margin-left: 12px; padding-left: 10px; }
  }

  @media (prefers-contrast: more) {
    .goal { border-width: 2px; border-color: var(--text-bright); }
    .goal_head { border-bottom-width: 2px; border-color: var(--text-bright); }
    .k { color: var(--text-bright); }
    .conv_bar { outline: 1px solid var(--text-bright); }
    .task_dot { color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .task_dot_done { color: Highlight; }
    .task_dot_run { color: Mark; }
    .conv_bar_fill { background: Highlight; }
    .goal_meta_v_ok { color: Highlight; }
  }
|}]

let status_pill_color (s : string) : Pill.color =
  match s with
  | "active" -> `Ok
  | "paused" -> `Warn
  | "done" | "completed" -> `Brass
  | _ -> `Neutral
;;

let task_dot_class status =
  match status with
  | "completed" -> Style.task_dot_done
  | "claimed" | "in_progress" -> Style.task_dot_run
  | _ -> Style.task_dot
;;

let task_glyph status =
  match status with
  | "completed" -> "●"
  | "claimed" | "in_progress" -> "◐"
  | "cancelled" -> "×"
  | _ -> "○"
;;

let view_task_chip (t : Goals_types.task) =
  Node.div
    ~attrs:[ Style.task ]
    [ Node.span
        ~attrs:[ Style.task_dot; task_dot_class t.status ]
        [ Node.text (task_glyph t.status) ]
    ; Node.span ~attrs:[ Style.task_title ] [ Node.text t.title ]
    ]
;;

let truncate ~max_len s =
  if String.length s <= max_len
  then s
  else String.sub s ~pos:0 ~len:(max_len - 1) ^ "…"
;;

let blocker_label source =
  match String.lowercase source with
  | "goal_phase" -> "goal phase"
  | "child_goal" -> "child goal"
  | "approval" -> "approval"
  | "keeper_runtime" -> "keeper runtime"
  | "task_fsm" -> "task fsm"
  | "stalled" -> "stalled"
  | _ -> source
;;

let truth_meta_items (n : Goals_types.node) =
  List.filter_opt
    [ Option.map n.latest_keeper_ref ~f:(fun keeper -> "keeper " ^ keeper)
    ; Option.map n.latest_turn_ref ~f:(fun turn -> "turn " ^ Int.to_string turn)
    ; Option.map n.stalled_since ~f:(fun ts -> "since " ^ ts)
    ]
;;

let rec view_node ~(depth : int) (n : Goals_types.node) : Node.t =
  let bar_fill_style =
    Attr.create "style"
      (Printf.sprintf "width:%d%%" (Int.clamp_exn n.convergence_pct ~min:0 ~max:100))
  in
  let horizon_text =
    if String.is_empty n.horizon then "" else Printf.sprintf "%s · p%d" n.horizon n.priority
  in
  let indent_attr =
    if depth > 0 then [ Style.goal_indent ] else []
  in
  let task_chips =
    if List.is_empty n.tasks
    then []
    else
      [ Node.div
          ~attrs:[ Style.tasks ]
          (List.map (List.take n.tasks 8) ~f:view_task_chip
           @
           if List.length n.tasks > 8
           then
             [ Node.div
                 ~attrs:[ Style.task ]
                 [ Node.span
                     ~attrs:[ Style.task_dot ]
                     [ Node.text
                         (Printf.sprintf "+%d more" (List.length n.tasks - 8))
                     ]
                 ]
             ]
           else [])
      ]
  in
  let children =
    if List.is_empty n.children
    then []
    else List.map n.children ~f:(view_node ~depth:(depth + 1))
  in
  let truth_meta = truth_meta_items n in
  let blocker_box =
    if String.equal n.blocking_source "none" || String.is_empty (String.strip n.blocking_reason)
    then []
    else
      [ Node.div
          ~attrs:[ Style.blocker ]
          ([ Node.div
              ~attrs:[ Style.blocker_k ]
              [ Node.text (blocker_label n.blocking_source) ]
          ; Node.div
              ~attrs:[ Style.blocker_v ]
              [ Node.text n.blocking_reason ]
           ]
           @
           if List.is_empty truth_meta
           then []
           else
             [ Node.div
                 ~attrs:[ Style.blocker_meta ]
                 [ Node.text (String.concat ~sep:" · " truth_meta) ]
             ])
      ]
  in
  let truth_refs_box =
    if (not (List.is_empty blocker_box)) || List.is_empty truth_meta
    then []
    else
      [ Node.div
          ~attrs:[ Style.blocker ]
          [ Node.div
              ~attrs:[ Style.blocker_k ]
              [ Node.text "truth refs" ]
          ; Node.div
              ~attrs:[ Style.blocker_meta ]
              [ Node.text (String.concat ~sep:" · " truth_meta) ]
          ]
      ]
  in
  let title_node =
    if depth = 0 then Node.h2 ~attrs:[ Style.goal_title ] [ Node.text (truncate ~max_len:60 n.title) ]
    else Node.h3 ~attrs:[ Style.goal_title ] [ Node.text (truncate ~max_len:60 n.title) ]
  in
  Node.div
    ~attrs:(Style.goal :: Attr.role "listitem" :: Attr.create "aria-label" n.title :: indent_attr)
    (List.concat
       [ [ Node.div
             ~attrs:[ Style.goal_head ]
             [ title_node
             ; Node.div
                 ~attrs:[ Style.goal_horizon ]
                 [ Node.text horizon_text ]
             ; Node.div
                 ~attrs:[ Style.conv_bar_wrap ]
                 [ Node.text (Printf.sprintf "%d%%" n.convergence_pct)
                 ; Node.div
                     ~attrs:[ Style.conv_bar; Attr.role "progressbar"; Attr.create "aria-label" "Goal convergence"
                            ; Attr.create "aria-valuenow" (Int.to_string n.convergence_pct)
                            ; Attr.create "aria-valuemin" "0"
                            ; Attr.create "aria-valuemax" "100" ]
                     [ Node.div
                         ~attrs:[ Style.conv_bar_fill; bar_fill_style ]
                         []
                     ]
                 ]
             ]
         ; Node.div
             ~attrs:[ Style.goal_meta ]
             [ Pill.view ~size:`Sm
                 ~color:(status_pill_color n.status)
                 ~label:(if String.is_empty n.status then "—" else n.status)
                 ()
             ; Node.span ~attrs:[]
                 [ Node.text "tasks "
                 ; Node.span
                     ~attrs:[ Style.goal_meta_v ]
                     [ Node.text (Printf.sprintf "%d" n.task_count) ]
                 ]
             ; Node.span ~attrs:[]
                 [ Node.text "done "
                 ; Node.span
                     ~attrs:[ Style.goal_meta_v_ok ]
                     [ Node.text (Printf.sprintf "%d" n.task_done_count) ]
                 ]
             ; (match n.metric with
                | Some m when String.length m > 0 ->
                  Node.span ~attrs:[]
                    [ Node.text "metric "
                    ; Node.span
                        ~attrs:[ Style.goal_meta_v ]
                        [ Node.text (truncate ~max_len:40 m) ]
                    ]
                | _ -> Node.none)
             ; (match n.due_date with
                | Some d when String.length d > 0 ->
                  Node.span ~attrs:[]
                    [ Node.text "due "
                    ; Node.span
                        ~attrs:[ Style.goal_meta_v ]
                        [ Node.text d ]
                    ]
                | _ -> Node.none)
             ]
         ]
       ; task_chips
       ; blocker_box
       ; truth_refs_box
       ; children
       ])
;;

let view_meta_strip (r : Goals_types.response) =
  let s = r.summary in
  Meta.strip
    ~label:"Goals summary"
    [ Meta.cell ~k:"goals" ~v:(Printf.sprintf "%d" s.total_goals) ()
    ; Meta.cell ~color:`Ok ~k:"active"
        ~v:(Printf.sprintf "%d" s.active_goals) ()
    ; Meta.cell ~k:"tasks"
        ~v:(Printf.sprintf "%d / %d" s.done_tasks s.total_tasks) ()
    ; Meta.cell ~color:`Brass ~k:"convergence"
        ~v:(Printf.sprintf "%d%%" s.overall_convergence_pct) ()
    ]
;;

let render ~(shell : Overview_types.response) (r : Goals_types.response) : Node.t =
  Shell_view.view
    ~shell
    ~active:Goals
    [ Hero.view
        ~eyebrow:"goals · convergence"
        ~title:"goals"
        ~tail:(Printf.sprintf "· %d" r.summary.total_goals, `Brass)
        ~sub:
          "config-driven goal forest. 각 node는 goal 하나 + 직속 \
           task들 + 하위 goals. convergence는 child goals의 평균 \
           progress."
        ~sub_lang:"ko"
        ()
    ; view_meta_strip r
    ; (match r.tree with
       | [] ->
         Node.div
           ~attrs:[ Style.quiet; Attr.role "status"; Attr.create "aria-label" "No goals" ]
           [ Node.text "goal tree is empty." ]
       | nodes ->
         Node.div
           ~attrs:[ Style.tree; Attr.role "list"; Attr.create "aria-label" "Goal tree" ]
           (List.map nodes ~f:(view_node ~depth:0)))
    ]
;;

let component (_graph @ local) =
  Bonsai.map2
    (Bonsai.Expert.Var.value Goals_var.var)
    (Bonsai.Expert.Var.value Overview_var.var)
    ~f:(fun goals shell -> render ~shell goals)
;;
