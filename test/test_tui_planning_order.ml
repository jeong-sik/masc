open Alcotest
open Masc_tui_types

let goal ?due ?updated id phase priority =
  { pg_id = id
  ; pg_criterion_revision = None
  ; pg_title = id
  ; pg_phase = phase
  ; pg_priority = priority
  ; pg_due_date = due
  ; pg_metric = None
  ; pg_target_value = None
  ; pg_proof = Tui_decode.Proof_idle
  ; pg_verifier_unreconciled = None
  ; pg_last_review_note = None
  ; pg_last_review_at = None
  ; pg_created_at = None
  ; pg_updated_at = updated
  }

let ids goals = List.map (fun (item : planning_goal) -> item.pg_id) goals

(* The pre-filter/sort behaviour: everything shown, lifecycle then priority,
   ties in the server's newest-first order. *)
let test_lifecycle_then_priority_then_server_recency () =
  let input =
    [ goal "done" Goal_phase.Completed 1
    ; goal "executing-p2" Goal_phase.Executing 2
    ; goal "executing-p1-new" Goal_phase.Executing 1
    ; goal "verifying" Goal_phase.Verifying 1
    ; goal "executing-p1-old" Goal_phase.Executing 1
    ; goal "dropped" Goal_phase.Dropped 1
    ]
  in
  let actual =
    planning_visible_goals ~filter:Planning_filter_all
      ~sort:Planning_sort_phase_priority input
    |> ids
  in
  check (list string) "visible order"
    [ "executing-p1-new"
    ; "executing-p1-old"
    ; "executing-p2"
    ; "verifying"
    ; "done"
    ; "dropped"
    ]
    actual

let test_default_filter_is_active () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  check bool "the default filter is Active" true
    (state.planning_filter = Planning_filter_active);
  check bool "the default sort is phase/priority" true
    (state.planning_sort = Planning_sort_phase_priority)

let test_filter_cycle_order () =
  check bool "all -> active" true
    (next_planning_filter Planning_filter_all = Planning_filter_active);
  check bool "active -> completed" true
    (next_planning_filter Planning_filter_active = Planning_filter_completed);
  check bool "completed -> dropped" true
    (next_planning_filter Planning_filter_completed = Planning_filter_dropped);
  check bool "dropped -> all" true
    (next_planning_filter Planning_filter_dropped = Planning_filter_all)

let test_sort_cycle_order () =
  check bool "phase -> updated" true
    (next_planning_sort Planning_sort_phase_priority = Planning_sort_updated);
  check bool "updated -> due" true
    (next_planning_sort Planning_sort_updated = Planning_sort_due);
  check bool "due -> phase" true
    (next_planning_sort Planning_sort_due = Planning_sort_phase_priority)

let phase_fixtures =
  [ goal "executing" Goal_phase.Executing 1
  ; goal "verifying" Goal_phase.Verifying 1
  ; goal "completed" Goal_phase.Completed 1
  ; goal "dropped" Goal_phase.Dropped 1
  ]

let visible ~filter =
  planning_visible_goals ~filter ~sort:Planning_sort_phase_priority
    phase_fixtures
  |> ids

let test_active_filter_hides_completed_and_dropped () =
  check (list string) "active keeps executing and verifying"
    [ "executing"; "verifying" ] (visible ~filter:Planning_filter_active)

let test_completed_and_dropped_filters () =
  check (list string) "completed only" [ "completed" ]
    (visible ~filter:Planning_filter_completed);
  check (list string) "dropped only" [ "dropped" ]
    (visible ~filter:Planning_filter_dropped);
  check (list string) "all keeps every phase"
    [ "executing"; "verifying"; "completed"; "dropped" ]
    (visible ~filter:Planning_filter_all)

let test_sort_updated_desc_with_none_last_and_stable_ties () =
  let input =
    [ goal "old" Goal_phase.Executing 1 ~updated:"2026-08-01T00:00:00Z"
    ; goal "no-stamp-first" Goal_phase.Executing 1
    ; goal "new" Goal_phase.Executing 1 ~updated:"2026-08-20T00:00:00Z"
    ; goal "tie-a" Goal_phase.Executing 1 ~updated:"2026-08-10T00:00:00Z"
    ; goal "tie-b" Goal_phase.Executing 1 ~updated:"2026-08-10T00:00:00Z"
    ; goal "no-stamp-second" Goal_phase.Executing 1
    ]
  in
  let actual =
    planning_visible_goals ~filter:Planning_filter_all
      ~sort:Planning_sort_updated input
    |> ids
  in
  check (list string) "newest first, ties stable, unstamped last"
    [ "new"; "tie-a"; "tie-b"; "old"; "no-stamp-first"; "no-stamp-second" ]
    actual

let test_sort_due_soonest_first_with_none_last () =
  let input =
    [ goal "later" Goal_phase.Executing 1 ~due:"2026-09-01"
    ; goal "no-date" Goal_phase.Executing 1
    ; goal "sooner" Goal_phase.Executing 1 ~due:"2026-08-30"
    ]
  in
  let actual =
    planning_visible_goals ~filter:Planning_filter_all
      ~sort:Planning_sort_due input
    |> ids
  in
  check (list string) "soonest first, undated last"
    [ "sooner"; "later"; "no-date" ] actual

(* Filter first, then sort: the sort only ever sees rows the filter kept. *)
let test_filter_composes_with_sort () =
  let input =
    [ goal "dropped-new" Goal_phase.Dropped 1 ~updated:"2026-08-20T00:00:00Z"
    ; goal "executing-old" Goal_phase.Executing 1 ~updated:"2026-08-01T00:00:00Z"
    ; goal "executing-new" Goal_phase.Executing 1 ~updated:"2026-08-15T00:00:00Z"
    ]
  in
  let actual =
    planning_visible_goals ~filter:Planning_filter_active
      ~sort:Planning_sort_updated input
    |> ids
  in
  check (list string) "filtered out rows never reach the sort"
    [ "executing-new"; "executing-old" ] actual

let test_suspension_visibility_and_keys () =
  let input = [goal "paused" (Goal_phase.Paused Goal_phase.Resume_verifying) 1;
               goal "blocked" (Goal_phase.Blocked Goal_phase.Resume_executing) 1] in
  check (list string) "suspended goals stay available for operator restore"
    ["paused"; "blocked"]
    (planning_visible_goals ~filter:Planning_filter_active ~sort:Planning_sort_phase_priority input |> ids);
  List.iter (fun (key, action) ->
    check bool ("key " ^ key) true (Masc_tui_render_prim.planning_action_of_key key = Some action))
    ["p", Goal_phase.Public_action.Pause; "R", Goal_phase.Public_action.Resume;
     "b", Goal_phase.Public_action.Block; "U", Goal_phase.Public_action.Unblock]

let test_narrow_planning_rollup_and_clause_packing () =
  let cols = 80 in
  let inner = cols - 4 in
  let rollup =
    { pr_active = 5
    ; pr_verifying = 2
    ; pr_awaiting_confirmation = 0
    ; pr_done = 12
    ; pr_dropped = 3
    ; pr_paused = 1
    ; pr_blocked = 0
    }
  in
  let backlog =
    { pb_todo = 8
    ; pb_claimed = 2
    ; pb_running = 4
    ; pb_awaiting_verification = 14
    ; pb_done = 42
    ; pb_cancelled = 3
    }
  in
  let snapshot =
    { pl_goals = []
    ; pl_rollup = rollup
    ; pl_backlog = backlog
    ; pl_goal_history = []
    ; pl_generated_at = "2026-10-17T00:00:00Z"
    }
  in
  let rollup_rows = Masc_tui_render_prim.planning_rollup_rows ~cols rollup in
  let backlog_rows =
    Masc_tui_render_prim.pack_planning_summary_rows ~cols
      (Masc_tui_render_prim.planning_backlog_clauses backlog)
  in
  let change_rows =
    Masc_tui_render_prim.pack_planning_summary_rows ~cols
      (Masc_tui_render_prim.planning_change_clauses ~baseline:(Some snapshot) snapshot)
  in
  let assert_packed_rows label rows =
    check bool (label ^ " produces multiple wrapped rows at 80 cols") true
      (List.length rows >= 2);
    List.iter
      (fun row ->
        let plain = Masc_tui_theme.strip_sgr row in
        let trimmed = String.trim plain in
        check bool (label ^ " fits framed_inner_width 80") true
          (Masc_tui_message_layout.display_width row <= inner);
        check bool (label ^ " keeps 2-cell left margin") true
          (String.starts_with ~prefix:"  " plain);
        check bool (label ^ " never strands a trailing bullet glyph") false
          (String.ends_with ~suffix:"●" trimmed);
        check bool (label ^ " never starts a continuation with bare +0") false
          (String.starts_with ~prefix:"+0" trimmed))
      rows
  in
  assert_packed_rows "planning_rollup_rows" rollup_rows;
  assert_packed_rows "backlog_rows" backlog_rows;
  assert_packed_rows "change_rows" change_rows

let test_work_tasks_budget_and_window_bounds () =
  check int "budget at or below header_rows leaves 0 task rows" 0
    (Masc_tui_render_prim.work_tasks_room ~budget:3 ~header_rows:3 ~count:6);
  check int "one row above header_rows draws 1 task row without overflow line" 1
    (Masc_tui_render_prim.work_tasks_room ~budget:4 ~header_rows:3 ~count:6);
  let room =
    Masc_tui_render_prim.work_tasks_room ~budget:7 ~header_rows:3 ~count:6
  in
  check int "four rows above header_rows reserves 1 row for [tasks a-b/n] when overflowing" 3 room;
  check string "overflow window text reports visible slice" "1-3/6"
    (Masc_tui_scroll.window_text ~scroll:0 ~height:room 6)

let test_studio_panel_top_border_and_lane_run_clock () =
  let rows =
    Masc_tui_render_prim.studio_panel ~width:24 ~title:"Workspace Studio"
      ~lines:[ "row one"; "row two" ]
  in
  check int "studio_panel emits top heading border, 2 body rows, and bottom border"
    4 (List.length rows);
  (match rows with
   | top :: _ ->
     let plain_top = Masc_tui_theme.strip_sgr top in
     check string "top border embeds title and restores horizontal rule to top-right corner"
       "┌ Workspace Studio ────┐" plain_top;
     check int "top border matches exact panel width" 24
       (Masc_tui_message_layout.display_width top)
   | [] -> fail "expected studio_panel rows");
  List.iter
    (fun row ->
      check int "every studio_panel row matches panel width" 24
        (Masc_tui_message_layout.display_width row))
    rows;
  let formatted = Masc_tui_render_prim.lane_run_clock 1_700_000_000.0 in
  check int "lane_run_clock formats as MM-DD HH:MM:SS (14 chars)" 14
    (String.length formatted);
  check char "month-day separator is hyphen" '-' formatted.[2];
  check char "date-time separator is space" ' ' formatted.[5];
  check char "hour-minute separator is colon" ':' formatted.[8];
  check char "minute-second separator is colon" ':' formatted.[11]

let () =
  run "tui_planning_order"
    [ ( "planning"
      , [ test_case "phase, priority, stable recency" `Quick
            test_lifecycle_then_priority_then_server_recency
        ; test_case "suspension visibility and restore keys" `Quick test_suspension_visibility_and_keys
        ; test_case "narrow 80-col rollup and clause packing" `Quick
            test_narrow_planning_rollup_and_clause_packing
        ; test_case "work_tasks budget and window bounds" `Quick
            test_work_tasks_budget_and_window_bounds
        ; test_case "studio_panel top border and lane_run_clock" `Quick
            test_studio_panel_top_border_and_lane_run_clock
        ; test_case "default filter is Active" `Quick
            test_default_filter_is_active
        ; test_case "filter cycles all/active/completed/dropped" `Quick
            test_filter_cycle_order
        ; test_case "sort cycles phase/updated/due" `Quick test_sort_cycle_order
        ; test_case "active hides completed and dropped" `Quick
            test_active_filter_hides_completed_and_dropped
        ; test_case "completed and dropped filters" `Quick
            test_completed_and_dropped_filters
        ] )
    ; ( "sort"
      , [ test_case "updated desc, none last, stable ties" `Quick
            test_sort_updated_desc_with_none_last_and_stable_ties
        ; test_case "due soonest first, none last" `Quick
            test_sort_due_soonest_first_with_none_last
        ; test_case "filter composes with sort" `Quick
            test_filter_composes_with_sort
        ] )
    ]
