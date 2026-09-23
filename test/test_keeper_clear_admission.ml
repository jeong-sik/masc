open Masc
open Alcotest

module Context = Keeper_context_core

let require_ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let with_keeper
      ?(save_checkpoint = true)
      ?(official_owner_epoch = Keeper_official_client_session_store.process_epoch ())
      ~paused
      ~install_owner
      f
  =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-clear-admission-" "" in
  let runtime_before = Runtime.For_testing.snapshot () in
  let startup_before = Runtime_startup_state.get () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_before;
      Runtime_startup_state.set startup_before;
      Keeper_registry.For_testing.clear ();
      Fs_compat.remove_tree base_path)
  @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  let runtime_path = Filename.concat base_path "runtime.toml" in
  Fs_compat.save_file runtime_path {|[runtime]
default = "clear_fixture.model"
[providers.clear_fixture]
protocol = "claude-code"
command = "/fixture-must-not-run-a-model"
is-non-interactive = true
[models.model]
api-name = "clear-fixture"
max-context = 4096
[clear_fixture.model]
|};
  Runtime.init_default ~config_path:runtime_path |> require_ok;
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "clear-admission-fixture"
              ; "trace_id", `String "trace-clear-admission-fixture"
              ; "activation_mode", `String "manual" ])
    |> require_ok
  in
  let meta = { meta with paused } in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file (Filename.concat keepers_dir (meta.name ^ ".toml"))
    "[keeper]\ninstructions = \"Clear admission fixture\"\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\n";
  Keeper_meta_store.replace_snapshot config meta |> require_ok;
  ignore (Keeper_registry.register_offline ~base_path meta.name meta);
  if install_owner then (
    match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
      ~on_turn_slot_released:None config with
    | Ok _ -> ()
    | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
  let base_dir = Keeper_types_profile.session_base_dir config in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session = Context.create_session ~session_id:trace_id ~base_dir in
  let saved =
    Context.append_many (Context.create ~eio:true ~system_prompt:"pinned")
      [ Agent_core.Types.user_msg "work already done"
      ; Agent_core.Types.assistant_msg "saved result" ]
  in
  let save ctx =
    match Context.save_agent_core_checkpoint_classified
      ~runtime_id:"fixture-runtime" ~keeper_name:meta.name ~session
      ~agent_name:meta.name ~ctx with
    | Ok (_, Keeper_checkpoint_store.Saved _) -> ()
    | Ok (_, Keeper_checkpoint_store.Stale_noop _) -> fail "save was stale"
    | Error error ->
      fail (Context.checkpoint_write_error_to_string
        ~persistence_error_to_string:Fun.id error)
  in
  if save_checkpoint then save saved;
  let _official_session =
    Keeper_official_client_session_store.claim
      ~base_path
      ~keeper_name:meta.name
      ~expected:None
      ~client_kind:Keeper_official_client_session_store.Claude_code
      ~owner_epoch:official_owner_epoch
      ~runtime_id:"clear_fixture.model"
      ~tool_surface_sha256:
        (Keeper_official_client_session_store.tool_surface_sha256
           ~native_posture:Runtime_native_tools.Native_none
           [])
      ~updated_at:1.0
    |> require_ok
  in
  let load () =
    match Context.load_context_from_checkpoint ~trace_id ~base_dir with
    | _, Some context -> context
    | _, None -> fail "checkpoint disappeared"
  in
  let ctx : _ Keeper_tool_surface.context =
    { config; agent_name = "operator"; sw; clock = Eio.Stdenv.clock env
    ; proc_mgr = None; net = None
    ; publication_recovery_provider =
        Keeper_publication_recovery_availability.non_runtime_provider }
  in
  let clear () =
    match Keeper_tool_surface.dispatch ctx ~name:"masc_keeper_clear"
      ~args:(`Assoc [ "name", `String meta.name; "reason", `String "operator reset" ]) with
    | Some result -> result
    | None -> fail "clear tool was not dispatched"
  in
  let official_session () =
    Keeper_official_client_session_store.load
      ~base_path
      ~keeper_name:meta.name
    |> require_ok
  in
  f ~config ~meta ~saved ~save ~load ~clear ~official_session
;;

let check_refused result =
  check bool "clear was refused" true (Tool_result.is_failed result);
  match result with
  | Tool_result.Failed { effect_disposition = Proven_pre_effect; _ } -> ()
  | _ -> failf "refusal did not prove that no effect started: %s" (Tool_result.message result)
;;

let check_empty load =
  let messages = Context.messages_of_context (load ()) in
  check bool "conversation is empty" true
    (List.for_all (fun (message : Agent_core.Types.message) ->
       message.role = Agent_core.Types.System) messages)
;;

let check_official_session_cleared official_session =
  check bool "official-client session is absent" true
    (Option.is_none (official_session ()))
;;

let test_clear_does_not_race_the_active_turn () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved ~save ~load ~clear ~official_session ->
  (match Keeper_owner_registry.run_autonomous_if_idle
    ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
      let before = Context.messages_of_context (load ()) in
      check_refused (clear ());
      check bool "busy clear kept the official-client session" true
        (Option.is_some (official_session ()));
      check bool "busy clear left canonical history untouched" true
        (before = Context.messages_of_context (load ()));
      (* The turn still owns its original history and is allowed to finish. *)
      save saved) with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _ | `Interrupted) -> fail "fixture turn did not run"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load;
  check_official_session_cleared official_session;
  (match Keeper_owner_registry.run_autonomous_if_idle
    ~base_path:config.base_path ~keeper_name:meta.name (fun () -> check_empty load) with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _ | `Interrupted) -> fail "next turn did not run"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error))
;;

let test_paused_keeper_can_clear_without_resuming () =
  with_keeper ~paused:true ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ->
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load;
  check_official_session_cleared official_session;
  match Keeper_meta_store.read_meta config meta.name |> require_ok with
  | Some current -> check bool "clear does not resume the keeper" true current.paused
  | None -> fail "keeper metadata disappeared"
;;

let test_missing_owner_does_not_clear () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config:_ ~meta:_ ~saved ~save:_ ~load ~clear ~official_session ->
  check_refused (clear ());
  check bool "unavailable owner kept the official-client session" true
    (Option.is_some (official_session ()));
  check bool "unavailable owner left history untouched" true
    (Context.messages_of_context saved = Context.messages_of_context (load ()))
;;

let checkpoint_path config (meta : Keeper_meta_contract.keeper_meta) =
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  Keeper_checkpoint_store.agent_core_checkpoint_path
    ~session_dir:(Keeper_types_support.keeper_session_dir config trace_id)
    ~session_id:trace_id
;;

(* A checkpoint no turn can read fails every turn, so the operator's clear
   moves it aside: the bytes stay on disk under the archive name, the
   canonical is gone, and the next turn starts from no checkpoint. *)
let test_unreadable_checkpoint_is_archived fault () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ->
  let path = checkpoint_path config meta in
  let missing_target = path ^ ".missing" in
  let unreadable_bytes =
    match fault with
    | `Malformed -> "{broken-checkpoint"
    | `Newer_version ->
      (match Yojson.Safe.from_string (Fs_compat.load_file path) with
       | `Assoc fields ->
         Yojson.Safe.to_string
           (`Assoc
             (List.map
                (fun (key, value) ->
                   if String.equal key "version"
                   then key, `Int (Agent_core.Checkpoint.checkpoint_version + 1)
                   else key, value)
                fields))
       | _ -> fail "checkpoint is not a JSON object")
    | `Unreadable_path -> missing_target
  in
  Unix.unlink path;
  (match fault with
   | `Malformed | `Newer_version -> Fs_compat.save_file path unreadable_bytes
   | `Unreadable_path -> Unix.symlink missing_target path);
  ignore (Keeper_turn_failure_streak.increment
    ~base_path:config.base_path ~keeper_name:meta.name);
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  let archived =
    Tool_result.data result |> Yojson.Safe.Util.member "unreadable_checkpoint_archived"
  in
  let field name = Yojson.Safe.Util.(member name archived |> to_string) in
  check string "result names the checkpoint it moved" path (field "checkpoint_path");
  let archive_path = field "archive_path" in
  check string "archive sits beside the checkpoint"
    (Unix.realpath (Filename.dirname path)) (Filename.dirname archive_path);
  (match fault with
   | `Malformed | `Newer_version ->
     check string "archive holds the original bytes" unreadable_bytes
       (Fs_compat.load_file archive_path)
   | `Unreadable_path ->
     check string "archive is the original link" unreadable_bytes
       (Unix.readlink archive_path));
  check bool "the canonical checkpoint is gone" true
    (match Unix.lstat path with
     | _ -> false
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true);
  check bool "a moved checkpoint counts as found" true
    Yojson.Safe.Util.(Tool_result.data result |> member "checkpoint_found" |> to_bool);
  check_official_session_cleared official_session;
  check int "clear resets the failure streak" 0
    (Keeper_registry.get_turn_failures ~base_path:config.base_path meta.name);
  let base_dir = Keeper_types_profile.session_base_dir config in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  match Keeper_owner_registry.run_autonomous_if_idle
    ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
      match Context.load_context_from_checkpoint_classified ~trace_id ~base_dir with
      | _, Context.Checkpoint_absent -> ()
      | _, Context.Checkpoint_loaded _ -> fail "next turn loaded a checkpoint"
      | _, Context.Checkpoint_unread error ->
        fail ("next turn still cannot read its checkpoint: "
              ^ Keeper_checkpoint_store.checkpoint_load_error_to_string error)) with
  | Ok (`Ran ()) -> ()
  | Ok (`Busy _ | `Interrupted) -> fail "next turn did not run"
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
;;

let session_dir_of config (meta : Keeper_meta_contract.keeper_meta) =
  Keeper_types_support.keeper_session_dir config
    (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
;;

let with_mode path mode f =
  let before = (Unix.stat path).Unix.st_perm in
  Unix.chmod path mode;
  Fun.protect ~finally:(fun () -> Unix.chmod path before) f
;;

let unreadable_archives session_dir =
  Sys.readdir session_dir |> Array.to_list
  |> List.filter (fun name ->
    String.starts_with ~prefix:(Filename.basename session_dir ^ ".json.unreadable-") name)
;;

let malformed = "{broken-checkpoint"

(* One fixed time, so the archive name is known before the call. *)
let archived_at = 1.0

let archive config meta =
  let session_dir = session_dir_of config meta in
  Keeper_checkpoint_store.archive_unreadable_canonical ~session_dir
    ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~archived_at
;;

let archive_error_message = function
  | Ok _ -> "Ok"
  | Error error -> Keeper_checkpoint_store.unreadable_archive_error_to_string error
;;

let test_archive_leaves_a_loadable_checkpoint () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ->
  let path = checkpoint_path config meta in
  let original = Fs_compat.load_file path in
  (match archive config meta with
   | Ok Keeper_checkpoint_store.Canonical_loadable -> ()
   | other -> failf "a readable checkpoint was not left alone: %s" (archive_error_message other));
  check string "the readable checkpoint is untouched" original (Fs_compat.load_file path);
  check (list string) "nothing was archived" [] (unreadable_archives (session_dir_of config meta))
;;

let test_archive_reports_absence () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ->
  Unix.unlink (checkpoint_path config meta);
  match archive config meta with
  | Ok Keeper_checkpoint_store.Canonical_absent -> ()
  | other -> failf "absence was not reported: %s" (archive_error_message other)
;;

let test_archive_moves_the_bytes () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ->
  let path = checkpoint_path config meta in
  Fs_compat.save_file path malformed;
  match archive config meta with
  | Ok (Keeper_checkpoint_store.Archived { archive_path; unreadable = Parse_error _ }) ->
    check string "archive name carries the given time in epoch ms"
      (Filename.basename path ^ ".unreadable-1000") (Filename.basename archive_path);
    check string "archive holds the bytes" malformed (Fs_compat.load_file archive_path);
    check bool "canonical is gone" false (Sys.file_exists path)
  | other -> failf "malformed checkpoint was not archived: %s" (archive_error_message other)
;;

let test_archive_refuses_a_taken_name () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ->
  let path = checkpoint_path config meta in
  Fs_compat.save_file path malformed;
  let occupant = path ^ ".unreadable-1000" in
  Fs_compat.save_file occupant "earlier archive";
  (match archive config meta with
   | Error (Keeper_checkpoint_store.Archive_not_moved _) -> ()
   | other -> failf "a taken name was not refused: %s" (archive_error_message other));
  check string "the earlier archive is not overwritten" "earlier archive"
    (Fs_compat.load_file occupant);
  check string "the canonical stays" malformed (Fs_compat.load_file path)
;;

let test_archive_refuses_an_os_read_failure () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ->
  let path = checkpoint_path config meta in
  let original = Fs_compat.load_file path in
  with_mode path 0o000 (fun () ->
    match archive config meta with
    | Error (Keeper_checkpoint_store.Archive_read_failed { cause = Os_error Unix.EACCES; _ }) -> ()
    | other -> failf "an OS read failure was not refused: %s" (archive_error_message other));
  check string "the checkpoint stays" original (Fs_compat.load_file path);
  check (list string) "nothing was archived" [] (unreadable_archives (session_dir_of config meta))
;;

(* A directory that can be written and entered but not opened: the rename
   lands, the directory fsync cannot open it. *)
let test_archive_reports_an_unconfirmed_move () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ->
  let path = checkpoint_path config meta in
  let session_dir = session_dir_of config meta in
  Fs_compat.save_file path malformed;
  let result = with_mode session_dir 0o333 (fun () -> archive config meta) in
  (match result with
   | Error (Keeper_checkpoint_store.Archive_durability_unknown _) -> ()
   | other -> failf "an unsynced move was not reported: %s" (archive_error_message other));
  check (list string) "the move itself happened"
    [ Filename.basename path ^ ".unreadable-1000" ] (unreadable_archives session_dir)
;;

let test_clear_refuses_an_os_read_failure () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ->
  let path = checkpoint_path config meta in
  let original = Fs_compat.load_file path in
  let result = with_mode path 0o000 clear in
  check_refused result;
  check bool "the refusal names an OS read failure" true
    (String.starts_with ~prefix:"os_error"
       Yojson.Safe.Util.(Tool_result.data result |> member "read_failure" |> to_string));
  check bool "the official session is kept" true (Option.is_some (official_session ()));
  check string "the checkpoint stays" original (Fs_compat.load_file path);
  check (list string) "nothing was archived" [] (unreadable_archives (session_dir_of config meta))
;;

let test_clear_reports_a_move_that_did_not_happen () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session:_ ->
  let path = checkpoint_path config meta in
  Fs_compat.save_file path malformed;
  let result = with_mode (session_dir_of config meta) 0o555 clear in
  check bool (Tool_result.message result) true (Tool_result.is_failed result);
  check bool "the result says the session was cleared" true
    Yojson.Safe.Util.(Tool_result.data result |> member "official_client_session_cleared" |> to_bool);
  check string "the checkpoint stays" malformed (Fs_compat.load_file path)
;;

let test_absent_checkpoint_is_a_noop () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ->
  let path = checkpoint_path config meta in
  Unix.unlink path;
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  let data = Tool_result.data result in
  check bool "absence is reported" false
    (Yojson.Safe.Util.member "checkpoint_found" data |> Yojson.Safe.Util.to_bool);
  check int "no messages were cleared" 0
    (Yojson.Safe.Util.member "cleared_message_count" data |> Yojson.Safe.Util.to_int);
  check bool "absence does not create a checkpoint" false (Sys.file_exists path);
  check_official_session_cleared official_session
;;

let test_superseded_checkpoint_clears_like_an_absent_one () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ->
  let path = checkpoint_path config meta in
  let earlier =
    match Yojson.Safe.from_string (Fs_compat.load_file path) with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if String.equal key "version"
              then key, `Int (Agent_core.Checkpoint.checkpoint_version - 1)
              else key, value)
           fields)
    | _ -> fail "checkpoint is not a JSON object"
  in
  Fs_compat.save_file path (Yojson.Safe.to_string earlier);
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check bool "a superseded checkpoint is not current history" false
    (Yojson.Safe.Util.member "checkpoint_found" (Tool_result.data result)
     |> Yojson.Safe.Util.to_bool);
  check_official_session_cleared official_session
;;

let test_paused_keeper_clears_stale_epoch_without_resuming () =
  with_keeper
    ~official_owner_epoch:"11111111-1111-4111-8111-111111111111"
    ~paused:true
    ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ->
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load;
  check_official_session_cleared official_session;
  match Keeper_meta_store.read_meta config meta.name |> require_ok with
  | Some current -> check bool "stale clear does not resume the keeper" true current.paused
  | None -> fail "keeper metadata disappeared"
;;
let () =
  run "keeper clear admission"
    [ "owner", [ test_case "active turn, clear, next turn" `Quick test_clear_does_not_race_the_active_turn
               ; test_case "paused keeper remains paused" `Quick test_paused_keeper_can_clear_without_resuming
               ; test_case "missing owner leaves history" `Quick test_missing_owner_does_not_clear
               ; test_case "malformed checkpoint is moved aside" `Quick
                   (test_unreadable_checkpoint_is_archived `Malformed)
               ; test_case "newer-version checkpoint is moved aside" `Quick
                   (test_unreadable_checkpoint_is_archived `Newer_version)
               ; test_case "unreadable path is moved aside" `Quick
                   (test_unreadable_checkpoint_is_archived `Unreadable_path)
               ; test_case "OS read failure refuses the clear" `Quick
                   test_clear_refuses_an_os_read_failure
               ; test_case "a failed move is a failed clear" `Quick
                   test_clear_reports_a_move_that_did_not_happen
               ; test_case "absent checkpoint clears only the official session" `Quick
                   test_absent_checkpoint_is_a_noop
               ; test_case "superseded checkpoint clears like an absent one" `Quick
                   test_superseded_checkpoint_clears_like_an_absent_one
               ; test_case "paused stale epoch clears without resume" `Quick
                   test_paused_keeper_clears_stale_epoch_without_resuming
               ]
    ; "archive", [ test_case "loadable checkpoint is left alone" `Quick
                     test_archive_leaves_a_loadable_checkpoint
                 ; test_case "absence is reported" `Quick test_archive_reports_absence
                 ; test_case "bytes move to the timed name" `Quick test_archive_moves_the_bytes
                 ; test_case "taken name is refused" `Quick test_archive_refuses_a_taken_name
                 ; test_case "OS read failure is refused" `Quick
                     test_archive_refuses_an_os_read_failure
                 ; test_case "unsynced move is reported" `Quick
                     test_archive_reports_an_unconfirmed_move
                 ] ]
