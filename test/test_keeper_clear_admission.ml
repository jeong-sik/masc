open Masc
open Alcotest

module Context = Keeper_context_core

let require_ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let with_keeper
      ?(save_checkpoint = true)
      ?(prior_input_unavailable = false)
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
    "[keeper]\ninstructions = \"Clear admission fixture\"\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
  Keeper_meta_store.replace_snapshot config meta |> require_ok;
  ignore (Keeper_registry.register_offline ~base_path meta.name meta);
  if prior_input_unavailable then begin
    (* Establish the actual unavailable prior-history basis before an Owner
       opens its journal; never rewrite a live writer or input capability. *)
    let module Store = Keeper_chat_operation_store in
    let path = Store.path_for_keeper ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_name:meta.name in
    Fs_compat.mkdir_p (Filename.dirname path);
    let store = Store.open_or_create ~path
      |> Result.map_error Store.error_to_string |> require_ok in
    Store.close store |> Result.map_error Store.error_to_string |> require_ok;
    let db = Sqlite3.db_open ~mode:`NO_CREATE path in
    Fun.protect ~finally:(fun () ->
      check bool "close prior-history fixture" true (Sqlite3.db_close db)) (fun () ->
      check bool "record unavailable prior history" true
        (Sqlite3.exec db "UPDATE input_history SET basis='prior_unavailable' WHERE singleton=1" = Sqlite3.Rc.OK))
  end;
  let owner_stop = ref None in
  let start_owner () =
    let installed,resolve_installed = Eio.Promise.create () in
    let stop,resolve_stop = Eio.Promise.create () in
    let ended,resolve_ended = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve resolve_ended ()) (fun () ->
        Eio.Switch.run (fun owner_sw ->
          let result = Keeper_owner_registry.install_from_store ~sw:owner_sw ~operation_runner:None
            ~on_turn_slot_released:None config in
          Eio.Promise.resolve resolve_installed result;
          ignore (Eio.Promise.await stop))));
    (match Eio.Promise.await installed with
     | Ok _ -> owner_stop := Some (resolve_stop,ended)
     | Error error -> fail (Keeper_owner_registry.install_error_to_string error)) in
  if install_owner then start_owner ();
  let restart () =
    (match Keeper_owner_registry.begin_stopping_all ~base_path with
     | Ok results -> List.iter (function Ok () -> () | Error error -> fail (Keeper_owner.error_to_string error)) results
     | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error));
    (match !owner_stop with
     | Some (resolve_stop,ended) -> Eio.Promise.resolve resolve_stop (); Eio.Promise.await ended
     | None -> fail "no original Owner scope");
    start_owner () in
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
  Fun.protect ~finally:(fun () -> match !owner_stop with
    | Some (resolve_stop,ended) -> Eio.Promise.resolve resolve_stop (); Eio.Promise.await ended
    | None -> ())
    (fun () -> f ~config ~meta ~saved ~save ~load ~clear ~official_session ~restart)
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
  @@ fun ~config ~meta ~saved ~save ~load ~clear ~official_session ~restart:_ ->
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
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart:_ ->
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
  @@ fun ~config:_ ~meta:_ ~saved ~save:_ ~load ~clear ~official_session ~restart:_ ->
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

let session_dir_of config (meta : Keeper_meta_contract.keeper_meta) =
  Keeper_types_support.keeper_session_dir config
    (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
;;

let is_absent path =
  match Unix.lstat path with
  | _ -> false
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
;;

let is_symlink path = (Unix.lstat path).Unix.st_kind = Unix.S_LNK

let session_entries session_dir =
  Sys.readdir session_dir |> Array.to_list |> List.sort String.compare
;;

(* The saved checkpoint rewritten as a later [checkpoint_version] wrote it. *)
let as_newer_version path =
  match Yojson.Safe.from_string (Fs_compat.load_file path) with
  | `Assoc fields ->
    Yojson.Safe.to_string
      (`Assoc
        (List.map
           (fun (key, value) ->
              if String.equal key "version"
              then key, `Int (Agent_core.Checkpoint.checkpoint_version + 1)
              else key, value)
           fields))
  | _ -> fail "checkpoint is not a JSON object"
;;

(* A checkpoint no turn can decode fails every turn, so the operator's clear
   deletes it: the canonical is gone, nothing else in the session directory
   changes (the history window included), and the next turn starts from no
   checkpoint. *)
let test_undecodable_checkpoint_is_removed () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ~restart:_ ->
  let path = checkpoint_path config meta in
  let session_dir = session_dir_of config meta in
  Unix.unlink path;
  Fs_compat.save_file path "{broken-checkpoint";
  let others_before =
    List.filter (fun entry -> not (String.equal entry (Filename.basename path)))
      (session_entries session_dir)
  in
  ignore (Keeper_turn_failure_streak.increment
    ~base_path:config.base_path ~keeper_name:meta.name);
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  let removed =
    Tool_result.data result |> Yojson.Safe.Util.member "undecodable_checkpoint_removed"
  in
  check string "result names the checkpoint it removed" path
    Yojson.Safe.Util.(member "checkpoint_path" removed |> to_string);
  check bool "result carries the decode error" true
    (String.length Yojson.Safe.Util.(member "decode_error" removed |> to_string) > 0);
  check bool "the canonical checkpoint is gone" true (is_absent path);
  check (list string) "nothing else in the session directory changed" others_before
    (session_entries session_dir);
  check bool "a removed checkpoint counts as found" true
    Yojson.Safe.Util.(Tool_result.data result |> member "checkpoint_found" |> to_bool);
  (* No message was counted and no system prompt was kept, so neither is
     claimed. *)
  check bool "no message count is claimed" true
    (Yojson.Safe.Util.(Tool_result.data result |> member "cleared_message_count") = `Null);
  check bool "no kept system prompt is claimed" true
    (Yojson.Safe.Util.(Tool_result.data result |> member "preserve_system_prompt") = `Null);
  check_official_session_cleared official_session;
  check int "clear resets the failure streak" 0
    (Keeper_registry.get_turn_failures ~base_path:config.base_path meta.name);
  let base_dir = Keeper_types_profile.session_base_dir config in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  match Keeper_owner_registry.run_autonomous_if_idle
    ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
      match
        Context.load_context_from_checkpoint_classified ~keeper_name:meta.name ~trace_id ~base_dir
      with
      | _, Context.Checkpoint_absent -> ()
      | _, Context.Checkpoint_loaded _ -> fail "next turn loaded a checkpoint"
      | _, Context.Checkpoint_unread error ->
        fail ("next turn still cannot read its checkpoint: "
              ^ Keeper_checkpoint_store.checkpoint_load_error_to_string error)) with
  | Ok (`Ran ()) -> ()
  | Ok (`Busy _ | `Interrupted) -> fail "next turn did not run"
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
;;

let with_mode path mode f =
  let before = (Unix.stat path).Unix.st_perm in
  Unix.chmod path mode;
  Fun.protect ~finally:(fun () -> Unix.chmod path before) f
;;

let malformed = "{broken-checkpoint"

let remove config meta =
  Keeper_checkpoint_store.remove_undecodable_canonical ~session_dir:(session_dir_of config meta)
    ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
;;

let removal_message = function
  | Ok _ -> "Ok"
  | Error error -> Keeper_checkpoint_store.undecodable_removal_error_to_string error
;;

let test_removal_leaves_a_loadable_checkpoint () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  let path = checkpoint_path config meta in
  let original = Fs_compat.load_file path in
  (match remove config meta with
   | Ok Keeper_checkpoint_store.Canonical_loadable -> ()
   | other -> failf "a readable checkpoint was not left alone: %s" (removal_message other));
  check string "the readable checkpoint is untouched" original (Fs_compat.load_file path)
;;

let test_removal_reports_absence () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  Unix.unlink (checkpoint_path config meta);
  match remove config meta with
  | Ok Keeper_checkpoint_store.Canonical_absent -> ()
  | other -> failf "absence was not reported: %s" (removal_message other)
;;

let test_removal_deletes_undecodable_bytes () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  let path = checkpoint_path config meta in
  let session_dir = session_dir_of config meta in
  Fs_compat.save_file path malformed;
  let others_before =
    List.filter (fun entry -> not (String.equal entry (Filename.basename path)))
      (session_entries session_dir)
  in
  match remove config meta with
  | Ok (Keeper_checkpoint_store.Removed { undecodable = Parse_error _ }) ->
    check bool "canonical is gone" true (is_absent path);
    check (list string) "no other file was created or removed" others_before
      (session_entries session_dir)
  | other -> failf "malformed checkpoint was not removed: %s" (removal_message other)
;;

let test_removal_refuses_an_os_read_failure () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  let path = checkpoint_path config meta in
  let original = Fs_compat.load_file path in
  with_mode path 0o000 (fun () ->
    match remove config meta with
    | Error
        (Keeper_checkpoint_store.Removal_refused
           (Read_failed { cause = Os_error Unix.EACCES; _ })) -> ()
    | other -> failf "an OS read failure was not refused: %s" (removal_message other));
  check string "the checkpoint stays" original (Fs_compat.load_file path)
;;

(* A path that is not a regular file was never read, so it says nothing
   about any bytes and is left in place. *)
let test_removal_refuses_a_path_that_is_not_a_regular_file () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  let path = checkpoint_path config meta in
  Unix.unlink path;
  Unix.symlink (path ^ ".missing") path;
  (match remove config meta with
   | Error (Keeper_checkpoint_store.Removal_refused (Io_error _)) -> ()
   | other -> failf "a non-regular path was not refused: %s" (removal_message other));
  check bool "the link stays" true (is_symlink path)
;;

(* A directory that can be written and entered but not opened: the unlink
   lands, the directory fsync cannot open it. *)
let test_removal_reports_an_unconfirmed_delete () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  let path = checkpoint_path config meta in
  Fs_compat.save_file path malformed;
  let result = with_mode (session_dir_of config meta) 0o333 (fun () -> remove config meta) in
  (match result with
   | Error (Keeper_checkpoint_store.Removal_durability_unknown _) -> ()
   | other -> failf "an unsynced delete was not reported: %s" (removal_message other));
  check bool "the delete itself happened" true (is_absent path)
;;

(* A later version wrote it and can still read it: the clear refuses before
   anything changes, the official-client session included. *)
let test_clear_refuses_a_newer_version_checkpoint () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ~restart:_ ->
  let path = checkpoint_path config meta in
  let newer = as_newer_version path in
  Fs_compat.save_file path newer;
  let result = clear () in
  check_refused result;
  check int "the refusal names the file's version"
    (Agent_core.Checkpoint.checkpoint_version + 1)
    Yojson.Safe.Util.(Tool_result.data result |> member "checkpoint_version" |> to_int);
  check bool "the official session is kept" true (Option.is_some (official_session ()));
  check string "the newer checkpoint stays" newer (Fs_compat.load_file path)
;;

let test_removal_refuses_a_newer_version () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  let path = checkpoint_path config meta in
  let newer = as_newer_version path in
  Fs_compat.save_file path newer;
  (match remove config meta with
   | Error (Keeper_checkpoint_store.Removal_refused (Newer_version { got; _ })) ->
     check int "the refusal carries the file's version"
       (Agent_core.Checkpoint.checkpoint_version + 1) got
   | other -> failf "a newer-version checkpoint was not refused: %s" (removal_message other));
  check string "the newer checkpoint stays" newer (Fs_compat.load_file path)
;;

(* A session id that is not a path segment never reaches a read, so nothing
   is known against any bytes. *)
let test_judgement_of_a_bad_session_id_is_inconclusive () =
  with_keeper ~paused:false ~install_owner:false
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear:_ ~official_session:_ ~restart:_ ->
  match
    Keeper_checkpoint_store.judge_canonical ~session_dir:(session_dir_of config meta)
      ~session_id:"../escape"
  with
  | Keeper_checkpoint_store.Judged_inconclusive (Store_error _) -> ()
  | Keeper_checkpoint_store.Judged_absent
  | Keeper_checkpoint_store.Judged_decoded _
  | Keeper_checkpoint_store.Judged_superseded _
  | Keeper_checkpoint_store.Judged_newer _
  | Keeper_checkpoint_store.Judged_undecodable _
  | Keeper_checkpoint_store.Judged_inconclusive _ ->
    fail "a bad session id was judged as if it had been read"
;;

let test_clear_refuses_an_os_read_failure () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ~restart:_ ->
  let path = checkpoint_path config meta in
  let original = Fs_compat.load_file path in
  let result = with_mode path 0o000 (fun () ->
    (match Keeper_checkpoint_store.load_agent_core_exact_snapshot
        ~session_dir:(session_dir_of config meta)
        ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) with
     | Error (Keeper_checkpoint_store.Ref_read_failed (Read_failed {cause=Os_error Unix.EACCES;_})) -> ()
     | Error error -> fail (Keeper_checkpoint_store.checkpoint_ref_load_error_to_string error)
     | Ok _ -> fail "unreadable canonical produced an exact snapshot");
    clear ()) in
  check_refused result;
  check bool "the refusal names an OS read failure" true
    (String.starts_with ~prefix:"os_error"
       Yojson.Safe.Util.(Tool_result.data result |> member "read_failure" |> to_string));
  check bool "the official session is kept" true (Option.is_some (official_session ()));
  check string "the checkpoint stays" original (Fs_compat.load_file path)
;;

let test_clear_refuses_a_path_that_is_not_a_regular_file () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ~restart:_ ->
  let path = checkpoint_path config meta in
  Unix.unlink path;
  Unix.symlink (path ^ ".missing") path;
  check_refused (clear ());
  check bool "the official session is kept" true (Option.is_some (official_session ()));
  check bool "the link stays" true (is_symlink path)
;;

let test_clear_reports_a_delete_that_did_not_happen () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session:_ ~restart:_ ->
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
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ~restart:_ ->
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
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ~restart:_ ->
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
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart:_ ->
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load;
  check_official_session_cleared official_session;
  match Keeper_meta_store.read_meta config meta.name |> require_ok with
  | Some current -> check bool "stale clear does not resume the keeper" true current.paused
  | None -> fail "keeper metadata disappeared"
;;
let run_owned ~config ~meta work =
  match Keeper_owner_registry.run_autonomous_if_idle ~base_path:config.Workspace.base_path
    ~keeper_name:meta.Keeper_meta_contract.name work with
  | Ok (`Ran value) -> value
  | Ok (`Busy _ | `Interrupted) -> fail "owned input fixture did not execute"
  | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
let input_source ~config ~meta load =
  let checkpoint = Context.checkpoint_of_context (load ()) in
  let session = Context.create_session ~session_id:(Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id)
    ~base_dir:(Keeper_types_profile.session_base_dir config) in
  session,checkpoint
let publish_input ~config ~meta ~session checkpoint =
  run_owned ~config ~meta (fun () ->
    let producer = Keeper_input_checkpoint_producer.prepare ~base_path:config.Workspace.base_path
      ~keeper_name:meta.Keeper_meta_contract.name ~session_dir:session.Keeper_types.session_dir
      ~trace_id:meta.runtime.trace_id ~source:(Some checkpoint)
      |> Result.map_error Keeper_input_checkpoint_producer.error_to_string |> require_ok in
    ignore (Keeper_input_checkpoint_producer.publish_autonomous producer checkpoint
      |> Result.map_error Keeper_input_checkpoint_producer.error_to_string |> require_ok))
let observed_input ~config ~meta =
  match Keeper_owner_registry.input_checkpoint ~base_path:config.Workspace.base_path ~keeper_name:meta.Keeper_meta_contract.name
    ~trace_id:meta.runtime.trace_id |> Result.map_error Keeper_owner_registry.command_error_to_string |> require_ok with
  | Keeper_chat_operation_store.Input_observed reference -> reference
  | Input_unobserved | Prior_input_unavailable -> fail "input observation was lost"
let check_next_prepare ~config ~meta ~session load =
  run_owned ~config ~meta (fun () ->
    ignore (Keeper_input_checkpoint_producer.prepare ~base_path:config.Workspace.base_path ~keeper_name:meta.Keeper_meta_contract.name
      ~session_dir:session.Keeper_types.session_dir ~trace_id:meta.runtime.trace_id
      ~source:(Some (Context.checkpoint_of_context (load ())))
      |> Result.map_error Keeper_input_checkpoint_producer.error_to_string |> require_ok))

let test_owned_clear_survives_owner_restart () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart ->
  let session,original = input_source ~config ~meta load in
  publish_input ~config ~meta ~session original;
  let before = observed_input ~config ~meta in
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load; check_official_session_cleared official_session;
  let after = observed_input ~config ~meta in
  check bool "clear publishes a different exact owned history" false (Keeper_checkpoint_ref.equal before after);
  let canonical = Keeper_checkpoint_store.load_agent_core_exact_snapshot
    ~session_dir:session.session_dir ~session_id:session.session_id
    |> Result.map_error Keeper_checkpoint_store.checkpoint_ref_load_error_to_string |> require_ok in
  check bool "canonical and input name the same cleared bytes" true
    (Keeper_checkpoint_ref.equal after (Keeper_checkpoint_store.exact_snapshot_reference canonical));
  check bool "clear persists its new derived message count" true
    (Agent_core.Context.get_scoped (Keeper_checkpoint_store.exact_snapshot_checkpoint canonical).context
      Session "message_count" = Some (`Int 0));
  check_next_prepare ~config ~meta ~session load;
  restart ();
  check bool "input ownership survives actual Owner reinstall" true
    (Keeper_checkpoint_ref.equal after (observed_input ~config ~meta));
  check_next_prepare ~config ~meta ~session load

let test_owned_clear_recovers_canonical ~corrupt () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart:_ ->
  let session,original = input_source ~config ~meta load in
  publish_input ~config ~meta ~session original;
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir:session.session_dir ~session_id:session.session_id in
  if corrupt then Fs_compat.save_file path "not a checkpoint" else Unix.unlink path;
  let result = clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load; check_official_session_cleared official_session;
  check bool "recovering owned history does not forget its input row" true
    (Option.is_none (Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir:session.session_dir
      ~reference:(observed_input ~config ~meta) |> function
        | Ok snapshot -> (Keeper_checkpoint_store.exact_snapshot_checkpoint snapshot).pending_input
        | Error _ -> fail "cleared input payload unavailable"));
  check_next_prepare ~config ~meta ~session load

let test_clear_refuses_owned_pending_input () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart:_ ->
  let session,original = input_source ~config ~meta load in
  let pending : Agent_core.Agent_input_request.pending =
    {run_id="clear-owned-run";request={request_id="clear-owned-request";participant_name=Some "operator";
      question="Must not be discarded";schema=None;timeout_s=None;created_at=1.}} in
  let waiting = {original with Agent_core.Checkpoint.pending_input=Some pending} in
  publish_input ~config ~meta ~session waiting;
  let owned = observed_input ~config ~meta in
  let before = Fs_compat.load_file (Keeper_checkpoint_store.agent_core_checkpoint_path
    ~session_dir:session.session_dir ~session_id:session.session_id) in
  check_refused (clear ());
  check bool "pending refusal preserves official session" true (Option.is_some (official_session ()));
  check bool "pending refusal preserves exact input" true (Keeper_checkpoint_ref.equal owned (observed_input ~config ~meta));
  check string "pending refusal preserves canonical bytes" before
    (Fs_compat.load_file (Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir:session.session_dir ~session_id:session.session_id))

let restart_records ~config ~meta =
  let keepers_dir=Workspace.keepers_runtime_dir config in
  match Keeper_turn_boundaries.read ~keepers_dir ~keeper_id:meta.Keeper_meta_contract.name with
  | Ok rows -> List.filter_map (function
      | _,Ok {Keeper_turn_boundaries.event=History_restarted _;_} -> Some ()
      | _,(Ok {event=Turn_ended _;_} | Error _) -> None) rows
  | Error error -> fail error

let test_clear_marker_follows_owned_commit () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session:_ ~restart:_ ->
  let session,original=input_source ~config ~meta load in
  publish_input ~config ~meta ~session original;
  let before=List.length (restart_records ~config ~meta) in
  let result=clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check bool "confirmed marker names the new input bytes" true
    (Keeper_checkpoint_ref.equal (observed_input ~config ~meta)
      (Keeper_checkpoint_store.load_agent_core_exact_snapshot ~session_dir:session.session_dir ~session_id:session.session_id
       |> Result.map_error Keeper_checkpoint_store.checkpoint_ref_load_error_to_string |> require_ok
       |> Keeper_checkpoint_store.exact_snapshot_reference));
  check int "one restart follows the confirmed two-store clear" (before+1)
    (List.length (restart_records ~config ~meta))

let test_clear_marker_write_failure_keeps_confirmed_input () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session:_ ~restart:_ ->
  let session,original=input_source ~config ~meta load in
  publish_input ~config ~meta ~session original;
  let path=Keeper_turn_boundaries.path_for_keepers_dir ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:meta.name in
  Fs_compat.mkdir_p path;
  let result=clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check bool "marker failure remains explicit" true
    (Yojson.Safe.Util.member "history_restart_line_error" (Tool_result.data result) <> `Null);
  check_empty load;
  check_next_prepare ~config ~meta ~session load

let test_clear_marker_repairs_torn_tail () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session:_ ~restart:_ ->
  let path=Keeper_turn_boundaries.path_for_keepers_dir ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_id:meta.name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path {|{"kind":"turn_ended"|};
  let result=clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check int "torn tail retains the confirmed restart" 1 (List.length (restart_records ~config ~meta))

let test_clear_refuses_same_turn_nonhistory_regression () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart:_ ->
  let session,original=input_source ~config ~meta load in
  let context=Agent_core.Context.copy original.context in
  Agent_core.Context.set context "input-side-effect" (`String "new owned value");
  let owned={original with Agent_core.Checkpoint.context;
    working_context=Some (`Assoc ["original-response",`String "accepted"])} in
  publish_input ~config ~meta ~session owned;
  let before=observed_input ~config ~meta in
  check_refused (clear ());
  check bool "ambiguous same-turn state keeps official session" true (Option.is_some (official_session ()));
  check bool "owned response context was not replaced by stale canonical state" true
    (Keeper_checkpoint_ref.equal before (observed_input ~config ~meta));
  let retained=Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir:session.session_dir ~reference:before
    |> function Ok snapshot -> Keeper_checkpoint_store.exact_snapshot_checkpoint snapshot
      | Error _ -> fail "owned context disappeared" in
  check bool "latest input side effect survives" true
    (Agent_core.Context.get retained.context "input-side-effect"=Some (`String "new owned value"))

let test_clear_refuses_inconsistent_derived_count () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart:_ ->
  let session,original = input_source ~config ~meta load in
  let context = Agent_core.Context.copy original.context in
  Agent_core.Context.set_scoped context Session "message_count" (`Int (List.length original.messages + 1));
  publish_input ~config ~meta ~session {original with Agent_core.Checkpoint.context};
  let before = observed_input ~config ~meta in
  check_refused (clear ());
  check bool "invalid derived state preserves official session" true (Option.is_some (official_session ()));
  check bool "invalid derived state preserves the owned payload" true
    (Keeper_checkpoint_ref.equal before (observed_input ~config ~meta))

let test_clear_refuses_unavailable_prior_input () =
  with_keeper ~prior_input_unavailable:true ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load:_ ~clear ~official_session ~restart:_ ->
  let path = checkpoint_path config meta in
  let before = Fs_compat.load_file path in
  check_refused (clear ());
  check bool "prior-input refusal preserves official session" true (Option.is_some (official_session ()));
  check string "prior-input refusal preserves canonical history" before (Fs_compat.load_file path);
  check bool "unavailable prior input never becomes unobserved" true
    ((Keeper_owner_registry.input_checkpoint ~base_path:config.base_path ~keeper_name:meta.name
      ~trace_id:meta.runtime.trace_id |> Result.map_error Keeper_owner_registry.command_error_to_string |> require_ok)
      = Keeper_chat_operation_store.Prior_input_unavailable)

let test_partial_clear_requires_fresh_maintenance_authority () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session ~restart:_ ->
  let session,original=input_source ~config ~meta load in
  publish_input ~config ~meta ~session original;
  let previous=observed_input ~config ~meta in
  let old_writer=ref None and old_receipt=ref None in
  (match Keeper_owner_registry.run_maintenance_if_idle ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
     let writer=Keeper_owner_registry.begin_history_clear ~base_path:config.base_path ~keeper_name:meta.name
       |> Result.map_error Keeper_owner_registry.command_error_to_string |> require_ok in
     let plan=Keeper_history_clear.prepare ~authority:(Keeper_owner.history_clear_authority writer)
       ~session_dir:session.session_dir ~preserve_system:true
       |> Result.map_error Keeper_history_clear.error_to_string |> require_ok in
     let receipt=Keeper_official_client_session_store.clear_then ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
       Keeper_history_clear.execute plan |> Result.map_error Keeper_history_clear.error_to_string |> require_ok) |> require_ok in
     old_writer:=Some writer;old_receipt:=Some receipt) with
   | Ok (`Ran ()) -> ()
   | Ok (`Busy _) -> fail "maintenance was busy"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  check_empty load;check_official_session_cleared official_session;
  check bool "canonical-only partial effect keeps previous owned input" true
    (Keeper_checkpoint_ref.equal previous (observed_input ~config ~meta));
  (match Keeper_owner_registry.run_maintenance_if_idle ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
     let fresh=Keeper_owner_registry.begin_history_clear ~base_path:config.base_path ~keeper_name:meta.name
       |> Result.map_error Keeper_owner_registry.command_error_to_string |> require_ok in
     (match Keeper_owner_registry.commit_history_clear ~base_path:config.base_path ~keeper_name:meta.name
       ~writer:fresh ~receipt:(Option.get !old_receipt) with
      | Error (Keeper_owner_registry.Command_rejected (Keeper_owner.Operation_rejected (Keeper_chat_operation_store.Invalid_input detail))) ->
         check string "fresh authority rejects the original receipt"
           "history clear receipt no longer belongs to its original maintenance child and trace" detail
       | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
       | Ok () -> fail "a fresh authority accepted another authority's receipt");
     check bool "foreign receipt refusal preserves owned input" true
       (Keeper_checkpoint_ref.equal previous (observed_input ~config ~meta));
     (* The old writer belongs to the previous child, so the inherited-child
        wrapper refuses before the Owner's receipt/trace guard above. *)
     (match Keeper_owner_registry.commit_history_clear ~base_path:config.base_path ~keeper_name:meta.name
       ~writer:(Option.get !old_writer) ~receipt:(Option.get !old_receipt) with
     | Error (Keeper_owner_registry.Command_rejected (Keeper_owner.Operation_rejected (Keeper_chat_operation_store.Invalid_input detail))) ->
        check string "another maintenance child cannot reuse the old authority"
          "history clear publication requires its inherited maintenance child" detail
      | Error error -> fail (Keeper_owner_registry.command_error_to_string error)
      | Ok () -> fail "another maintenance child reused the old clear authority");
     check bool "foreign child refusal preserves owned input" true
       (Keeper_checkpoint_ref.equal previous (observed_input ~config ~meta))) with
   | Ok (`Ran ()) -> () | Ok (`Busy _) -> fail "second maintenance was busy"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  let result=clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check bool "fresh explicit clear reconciles partial canonical/input state" false
    (Keeper_checkpoint_ref.equal previous (observed_input ~config ~meta));
  check_next_prepare ~config ~meta ~session load

let test_clear_cas_refuses_equal_turn_external_change () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear:_ ~official_session ~restart:_ ->
  let session,original=input_source ~config ~meta load in
  publish_input ~config ~meta ~session original;
  let before=observed_input ~config ~meta in
  let marker_count=List.length (restart_records ~config ~meta) in
  (match Keeper_owner_registry.run_maintenance_if_idle ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
     let writer=Keeper_owner_registry.begin_history_clear ~base_path:config.base_path ~keeper_name:meta.name
       |> Result.map_error Keeper_owner_registry.command_error_to_string |> require_ok in
     let plan=Keeper_history_clear.prepare ~authority:(Keeper_owner.history_clear_authority writer)
       ~session_dir:session.session_dir ~preserve_system:true
       |> Result.map_error Keeper_history_clear.error_to_string |> require_ok in
     let snapshot=Keeper_checkpoint_store.load_agent_core_exact_snapshot ~session_dir:session.session_dir ~session_id:session.session_id
       |> Result.map_error Keeper_checkpoint_store.checkpoint_ref_load_error_to_string |> require_ok in
     let changed={original with Agent_core.Checkpoint.messages=original.messages @ [Agent_core.Types.user_msg "external equal-turn write"]} in
     (match Keeper_checkpoint_store.save_agent_core_if_source ~session_dir:session.session_dir
       ~expected_source_ref:(Keeper_checkpoint_store.exact_snapshot_reference snapshot) changed
       |> Keeper_checkpoint_store.require_confirmed_installation with
      | Ok _ -> () | Error _ -> fail "external canonical write failed");
     let outcome=Keeper_official_client_session_store.clear_then ~base_path:config.base_path ~keeper_name:meta.name
       (fun () -> Keeper_history_clear.execute plan) |> require_ok in
     (match outcome with
      | Error (Keeper_history_clear.Installation_unconfirmed (Keeper_checkpoint_store.Not_installed {cause=Source_changed _;_})) -> ()
      | Error _ -> fail "clear did not report its exact stale source"
      | Ok _ -> fail "equal-turn external canonical write was overwritten")) with
   | Ok (`Ran ()) -> () | Ok (`Busy _) -> fail "maintenance was busy"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  check_official_session_cleared official_session;
  check bool "stale plan keeps original input owner" true (Keeper_checkpoint_ref.equal before (observed_input ~config ~meta));
  check int "stale clear writes no restart marker" marker_count (List.length (restart_records ~config ~meta));
  check bool "external canonical conversation survives" true
    (List.exists (fun (message:Agent_core.Types.message) ->
       Agent_core.Types.text_of_content message.content="external equal-turn write") (Context.messages_of_context (load ())))

let test_clear_journal_failure_recovers_after_owner_restart ~after_commit () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved:_ ~save:_ ~load ~clear ~official_session:_ ~restart ->
  let session,original=input_source ~config ~meta load in
  publish_input ~config ~meta ~session original;
  let before=observed_input ~config ~meta in
  let marker_count=List.length (restart_records ~config ~meta) in
  (match Keeper_owner_registry.run_maintenance_if_idle ~base_path:config.base_path ~keeper_name:meta.name (fun () ->
     let writer=Keeper_owner_registry.begin_history_clear ~base_path:config.base_path ~keeper_name:meta.name
       |> Result.map_error Keeper_owner_registry.command_error_to_string |> require_ok in
     let plan=Keeper_history_clear.prepare ~authority:(Keeper_owner.history_clear_authority writer)
       ~session_dir:session.session_dir ~preserve_system:true
       |> Result.map_error Keeper_history_clear.error_to_string |> require_ok in
     let receipt=Keeper_history_clear.execute plan |> Result.map_error Keeper_history_clear.error_to_string |> require_ok in
     Keeper_chat_operation_store.For_testing.fail_next_commit
       (if after_commit then Fail_after_commit else Fail_before_commit);
     Fun.protect ~finally:Keeper_chat_operation_store.For_testing.clear_commit_fault (fun () ->
       match Keeper_owner_registry.commit_history_clear ~base_path:config.base_path ~keeper_name:meta.name ~writer ~receipt with
       | Error _ -> () | Ok () -> fail "unconfirmed journal commit became clear success")) with
   | Ok (`Ran ()) -> () | Ok (`Busy _) -> fail "maintenance was busy"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  check_empty load;
  check int "unconfirmed input commit writes no marker" marker_count (List.length (restart_records ~config ~meta));
  let actual=observed_input ~config ~meta in
  check bool "actual commit disposition is preserved" (not after_commit) (Keeper_checkpoint_ref.equal before actual);
  (* Availability recovery reopens the journal before a fresh admission; it
     never blindly replays the uncertain old witness. *)
  let result=clear () in
  check bool (Tool_result.message result) true (Tool_result.is_success result);
  check_empty load;
  check_next_prepare ~config ~meta ~session load;
  restart ();
  check_next_prepare ~config ~meta ~session load

let () =
  run "keeper clear admission"
    [ "owner", [ test_case "equal-turn external write defeats a stale clear plan" `Quick test_clear_cas_refuses_equal_turn_external_change
               ; test_case "precommit clear failure permits fresh explicit recovery" `Quick (test_clear_journal_failure_recovers_after_owner_restart ~after_commit:false)
               ; test_case "uncertain clear commit preserves actual input across restart" `Quick (test_clear_journal_failure_recovers_after_owner_restart ~after_commit:true)
               ; test_case "restart marker follows owned input commit" `Quick test_clear_marker_follows_owned_commit
               ; test_case "marker failure preserves confirmed input clear" `Quick test_clear_marker_write_failure_keeps_confirmed_input
               ; test_case "restart marker repairs a torn tail" `Quick test_clear_marker_repairs_torn_tail
               ; test_case "same-turn nonhistory ambiguity refuses before effects" `Quick test_clear_refuses_same_turn_nonhistory_regression
               ; test_case "inconsistent derived message count refuses before effects" `Quick test_clear_refuses_inconsistent_derived_count
               ; test_case "unavailable prior input refuses before official-session effects" `Quick test_clear_refuses_unavailable_prior_input
               ; test_case "partial clear requires fresh original maintenance authority" `Quick test_partial_clear_requires_fresh_maintenance_authority
               ; test_case "owned clear resumes before and after Owner restart" `Quick test_owned_clear_survives_owner_restart
               ; test_case "owned clear recovers missing canonical" `Quick (test_owned_clear_recovers_canonical ~corrupt:false)
               ; test_case "owned clear recovers corrupt canonical" `Quick (test_owned_clear_recovers_canonical ~corrupt:true)
               ; test_case "owned pending input refuses before official-session effects" `Quick test_clear_refuses_owned_pending_input
               ; test_case "active turn, clear, next turn" `Quick test_clear_does_not_race_the_active_turn
               ; test_case "paused keeper remains paused" `Quick test_paused_keeper_can_clear_without_resuming
               ; test_case "missing owner leaves history" `Quick test_missing_owner_does_not_clear
               ; test_case "malformed checkpoint is deleted" `Quick
                   test_undecodable_checkpoint_is_removed
               ; test_case "newer-version checkpoint refuses the clear" `Quick
                   test_clear_refuses_a_newer_version_checkpoint
               ; test_case "OS read failure refuses the clear" `Quick
                   test_clear_refuses_an_os_read_failure
               ; test_case "non-regular path refuses the clear" `Quick
                   test_clear_refuses_a_path_that_is_not_a_regular_file
               ; test_case "a failed delete is a failed clear" `Quick
                   test_clear_reports_a_delete_that_did_not_happen
               ; test_case "absent checkpoint clears only the official session" `Quick
                   test_absent_checkpoint_is_a_noop
               ; test_case "superseded checkpoint clears like an absent one" `Quick
                   test_superseded_checkpoint_clears_like_an_absent_one
               ; test_case "paused stale epoch clears without resume" `Quick
                   test_paused_keeper_clears_stale_epoch_without_resuming
               ]
    ; "removal", [ test_case "loadable checkpoint is left alone" `Quick
                     test_removal_leaves_a_loadable_checkpoint
                 ; test_case "absence is reported" `Quick test_removal_reports_absence
                 ; test_case "undecodable bytes are deleted" `Quick
                     test_removal_deletes_undecodable_bytes
                 ; test_case "newer version is refused" `Quick
                     test_removal_refuses_a_newer_version
                 ; test_case "bad session id is inconclusive" `Quick
                     test_judgement_of_a_bad_session_id_is_inconclusive
                 ; test_case "OS read failure is refused" `Quick
                     test_removal_refuses_an_os_read_failure
                 ; test_case "non-regular path is refused" `Quick
                     test_removal_refuses_a_path_that_is_not_a_regular_file
                 ; test_case "unsynced delete is reported" `Quick
                     test_removal_reports_an_unconfirmed_delete
                 ] ]
