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
    "[keeper]\ninstructions = \"Clear admission fixture\"\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"masc-sandbox:general\"\n";
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

let test_checkpoint_read_failure fault () =
  with_keeper ~paused:false ~install_owner:true
  @@ fun ~config ~meta ~saved ~save:_ ~load ~clear ~official_session ->
  let path = checkpoint_path config meta in
  let original = Fs_compat.load_file path in
  let backup = path ^ ".test-original" in
  let missing_target = path ^ ".missing" in
  let invalid_json = "{broken-checkpoint" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path in
  let boundaries () = Keeper_turn_boundaries.read ~keepers_dir ~keeper_id:meta.name |> require_ok in
  let before_boundaries = boundaries () in
  let before_failures = Keeper_turn_failure_streak.increment
    ~base_path:config.base_path ~keeper_name:meta.name in
  Unix.rename path backup;
  (match fault with
   | `Malformed -> Fs_compat.save_file path invalid_json
   | `Unreadable_path -> Unix.symlink missing_target path);
  Fun.protect
    ~finally:(fun () -> Unix.unlink path; Unix.rename backup path)
    (fun () ->
      let result = clear () in
      check_refused result;
      check string "failure identifies the checkpoint" path
        (Tool_result.data result |> Yojson.Safe.Util.member "checkpoint_path"
         |> Yojson.Safe.Util.to_string);
      (match fault with
       | `Malformed ->
         check string "malformed original is not overwritten" invalid_json (Fs_compat.load_file path)
       | `Unreadable_path ->
         check string "unreadable path is not replaced" missing_target (Unix.readlink path));
      check bool "failed clear appends no restart marker" true (before_boundaries = boundaries ());
      check int "process failure streak is preserved" before_failures
        (Keeper_registry.get_turn_failures ~base_path:config.base_path meta.name);
      check bool "checkpoint refusal keeps the official session" true
        (Option.is_some (official_session ()));
      match Keeper_turn_failure_streak_store.load ~base_path:config.base_path ~keeper_name:meta.name with
      | Ok count -> check (option int) "durable failure streak is preserved" (Some before_failures) count
      | Error error -> fail (Keeper_turn_failure_streak_store.error_to_string error));
  check string "original bytes remain available after read recovery" original (Fs_compat.load_file path);
  check bool "next load continues the original conversation" true
    (Context.messages_of_context saved = Context.messages_of_context (load ()))
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
               ; test_case "parse failure preserves history and failure state" `Quick
                   (test_checkpoint_read_failure `Malformed)
               ; test_case "unreadable path is not absence" `Quick
                   (test_checkpoint_read_failure `Unreadable_path)
               ; test_case "absent checkpoint clears only the official session" `Quick
                   test_absent_checkpoint_is_a_noop
               ; test_case "superseded checkpoint clears like an absent one" `Quick
                   test_superseded_checkpoint_clears_like_an_absent_one
               ; test_case "paused stale epoch clears without resume" `Quick
                   test_paused_keeper_clears_stale_epoch_without_resuming
               ] ]
