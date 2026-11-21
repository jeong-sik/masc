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

(* Sound, with unsigned reasoning ahead of the protected tail. *)
let sound =
  [ Types.user_msg "(autonomous wake)"
  ; assistant [ Types.Thinking { content = "unsigned"; signature = None }; Types.Text "reply" ]
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

let log_path config =
  Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name
;;

let line_text : Keeper_turn_log.line -> string = function
  | Log_started { mark; _ } -> Printf.sprintf "started at %d" mark.closed_messages
  | Opened _ -> "opened"
  | Closed _ -> "closed"
  | Reset { cause; before; after; closed_before; _ } ->
    Printf.sprintf "reset %s %d to %d, naming %d"
      (match cause with
       | Unannounced -> "unannounced"
       | Announced Cleared -> "cleared"
       | Announced Recovered -> "recovered")
      before.closed_messages after.closed_messages
      (List.fold_left (fun count (slice : Keeper_turn_log.slice) -> count + slice.take) 0 closed_before)
;;

let log_text config =
  String.split_on_char '\n' (Fs_compat.load_file (log_path config))
  |> List.filter (fun row -> not (String.equal row ""))
  |> List.map (fun row ->
    match Keeper_turn_log_codec.of_json (Yojson.Safe.from_string row) with
    | Ok line -> line_text line
    | Error error -> fail (Keeper_memory_os_types.wire_error_to_string error))
  |> String.concat "\n"
;;

let head config trace_id =
  match Keeper_turn_log_head.read ~session_dir:(session_dir config trace_id) ~session_id:trace_id with
  | Ok head -> head
  | Error error -> fail (Keeper_checkpoint_store_session.checkpoint_load_error_to_string error)
;;

let backups config =
  Sys.readdir (Workspace.masc_dir config)
  |> Array.to_list
  |> List.filter (String.starts_with ~prefix:"backups-checkpoint-purge-")
;;

(* The head was saved mid-turn, so every message is open. The line still
   names them all: they are closed first, then named, then dropped. *)
let test_a_recovery_names_what_it_drops =
  with_keeper
  @@ fun ~config ~trace_id ->
  write_head ~boundary:Agent_core.Checkpoint_objects.Turn_continues config trace_id broken;
  start_log config trace_id;
  check string "the log starts below the open messages" "started at 0" (log_text config);
  match Checkpoints.purge_current config ~keeper_name ~apply:true with
  | Error error -> fail (Checkpoints.purge_error_to_string error)
  | Ok result ->
    let before = result.report.messages_before in
    let after = result.report.messages_after in
    check bool "applied" true result.applied;
    check bool "the recovery dropped messages" true (after < before);
    check string "the line names every message, the open ones too"
      (Printf.sprintf "started at 0\nreset recovered %d to %d, naming %d" before after before)
      (log_text config);
    let installed = head config trace_id in
    check int "the head ends where the line says" after installed.closed_messages;
    check int "with nothing open" 0 installed.open_messages
;;

let test_a_purge_against_an_unreadable_turn_log_replaces_nothing =
  with_keeper
  @@ fun ~config ~trace_id ->
  write_head config trace_id broken;
  start_log config trace_id;
  let unreadable = Fs_compat.load_file (log_path config) ^ "not a line\n" in
  Fs_compat.save_file (log_path config) unreadable;
  let source = Fs_compat.load_file (canonical config trace_id) in
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Error (Checkpoints.Purge_turn_log_unreadable _) -> ()
   | Error error -> fail (Checkpoints.purge_error_to_string error)
   | Ok _ -> fail "a purge replaced the head against a turn log it could not read");
  check string "the head is as it was" source (Fs_compat.load_file (canonical config trace_id));
  check string "the log is as it was" unreadable (Fs_compat.load_file (log_path config));
  check (list string) "nothing was backed up" [] (backups config)
;;

let test_a_rewrite_writes_no_line =
  with_keeper
  @@ fun ~config ~trace_id ->
  write_head config trace_id sound;
  start_log config trace_id;
  let log = Fs_compat.load_file (log_path config) in
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Error error -> fail (Checkpoints.purge_error_to_string error)
   | Ok result ->
     check bool "applied" true result.applied;
     check int "nothing dropped" 0 result.report.messages_dropped_at_structural_break);
  check string "no line" log (Fs_compat.load_file (log_path config))
;;

(* The head grew past the log's last line. The next unit reads those
   messages from the head, so the purge leaves them byte-exact and rewrites
   only what the log has named. It reads no Memory writer and waits on none:
   none runs here. *)
let test_a_rewrite_leaves_what_no_line_has_named =
  with_keeper
  @@ fun ~config ~trace_id ->
  write_head config trace_id sound;
  start_log config trace_id;
  let later =
    assistant [ Types.Thinking { content = "not read yet"; signature = None }; Types.Text "later" ]
  in
  let grown = sound @ [ Types.user_msg "(autonomous wake)"; later ] @ recent in
  write_head config trace_id grown;
  let log = Fs_compat.load_file (log_path config) in
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Error error -> fail (Checkpoints.purge_error_to_string error)
   | Ok result ->
     check bool "applied" true result.applied;
     check int "only the reasoning the log has named is stripped" 1
       result.report.reasoning_blocks_stripped);
  check string "no line" log (Fs_compat.load_file (log_path config));
  let past_the_mark messages =
    List.map Types.show_message
      (List.filteri (fun index _ -> index >= List.length sound) messages)
  in
  match Store.load_agent_core ~session_dir:(session_dir config trace_id) ~session_id:trace_id with
  | Error _ -> fail "the purged head is not readable"
  | Ok purged ->
    check (list string) "the messages past the log's last line are as they were"
      (past_the_mark grown) (past_the_mark purged.messages)
;;

(* The head was replaced since the log's last line: it holds fewer closed
   messages than the line counts. The next unit reads all of it from the
   head, after the reset the next line writes, so the purge rewrites nothing
   and installs nothing, though the head's reasoning lies ahead of the
   protected tail. *)
let test_a_purge_of_a_replaced_head_rewrites_nothing =
  with_keeper
  @@ fun ~config ~trace_id ->
  write_head config trace_id (sound @ recent @ recent);
  start_log config trace_id;
  write_head config trace_id (sound @ recent);
  let head_bytes = Fs_compat.load_file (canonical config trace_id) in
  let log = Fs_compat.load_file (log_path config) in
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Error error -> fail (Checkpoints.purge_error_to_string error)
   | Ok result ->
     check bool "not applied" false result.applied;
     check int "nothing stripped" 0 result.report.reasoning_blocks_stripped);
  check string "the head is as it was" head_bytes (Fs_compat.load_file (canonical config trace_id));
  check string "no line" log (Fs_compat.load_file (log_path config));
  check (list string) "nothing was backed up" [] (backups config)
;;

let test_a_preview_writes_no_line =
  with_keeper
  @@ fun ~config ~trace_id ->
  write_head ~boundary:Agent_core.Checkpoint_objects.Turn_continues config trace_id broken;
  start_log config trace_id;
  let log = Fs_compat.load_file (log_path config) in
  (match Checkpoints.purge_current config ~keeper_name ~apply:false with
   | Error error -> fail (Checkpoints.purge_error_to_string error)
   | Ok preview -> check bool "not applied" false preview.applied);
  check string "no line" log (Fs_compat.load_file (log_path config));
  check int "nothing closed" (List.length broken) (head config trace_id).open_messages
;;

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "keeper_purge_turn_log"
    [ ( "dashboard purge"
      , [ test_case "a recovery names what it drops" `Quick test_a_recovery_names_what_it_drops
        ; test_case "a purge against a turn log it cannot read replaces nothing" `Quick
            test_a_purge_against_an_unreadable_turn_log_replaces_nothing
        ; test_case "a rewrite writes no line" `Quick test_a_rewrite_writes_no_line
        ; test_case "a rewrite leaves what no line has named" `Quick
            test_a_rewrite_leaves_what_no_line_has_named
        ; test_case "a purge of a replaced head rewrites nothing" `Quick
            test_a_purge_of_a_replaced_head_rewrites_nothing
        ; test_case "a preview writes no line" `Quick test_a_preview_writes_no_line
        ] )
    ]
;;
