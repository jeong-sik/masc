(* A stop that deletes the session writes the Keeper's turn log line first
   (RFC librarian-call-only-proposes §5.2): every time, without reading the
   head, from the last mark to nothing in the stores the directory holds. A
   line that is not written keeps the session and fails the step. *)

open Alcotest
open Masc
open Keeper_shutdown_types

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir path =
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Unix.chmod p 0o700;
      Array.iter (fun name -> rm (Filename.concat p name)) (Sys.readdir p);
      Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error _ -> ()
  in
  rm path
;;

let with_workspace f () =
  let base = temp_dir "keeper_shutdown_session_turn_log_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Fun.protect
         ~finally:(fun () -> Fs_compat.clear_fs ())
         (fun () ->
            let config = Workspace.default_config base in
            let (_ : string) = Workspace.init config ~agent_name:None in
            f ~config))
;;

let keeper_name = "session-turn-log"
let trace = "trace-session-turn-log"

let trace_id =
  match Keeper_id.Trace_id.of_string trace with
  | Ok trace_id -> trace_id
  | Error detail -> failf "trace id rejected: %s" detail
;;

let operation ~remove_session =
  { schema_version = Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id = Operation_id.generate ()
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id
  ; actor = "operator"
  ; cleanup_intent = { reason = Operator_stop_remove_meta; remove_session }
  ; turn_disposition = No_inflight_turn
  ; expected_backlog_version = 0
  ; owned_task_ids = []
  ; join_evidence = None
  ; phase = Joining_lanes
  ; created_at = Masc_domain.now_iso ()
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let session_dir config = Filename.concat (Keeper_types_profile.session_base_dir config) trace

let place config : Keeper_turn_log_recorder.place =
  { keepers_dir = Workspace.keepers_runtime_dir config
  ; base_path = config.Workspace.base_path
  ; keeper_name
  ; session_dir = session_dir config
  ; session_id = trace
  }
;;

let message role text : Agent_core.Types.message =
  { origin = Llm_provider.Types.Conversation
  ; role
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let checkpoint messages : Agent_core.Checkpoint.t =
  { provider_binding = None
  ; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace
  ; agent_name = keeper_name
  ; model = "test-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count = 1
  ; created_at = 1000.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; pending_input = None
  ; working_context = None
  }
;;

(* A session with two closed messages and an official-client history file,
   and a log that starts there. *)
let session_with_a_log config =
  Fs_compat.mkdir_p (session_dir config);
  (match
     Keeper_checkpoint_store.save_agent_core_classified ~session_dir:(session_dir config)
       ~history_retained:0 ~boundary:Agent_core.Checkpoint_objects.Turn_closes
       (checkpoint [ message User "asks"; message Assistant "answers" ])
   with
   | Ok (Keeper_checkpoint_store.Saved _) -> ()
   | Ok (Keeper_checkpoint_store.Stale_noop _) -> fail "the save was read as stale"
   | Error detail -> fail detail);
  Fs_compat.save_file
    (Keeper_turn_fragments.path ~session_dir:(session_dir config) Main)
    "{\"line\":1}\n";
  match
    Keeper_turn_log_recorder.record ~at:1.0 ~new_log_id:(Keeper_turn_log.Log_id.fresh ())
      (place config) Keeper_turn_log_writer.Process_start
  with
  | Ok (Keeper_turn_log_recorder.Appended _) -> ()
  | Ok Nothing_to_append -> fail "the log had started already"
  | Error error -> fail (Keeper_turn_log_recorder.not_recorded_to_string error)
;;

let log_path config =
  Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name
;;

let mark_text (mark : Keeper_turn_log.mark) =
  Printf.sprintf "%s:%d/history %d" mark.trace mark.closed_messages mark.history_bytes
;;

let log_text config =
  String.split_on_char '\n' (Fs_compat.load_file (log_path config))
  |> List.filter (fun row -> not (String.equal row ""))
  |> List.map (fun row ->
    match Keeper_turn_log_codec.of_json (Yojson.Safe.from_string row) with
    | Ok (Log_started { mark; _ }) -> "started at " ^ mark_text mark
    | Ok (Reset { cause = Unannounced; before; after; closed_before = []; _ }) ->
      Printf.sprintf "dropped %s -> %s" (mark_text before) (mark_text after)
    | Ok (Opened _ | Closed _ | Reset _) -> "another line"
    | Error error -> fail (Keeper_memory_os_types.wire_error_to_string error))
  |> String.concat "\n"
;;

let remove config ~remove_session =
  Keeper_shutdown_finalize.For_testing.remove_session_dir ~config (operation ~remove_session)
;;

let test_the_line_goes_before_the_session =
  with_workspace
  @@ fun ~config ->
  session_with_a_log config;
  (match remove config ~remove_session:true with
   | Ok () -> ()
   | Error detail -> fail detail);
  check bool "the session is gone" false (Sys.file_exists (session_dir config));
  check string "the drop line"
    (Printf.sprintf "started at %s:2/history 11\ndropped %s:2/history 11 -> %s:0/history 0" trace
       trace trace)
    (log_text config)
;;

let test_a_line_that_fails_keeps_the_session =
  with_workspace
  @@ fun ~config ->
  session_with_a_log config;
  let unreadable = Fs_compat.load_file (log_path config) ^ "not a line\n" in
  Fs_compat.save_file (log_path config) unreadable;
  (match remove config ~remove_session:true with
   | Ok () -> fail "the session was deleted with no line"
   | Error detail ->
     check bool "the step says the session was kept" true
       (String.starts_with ~prefix:"the session was kept: " detail));
  check bool "the session is kept" true (Sys.file_exists (session_dir config));
  check string "the log is as it was" unreadable (Fs_compat.load_file (log_path config))
;;

let test_a_stop_that_keeps_the_session_writes_nothing =
  with_workspace
  @@ fun ~config ->
  session_with_a_log config;
  let before = Fs_compat.load_file (log_path config) in
  (match remove config ~remove_session:false with
   | Ok () -> ()
   | Error detail -> fail detail);
  check bool "the session is kept" true (Sys.file_exists (session_dir config));
  check string "no line" before (Fs_compat.load_file (log_path config))
;;

let () =
  run "keeper_shutdown_session_turn_log"
    [ ( "session removal"
      , [ test_case "the line goes before the session" `Quick test_the_line_goes_before_the_session
        ; test_case "a line that fails keeps the session" `Quick
            test_a_line_that_fails_keeps_the_session
        ; test_case "a stop that keeps the session writes nothing" `Quick
            test_a_stop_that_keeps_the_session_writes_nothing
        ] )
    ]
;;
