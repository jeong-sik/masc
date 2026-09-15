(** Regression: keeper diagnostics must not manufacture [last_error] from the
    display-oriented proactive reason after the dead workspace-agent projection
    is removed. Keeper health is derived from keeper-owned runtime evidence. *)

open Masc

let now_ts = 1_781_100_000.0

let member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let meta_with_persisted_reason ~last_turn_ts =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "stalekeeper"
        ; "trace_id", `String "trace-stalekeeper"
        ; "last_proactive_outcome", `String "error"
        ; ( "last_proactive_reason"
          , `String "unified:error:Tool retry budget exhausted after 2/2 retries" )
        ; "last_proactive_ts", `Float (now_ts -. 300.0)
        ; "last_turn_ts", `Float last_turn_ts
        ; "total_turns", `Int 5
        ; "proactive_count_total", `Int 5
        ])
  with
  | Ok meta -> meta
  | Error error -> Alcotest.failf "meta_of_json_fixture failed: %s" error
;;

let diagnostic ~phase ~last_turn_ts =
  Keeper_status_runtime.keeper_diagnostic_json
    ~meta:(meta_with_persisted_reason ~last_turn_ts)
    ~phase:(Some phase)
    ~history_items:[]
    ~now_ts
;;

let test_proactive_reason_is_not_reclassified_as_error () =
  let row =
    diagnostic ~phase:Keeper_state_machine.Running ~last_turn_ts:(now_ts -. 120.0)
  in
  Alcotest.(check bool)
    "display reason is not an error authority"
    true
    (member "last_error" row = Some `Null)
;;

let test_running_keeper_uses_keeper_health_evidence () =
  let row =
    diagnostic ~phase:Keeper_state_machine.Running ~last_turn_ts:(now_ts -. 120.0)
  in
  Alcotest.(check bool)
    "running keeper is healthy"
    true
    (member "health_state" row = Some (`String "healthy"))
;;

let test_stopped_keeper_is_offline () =
  let row =
    diagnostic ~phase:Keeper_state_machine.Stopped ~last_turn_ts:(now_ts -. 120.0)
  in
  Alcotest.(check bool)
    "stopped keeper is offline"
    true
    (member "health_state" row = Some (`String "offline"))
;;

let () =
  Alcotest.run
    "keeper_diagnostic_stale_last_error"
    [ ( "keeper-owned diagnostic evidence"
      , [ Alcotest.test_case
            "proactive reason is not reclassified as error"
            `Quick
            test_proactive_reason_is_not_reclassified_as_error
        ; Alcotest.test_case
            "running keeper uses keeper health evidence"
            `Quick
            test_running_keeper_uses_keeper_health_evidence
        ; Alcotest.test_case
            "stopped keeper is offline"
            `Quick
            test_stopped_keeper_is_offline
        ] )
    ]
;;
