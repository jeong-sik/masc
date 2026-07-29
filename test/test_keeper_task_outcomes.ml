(** Keeper task outcome and response-finalization regression tests. *)

open Alcotest

module Task = Masc.Keeper_tool_task_runtime
module Response_text = Masc.Keeper_agent_run_response_text
module U = Yojson.Safe.Util
(* Tool_result lives in the leaf [masc_tool_types] lib (wrapped false), so
   it is referenced bare — not under [Masc.] — matching existing tests. *)
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
        [ "name", `String "task-create-test"
        ; "agent_name", `String "keeper-task-create-test-agent"
        ; "trace_id", `String "trace-task-create-test"
        ; ( "active_goal_ids"
          , `List (List.map (fun goal_id -> `String goal_id) goal_ids) )
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

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

let test_tasks_list_returns_producer_owned_typed_data () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = meta_with_active_goals [] in
       let execution =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_tasks_list"
           ~args:(`Assoc [])
       in
       match execution.data with
       | Some (`List tasks) ->
         check int "empty typed task list" 0 (List.length tasks);
         check string
           "raw rendering derives from typed data"
           "[]"
           execution.raw_output
       | Some other ->
         failf "expected typed list, got %s" (Yojson.Safe.to_string other)
       | None -> fail "expected producer-owned typed list")

let test_response_finalization_keeps_visible_reply_only () =
  let finalized =
    Response_text.finalize
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:"Completed with typed tool evidence."
      ()
  in
  check string
    "visible assistant reply is preserved"
    "Completed with typed tool evidence."
    finalized.response_text;
  let suppressed =
    Response_text.finalize
      ~stop_reason:Runtime_agent.Completed
      ~raw_response_text:"Internal completion text"
      ~suppress_response_text:true
      ()
  in
  check string "explicit suppression is empty" "" suppressed.response_text
;;

(* A rejected [keeper_task_done] carries producer-owned typed outcome data.
   Consumers may decode this typed payload at an explicit schema boundary;
   model-facing output text is not an authority for reconstructing it. *)
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

let strict_contract : Masc_domain.task_contract =
  { strict = true
  ; completion_contract = [ "peer verification required" ]
  ; required_evidence = []
  ; inspect_gate_evidence = []
  ; verify_gate_evidence = []
  ; links = { operation_id = None; session_id = None }
  }

let test_strict_done_submits_for_verification () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       let agent_name = "keeper-task-create-test-agent" in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       ignore
         (Masc.Workspace.add_task
            config
            ~contract:strict_contract
            ~title:"Evidence-bearing completion"
            ~priority:1
            ~description:"");
       ignore
         (Masc.Workspace.bind_session
            config
            ~agent_name
            ~capabilities:[]
            ());
       (match
          Masc.Workspace.claim_task_r
            config
            ~agent_name
            ~task_id:"task-001"
            ()
        with
        | Ok _ -> ()
        | Error error ->
          fail
            ("claim failed: " ^ Masc_domain.masc_error_to_string error));
       let meta = meta_with_active_goals [] in
       ignore
         (Task.handle_keeper_task_tool
            ~config
            ~meta
            ~name:"keeper_task_done"
            ~args:
              (`Assoc
                [ "task_id", `String "task-001"
                ; "result", `String "implementation complete"
                ; "evidence_refs", `List [ `String "commit:abc123" ]
                ]));
       match Masc.Workspace.get_tasks_raw config with
       | [ { task_status = Masc_domain.AwaitingVerification _;
             handoff_context = Some handoff; _ } ] ->
         check string "result preserved as summary"
           "implementation complete" handoff.summary;
         check (list string) "evidence preserved"
           [ "commit:abc123" ] handoff.evidence_refs
       | [ _ ] -> fail "completion did not enter awaiting_verification"
       | tasks ->
         failf "expected exactly one persisted task, got %d" (List.length tasks))

let test_default_done_is_terminal () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       let agent_name = "keeper-task-create-test-agent" in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       ignore
         (Masc.Workspace.add_task
            config
            ~title:"Advisory completion"
            ~priority:1
            ~description:"");
       ignore
         (Masc.Workspace.bind_session
            config
            ~agent_name
            ~capabilities:[]
            ());
       (match
          Masc.Workspace.claim_task_r
            config
            ~agent_name
            ~task_id:"task-001"
            ()
        with
        | Ok _ -> ()
        | Error error ->
          fail
            ("claim failed: " ^ Masc_domain.masc_error_to_string error));
       let meta = meta_with_active_goals [] in
       let execution =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_task_done"
           ~args:
             (`Assoc
               [ "task_id", `String "task-001"
               ; "result", `String "implementation complete"
               ; "evidence_refs", `List [ `String "commit:abc123" ]
               ])
       in
       (match execution.disposition with
        | Tool_result.Completed () -> ()
        | Tool_result.Deferred () -> fail "default completion was deferred"
        | Tool_result.Failed _ ->
          fail ("default completion failed: " ^ execution.raw_output));
       match Masc.Workspace.get_tasks_raw config with
       | [ { task_status = Masc_domain.Done _;
             handoff_context = Some handoff; _ } ] ->
         check string "result preserved as summary"
           "implementation complete" handoff.summary;
         check (list string) "evidence preserved"
           [ "commit:abc123" ] handoff.evidence_refs
       | [ _ ] -> fail "advisory/default completion was not terminal"
       | tasks ->
         failf "expected exactly one persisted task, got %d" (List.length tasks))

let () =
  run "keeper task outcomes"
    [ ( "outcomes"
      , [ test_case
            "keeper_task_create treats ambiguous active_goal_ids as advisory"
            `Quick
            test_task_create_multi_active_goals_without_goal_id_is_unscoped
        ; test_case
            "keeper_tasks_list returns typed data"
            `Quick
            test_tasks_list_returns_producer_owned_typed_data
        ; test_case "response finalization keeps visible reply only" `Quick
            test_response_finalization_keeps_visible_reply_only
        ; test_case "rejected done (missing task_id) emits typed Error (D1)"
            `Quick test_done_missing_task_id_emits_typed_error
        ; test_case "rejected done (missing evidence_refs) emits typed Error (D1)"
            `Quick test_done_missing_evidence_refs_emits_typed_error
        ; test_case "rejected done (failed transition) emits typed Error (D1)"
            `Quick test_done_failed_transition_emits_typed_error
        ; test_case "strict done submits for verification"
            `Quick test_strict_done_submits_for_verification
        ; test_case "default done is terminal"
            `Quick test_default_done_is_terminal
        ] )
    ]
