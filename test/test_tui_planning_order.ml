open Alcotest
open Masc_tui_types

let goal ?due ?updated id phase priority =
  { pg_id = id
  ; pg_title = id
  ; pg_phase = phase
  ; pg_priority = priority
  ; pg_due_date = due
  ; pg_metric = None
  ; pg_target_value = None
  ; pg_proof = Tui_decode.Proof_idle
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

let () =
  run "tui_planning_order"
    [ ( "planning"
      , [ test_case "phase, priority, stable recency" `Quick
            test_lifecycle_then_priority_then_server_recency
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
