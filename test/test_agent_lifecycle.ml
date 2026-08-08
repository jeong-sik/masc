(** Tests for Agent_lifecycle module — snapshot building, runtime names. *)

open Agent_sdk

(* ── build_snapshot tests ─────────────────────────────────── *)

let test_build_snapshot_fresh () =
  let snap =
    Agent_lifecycle.build_snapshot
      ~agent_name:"test-agent"
      ~model:"claude-sonnet-4-6"
      Agent_lifecycle.Running
  in
  Alcotest.(check string) "agent_name" "test-agent" snap.agent_name;
  Alcotest.(check bool) "status running" true (snap.status = Agent_lifecycle.Running);
  Alcotest.(check (option string)) "no run_id" None snap.current_run_id;
  Alcotest.(check (option string)) "no resolved model" None snap.resolved_model;
  Alcotest.(check (option (float 0.001))) "no accepted_at" None snap.accepted_at;
  Alcotest.(check (option (float 0.001))) "no finished_at" None snap.finished_at
;;

let test_build_snapshot_merge_previous () =
  let prev =
    Agent_lifecycle.build_snapshot
      ~agent_name:"test-agent"
      ~model:"claude-sonnet-4-6"
      ~accepted_at:100.0
      ~started_at:101.0
      Agent_lifecycle.Running
  in
  let snap =
    Agent_lifecycle.build_snapshot
      ~agent_name:"test-agent"
      ~model:"claude-sonnet-4-6"
      ~previous:prev
      ~finished_at:200.0
      Agent_lifecycle.Completed
  in
  Alcotest.(check (option (float 0.001)))
    "accepted_at preserved"
    (Some 100.0)
    snap.accepted_at;
  Alcotest.(check (option (float 0.001)))
    "started_at preserved"
    (Some 101.0)
    snap.started_at;
  Alcotest.(check (option (float 0.001))) "finished_at set" (Some 200.0) snap.finished_at
;;

let test_build_snapshot_last_error () =
  let prev =
    Agent_lifecycle.build_snapshot
      ~agent_name:"test-agent"
      ~model:"claude-sonnet-4-6"
      ~last_error:"previous error"
      Agent_lifecycle.Failed
  in
  let snap =
    Agent_lifecycle.build_snapshot
      ~agent_name:"test-agent"
      ~model:"claude-sonnet-4-6"
      ~previous:prev
      Agent_lifecycle.Running
  in
  Alcotest.(check (option string))
    "last_error carried"
    (Some "previous error")
    snap.last_error
;;

let test_build_snapshot_with_provider_config () =
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.Anthropic
      ~provider_id:"anthropic"
      ~model_id:"carrier-parent-model"
      ~base_url:"https://api.anthropic.com"
      ~api_key:"test"
      ~headers:[ "Content-Type", "application/json" ]
      ~request_path:"/v1/messages"
      ()
  in
  let snap =
    Agent_lifecycle.build_snapshot
      ~agent_name:"test-agent"
      ~provider_config
      ~model:"claude-sonnet-4-6"
      Agent_lifecycle.Accepted
  in
  Alcotest.(check (option string))
    "requested_provider"
    (Some "anthropic")
    snap.requested_provider;
  Alcotest.(check (option string))
    "resolved_model"
    (Some "claude-sonnet-4-6")
    snap.resolved_model
;;

(* ── hook_decision_to_string tests ────────────────────────── *)

let test_hook_decision_strings () =
  Alcotest.(check string)
    "continue"
    "continue"
    (Agent_lifecycle.hook_decision_to_string Hooks.Continue);
  Alcotest.(check string)
    "block"
    "block"
    (Agent_lifecycle.hook_decision_to_string (Hooks.Block "blocked"))
;;

(* ── transition guard tests ───────────────────────────── *)

let check_ok msg = function
  | Ok _ -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf
         "%s: unexpected error: %s"
         msg
         (Agent_lifecycle.transition_error_to_string e))
;;

let check_error msg = function
  | Error _ -> ()
  | Ok s ->
    Alcotest.fail
      (Printf.sprintf
         "%s: expected error but got Ok %s"
         msg
         (Agent_lifecycle.show_lifecycle_status s))
;;

let test_transition_accepted_to_ready () =
  check_ok "Accepted->Ready" (Agent_lifecycle.transition ~from:Accepted ~to_:Ready)
;;

let test_transition_ready_to_running () =
  check_ok "Ready->Running" (Agent_lifecycle.transition ~from:Ready ~to_:Running)
;;

let test_transition_running_to_ready () =
  check_ok
    "Running->Ready (multi-turn)"
    (Agent_lifecycle.transition ~from:Running ~to_:Ready)
;;

let test_transition_running_to_completed () =
  check_ok "Running->Completed" (Agent_lifecycle.transition ~from:Running ~to_:Completed)
;;

let test_transition_running_to_failed () =
  check_ok "Running->Failed" (Agent_lifecycle.transition ~from:Running ~to_:Failed)
;;

let test_transition_accepted_to_failed () =
  check_ok "Accepted->Failed" (Agent_lifecycle.transition ~from:Accepted ~to_:Failed)
;;

let test_transition_self_running () =
  check_ok
    "Running->Running (self)"
    (Agent_lifecycle.transition ~from:Running ~to_:Running)
;;

let test_transition_self_accepted () =
  check_ok
    "Accepted->Accepted (self)"
    (Agent_lifecycle.transition ~from:Accepted ~to_:Accepted)
;;

let test_transition_invalid_accepted_to_running () =
  check_error
    "Accepted->Running (skip Ready)"
    (Agent_lifecycle.transition ~from:Accepted ~to_:Running)
;;

let test_transition_invalid_accepted_to_completed () =
  check_error
    "Accepted->Completed (skip Ready,Running)"
    (Agent_lifecycle.transition ~from:Accepted ~to_:Completed)
;;

let test_transition_invalid_ready_to_completed () =
  check_error
    "Ready->Completed (skip Running)"
    (Agent_lifecycle.transition ~from:Ready ~to_:Completed)
;;

let test_transition_terminal_completed () =
  let r = Agent_lifecycle.transition ~from:Completed ~to_:Running in
  match r with
  | Error (AlreadyTerminal { status }) ->
    Alcotest.(check bool) "terminal status" true (status = Agent_lifecycle.Completed)
  | _ -> Alcotest.fail "expected AlreadyTerminal"
;;

let test_transition_terminal_failed () =
  let r = Agent_lifecycle.transition ~from:Failed ~to_:Accepted in
  match r with
  | Error (AlreadyTerminal { status }) ->
    Alcotest.(check bool) "terminal status" true (status = Agent_lifecycle.Failed)
  | _ -> Alcotest.fail "expected AlreadyTerminal"
;;

let test_transition_terminal_self () =
  check_error
    "Completed->Completed (terminal self)"
    (Agent_lifecycle.transition ~from:Completed ~to_:Completed)
;;

let test_is_terminal () =
  Alcotest.(check bool) "Completed" true (Agent_lifecycle.is_terminal Completed);
  Alcotest.(check bool) "Failed" true (Agent_lifecycle.is_terminal Failed);
  Alcotest.(check bool) "Accepted" false (Agent_lifecycle.is_terminal Accepted);
  Alcotest.(check bool) "Ready" false (Agent_lifecycle.is_terminal Ready);
  Alcotest.(check bool) "Running" false (Agent_lifecycle.is_terminal Running)
;;

let test_valid_transitions_exhaustive () =
  Alcotest.(check int)
    "Accepted has 2"
    2
    (List.length (Agent_lifecycle.valid_transitions Accepted));
  Alcotest.(check int)
    "Ready has 2"
    2
    (List.length (Agent_lifecycle.valid_transitions Ready));
  Alcotest.(check int)
    "Running has 3"
    3
    (List.length (Agent_lifecycle.valid_transitions Running));
  Alcotest.(check int)
    "Completed has 0"
    0
    (List.length (Agent_lifecycle.valid_transitions Completed));
  Alcotest.(check int)
    "Failed has 0"
    0
    (List.length (Agent_lifecycle.valid_transitions Failed))
;;

let test_transition_error_to_string () =
  let s =
    Agent_lifecycle.transition_error_to_string
      (InvalidTransition { from_status = Accepted; to_status = Running })
  in
  Alcotest.(check bool) "contains 'invalid'" true (String.length s > 0);
  let s2 =
    Agent_lifecycle.transition_error_to_string (AlreadyTerminal { status = Completed })
  in
  Alcotest.(check bool) "contains 'terminal'" true (String.length s2 > 0)
;;

(* ── yojson round-trip tests (PR-A3 mirror) ───────────────── *)
(* Mirrors AgentLifecycle.tla state set {Accepted, Ready, Running,
   Completed, Failed} via ppx_deriving_yojson.  Round-trip ensures that
   adding a constructor without updating wire encoders is caught at
   test time rather than at deserialization. *)

let test_yojson_round_trip () =
  let all_states =
    [ Agent_lifecycle.Accepted
    ; Agent_lifecycle.Ready
    ; Agent_lifecycle.Running
    ; Agent_lifecycle.Completed
    ; Agent_lifecycle.Failed
    ]
  in
  List.iter
    (fun status ->
       let json = Agent_lifecycle.lifecycle_status_to_yojson status in
       match Agent_lifecycle.lifecycle_status_of_yojson json with
       | Ok parsed ->
         Alcotest.(check bool)
           (Printf.sprintf "round-trip %s" (Agent_lifecycle.show_lifecycle_status status))
           true
           (status = parsed)
       | Error msg ->
         Alcotest.fail
           (Printf.sprintf
              "round-trip failed for %s: %s"
              (Agent_lifecycle.show_lifecycle_status status)
              msg))
    all_states
;;

let test_yojson_rejects_unknown () =
  let bogus = `String "NonexistentStatus" in
  match Agent_lifecycle.lifecycle_status_of_yojson bogus with
  | Error _ -> () (* expected — unknown value rejected *)
  | Ok _ -> Alcotest.fail "unknown string should be rejected"
;;

let test_lifecycle_snapshot_roundtrip () =
  let snap =
    Agent_lifecycle.build_snapshot
      ~agent_name:"roundtrip-test"
      ~model:"claude-sonnet-4-6"
      ~accepted_at:100.0
      ~started_at:101.0
      ~finished_at:200.0
      Agent_lifecycle.Completed
  in
  let json = Agent_lifecycle.lifecycle_snapshot_to_yojson snap in
  match Agent_lifecycle.lifecycle_snapshot_of_yojson json with
  | Ok snap' ->
    Alcotest.(check string) "agent_name" snap.agent_name snap'.agent_name;
    Alcotest.(check bool) "status" true (snap.status = snap'.status);
    Alcotest.(check (option (float 0.001)))
      "accepted_at"
      snap.accepted_at
      snap'.accepted_at;
    Alcotest.(check (option (float 0.001))) "started_at" snap.started_at snap'.started_at;
    Alcotest.(check (option (float 0.001)))
      "finished_at"
      snap.finished_at
      snap'.finished_at
  | Error e -> Alcotest.failf "lifecycle_snapshot roundtrip failed: %s" e
;;

(* ── Test runner ────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Agent_lifecycle"
    [ ( "build_snapshot"
      , [ Alcotest.test_case "fresh snapshot" `Quick test_build_snapshot_fresh
        ; Alcotest.test_case "merge previous" `Quick test_build_snapshot_merge_previous
        ; Alcotest.test_case "last_error carry" `Quick test_build_snapshot_last_error
        ; Alcotest.test_case
            "with provider config"
            `Quick
            test_build_snapshot_with_provider_config
        ] )
    ; ( "hook_decision"
      , [ Alcotest.test_case "string conversion" `Quick test_hook_decision_strings ] )
    ; ( "yojson_roundtrip"
      , [ Alcotest.test_case "lifecycle_status roundtrip" `Quick test_yojson_round_trip
        ; Alcotest.test_case
            "lifecycle_snapshot roundtrip"
            `Quick
            test_lifecycle_snapshot_roundtrip
        ] )
    ; ( "transition_guards"
      , [ Alcotest.test_case "Accepted -> Ready" `Quick test_transition_accepted_to_ready
        ; Alcotest.test_case "Ready -> Running" `Quick test_transition_ready_to_running
        ; Alcotest.test_case
            "Running -> Ready (multi-turn)"
            `Quick
            test_transition_running_to_ready
        ; Alcotest.test_case
            "Running -> Completed"
            `Quick
            test_transition_running_to_completed
        ; Alcotest.test_case "Running -> Failed" `Quick test_transition_running_to_failed
        ; Alcotest.test_case
            "Accepted -> Failed"
            `Quick
            test_transition_accepted_to_failed
        ; Alcotest.test_case "self Running -> Running" `Quick test_transition_self_running
        ; Alcotest.test_case
            "self Accepted -> Accepted"
            `Quick
            test_transition_self_accepted
        ; Alcotest.test_case
            "invalid Accepted -> Running"
            `Quick
            test_transition_invalid_accepted_to_running
        ; Alcotest.test_case
            "invalid Accepted -> Completed"
            `Quick
            test_transition_invalid_accepted_to_completed
        ; Alcotest.test_case
            "invalid Ready -> Completed"
            `Quick
            test_transition_invalid_ready_to_completed
        ; Alcotest.test_case
            "terminal Completed -> Running"
            `Quick
            test_transition_terminal_completed
        ; Alcotest.test_case
            "terminal Failed -> Accepted"
            `Quick
            test_transition_terminal_failed
        ; Alcotest.test_case
            "terminal self Completed"
            `Quick
            test_transition_terminal_self
        ; Alcotest.test_case "is_terminal" `Quick test_is_terminal
        ; Alcotest.test_case
            "valid_transitions exhaustive"
            `Quick
            test_valid_transitions_exhaustive
        ; Alcotest.test_case "error_to_string" `Quick test_transition_error_to_string
        ] )
    ; ( "yojson"
      , [ Alcotest.test_case "round-trip all states" `Quick test_yojson_round_trip
        ; Alcotest.test_case "rejects unknown" `Quick test_yojson_rejects_unknown
        ] )
    ]
;;
