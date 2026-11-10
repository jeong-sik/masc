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

let test_startup_observation_keeps_the_exact_existing_policy_deadline () =
  let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc [
      "name", `String "startup-policy"; "trace_id", `String "startup-policy-trace";
      "activation_mode", `String "autonomous"; "created_at", `String "1970-01-01T00:01:40Z";
      "total_turns", `Int 0; "proactive_count_total", `Int 0]) with
    | Ok meta -> meta | Error detail -> Alcotest.fail detail in
  let observe ~meta ~phase now_ts = Keeper_status_runtime.keeper_diagnostic_observation
      ~meta ~phase ~history_items:[] ~now_ts in
  let before = observe ~meta ~phase:(Some Keeper_state_machine.Running) 220.0 in
  Alcotest.(check bool) "the original inclusive startup boundary is preserved" true
    (member "quiet_reason" before.json = Some (`String "startup"));
  let deadline = Float.next_after 220.0 infinity in
  Alcotest.(check (option (float 0.0))) "the same typed observation owns its exact next boundary"
    (Some deadline) before.next_deadline_unix;
  let after = observe ~meta ~phase:(Some Keeper_state_machine.Running) deadline in
  Alcotest.(check bool) "the returned instant changes the actual quiet reason" true
    (member "quiet_reason" after.json = Some (`String "never_started"));
  Alcotest.(check bool) "health remains the same clockless observation" true
    (member "health_state" before.json = member "health_state" after.json);
  Alcotest.(check (option (float 0.0))) "elapsed policy does not create a cadence" None after.next_deadline_unix;
  let stopped = observe ~meta ~phase:(Some Keeper_state_machine.Stopped) 200.0 in
  Alcotest.(check (option (float 0.0))) "a stopped keepalive has no startup timer" None stopped.next_deadline_unix;
  let invalid = observe ~meta:{meta with created_at = "unknown"}
      ~phase:(Some Keeper_state_machine.Running) 200.0 in
  Alcotest.(check (option (float 0.0))) "unknown creation time never gets a synthetic deadline" None invalid.next_deadline_unix
;;

let () =
  Alcotest.run
    "keeper_diagnostic_stale_last_error"
    [ ( "keeper-owned diagnostic evidence"
      , [ Alcotest.test_case "startup observation retains its actual policy deadline" `Quick
            test_startup_observation_keeps_the_exact_existing_policy_deadline
        ; Alcotest.test_case
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
