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

let test_keeper_broadcast_forwards_typed_cache_signal () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = keeper_meta () in
       ignore
         (Masc.Workspace.bind_session
            config
            ~agent_name:meta.name
            ~capabilities:[ "test" ]
            ());
       let subject = Masc.Workspace.resolve_agent_name config meta.name in
       ignore
         (Masc.Workspace.add_task
            config
            ~title:"Terminal cache fixture"
            ~priority:1
            ~description:"");
       ignore (Masc.Workspace.claim_task config ~agent_name:subject ~task_id:"task-001");
       let backlog = Workspace_backlog.read_backlog_r config |> Result.get_ok in
       let terminal_backlog =
         { backlog with
           tasks =
             List.map
               (fun (task : Masc_domain.task) ->
                  if String.equal task.id "task-001"
                  then
                    { task with
                      task_status =
                        Masc_domain.Done
                          { assignee = subject
                          ; completed_at = "2026-08-22T00:00:00Z"
                          ; notes = Some "keeper broadcast cache fixture"
                          }
                    }
                  else task)
               backlog.tasks
         }
       in
       Workspace_backlog.write_backlog config terminal_backlog;
       let agent_file =
         Filename.concat
           (Masc.Workspace.agents_dir config)
           (Masc.Workspace.safe_filename subject ^ ".json")
       in
       let stale_agent =
         match
           Masc.Workspace.read_json config agent_file
           |> Masc_domain.agent_of_yojson
         with
         | Ok agent ->
           { agent with
             status = Masc_domain.Busy
           ; current_task = Some "task-001"
           }
         | Error detail -> fail ("fixture agent decode failed: " ^ detail)
       in
       Masc.Workspace.write_json
         config
         agent_file
         (Masc_domain.agent_to_yojson stale_agent);
       let execution =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_broadcast"
           ~args:
             (`Assoc
               [ "content", `String "typed stale cache observation"
               ; "task_cache_subject_agent", `String subject
               ; "task_cache_task_id", `String "task-001"
               ])
       in
       (match execution.disposition with
        | Tool_result.Completed () -> ()
        | Tool_result.Deferred () -> fail "keeper broadcast was deferred"
        | Tool_result.Failed _ ->
          fail ("keeper broadcast failed: " ^ execution.raw_output));
       check bool
         "keeper surface persists canonical cache invalidation"
         true
         (String_util.contains_substring
            execution.raw_output
            "[cache_invalidated]");
       let current_task =
         Option.bind
           (Masc.Workspace.get_agents_raw config
            |> List.find_opt (fun (agent : Masc_domain.agent) ->
              String.equal agent.name subject))
           (fun agent -> agent.current_task)
       in
       check (option string) "keeper surface clears exact stale cache" None current_task)

let test_keeper_broadcast_rejects_partial_typed_cache_signal () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let execution =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta:(keeper_meta ())
           ~name:"keeper_broadcast"
           ~args:
             (`Assoc
               [ "content", `String "partial typed signal"
               ; "task_cache_subject_agent", `String "subject"
               ])
       in
       (match execution.disposition with
        | Tool_result.Failed Tool_result.Policy_rejection -> ()
        | Tool_result.Failed _ -> fail "partial pair used the wrong failure class"
        | Tool_result.Completed () | Tool_result.Deferred () ->
          fail "partial typed cache pair was accepted");
       check bool
         "partial pair error names both fields"
         true
         (String_util.contains_substring
            execution.raw_output
            "task_cache_subject_agent and task_cache_task_id"))

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
       check bool "whole backlog is not truncated" false U.(whole |> member "truncated" |> to_bool);
       (* Re-issuing the truncated page's revision must answer [unchanged]
          without the row statistics: a response that carries zero rows and
          still said `truncated:true, returned_count:2` contradicted itself,
          and models resolved the contradiction by repeating the identical
          call (211 back-to-back identical pairs on 2026-09-01). *)
       let unchanged_execution =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_tasks_list"
           ~args:
             (`Assoc
               [ "limit", `Int 2
               ; "if_revision", `String U.(cut |> member "revision" |> to_string)
               ])
       in
       let unchanged_cut =
         match unchanged_execution.data with
         | Some data -> data
         | None -> fail "expected producer-owned unchanged response"
       in
       check string
         "truncated page revision answers unchanged"
         "unchanged"
         U.(unchanged_cut |> member "kind" |> to_string);
       List.iter
         (fun field ->
            check
              bool
              (Printf.sprintf "unchanged carries no %s" field)
              false
              (List.mem field (U.keys unchanged_cut)))
         [ "matching_count"; "returned_count"; "truncated" ])
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
         unchanged.raw_output;
       (* Exact key sets, not member-null probes: the snapshot keeps the row
          statistics, the unchanged variant must not carry them (it has no
          rows for them to describe). *)
       let sorted_keys json = List.sort String.compare (U.keys json) in
       check
         (list string)
         "snapshot key set"
         [ "backlog_authority"
         ; "degraded"
         ; "kind"
         ; "matching_count"
         ; "projection"
         ; "returned_count"
         ; "revision"
         ; "snapshot"
         ; "truncated"
         ]
         (sorted_keys snapshot);
       check
         (list string)
         "unchanged key set"
         [ "backlog_authority"; "degraded"; "kind"; "projection"; "revision" ]
         (sorted_keys unchanged_data);
       check string
         "unchanged backlog authority stays primary"
         "primary"
         U.(unchanged_data |> member "backlog_authority" |> to_string);
       check bool
         "unchanged is not degraded"
         false
         U.(unchanged_data |> member "degraded" |> to_bool))

let test_tasks_list_projection_compact_by_default_full_on_request () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = keeper_meta () in
       ignore
         (Task.handle_keeper_task_tool
            ~config
            ~meta
            ~name:"keeper_task_create"
            ~args:
              (`Assoc
                [ "title", `String "Projection fixture"
                ; "description", `String "a body the compact row must not carry"
                ; "priority", `Int 2
                ]));
       let list args =
         match
           (Task.handle_keeper_task_tool_with_outcome
              ~config
              ~meta
              ~name:"keeper_tasks_list"
              ~args)
             .data
         with
         | Some data -> data
         | None -> fail "expected producer-owned snapshot"
       in
       let only_row data =
         match U.(data |> member "snapshot" |> to_list) with
         | [ row ] -> row
         | rows -> failf "expected one row, got %d" (List.length rows)
       in
       let compact = list (`Assoc []) in
       check string "default projection is compact" "compact"
         U.(compact |> member "projection" |> to_string);
       let compact_row = only_row compact in
       check string "compact row keeps the title" "Projection fixture"
         U.(compact_row |> member "title" |> to_string);
       check string "compact row keeps the status" "todo"
         U.(compact_row |> member "status" |> to_string);
       check int "compact row keeps the priority" 2
         U.(compact_row |> member "priority" |> to_int);
       List.iter
         (fun field ->
            check bool (field ^ " is absent from the compact row") true
              (U.member field compact_row = `Null))
         [ "description"; "files"; "contract"; "handoff_context"; "execution_links" ];
       let full = list (`Assoc [ "projection", `String "full" ]) in
       check string "requested projection is echoed" "full"
         U.(full |> member "projection" |> to_string);
       let full_row = only_row full in
       check string "full row carries the description"
         "a body the compact row must not carry"
         U.(full_row |> member "description" |> to_string);
       check bool "full row carries files" true
         (U.member "files" full_row <> `Null);
       check bool "the two projections have distinct revisions" true
         (U.(compact |> member "revision" |> to_string)
          <> U.(full |> member "revision" |> to_string));
       let rejected =
         Task.handle_keeper_task_tool_with_outcome
           ~config
           ~meta
           ~name:"keeper_tasks_list"
           ~args:(`Assoc [ "projection", `String "summary" ])
       in
       check bool "unknown projection is rejected, not defaulted" true
         (rejected.data = None);
       check bool "rejection names the accepted values" true
         (let message = rejected.raw_output in
          let contains needle =
            let n = String.length needle and h = String.length message in
            let rec go i = i + n <= h && (String.sub message i n = needle || go (i + 1)) in
            go 0
          in
          contains "compact" && contains "full" && contains "summary"))
;;

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
       let agent_name = "task-create-test" in
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
       let agent_name = "task-create-test" in
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

(* task-540: an oversized artifact: evidence list must be refused at the
   keeper_task_done boundary with the byte count and the note: escape hatch,
   not submitted as a truncated prefix that stalls the completion authority.
   A same-size list under the limit must still submit. *)
let test_done_refuses_oversized_artifact_evidence () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       let agent_name = "task-create-test" in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       ignore
         (Masc.Workspace.add_task
            config
            ~title:"Oversized evidence refusal"
            ~priority:2
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
          fail ("claim failed: " ^ Masc_domain.masc_error_to_string error));
       let meta = keeper_meta () in
       (* Producer playground fixture: the artifact size check resolves
          [artifact:<path>] against the agent's sandbox root, so the file
          must exist there for the byte count to be measurable at all. *)
       let producer_root =
         Keeper_sandbox_config.host_root_abs_of_agent
           ~base_path:
             (Workspace_verification_store.project_root_of_base_path
                config.base_path)
           ~agent_name
       in
       let rec mkdir_p dir =
         if not (Sys.file_exists dir)
         then (
           mkdir_p (Filename.dirname dir);
           try Unix.mkdir dir 0o755
           with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
       in
       mkdir_p producer_root;
       let run_done evidence =
         Task.handle_keeper_task_tool
           ~config
           ~meta
           ~name:"keeper_task_done"
           ~args:
             (`Assoc
               [ "task_id", `String "task-001"
               ; "result", `String "implementation complete"
               ; "evidence_refs", `List evidence
               ])
       in
       let expected_limit = 512 in
       let expected_total = 513 in
       let big_artifact =
         Filename.concat producer_root (Printf.sprintf "big-%d.txt" expected_total)
       in
       Out_channel.with_open_text big_artifact (fun oc ->
         output_string oc (String.make expected_total 'x'));
       let payload =
         Task.with_evidence_total_bytes_limit expected_limit @@ fun () ->
         run_done
           [ `String
               (Printf.sprintf "artifact:big-%d.txt" expected_total)
           ]
       in
       let json = Yojson.Safe.from_string payload in
       check bool "oversized submit is not ok" false
         (json |> U.member "ok" |> U.to_bool);
       check bool "rejection names the measured total" true
         (String_util.contains_substring
            payload
            (Printf.sprintf "artifact total size %d bytes" expected_total));
       check bool "rejection names the limit" true
         (String_util.contains_substring
            payload
            (Printf.sprintf "exceeds limit %d bytes" expected_limit));
       check bool "rejection names the note: escape hatch" true
         (String_util.contains_substring payload "use note:");
       check bool "task stays claimed, not submitted" true
         (match Masc.Workspace.get_tasks_raw config with
          | [ { task_status = Masc_domain.Claimed _; _ } ] -> true
          | _ -> false))
;;

(* Without an Eio fs context the workspace backend falls back to Memory
   (workspace_utils_backend_setup.ml), and three cases here reach past that
   backend: two write a corrupt backlog file directly to drive the recovery
   path, and one reads the persisted task back. Under the fallback the writes
   land nowhere the reader looks, so recovery reported [primary] and the done
   transition read as non-terminal. Bind the real filesystem once, here, so
   every case sees the store it writes to. *)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* Keeper task payloads are not one shape. A claim reports refusal through
   [typed_outcome] and carries no "ok" at all -- a claimed task deliberately
   omits the field -- while the release path reports through "ok". Read
   refusal as "the payload says Error", which both express, so these tests do
   not pin a field one of the two tools never had. *)
let refused json =
  (match json |> U.member "ok" with
   | `Bool false -> true
   | _ -> false)
  || (match Outcome.of_json (json |> U.member "typed_outcome") with
      | Some (Outcome.Error _) -> true
      | Some Outcome.Progress | Some (Outcome.No_progress _) | None -> false)

let accepted json = not (refused json)

let release_test_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "release-test"
        ; "trace_id", `String "trace-release-test"
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let with_release_fixture f =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta = release_test_meta () in
       ignore
         (Masc.Workspace.bind_session
            config
            ~agent_name:meta.name
            ~capabilities:[ "test" ]
            ());
       ignore
         (Masc.Workspace.add_task config ~title:"Held work" ~priority:1 ~description:"");
       ignore
         (Masc.Workspace.add_task config ~title:"Other work" ~priority:1 ~description:"");
       let call name args =
         Yojson.Safe.from_string (Task.handle_keeper_task_tool ~config ~meta ~name ~args)
       in
       f call)

(* keeper_task_release exists so a Keeper holding work it cannot finish can go
   take different work. "release returned ok" on its own does not show that:
   the claim refusal reads backlog ownership, so the proof is the second claim
   failing before the release and succeeding after it. Before this tool that
   second claim stayed refused for the life of the Keeper. *)
let test_release_frees_the_keeper_to_claim_again () =
  with_release_fixture (fun call ->
    let claim task_id = call "keeper_task_claim" (`Assoc [ "task_id", `String task_id ]) in
    check bool "first claim succeeds" true (accepted (claim "task-001"));
    let second = claim "task-002" in
    check bool "a second claim is refused while the first is held" true (refused second);
    (* The refusal has to name something the reader can call. It used to name
       only masc_transition, which the Keeper surface projects away behind
       keeper_task_claim. *)
    check
      bool
      "the refusal names keeper_task_release"
      true
      (contains ~needle:"keeper_task_release" (Yojson.Safe.to_string second));
    let released =
      call
        "keeper_task_release"
        (`Assoc
          [ "task_id", `String "task-001"
          ; "summary", `String "blocked on a checkout this Keeper does not have"
          ])
    in
    check bool "release succeeds" true (accepted released);
    check
      bool
      "the Keeper can claim different work once it has handed the task back"
      true
      (accepted (claim "task-002")))

(* The next owner reads the summary and nothing else about where the work
   stands, so an empty one is refused at the tool rather than stored. *)
let test_release_without_summary_is_refused () =
  with_release_fixture (fun call ->
    check
      bool
      "claim succeeds"
      true
      (accepted (call "keeper_task_claim" (`Assoc [ "task_id", `String "task-001" ])));
    let rejection = call "keeper_task_release" (`Assoc [ "task_id", `String "task-001" ]) in
    check bool "release without a summary is refused" true (refused rejection);
    (* Pin the Keeper-vocabulary rejection, not the transition layer's. The
       transition also refuses an empty handoff_context.summary, so a test
       that only asked "was it refused" stayed green with this tool's own
       check deleted -- and the Keeper would then read a message naming
       handoff_context.summary, a field it never sent. Same reason
       keeper_task_done enforces its schema locally. *)
    check
      bool
      "the refusal names the parameter the Keeper actually sent"
      true
      (contains
         ~needle:"keeper_task_release rejected: summary required"
         (Yojson.Safe.to_string rejection));
    (* A refused release must not hand the task back anyway. Re-claiming
       task-001 is a bad probe -- an owner re-claiming what it holds can
       succeed -- so ask whether different work is still barred. *)
    check
      bool
      "different work is still barred after the refused release"
      true
      (refused (call "keeper_task_claim" (`Assoc [ "task_id", `String "task-002" ]))))

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
        ; test_case "keeper_broadcast forwards typed cache signal" `Quick
            test_keeper_broadcast_forwards_typed_cache_signal
        ; test_case "keeper_broadcast rejects partial typed cache signal" `Quick
            test_keeper_broadcast_rejects_partial_typed_cache_signal
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
        ; test_case
            "keeper_tasks_list is compact by default and full on request"
            `Quick
            test_tasks_list_projection_compact_by_default_full_on_request
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
        ; test_case
            "done refuses oversized artifact evidence (task-540)"
            `Quick test_done_refuses_oversized_artifact_evidence
        ; test_case
            "release frees the Keeper to claim different work"
            `Quick test_release_frees_the_keeper_to_claim_again
        ; test_case
            "release without a summary is refused and keeps the task held"
            `Quick test_release_without_summary_is_refused
        ] )
    ]
