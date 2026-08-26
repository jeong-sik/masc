open Alcotest
open Masc_tui_types

let goal id phase priority =
  { pg_id = id
  ; pg_title = id
  ; pg_phase = phase
  ; pg_priority = priority
  ; pg_due_date = None
  ; pg_metric = None
  ; pg_target_value = None
  ; pg_proof = Tui_decode.Proof_idle
  ; pg_last_review_note = None
  }

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
  let actual = planning_visible_goals input |> List.map (fun item -> item.pg_id) in
  check (list string) "visible order"
    [ "executing-p1-new"
    ; "executing-p1-old"
    ; "executing-p2"
    ; "verifying"
    ; "done"
    ; "dropped"
    ]
    actual

let () =
  run "tui_planning_order"
    [ ( "planning"
      , [ test_case "phase, priority, stable recency" `Quick
            test_lifecycle_then_priority_then_server_recency
        ] )
    ]
