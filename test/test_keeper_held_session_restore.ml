open Masc

let keeper_name = "held-restore-keeper"

let write_file path body =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel body)

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let require_session registry name =
  match Session.get_session registry ~agent_name:name with
  | Some session -> session
  | None -> Alcotest.failf "missing session %s" name

let write_agent ~agents_path name =
  let now = Types_core.now_iso () in
  let agent : Types_core.agent =
    { id = None
    ; name
    ; agent_type = "test"
    ; status = Types_core.Active
    ; capabilities = []
    ; current_task = None
    ; session_bound_at = now
    ; last_seen = now
    ; meta = None
    }
  in
  write_file (Filename.concat agents_path (name ^ ".json"))
    (Yojson.Safe.to_string (Types_core.agent_to_yojson agent))

let test_keeper_boots_while_real_restore_is_held () =
  let base_path = Filename.temp_dir "keeper-held-restore-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" (Some "1") @@ fun () ->
  Masc_test_deps.with_process_env "MASC_CONFIG_DIR"
    (Some (Filename.concat base_path ".masc/config")) @@ fun () ->
  Masc_test_deps.with_process_env "MASC_KEEPER_AUTONOMOUS_ENABLED" (Some "true") @@ fun () ->
  Eio_main.run @@ fun env ->
  let previous_context = Eio_context.snapshot_state () in
  let guard_was_ready = Eio_guard.is_ready () in
  Fs_compat.set_fs env#fs;
  Eio_context.set_env env;
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      Eio_context.restore_state previous_context;
      if not guard_was_ready then Eio_guard.disable ())
    (fun () ->
  let passed, signal_passed = Eio.Promise.create () in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      Masc_test_deps.init_eio_clock ~sw env;
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:None : string);
      (* This fixture exercises bootstrap, not container execution. Declare a
         host catalog pin; do not claim the image is installed or runnable. *)
      let config_root =
        (Config_dir_resolver.resolve_for_base_path ~base_path).config_root.path
      in
      write_file (Filename.concat config_root "sandbox-image-builds.toml")
        "[images.base.docker]\nreference = \"fixture/held-restore:declared\"\n";
      let toml_path =
        Filename.concat
          (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
          (keeper_name ^ ".toml")
      in
      write_file toml_path
        (Printf.sprintf
           "[keeper]\nname = %S\ninstructions = \"held restore fixture\"\nactivation_mode = \"autonomous\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n"
           keeper_name);
      let prompts_dir = Config_dir_resolver.prompts_dir_for_base_path ~base_path in
      Fs_compat.mkdir_p prompts_dir;
      let prompt_sync =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
          ~edit_layer:Managed_asset_sync.No_edit_layer
          ~read:Embedded_config.read ~files:Embedded_config.file_list
          ~dest_dir:prompts_dir ()
      in
      (match prompt_sync.failed with
       | [] -> ()
       | failures ->
           Alcotest.fail
             (String.concat "; "
                (List.map (fun (file, reason) -> file ^ ": " ^ reason) failures)));
      let meta =
        Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String keeper_name; "trace_id", `String "held-restore-trace" ])
        |> require_ok Fun.id
      in
      Keeper_meta_store.replace_snapshot config meta |> require_ok Fun.id;
      let state =
        Mcp_server.create_state_eio ~sw ~proc_mgr:env#process_mgr ~fs:env#fs
          ~clock:env#clock ~mono_clock:env#mono_clock ~net:env#net ~base_path
      in
      let config = Mcp_server.workspace_config state in
      Keeper_owner_registry.install_from_store ~sw
        ~operation_runner:
          (Some (Server_routes_http_keeper_stream.operation_runner ~state ~clock:env#clock))
        ~on_turn_slot_released:None config
      |> require_ok Keeper_owner_registry.install_error_to_string
      |> ignore;
      ignore
        (Prompt_defaults.bootstrap_runtime
           ~workspace_path:config.workspace_path ~base_path : string);
      Alcotest.(check bool) "shipped Keeper system prompt is available" true
        (String.length (Keeper_prompt.system_prompt_body ()) > 0);
      Keeper_approval_queue.install_persistence ~base_path
      |> require_ok Keeper_approval_queue_result.install_error_to_string
      |> ignore;
      Server_mcp_transport_http_session.load_sessions_from_file ~base_path ();
      let prepared =
        Server_bootstrap_loops.prepare_keeper_persistence
          ~accept_store_quarantine:false ~config ()
        |> require_ok Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
      in
      let claimed =
        Server_bootstrap_loops.claim_prepared_keeper_persistence ~config prepared
        |> require_ok Server_bootstrap_loops.keeper_persistence_claim_error_to_string
      in
      Alcotest.(check bool) "fixture keeper is admitted by real profile reads" true
        (List.mem keeper_name (Keeper_runtime.bootable_keeper_names config));
      Alcotest.(check bool) "keeper was not pre-registered" false
        (Keeper_registry.is_registered ~base_path keeper_name);
      let registry = state.session_registry in
      let live = Session.register registry ~agent_name:"live" in
      ignore (Session.register registry ~agent_name:"retired" : Session.session);
      let event = `Assoc [ "payload", `String "live notification" ] in
      ignore (Session.push_notification_to_active_agents registry ~event);
      let agents_path = Workspace.agents_dir config in
      List.iter (write_agent ~agents_path)
        [ "live"; "retired"; "restored-peer" ];
      Server_startup_state.reset ();
      Server_startup_state.prepare_lazy_tasks ~tasks:[ "restore_sessions" ]
      |> require_ok Server_startup_state.lazy_prepare_error_to_string;
      let discovered, signal_discovered = Eio.Promise.create () in
      let release, signal_release = Eio.Promise.create () in
      let restore_completed = ref false in
      let restored = Eio.Fiber.fork_promise ~sw (fun () ->
        Session.For_testing.restore_from_disk registry ~agents_path
          ~after_discovery:(fun () ->
            Eio.Promise.resolve signal_discovered ();
            Eio.Promise.await release);
        restore_completed := true;
        Server_startup_state.finish_lazy_task ~task:"restore_sessions")
      in
      Eio.Promise.await discovered;
      Session.unregister registry ~agent_name:"retired";
      Alcotest.(check bool) "concurrent unregister committed" true
        (Option.is_none (Session.get_session registry ~agent_name:"retired"));
      (* Model availability is an explicit input to this fixture. No model
         request or successful turn is asserted. *)
      Runtime_startup_state.set Available;
      Server_bootstrap_loops.start_keeper_loops ~claimed_persistence:claimed
        ~invalidate_full_health_snapshot:(fun () -> ()) ~sw ~clock:env#clock
        ~net:env#net ~proc_mgr:env#process_mgr state;
      let rec await_started_lane () =
        match Keeper_registry.get ~base_path keeper_name with
        | Some entry when Keeper_lane.crossed_start_boundary entry.lane -> entry
        | Some _ | None ->
            (match Keeper_runtime.boot_meta_failure_for ~base_path ~name:keeper_name with
             | Some failure -> Alcotest.fail failure.error
             | None -> ());
            Eio.Fiber.yield ();
            await_started_lane ()
      in
      let entry = await_started_lane () in
      Alcotest.(check bool) "actual Keeper lane crossed its start boundary" true
        (Keeper_lane.crossed_start_boundary entry.lane);
      Alcotest.(check bool) "lane has not exited at the observed boundary" true
        (Option.is_none (Keeper_lane.peek_exit entry.lane));
      Alcotest.(check bool) "real Session restore is still held" false !restore_completed;
      Alcotest.(check (list string)) "pending restore is not falsely failed"
        [ "restore_sessions" ] (Server_startup_state.pending_lazy_tasks ());
      Alcotest.(check (option string)) "no elapsed-time failure invented" None
        (Server_startup_state.snapshot ()).last_error;
      Eio.Promise.resolve signal_release ();
      Eio.Promise.await_exn restored;
      Alcotest.(check bool) "real restoration completes after release" true !restore_completed;
      ignore (require_session registry "restored-peer" : Session.session);
      Alcotest.(check bool) "original live connection object survives" true
        (require_session registry "live" == live);
      Alcotest.(check bool) "notification survives restoration" true
        (match Session.pop_message registry ~agent_name:"live" with
         | Some actual -> Yojson.Safe.equal event actual
         | None -> false);
      Alcotest.(check bool) "concurrent removal is not resurrected" true
        (Option.is_none (Session.get_session registry ~agent_name:"retired"));
      Eio.Promise.resolve signal_passed ();
      Eio.Fiber.await_cancel ())
    (fun () -> Eio.Promise.await passed)))

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run "Keeper with held Session restoration"
    [ "bootstrap",
      [ Alcotest.test_case "actual Keeper lane starts during held restoration"
          `Quick test_keeper_boots_while_real_restore_is_held ] ]
