(** Keeper task outcome and response-finalization regression tests. *)

open Alcotest

module Task = Masc.Keeper_tool_task_runtime
module Response_text = Masc.Keeper_agent_run_response_text
module Receipt = Masc.Keeper_execution_receipt
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

let make_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "keeper-task-create-test"
        ; "agent_name", `String "keeper-task-create-test"
        ; "trace_id", `String "trace-task-create-test"
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let test_tasks_list_returns_producer_owned_typed_data () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = make_meta () in
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
      ~completion_contract_result:Receipt.Completion_response_observed
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
      ~completion_contract_result:Receipt.Completion_response_observed
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
       let meta = make_meta () in
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
       let meta = make_meta () in
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
       let meta = make_meta () in
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
  run "keeper task outcomes"
    [ ( "outcomes"
      , [ test_case
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
        ] )
    ]
