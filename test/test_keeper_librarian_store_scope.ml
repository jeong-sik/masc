open Alcotest

module Workspace = Masc.Workspace
module Boundaries = Masc.Keeper_turn_boundaries
module Progress = Masc.Keeper_librarian_progress
module Meta = Masc.Keeper_meta_store
module Turn = Masc.Keeper_agent_run_turn_helpers

let keeper_name = "scope-keeper"

let with_workspace f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun _env ->
  let base_path = Filename.temp_dir "librarian-stores-" "" in
  Config_dir_resolver.reset ();
  Fun.protect ~finally:(fun () ->
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    let (_ : string) = Workspace.init config ~agent_name:None in
    f config)
;;

let meta trace_id =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc [ "name", `String keeper_name; "trace_id", `String trace_id ]) with
  | Ok meta -> meta
  | Error detail -> failf "fixture metadata: %s" detail
;;

let write_meta config trace_id =
  match Meta.replace_snapshot config (meta trace_id) with
  | Ok () -> ()
  | Error detail -> failf "write metadata: %s" detail
;;

let store_boundary config trace_id =
  match Boundaries.append ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name
    { recorded_at = 1.0; event = Boundaries.History_restarted { trace_id } } with
  | Ok () -> ()
  | Error error -> fail (Boundaries.append_error_to_string error)
;;

let read_boundaries config =
  match Boundaries.read
    ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name with
  | Ok lines -> List.map (fun (_, decoded) -> match decoded with
      | Ok record -> record.Boundaries.event
      | Error error -> fail (Boundaries.read_error_to_string error)) lines
  | Error detail -> fail detail
;;

let value trace_id : Progress.t =
  { position = { trace_id; end_atom = 1; last_atom_digest = "fixture-atom" }
  ; boundary_lines_seen = 1
  }
;;

let write_progress config trace_id =
  match Progress.write ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name (value trace_id) with
  | Ok () -> ()
  | Error error -> fail (Progress.write_error_to_string error)
;;

let read_progress config =
  match Progress.read ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name with
  | Ok value -> value
  | Error error -> fail (Progress.read_error_to_string error)
;;

let test_progress_is_not_a_metadata_record () =
  with_workspace @@ fun a ->
  write_meta a "trace-a";
  write_progress a "trace-a";
  let names = match Meta.persisted_keeper_names_result a with
    | Ok names -> names
    | Error detail -> fail detail in
  check (list string) "progress introduces no fake Keeper" [ keeper_name ] names
;;

let readable_journal_tail ~keepers_dir ~keeper_id ~limit =
  match Masc.Keeper_memory_os_current.read_journal_tail ~keepers_dir ~keeper_id ~limit with
  | Ok rows -> rows
  | Error detail -> failwith ("memory journal unreadable: " ^ detail)
;;

(* The purge is the one place that stops a Librarian unit early, and it does
   so before any file goes, whichever operation asked for the purge. *)
let test_purge_stops_the_running_librarian_unit_first () =
  with_workspace @@ fun a ->
  let module Lane = Masc.Keeper_memory_lane in
  let module Current = Masc.Keeper_memory_os_current in
  Lane.For_testing.reset ();
  Fun.protect ~finally:Lane.For_testing.reset @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Lane.init ~sw;
  Fs_compat.mkdir_p (Filename.dirname
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:a.base_path));
  store_boundary a "trace-a";
  write_progress a "trace-a";
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:a.base_path in
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name in
  let journal_lock = Fs_compat.private_jsonl_lock_path journal in
  let append_failure trace_id =
    Current.append_librarian_failure ~keepers_dir ~keeper_id:keeper_name
      ~now:1.0 ~trace_id ~kind:Current.Exact_execution_failure
      ~detail:"fixture failure" ~snapshot_present:false in
  let started, resolve_started = Eio.Promise.create () in
  let never, _never_resolver = Eio.Promise.create () in
  let cancelled = ref false in
  let journal_survived_until_cancel = ref false in
  (match Lane.submit ~base_path:a.base_path ~keeper_name (fun () ->
     append_failure "trace-before";
     Eio.Promise.resolve resolve_started ();
     try Eio.Promise.await never with
     | Eio.Cancel.Cancelled _ as exn ->
       cancelled := true;
       journal_survived_until_cancel := Sys.file_exists journal && Sys.file_exists journal_lock;
       raise exn) with
   | Lane.Submitted -> ()
   | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
     fail "the parked Librarian unit was not submitted");
  Eio.Promise.await started;
  check bool "ordinary append retains its stable lock" true (Sys.file_exists journal_lock);
  (match Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
    a ~keeper_name ~remove_configuration:false
    { Masc.Keeper_shutdown_types.requested_name = keeper_name } with
   | Ok () -> ()
   | Error detail -> failf "artifact purge: %s" detail);
  check bool "the unit was cancelled before the files went" true !cancelled;
  check bool "journal and lock remain until the writer is cancelled" true
    !journal_survived_until_cancel;
  check bool "quiesced purge removes the journal" false (Sys.file_exists journal);
  check bool "quiesced purge removes its stable sibling" false (Sys.file_exists journal_lock);
  check (option int) "nothing is left running on the lane" (Some 0)
    (Lane.For_testing.pending ~base_path:a.base_path ~keeper_name);
  check bool "no progress after the purge" true (read_progress a = None);
  check bool "no boundaries after the purge" true (read_boundaries a = []);
  append_failure "trace-after";
  check bool "a same-name successor recreates the lock" true (Sys.file_exists journal_lock);
  match readable_journal_tail ~keepers_dir ~keeper_id:keeper_name ~limit:10 with
  | [Ok (Current.Journal_failed entry)] ->
    check string "successor sees only its own journal entry" "trace-after" entry.trace_id
  | _ -> fail "successor journal did not contain exactly its new failure"
;;

(* Memory events are keyed by claim-hash memory ids, so a same-name keeper
   created after a purge would count the deleted keeper's retrievals as its own
   unless the sidecar goes with the keeper. *)
let test_purge_removes_memory_events () =
  with_workspace @@ fun a ->
  let module Events = Masc.Keeper_memory_os_events in
  Fs_compat.mkdir_p (Filename.dirname
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:a.base_path));
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:a.base_path in
  let path = Events.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name in
  let retrieved trace_id : Events.event =
    { recorded_at = 1.0; memory_id = "sha256:" ^ String.make 64 'a'; trace_id
    ; kind = Events.Retrieved { query = "pdf pages" } } in
  let append trace_id = match Events.append ~keepers_dir ~keeper_id:keeper_name
      (retrieved trace_id) with
    | Ok () -> ()
    | Error error -> fail (Events.append_error_to_string error) in
  let trace_ids () = match Events.read ~keepers_dir ~keeper_id:keeper_name with
    | Ok rows -> List.map (fun (_, decoded) -> match decoded with
        | Ok (event : Events.event) -> event.trace_id
        | Error error -> fail (Events.read_error_to_string error)) rows
    | Error error -> fail (Events.file_read_error_to_string error) in
  append "trace-before";
  check bool "events sidecar written" true (Sys.file_exists path);
  (match Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
    a ~keeper_name ~remove_configuration:false
    { Masc.Keeper_shutdown_types.requested_name = keeper_name } with
   | Ok () -> ()
   | Error detail -> failf "artifact purge: %s" detail);
  check bool "events sidecar removed" false (Sys.file_exists path);
  append "trace-after";
  check (list string) "a same-name keeper sees only its own events"
    [ "trace-after" ] (trace_ids ())
;;

let test_purge_removes_only_the_owned_admission_queue () =
  with_workspace @@ fun a ->
  let module Queue = Masc.Keeper_memory_admission_queue in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:a.base_path in
  Fs_compat.mkdir_p (Filename.dirname
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:a.base_path));
  let fact : Masc.Keeper_memory_os_types.fact =
    { claim = "Retain pending deployment context."; category = Fact;
      first_seen = 1.; last_seen = 1.;
      origin = {kind = Authored; trace_id = "purge-admission"};
      basis = Observed Transcript } in
  List.iter (fun keeper_id ->
    match Queue.append ~keepers_dir ~keeper_id ~request_id:"request" fact with
    | Ok _ -> () | Error detail -> fail (Queue.append_error_to_string detail)) [keeper_name; "other-keeper"];
  let other = Queue.path ~keepers_dir ~keeper_id:"other-keeper" in
  let before = Fs_compat.load_file other in
  (match Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
    a ~keeper_name ~remove_configuration:false
    { Masc.Keeper_shutdown_types.requested_name = keeper_name } with
   | Ok () -> () | Error detail -> fail detail);
  check bool "whole Keeper purge removes pending inputs in config scope" false
    (Sys.file_exists (Queue.path ~keepers_dir ~keeper_id:keeper_name));
  check string "another Keeper's pending input survives" before (Fs_compat.load_file other)
;;

(* [Workspace.init] makes the runtime root, so it is removed first: the
   reads below must not bring it back. *)
(* The Keeper's Memory writer, the commit lines it wrote, and a claim written
   through it by the Keeper. *)
module Writers = Masc.Librarian_writers
module Commit_log = Masc.Librarian_log_store
module Cleanup = Server_dashboard_http_keeper_memory_cleanup

let memory_id_of = Masc.Keeper_memory_os_types.memory_id_of_claim

let writers (config : Workspace.config) =
  match Masc.Keeper_memory_writers.find ~base_path:config.base_path with
  | Some writers -> writers
  | None -> fail "the workspace has no Memory writers"
;;

let commit_log_path (config : Workspace.config) =
  Commit_log.path_for_keepers_dir
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path)
    ~keeper_id:keeper_name
;;

let commits config =
  match
    Commit_log.fold (commit_log_path config) ~init:[] ~f:(fun seen (scanned : Commit_log.scanned) ->
      match scanned.line with
      | Ok (Committed commit) -> commit :: seen
      | Ok (Started _) -> seen
      | Error (_ : Commit_log.undecodable) -> fail "a commit line does not decode")
  with
  | Ok seen -> List.rev seen
  | Error error -> fail (Masc.Private_jsonl_scan.error_to_string error)
;;

let keeper_remembers config claim =
  match
    Writers.write (writers config) keeper_name ~by:Masc.Librarian_effects.Keeper ~trace:"turn-1"
      (Remember
         { claim
         ; category = Masc.Keeper_memory_os_types.Constraint
         ; basis = Masc.Keeper_memory_os_types.Observed Masc.Keeper_memory_os_types.Transcript
         })
  with
  | Written (_ : Masc.Librarian_log.commit) -> ()
  | Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _ ->
    fail "the claim of the fixture was not written"
;;

let retraction_text ((retraction : Cleanup.retraction), (result : Cleanup.retraction_result)) =
  match result with
  | Retraction_not_current -> retraction.memory_id ^ ": not current"
  | Retraction_committed commit ->
    Printf.sprintf "%s: retracted, removed %s" retraction.memory_id
      (String.concat ","
         (List.map
            (fun ((fact : Masc.Keeper_memory_os_types.fact), (_ : Masc.Librarian_effects.removal)) ->
               fact.claim)
            commit.effects.removed))
;;

let stopped_text (outcome : Cleanup.retractions_outcome) =
  match outcome.stopped with
  | None -> "not stopped"
  | Some (retraction, why) ->
    retraction.memory_id ^ ": "
    ^ Masc.Keeper_tool_memory_validation.memory_unwritable_to_string why
;;

let port = "the port is 8935"
let owner = "the owner is the release team"

let request ids : Cleanup.current_memory_request =
  { plan_id = "plan-1"
  ; retractions = List.map (fun memory_id : Cleanup.retraction -> { memory_id; reason = "wrong" }) ids
  }
;;

(* An operator's retractions are direct writes to the Keeper's writer, so
   they are lines of the commit log and do not change the snapshot behind
   the writer. *)
let test_operator_retractions_go_through_the_writer () =
  with_workspace @@ fun a ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.ensure_memory_writer ~sw ~config:a keeper_name;
  keeper_remembers a port;
  keeper_remembers a owner;
  let never_written = memory_id_of "never written" in
  let retract request =
    Cleanup.retract_through_writer ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1"
      request
  in
  let outcome = retract (request [ memory_id_of port; never_written ]) in
  check string "every retraction was answered" "not stopped" (stopped_text outcome);
  check (list string) "one left Memory and one was never there"
    [ memory_id_of port ^ ": retracted, removed " ^ port; never_written ^ ": not current" ]
    (List.map retraction_text outcome.answered);
  (match List.rev (commits a) with
   | last :: _ ->
     (match last.cause with
      | Direct { by = Operator operator; trace; write = Retract { id; reason } } ->
        check (list string) "the line names the operator, the plan, the fact and the reason"
          [ "operator-1"; "plan-1"; memory_id_of port; "wrong" ]
          [ operator; trace; id; reason ]
      | Direct { by = Keeper | Operator _; write = Remember _ | Supersede _ | Retract _; _ }
      | Adopt _ -> fail "the last commit line is not the operator's retraction");
     (match last.effects.removed with
      | [ ((fact : Masc.Keeper_memory_os_types.fact), Retracted { by = Operator by; reason }) ] ->
        check (list string) "the fact left with the operator's name and reason"
          [ port; "operator-1"; "wrong" ]
          [ fact.claim; by; reason ]
      | _ -> fail "the retraction removed something else")
   | [] -> fail "nothing was committed");
  check int "two claims and one retraction are three lines" 3 (List.length (commits a));
  (match Writers.write (writers a) keeper_name ~by:Masc.Librarian_effects.Keeper ~trace:"turn-2"
           (Retract { id = memory_id_of owner; reason = "moved" })
   with
   | Written (_ : Masc.Librarian_log.commit) -> ()
   | Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _ ->
     fail "the Keeper's writer did not go on after the operator's retraction");
  let again = retract (request [ memory_id_of port; never_written ]) in
  check (list string) "the same request again finds neither"
    [ memory_id_of port ^ ": not current"; never_written ^ ": not current" ]
    (List.map retraction_text again.answered);
  check int "and commits nothing" 4 (List.length (commits a));
  let unregistered =
    Cleanup.retract_through_writer ~base_path:a.base_path ~keeper:"another-keeper"
      ~actor:"operator-1" (request [ memory_id_of port; never_written ])
  in
  check string "a Keeper out of the registry has no writer"
    (memory_id_of port ^ ": keeper_not_registered")
    (stopped_text unregistered);
  check int "and nothing of the request was answered" 0 (List.length unregistered.answered)
;;

let test_operator_retractions_without_writers () =
  with_workspace @@ fun a ->
  let outcome =
    Cleanup.retract_through_writer ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1"
      (request [ memory_id_of port ])
  in
  check string "a process that started no writers" (memory_id_of port ^ ": no_writer_in_process")
    (stopped_text outcome)
;;

(* The writer holds the commit log and its lock while the Keeper is in the
   registry. The purge ends it first, and does not remove the files of a
   Keeper that is registered. *)
let test_purge_ends_the_memory_writer_first () =
  with_workspace @@ fun a ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.mkdir_p (Filename.dirname
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:a.base_path));
  Masc_test_deps.ensure_memory_writer ~sw ~config:a keeper_name;
  keeper_remembers a port;
  let purge () =
    Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
      a ~keeper_name ~remove_configuration:false
      { Masc.Keeper_shutdown_types.requested_name = keeper_name }
  in
  check bool "a registered Keeper is not purged" true (Result.is_error (purge ()));
  check bool "its commit log is where it was" true (Sys.file_exists (commit_log_path a));
  check int "and its writer goes on" 1 (List.length (Writers.statuses (writers a)));
  Masc.Keeper_registry.For_testing.unregister ~base_path:a.base_path keeper_name;
  (match purge () with
   | Ok () -> ()
   | Error detail -> failf "artifact purge: %s" detail);
  check int "the writer has ended" 0 (List.length (Writers.statuses (writers a)));
  check bool "the commit log is removed" false (Sys.file_exists (commit_log_path a))
;;

let test_reads_do_not_create_runtime_directories () =
  with_workspace @@ fun a ->
  let root = Workspace.keepers_runtime_dir a in
  Fs_compat.remove_tree root;
  check bool "runtime root absent before read" false (Sys.file_exists root);
  check bool "no boundary yet" true (read_boundaries a = []);
  check bool "no progress yet" true (read_progress a = None);
  check bool "runtime root absent after read" false (Sys.file_exists root)
;;

let () =
  run "Librarian runtime store scope"
    [ "store scope",
        [ test_case "progress is not Keeper metadata" `Quick
            test_progress_is_not_a_metadata_record
        ; test_case "purge stops the running Librarian unit first" `Quick
            test_purge_stops_the_running_librarian_unit_first
        ; test_case "purge removes memory events" `Quick
            test_purge_removes_memory_events
        ; test_case "whole Keeper purge removes only its pending admission input" `Quick
            test_purge_removes_only_the_owned_admission_queue
        ; test_case "operator retractions go through the Memory writer" `Quick
            test_operator_retractions_go_through_the_writer
        ; test_case "operator retractions in a process without writers" `Quick
            test_operator_retractions_without_writers
        ; test_case "purge ends the Memory writer first" `Quick
            test_purge_ends_the_memory_writer_first
        ; test_case "reading absent stores creates no directories" `Quick
            test_reads_do_not_create_runtime_directories
        ]
    ]
