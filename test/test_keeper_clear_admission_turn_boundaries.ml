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
      ~base_path:config.base_path
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
    |> Result.map_error Keeper_official_client_session_store.read_error_to_string
    |> require_ok
  in
  Fun.protect ~finally:(fun () -> match !owner_stop with
    | Some (resolve_stop,ended) -> Eio.Promise.resolve resolve_stop (); Eio.Promise.await ended
    | None -> ())
    (fun () -> f ~config ~meta ~saved ~save ~load ~clear ~official_session ~restart)
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
     (match Keeper_checkpoint_store.save_agent_core_if_source ~boundary:Agent_core.Checkpoint_objects.Turn_continues ~session_dir:session.session_dir
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
  run "keeper_clear_admission_turn_boundaries"
    [ "owner", [ test_case "equal-turn external write defeats a stale clear plan" `Quick test_clear_cas_refuses_equal_turn_external_change
               ; test_case "precommit clear failure permits fresh explicit recovery" `Quick (test_clear_journal_failure_recovers_after_owner_restart ~after_commit:false)
               ; test_case "uncertain clear commit preserves actual input across restart" `Quick (test_clear_journal_failure_recovers_after_owner_restart ~after_commit:true)
               ; test_case "restart marker follows owned input commit" `Quick test_clear_marker_follows_owned_commit
               ; test_case "marker failure preserves confirmed input clear" `Quick test_clear_marker_write_failure_keeps_confirmed_input
               ; test_case "restart marker repairs a torn tail" `Quick test_clear_marker_repairs_torn_tail
               ]
    ]
