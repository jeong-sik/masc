(** D2: caller-input validation errors must not trip the keeper HEALTH circuit
    breaker (Gate #1), while the per-(tool,args) breaker (Gate #2) must still
    count them so retrying the SAME bad args stays blocked.

    The fix tags keeper_task_create validation errors with
    [Tool_result.Policy_rejection] (RFC-0062 §3.2). This test proves the
    end-to-end behavior on the payload the producer actually emits — not a
    hand-built literal — so a regression in the producer (dropping the class)
    is caught here. *)

open Alcotest

module Task = Masc.Keeper_tool_task_runtime
module Dispatch = Masc.Keeper_tool_dispatch_runtime
module Boundary = Masc.Keeper_tools_oas_failure_boundary
module Response_text = Masc.Keeper_agent_run_response_text
module State = Masc.Keeper_memory_policy
module Receipt = Masc.Keeper_execution_receipt
module U = Yojson.Safe.Util
(* Tool_result lives in the leaf [masc_tool_types] lib (wrapped false), so
   it is referenced bare — not under [Masc.] — matching existing tests. *)
module TR = Tool_result
(* Keeper_tool_outcome lives in the [keeper_metrics] lib (wrapped false), so it
   is referenced bare — not under [Masc.] — matching the bare [Tool_result]. *)
module Outcome = Keeper_tool_outcome

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_task_create_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  in
  try rm dir with _ -> ()

let meta_with_active_goals goal_ids =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "keeper-task-create-test"
        ; "agent_name", `String "keeper-task-create-test"
        ; "trace_id", `String "trace-task-create-test"
        ; ( "active_goal_ids"
          , `List (List.map (fun goal_id -> `String goal_id) goal_ids) )
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

(* The error a keeper sees when it sends a non-object contract — the residual
   validation case after D1 makes an OMITTED contract [Ok None]. *)
let payload =
  Task.validation_error_json
    "contract must be an object when provided (received string)"

(* A — producer: keeper_task_create validation errors carry policy_rejection. *)
let test_producer_tags_policy_rejection () =
  check (option string) "validation payload carries policy_rejection class"
    (Some "policy_rejection")
    (Option.map TR.tool_failure_class_to_string
       (Dispatch.failure_class_of_tool_result_payload payload))

(* B — Gate #1 (health breaker): validation is exempt, but an UNCLASSIFIED
   error still counts (conservative: unknown -> fail, never permissive-default
   per CLAUDE.md anti-pattern #2). *)
let test_gate1_exempts_validation_but_counts_unclassified () =
  check bool "Gate#1 exempts policy_rejection validation" false
    (Dispatch.should_apply_circuit_breaker_to_failure_payload
       (Dispatch.failure_class_of_tool_result_payload payload));
  check bool "Gate#1 still counts an unclassified (class-less) error" true
    (Dispatch.should_apply_circuit_breaker_to_failure_payload
       (Dispatch.failure_class_of_tool_result_payload
          {|{"error":"contract must be an object when provided"}|}))

(* C — Gate #2 (per-(tool,args) breaker): validation is NOT a workflow
   rejection, so identical bad args remain counted (retry-block intact). This
   is the proof we did not OVER-exempt. *)
let test_gate2_still_counts_validation () =
  let classified = Boundary.classify_raw_failure payload in
  check string "Gate#2 sees policy_rejection class" "policy_rejection"
    (TR.tool_failure_class_to_string classified.Boundary.failure_class);
  check bool
    "Gate#2 does not treat validation as workflow_rejection (still counts)"
    false classified.Boundary.is_workflow_rejection

let test_task_create_multi_active_goals_without_goal_id_is_unscoped () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = meta_with_active_goals [ "goal-a"; "goal-b" ] in
       let payload =
         Task.handle_keeper_task_tool
           ~config
           ~meta
           ~name:"keeper_task_create"
           ~args:
             (`Assoc
               [ "title", `String "Unscoped task"
               ; "description", `String "Should not require a disambiguating goal_id"
               ; "priority", `Int 3
               ])
       in
       let json = Yojson.Safe.from_string payload in
       check bool "task create succeeds" true (json |> U.member "ok" |> U.to_bool);
       check bool "task create returns null goal_id" true
         (json |> U.member "goal_id" = `Null);
       match Masc.Workspace.get_tasks_raw config with
       | [ _task ] -> ()
       | tasks ->
           failf "expected exactly one persisted task, got %d" (List.length tasks))

let test_state_block_reply_returns_state_snapshot () =
  let raw_response_text =
    "[STATE]\n\
     Goal: Keep runtime visible\n\
     Next: Check main CI\n\
     Constraints: Use worktrees\n\
     [/STATE]"
  in
  let
    { Response_text.state_snapshot
    ; state_snapshot_source
    ; response_text
    }
    =
    Response_text.finalize
      ~reported_state_snapshot:None
      ~keeper_name:"keeper-task-create-test"
      ~goal:"Keep runtime visible"
      ~actual_keeper_tool_names:[]
      ~completion_contract_result:Receipt.Contract_satisfied_completion
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text
      ()
  in
  check string "state block source" "model_state_block"
    (State.state_snapshot_source_to_string state_snapshot_source);
  check (option string) "state keeps goal" (Some "Keep runtime visible")
    state_snapshot.goal;
  check (list string) "state keeps next items" [ "Check main CI" ]
    state_snapshot.next_items;
  check (list string) "state keeps constraints" [ "Use worktrees" ]
    state_snapshot.constraints;
  check string "state-only block is not a visible response" ""
    response_text

(* RFC-0239 / audit D1: a rejected keeper_task_done must carry a typed
   [Error] outcome so the no-progress loop detector demotes it (PR #22127
   wired the detector to read typed_outcome; this proves the producer emits
   it on rejection instead of leaving it [None] and being counted as
   evidence by tool name alone). *)
let rejected_done_typed_outcome ~base_path:_ config meta args =
  let payload =
    Task.handle_keeper_task_tool ~config ~meta ~name:"keeper_task_done" ~args
  in
  let json = Yojson.Safe.from_string payload in
  check bool "rejected done is not ok" false (json |> U.member "ok" |> U.to_bool);
  Outcome.of_json (json |> U.member "typed_outcome")

let test_done_missing_task_id_emits_typed_error () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = meta_with_active_goals [] in
       (* task_id omitted -> early workflow_rejection path. *)
       match
         rejected_done_typed_outcome ~base_path config meta
           (`Assoc [ "result", `String "done" ])
       with
       | Some (Outcome.Error _) -> ()
       | other ->
         failf "expected typed_outcome = Error, got %s"
           (match other with
            | None -> "None"
            | Some Outcome.Progress -> "Progress"
            | Some (Outcome.No_progress _) -> "No_progress"
            | Some (Outcome.Error _) -> "Error"))

let test_done_missing_evidence_refs_emits_typed_error () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = meta_with_active_goals [] in
       match
         rejected_done_typed_outcome ~base_path config meta
           (`Assoc
             [ "task_id", `String "task-001"
             ; "result", `String "implemented and opened PR#123"
             ])
       with
       | Some (Outcome.Error _) -> ()
       | other ->
         failf "expected typed_outcome = Error, got %s"
           (match other with
            | None -> "None"
            | Some Outcome.Progress -> "Progress"
            | Some (Outcome.No_progress _) -> "No_progress"
            | Some (Outcome.Error _) -> "Error"))

let test_done_failed_transition_emits_typed_error () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = meta_with_active_goals [] in
       (* A done on a task that does not exist fails the transition -> the
          [else] branch must emit a typed [Error], not [None]. *)
       match
         rejected_done_typed_outcome ~base_path config meta
           (`Assoc
             [ "task_id", `String "task-does-not-exist"
             ; "result", `String "completed"
             ; "evidence_refs", `List [ `String "PR#404" ]
             ])
       with
       | Some (Outcome.Error _) -> ()
       | other ->
         failf "expected typed_outcome = Error, got %s"
           (match other with
            | None -> "None"
            | Some Outcome.Progress -> "Progress"
            | Some (Outcome.No_progress _) -> "No_progress"
            | Some (Outcome.Error _) -> "Error"))

let () =
  run "keeper validation breaker exemption"
    [ ( "validation_failure_class"
      , [ test_case "producer tags policy_rejection" `Quick
            test_producer_tags_policy_rejection
        ; test_case "Gate#1 exempts validation, counts unclassified" `Quick
            test_gate1_exempts_validation_but_counts_unclassified
        ; test_case "Gate#2 still counts validation (no over-exempt)" `Quick
            test_gate2_still_counts_validation
        ; test_case
            "keeper_task_create treats ambiguous active_goal_ids as advisory"
            `Quick
            test_task_create_multi_active_goals_without_goal_id_is_unscoped
        ; test_case "state block reply returns state snapshot" `Quick
            test_state_block_reply_returns_state_snapshot
        ; test_case "rejected done (missing task_id) emits typed Error (D1)"
            `Quick test_done_missing_task_id_emits_typed_error
        ; test_case "rejected done (missing evidence_refs) emits typed Error (D1)"
            `Quick test_done_missing_evidence_refs_emits_typed_error
        ; test_case "rejected done (failed transition) emits typed Error (D1)"
            `Quick test_done_failed_transition_emits_typed_error
        ] )
    ]
