(* A dashboard purge and the Keeper's turn log (RFC
   librarian-call-only-proposes §5.2, §5.6). A purge that drops what follows
   a break shrinks the head, so it writes the turn log line first: one save
   closes the open messages, and the line names everything closed since the
   last unit before the purged head goes in. A line that is not written
   replaces nothing. A purge that drops nothing writes no line and rewrites
   only what the log has named: the next unit reads the messages past the
   last unit's mark from the head, so they go out as they are. *)

open Alcotest
open Masc
module Checkpoints = Server_dashboard_http_keeper_api_checkpoints
module Store = Keeper_checkpoint_store
module Types = Agent_core.Types

let keeper_name = "purge-turn-log"

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_keeper f () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None
  @@ fun () ->
  let dir = Filename.temp_file "purge-turn-log" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> rm_rf dir)
  @@ fun () ->
  let state = Mcp_server.For_testing.create_state ~base_path:dir in
  let config = Mcp_server.workspace_config state in
  let trace_id = Keeper_identity.generate_trace_id ~now:1.0 () in
  (match
     Masc_test_deps.meta_of_json_fixture
       (`Assoc [ "name", `String keeper_name; "trace_id", `String trace_id ])
   with
   | Error detail -> fail detail
   | Ok meta ->
     (match Keeper_meta_store.replace_snapshot config meta with
      | Ok () -> ()
      | Error detail -> fail detail));
  f ~config ~trace_id
;;

let session_dir config trace_id = Keeper_types_support.keeper_session_dir config trace_id

let place config trace_id : Keeper_turn_log_recorder.place =
  { keepers_dir = Workspace.keepers_runtime_dir config
  ; base_path = config.Workspace.base_path
  ; keeper_name
  ; session_dir = session_dir config trace_id
  ; session_id = trace_id
  }
;;

let assistant content : Types.message =
  { origin = Llm_provider.Types.Conversation
  ; role = Types.Assistant
  ; content
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let tool_use id = Types.ToolUse { id; name = "test_tool"; input = `Assoc [] }

let recent =
  List.init Keeper_checkpoint_purge.default_config.keep_recent_messages (fun i ->
    Types.user_msg (Printf.sprintf "recent %d" i))
;;

(* Two tool cycles open before either is answered. *)
let broken =
  [ Types.user_msg "(autonomous wake)"
  ; assistant [ tool_use "c1" ]
  ; assistant [ tool_use "c2" ]
  ; Types.tool_result_msg ~tool_use_id:"c1" ~content:"one" ()
  ; Types.tool_result_msg ~tool_use_id:"c2" ~content:"two" ()
  ]
  @ recent
;;

let checkpoint ~trace_id messages : Agent_core.Checkpoint.t =
  { provider_binding = None
  ; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace_id
  ; agent_name = keeper_name
  ; model = "test-model"
  ; system_prompt = None
  ; messages
  ; usage = Types.empty_usage
  ; turn_count = 3
  ; created_at = 3.0
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
  ; response_format = Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; pending_input = None
  ; working_context = None
  }
;;

let canonical config trace_id =
  Store.agent_core_checkpoint_path ~session_dir:(session_dir config trace_id) ~session_id:trace_id
;;

(* The normal save refuses a broken transcript, so the head is written by
   hand, as a corrupt one sits on disk. *)
let write_head ?boundary config trace_id messages =
  let (_ : string) =
    Masc_test_deps.write_checkpoint_head ?boundary ~session_dir:(session_dir config trace_id)
      ~path:(canonical config trace_id) (checkpoint ~trace_id messages)
  in
  ()
;;

let start_log config trace_id =
  match
    Keeper_turn_log_recorder.record ~at:1.0 ~new_log_id:(Keeper_turn_log.Log_id.fresh ())
      (place config trace_id) Keeper_turn_log_writer.Process_start
  with
  | Ok (Keeper_turn_log_recorder.Appended _) -> ()
  | Ok Nothing_to_append -> fail "the log had started already"
  | Error error -> fail (Keeper_turn_log_recorder.not_recorded_to_string error)
;;

(* The old Librarian read position is in [librarian-progress.json]; the
   server no longer starts the lane that read atoms from it. A purge neither
   reads nor writes that file
   (RFC librarian-call-only-proposes §5.6): one that does not decode does
   not stop a recovery, and the recovery leaves it byte for byte. *)
let test_a_recovery_leaves_the_librarian_position_file =
  with_keeper
  @@ fun ~config ~trace_id ->
  write_head ~boundary:Agent_core.Checkpoint_objects.Turn_continues config trace_id broken;
  start_log config trace_id;
  let position_path =
    Keeper_librarian_progress.path_for_keepers_dir
      ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
  in
  let undecodable = "not a position\n" in
  Fs_compat.mkdir_p (Filename.dirname position_path);
  Fs_compat.save_file position_path undecodable;
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Error error -> fail (Checkpoints.purge_error_to_string error)
   | Ok result ->
     check bool "applied" true result.applied;
     check bool "the recovery dropped messages" true
       (result.report.messages_after < result.report.messages_before));
  check string "the position file is as it was" undecodable (Fs_compat.load_file position_path)
;;

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "keeper_purge_turn_log_librarian_progress"
    [ ( "dashboard purge"
      , [ test_case "a recovery leaves the Librarian position file" `Quick
            test_a_recovery_leaves_the_librarian_position_file
        ] )
    ]
;;
