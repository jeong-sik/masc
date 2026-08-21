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

let keeper_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "task-create-test"
        ; "agent_name", `String "keeper-task-create-test-agent"
        ; "trace_id", `String "trace-task-create-test"
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let test_task_create_without_goal_id_is_unscoped () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = keeper_meta () in
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

(* A page is not the backlog. The sort keys on priority alone and is stable, so
   within one priority the newest task sits last and falls off [limit] first.
   Eight tasks registered at priority 2 and 3 stayed invisible across nineteen
   todo listings because the response gave no sign it had cut anything (#29101). *)
let test_tasks_list_reports_truncation () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = keeper_meta () in
       for index = 1 to 4 do
         ignore
           (Task.handle_keeper_task_tool
              ~config
              ~meta
              ~name:"keeper_task_create"
              ~args:
                (`Assoc
                  [ "title", `String (Printf.sprintf "task %d" index)
                  ; "description", `String "truncation fixture"
                  ; "priority", `Int 3
                  ]))
       done;
       let list_with_limit limit =
         let execution =
           Task.handle_keeper_task_tool_with_outcome
             ~config
             ~meta
             ~name:"keeper_tasks_list"
             ~args:(`Assoc [ "limit", `Int limit ])
         in
         match execution.data with
         | Some data -> data
         | None -> fail "expected producer-owned snapshot"
       in
       let cut = list_with_limit 2 in
       check int "matching count is the whole backlog" 4 U.(cut |> member "matching_count" |> to_int);
       check int "returned count is the page" 2 U.(cut |> member "returned_count" |> to_int);
       check bool "cut page says so" true U.(cut |> member "truncated" |> to_bool);
       check int "page holds the limit" 2 U.(cut |> member "snapshot" |> to_list |> List.length);
       let whole = list_with_limit 50 in
       check int "whole backlog matches" 4 U.(whole |> member "matching_count" |> to_int);
       check bool "whole backlog is not truncated" false U.(whole |> member "truncated" |> to_bool))
;;

let test_tasks_list_returns_snapshot_and_unchanged () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = keeper_meta () in
       let execution =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_tasks_list"
           ~args:(`Assoc [])
       in
       let snapshot =
         match execution.data with
         | Some data -> data
         | None -> fail "expected producer-owned snapshot"
       in
       check string "snapshot kind" "snapshot" U.(snapshot |> member "kind" |> to_string);
       let revision = U.(snapshot |> member "revision" |> to_string) in
       check int
         "empty typed task list"
         0
         U.(snapshot |> member "snapshot" |> to_list |> List.length);
       check string
         "raw rendering derives from snapshot"
         (Yojson.Safe.to_string snapshot)
         execution.raw_output;
       let unchanged =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_tasks_list"
           ~args:(`Assoc [ "if_revision", `String revision ])
       in
       let unchanged_data =
         match unchanged.data with
         | Some data -> data
         | None -> fail "expected producer-owned unchanged response"
       in
       check string
         "unchanged kind"
         "unchanged"
         U.(unchanged_data |> member "kind" |> to_string);
       check string
         "unchanged revision"
         revision
         U.(unchanged_data |> member "revision" |> to_string);
       check string
         "raw rendering derives from unchanged response"
         (Yojson.Safe.to_string unchanged_data)
       unchanged.raw_output)

let test_tasks_list_recovery_is_degraded_and_never_unchanged () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       ignore
         (Masc.Workspace.add_task
            config
            ~title:"Recovery-only task snapshot"
            ~priority:2
            ~description:"");
       Out_channel.with_open_text (Masc.Workspace.backlog_path config) (fun oc ->
         output_string oc "{not valid json");
       let meta = keeper_meta () in
       let execute args =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_tasks_list"
           ~args
       in
       let first_data = Option.get (execute (`Assoc [])).data in
       check string
         "recovery authority is explicit"
         "recovery_non_authoritative"
         U.(first_data |> member "backlog_authority" |> to_string);
       check bool
         "recovery snapshot is degraded"
         true
         U.(first_data |> member "degraded" |> to_bool);
       let revision = U.(first_data |> member "revision" |> to_string) in
       let repeated_data =
         Option.get (execute (`Assoc [ "if_revision", `String revision ])).data
       in
       check string
         "recovery cannot collapse to unchanged"
         "snapshot"
         U.(repeated_data |> member "kind" |> to_string))

let test_tasks_list_revision_covers_projected_contents () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       ignore
         (Masc.Workspace.add_task
            config
            ~title:"First workspace task"
            ~priority:1
            ~description:"");
       let meta = keeper_meta () in
       let snapshot () =
         match
           (Task.handle_keeper_task_tool_with_outcome
              ~config
              ~meta
              ~name:"keeper_tasks_list"
              ~args:(`Assoc [])).data
         with
         | Some data -> data
         | None -> fail "expected producer-owned snapshot"
       in
       let first = snapshot () in
       (* [.backlog] is the lock path ([Workspace_backlog.backlog_lock_path]),
          not the store. Reading it as JSON never had a chance to work. *)
       let backlog_path = Masc.Workspace.backlog_path config in
       let rewrite_title = function
         | `Assoc fields ->
           `Assoc
             (List.map
                (function
                  | "tasks", `List [ `Assoc task_fields ] ->
                    ( "tasks"
                    , `List
                        [ `Assoc
                            (List.map
                               (function
                                 | "title", _ -> "title", `String "Second workspace task"
                                 | field -> field)
                               task_fields)
                        ] )
                  | field -> field)
                fields)
         | other -> failf "unexpected backlog shape: %s" (Yojson.Safe.to_string other)
       in
       let original_backlog = Yojson.Safe.from_file backlog_path in
       let rewritten_backlog = rewrite_title original_backlog in
       Fs_compat.save_file backlog_path (Yojson.Safe.to_string rewritten_backlog);
       let second = snapshot () in
       check int
         "fixture keeps the exact backlog revision"
         U.(original_backlog |> member "version" |> to_int)
         U.(rewritten_backlog |> member "version" |> to_int);
       check string
         "fixture changes only visible task content"
         "Second workspace task"
         U.(second |> member "snapshot" |> index 0 |> member "title" |> to_string);
       check bool
         "same counter with different visible task content changes revision"
         true
         (not
            (String.equal
               U.(first |> member "revision" |> to_string)
               U.(second |> member "revision" |> to_string))))

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
       let meta = keeper_meta () in
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
       let meta = keeper_meta () in
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
       let meta = keeper_meta () in
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
  }

(* [verification_submit_request_fn] defaults to an error and is filled at boot
   by the server (`Verification_run_registry.install_global`). These two cases
   exercise the outcome the task tool returns, not the storage boundary behind
   it, so they stand in a persisting hook for the duration. Restored after, so
   a case that should see the absent-hook error still does. *)
let with_verification_persistence f =
  let previous = Atomic.get Workspace_hooks.verification_submit_request_fn in
  Atomic.set
    Workspace_hooks.verification_submit_request_fn
    (fun _config ~task:_ ~assignee:_ ~verification_id:_ ~evidence_refs:_ -> Ok ());
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.verification_submit_request_fn previous)
    f
;;

let test_strict_done_submits_for_verification () =
  with_verification_persistence @@ fun () ->
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
       let meta = keeper_meta () in
       ignore
         (Task.handle_keeper_task_tool
            ~config
            ~meta
            ~name:"keeper_task_done"
            ~args:
              (`Assoc
                [ "task_id", `String "task-001"
                ; "result", `String "implementation complete"
                ; "evidence_refs", `List [ `String "note:commit abc123" ]
                ]));
       match Masc.Workspace.get_tasks_raw config with
       | [ { task_status = Masc_domain.AwaitingVerification _;
             handoff_context = Some handoff; _ } ] ->
         check string "result preserved as summary"
           "implementation complete" handoff.summary;
         check (list string) "evidence preserved"
           [ "note:commit abc123" ] handoff.evidence_refs
       | [ _ ] -> fail "completion did not enter awaiting_verification"
       | tasks ->
         failf "expected exactly one persisted task, got %d" (List.length tasks))

let test_default_done_is_terminal () =
  with_verification_persistence @@ fun () ->
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
       let meta = keeper_meta () in
       let execution =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_task_done"
           ~args:
             (`Assoc
               [ "task_id", `String "task-001"
               ; "result", `String "implementation complete"
               ; "evidence_refs", `List [ `String "note:commit abc123" ]
               ])
       in
       (match execution.disposition with
        | Tool_result.Completed () -> ()
        | Tool_result.Deferred () -> fail "default completion was deferred"
        | Tool_result.Failed _ ->
          fail ("default completion failed: " ^ execution.raw_output));
       (* [keeper_task_done] submits evidence; it does not end the Task. The
          handler picks [submit_for_verification] unconditionally
          (keeper_tool_task_runtime.ml), with no strict/advisory branch, and
          [Workspace_task_lifecycle] refuses to resolve an
          [AwaitingVerification] obligation from any agent action. This case
          used to assert the default path was terminal, which stopped being
          true when the completion authority took over the verdict. *)
       match Masc.Workspace.get_tasks_raw config with
       | [ { task_status =
               Masc_domain.AwaitingVerification { verification_id; _ }
           ; handoff_context = Some handoff
           ; _
           } ] ->
         check string "result preserved as summary"
           "implementation complete" handoff.summary;
         check (list string) "evidence preserved"
           [ "note:commit abc123" ] handoff.evidence_refs;
         (match
            Masc.Workspace.commit_verdict_r
              config
              ~authority:
                (Masc_domain.Human_operator { operator_id = "operator" })
              ~verdict:Masc_domain.Verdict_approved
              ~task_id:"task-001"
              ~verification_id
              ()
          with
          | Ok _ -> ()
          | Error error ->
            fail ("verdict failed: " ^ Masc_domain.masc_error_to_string error));
         (match Masc.Workspace.get_tasks_raw config with
          | [ { task_status = Masc_domain.Done _; _ } ] -> ()
          | [ t ] ->
            failf
              "an approved obligation did not become Done: %s"
              (Masc_domain.show_task_status t.task_status)
          | tasks ->
            failf "expected exactly one persisted task, got %d"
              (List.length tasks))
       | [ t ] ->
         failf
           "keeper_task_done did not submit for verification: %s"
           (Masc_domain.show_task_status t.task_status)
       | tasks ->
         failf "expected exactly one persisted task, got %d" (List.length tasks))

(* Without an Eio fs context the workspace backend falls back to Memory
   (workspace_utils_backend_setup.ml), and three cases here reach past that
   backend: two write a corrupt backlog file directly to drive the recovery
   path, and one reads the persisted task back. Under the fallback the writes
   land nowhere the reader looks, so recovery reported [primary] and the done
   transition read as non-terminal. Bind the real filesystem once, here, so
   every case sees the store it writes to. *)
let () =
  Eio_main.run
  @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "keeper task outcomes"
    [ ( "outcomes"
      , [ test_case
            "keeper_task_create without goal_id remains unscoped"
            `Quick
            test_task_create_without_goal_id_is_unscoped
        ; test_case
            "keeper_tasks_list reports a truncated page"
            `Quick
            test_tasks_list_reports_truncation
        ; test_case
            "keeper_tasks_list returns snapshot and unchanged"
            `Quick
            test_tasks_list_returns_snapshot_and_unchanged
        ; test_case
            "keeper_tasks_list revision covers projected task contents"
            `Quick
            test_tasks_list_revision_covers_projected_contents
        ; test_case
            "keeper_tasks_list recovery is degraded and never unchanged"
            `Quick
            test_tasks_list_recovery_is_degraded_and_never_unchanged
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
        ; test_case "default done submits for verification"
            `Quick test_default_done_is_terminal
        ] )
    ]
