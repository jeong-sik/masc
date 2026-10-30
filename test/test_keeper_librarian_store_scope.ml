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

let restart config trace_id =
  Turn.record_history_restart ~config ~keeper_name ~trace_id Turn.At_turn_start
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
  match Current.read_journal_tail ~keepers_dir ~keeper_id:keeper_name ~limit:10 with
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
        ; test_case "reading absent stores creates no directories" `Quick
            test_reads_do_not_create_runtime_directories
        ]
    ]
