include Test_exact_output_catalog_precedence_fixture

let with_saved_model_catalog f =
  let previous = Llm_provider.Model_catalog.global () in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some catalog -> Llm_provider.Model_catalog.set_global catalog
      | None -> Llm_provider.Model_catalog.clear_global ())
    f
;;

let test_offline_runtime_save_converges_by_write_stage () =
  with_saved_model_catalog @@ fun () ->
  with_temp_dir "exact-output-offline-capabilities" @@ fun root ->
  (* Offline means no published exact registry, not an uncatalogued model.
     Install the capability row for the synthetic runtime used by the save
     fixture, leaving its registry and durability assertions unchanged. *)
  let catalog_path = Filename.concat root "models.toml" in
  write_file catalog_path replacement_catalog;
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Error detail -> Alcotest.failf "offline capability fixture failed: %s" detail
   | Ok catalog -> Llm_provider.Model_catalog.set_global catalog);
  Test_exact_output_catalog_precedence_fixture
    .test_offline_runtime_save_converges_by_write_stage ()
;;

let require_lane_slots label ~lane_id ~expected registry =
  match Registry.resolve_lane registry ~lane_id with
  | Error error ->
    Alcotest.failf
      "%s: %s"
      label
      (Registry.lane_resolution_error_to_string error)
  | Ok { selected_slots } ->
    Alcotest.(check (list string))
      label
      expected
      (List.map
         (fun (slot : Registry.selected_slot) -> slot.slot_id)
         selected_slots)
;;

let require_lane_unconfigured label ~lane_id registry =
  match Registry.resolve_lane registry ~lane_id with
  | Error (Registry.Exact_lane_unconfigured { lane_id = actual_lane_id }) ->
    Alcotest.(check string) label lane_id actual_lane_id
  | Error error ->
    Alcotest.failf
      "%s returned the wrong failure: %s"
      label
      (Registry.lane_resolution_error_to_string error)
  | Ok _ -> Alcotest.failf "%s unexpectedly resolved" label
;;

let test_full_replacement_precedence ~clock ~mono_clock ~net ~proc_mgr ~fs () =
  with_temp_dir "exact-output-catalog-precedence" @@ fun root ->
  let config_root = Filename.concat root "config" in
  let base_path = Filename.concat root "workspace" in
  mkdir_p config_root;
  mkdir_p base_path;
  List.iter
    (fun name -> mkdir_p (Filename.concat config_root name))
    [ "keepers"; "prompts" ];
  let deployment_path = Filename.concat config_root "deployment-models.toml" in
  let replacement_path = Filename.concat root "replacement-models.toml" in
  let runtime_path = Filename.concat config_root "runtime.toml" in
  write_file deployment_path deployment_catalog;
  write_file replacement_path replacement_catalog;

  let deployment_snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = deployment_path; contents = deployment_catalog })
  in
  require_admitted deployment_snapshot deployment_target;
  let replacement_snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = replacement_path; contents = replacement_catalog })
  in
  require_admitted replacement_snapshot replacement_target;
  require_not_admitted replacement_snapshot deployment_target;

  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Unix.putenv "AGENT_CORE_MODEL_CATALOG" replacement_path;
  let create_server_state () =
    Eio.Switch.run @@ fun sw ->
    ignore
      (Server_runtime_bootstrap.create_server_state
         ~sw
         ~base_path
         ~clock
         ~mono_clock
         ~net
         ~proc_mgr
         ~fs
         ());
    (match Runtime.init_default ~config_path:runtime_path with
     | Ok () -> ()
     | Error detail -> Alcotest.failf "runtime initialization failed: %s" detail);
    Server_runtime_bootstrap.For_testing.configure_exact_output_registry
      ~config_root
      ()
  in
  let require_bootstrap_rejected label target_id =
    write_file runtime_path (runtime_toml target_id);
    let rejected =
      try
        create_server_state ();
        false
      with
      | Env_config_core.Config_error _ -> true
    in
    Alcotest.(check bool) label true rejected;
    require_registry_unpublished label
  in
  require_registry_unpublished "fresh process";
  let require_missing_mandatory_lane_rejected ~lane_id content =
    write_file runtime_path content;
    let message =
      try
        create_server_state ();
        Alcotest.failf "missing mandatory exact lane %s must reject startup" lane_id
      with
      | Env_config_core.Config_error message -> message
    in
    Alcotest.(check bool)
      ("missing lane error names " ^ lane_id)
      true
      (String_util.contains_substring message lane_id);
    Alcotest.(check bool)
      "missing lane error gives runtime.toml reset guidance"
      true
      (String_util.contains_substring message "reset the preserved runtime.toml");
    require_registry_unpublished ("missing mandatory exact lane " ^ lane_id)
  in
  require_missing_mandatory_lane_rejected
    ~lane_id:"hitl_auto_judge"
    (runtime_toml ~include_hitl_auto_judge:false replacement_target);
  require_missing_mandatory_lane_rejected
    ~lane_id:"board_attention_exact"
    (runtime_toml ~include_board_attention:false replacement_target);
  require_bootstrap_rejected "deployment target is suppressed" deployment_target;

  write_file runtime_path (runtime_toml replacement_target);
  create_server_state ();
  match Registry.current () with
  | Error _ -> Alcotest.fail "replacement-only target must publish the registry"
  | Ok registry ->
    let lanes =
      match Runtime_toml.parse_file runtime_path with
      | Ok (config : Runtime_schema.config) -> config.exact_output_lane_decls
      | Error errors ->
        Alcotest.failf
          "replacement runtime failed to parse for exact lanes: %d error(s)"
          (List.length errors)
    in
    let require_slots label registry =
      match Registry.resolve_lane registry ~lane_id:"auxiliary_exact" with
      | Error error ->
        Alcotest.failf
          "%s: %s"
          label
          (Registry.lane_resolution_error_to_string error)
      | Ok { selected_slots } ->
        Alcotest.(check (list string))
          label
          [ replacement_target ]
          (List.map
             (fun (slot : Registry.selected_slot) -> slot.slot_id)
             selected_slots)
    in
    require_slots "replacement-only lane" registry;
    let stable_registry_snapshot = registry in
    let prepared =
      match Registry.prepare_replacement ~lanes with
      | Ok prepared -> prepared
      | Error error ->
        Alcotest.failf
          "same-lane preparation failed: %s"
          (Registry.publication_error_to_string error)
    in
    (match Registry.current () with
     | Ok current ->
       Alcotest.(check bool)
         "pure preparation does not fence current"
         true
         (current == stable_registry_snapshot)
     | Error error ->
       Alcotest.failf
         "pure preparation fenced current: %s"
         (Registry.publication_error_to_string error));
    let reservation =
      match Registry.reserve_replacement prepared with
      | Ok reservation -> reservation
      | Error error ->
        Alcotest.failf
          "same-lane reservation failed: %s"
          (Registry.publication_error_to_string error)
    in
    Registry.current () |> require_publication_busy "published registry read fence";
    let concurrently_prepared =
      match Registry.prepare_replacement ~lanes with
      | Ok prepared -> prepared
      | Error error ->
        Alcotest.failf
          "pure preparation failed behind a publication fence: %s"
          (Registry.publication_error_to_string error)
    in
    Registry.reserve_replacement concurrently_prepared
    |> require_publication_busy "published second reservation";
    Registry.publish ~lanes replacement_snapshot
    |> require_publication_busy "published direct write fence";
    (match Registry.finish_replacement reservation with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "same-lane reservation did not finish: %s"
         (Registry.reservation_error_to_string error));
    let after_noop =
      match Registry.current () with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "same-lane finish did not republish: %s"
          (Registry.publication_error_to_string error)
    in
    Alcotest.(check bool)
      "same lanes preserve registry generation"
      true
      (after_noop == stable_registry_snapshot);
    require_slots "same-lane finish preserves slots" after_noop;
    let successor_prepared =
      match Registry.prepare_replacement ~lanes with
      | Ok prepared -> prepared
      | Error error ->
        Alcotest.failf
          "successor preparation failed: %s"
          (Registry.publication_error_to_string error)
    in
    let successor =
      match Registry.reserve_replacement successor_prepared with
      | Ok reservation -> reservation
      | Error error ->
        Alcotest.failf
          "successor reservation failed: %s"
          (Registry.publication_error_to_string error)
    in
    Registry.finish_replacement reservation
    |> require_reservation_inactive "stale finish";
    Registry.current () |> require_publication_busy "stale finish successor fence";
    Registry.abort_replacement reservation
    |> require_reservation_inactive "stale abort";
    Registry.current () |> require_publication_busy "stale abort successor fence";
    (match Registry.abort_replacement successor with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "successor reservation did not abort: %s"
         (Registry.reservation_error_to_string error));
    let after_stale_tokens =
      match Registry.current () with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "successor abort did not restore the published registry: %s"
          (Registry.publication_error_to_string error)
    in
    Alcotest.(check bool)
      "stale tokens preserve registry generation"
      true
      (after_stale_tokens == stable_registry_snapshot);
    require_slots "stale tokens preserve slots" after_stale_tokens;
    let stable_file = Fs_compat.load_file runtime_path in
    let stable_runtime = Runtime.get_default_runtime_id () in
    let failed_path = Filename.concat root "published-runtime-target-directory" in
    Unix.mkdir failed_path 0o755;
    (match
       Runtime.save_config_text
         ~runtime_config_path:failed_path
         failed_runtime_toml
     with
     | Error _ -> ()
     | Ok _receipt -> Alcotest.fail "published runtime save unexpectedly replaced a directory");
    let after_failed_save =
      match Registry.current () with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "failed published save left registry unavailable: %s"
          (Registry.publication_error_to_string error)
    in
    Alcotest.(check string)
      "failed published save preserves source file"
      stable_file
      (Fs_compat.load_file runtime_path);
    Alcotest.(check bool)
      "failed published save preserves target directory"
      true
      (Sys.is_directory failed_path);
    Alcotest.(check string)
      "failed published save preserves runtime cache"
      stable_runtime
      (Runtime.get_default_runtime_id ());
    Alcotest.(check bool)
      "failed published save preserves registry generation"
      true
      (after_failed_save == stable_registry_snapshot);
    require_slots "failed published save preserves slots" after_failed_save;
    let stale_prepared =
      match Registry.prepare_replacement ~lanes with
      | Ok prepared -> prepared
      | Error error ->
        Alcotest.failf
          "stale-candidate preparation failed: %s"
          (Registry.publication_error_to_string error)
    in
    let (_ : Registry.t) =
      match Registry.publish ~lanes replacement_snapshot with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "concurrent publication fixture failed: %s"
          (Registry.publication_error_to_string error)
    in
    Registry.reserve_replacement stale_prepared
    |> require_replacement_base_changed
         "stale prepared candidate";
    let successor_prepared =
      match Registry.prepare_replacement ~lanes with
      | Ok prepared -> prepared
      | Error error ->
        Alcotest.failf
          "post-CAS successor preparation failed: %s"
          (Registry.publication_error_to_string error)
    in
    let successor =
      match Registry.reserve_replacement successor_prepared with
      | Ok reservation -> reservation
      | Error error ->
        Alcotest.failf
          "post-CAS successor reservation failed: %s"
          (Registry.publication_error_to_string error)
    in
    Registry.reserve_replacement stale_prepared
    |> require_publication_busy "stale candidate cannot cross successor fence";
    Registry.current ()
    |> require_publication_busy "stale candidate preserves successor fence";
    (match Registry.abort_replacement successor with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "post-CAS successor abort failed: %s"
         (Registry.reservation_error_to_string error))
;;

let test_registry_preserves_admitted_slots_without_resolving_credentials () =
  let contents =
    [ catalog_toml
        ~api_key_env:"MISSING_FIXTURE_KEY"
        ~provider_id:"credential-missing-provider"
        ~model_id:"credential-missing-model"
        ~target_id:"credential-missing"
    ()
    ; catalog_toml
        ~api_key_env:"AVAILABLE_FIXTURE_KEY"
        ~provider_id:"credential-available-provider"
        ~model_id:"credential-available-model"
        ~target_id:"credential-available"
    ()
    ; catalog_toml
        ~api_key_env:"INVALID_FIXTURE_KEY"
        ~provider_id:"credential-invalid-provider"
        ~model_id:"credential-invalid-model"
        ~target_id:"credential-invalid"
    ()
    ; catalog_toml
        ~api_key_env:"READ_FAILED_FIXTURE_KEY"
        ~provider_id:"credential-read-failed-provider"
        ~model_id:"credential-read-failed-model"
        ~target_id:"credential-read-failed"
    ()
    ]
    |> String.concat "\n"
  in
  let getenv = function
    | "AVAILABLE_FIXTURE_KEY" -> Ok (Some "frozen-secret")
    | "INVALID_FIXTURE_KEY" -> Ok (Some "invalid\nsecret")
    | "READ_FAILED_FIXTURE_KEY" -> Error ()
    | "MISSING_FIXTURE_KEY" | _ -> Ok None
  in
  let snapshot =
    load_snapshot
      ~getenv
      (Exact_output.Full_replacement
         { source = "registry credential outcomes"; contents })
  in
  let credential_constrained =
    [ "credential-missing"; "credential-invalid"; "credential-read-failed" ]
  in
  let lanes : Runtime_schema.exact_output_lane_decl list =
    [ { id = "mixed-credentials"
      ; slot_ids =
          [ "credential-missing"
          ; "credential-available"
          ; "credential-invalid"
          ; "credential-read-failed"
          ]
      ; cli_slot_ids = []
      }
    ; { id = "credential-constrained"; slot_ids = credential_constrained ; cli_slot_ids = [] }
    ]
  in
  let registry =
    match Registry.publish ~lanes snapshot with
    | Ok registry -> registry
    | Error error ->
      Alcotest.failf
        "credential outcomes must not block publication: %s"
        (Registry.publication_error_to_string error)
  in
  require_lane_slots
    "MASC preserves every admitted mixed-credential slot"
    ~lane_id:"mixed-credentials"
    ~expected:
      [ "credential-missing"
      ; "credential-available"
      ; "credential-invalid"
      ; "credential-read-failed"
      ]
    registry;
  require_lane_slots
    "MASC does not pre-resolve credential-constrained slots"
    ~lane_id:"credential-constrained"
    ~expected:credential_constrained
    registry
;;

let with_configured_verifier_cli f =
  let saved = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "verifier-cli-runtime-" ".toml" in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore saved; Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun out -> output_string out {|[providers.official]
protocol = "claude-code"
command = "fixture-not-executed"
is-non-interactive = true
[models.verifier]
api-name = "verifier-fixture"
max-context = 400000
tools-support = true
[official.verifier]
[runtime]
default = "official.verifier"
|});
    (match Runtime.init_default ~config_path:path with
     | Ok () -> () | Error detail -> Alcotest.fail detail);
    f ())
;;

let test_cli_slots_survive_resolution_and_keep_a_lane_alive () =
  with_configured_verifier_cli @@ fun () ->
  let snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = "cli-slot-carry"; contents = replacement_catalog })
  in
  let cli = [ "official.verifier" ] in
  (match Registry.publish
     ~lanes:[{id="mixed-kind-duplicate";slot_ids=[replacement_target];cli_slot_ids=[replacement_target]}]
     snapshot with
   | Error (Registry.Duplicate_lane_slot {slot_id; _}) ->
     Alcotest.(check string) "API/CLI occurrences cannot lose their kind" replacement_target slot_id
   | Error error -> Alcotest.fail (Registry.publication_error_to_string error)
   | Ok _ -> Alcotest.fail "cross-kind duplicate was admitted");
  (match
     Registry.publish
       ~lanes:[ { id = "mixed"; slot_ids = [ replacement_target ]; cli_slot_ids = cli } ]
       snapshot
   with
   | Error error ->
     Alcotest.failf
       "cli-suffixed lane must publish: %s"
       (Registry.publication_error_to_string error)
   | Ok registry ->
     (match Registry.resolve_lane registry ~lane_id:"mixed" with
      | Ok { selected_slots; cli_slots } ->
        Alcotest.(check (list string))
          "catalog slots admit unchanged"
          [ replacement_target ]
          (List.map
             (fun (slot : Registry.selected_slot) -> slot.slot_id)
             selected_slots);
        Alcotest.(check (list string)) "cli slots carried verbatim" cli cli_slots
      | Error error ->
        Alcotest.failf
          "cli-suffixed lane must resolve: %s"
          (Registry.lane_resolution_error_to_string error)));
  (match Registry.publish
      ~required_lane_ids:[ "cli-required" ]
      ~lanes:[ { id = "cli-required"; slot_ids = []; cli_slot_ids = cli } ]
      snapshot with
   | Error error -> Alcotest.failf "CLI-only required lane must publish: %s"
       (Registry.publication_error_to_string error)
   | Ok registry ->
     (match Registry.resolve_lane registry ~lane_id:"cli-required" with
      | Ok { selected_slots = []; cli_slots } ->
        Alcotest.(check (list string)) "required CLI runtime" cli cli_slots
      | _ -> Alcotest.fail "required CLI-only lane must resolve"));
  (match Registry.publish
      ~required_lane_ids:[ "verifier_exact" ]
      ~lanes:[ { id = "verifier_exact"; slot_ids = []; cli_slot_ids = cli } ]
      snapshot with
   | Error error -> Alcotest.fail (Registry.publication_error_to_string error)
   | Ok _ ->
     (match Runtime.verifier_exact_lane_slot_ids () with
      | Ok slots -> Alcotest.(check (list string))
          "completion authority retains configured official clients" cli slots
      | Error detail -> Alcotest.fail detail);
     (* Carrying the id and being able to judge with it are different answers,
        and the server reports exact_output_authority_available from the
        readiness one. with_configured_verifier_cli materializes this official
        client, so here readiness has to accept it... *)
     (match Runtime.verifier_exact_lane_readiness () with
      | Ok [] -> ()
      | Ok (_ :: _) ->
        Alcotest.fail "readiness rejected a cli slot the runtime table admits"
      | Error detail ->
        Alcotest.failf "readiness refused a configured official client: %s" detail));
  (* ...and refuse the same lane once its cli slot names nothing in the runtime
     table. Publication carries cli ids verbatim and accepts it; readiness must not. *)
  let unmaterialized = "official.unmaterialized" in
  (match Registry.publish
      ~required_lane_ids:[ "verifier_exact" ]
      ~lanes:[ { id = "verifier_exact"; slot_ids = []; cli_slot_ids = [ unmaterialized ] } ]
      snapshot with
   | Error error -> Alcotest.fail (Registry.publication_error_to_string error)
   | Ok _ ->
     (match Runtime.verifier_exact_lane_readiness () with
      | Error detail ->
        Alcotest.(check bool)
          "readiness names the cli slot that resolves to no runtime"
          true
          (String_util.contains_substring detail unmaterialized)
      | Ok _ ->
        Alcotest.fail "readiness accepted a cli slot with no materialized runtime"));
  (match Registry.publish
      ~lanes:[ { id = "empty"; slot_ids = []; cli_slot_ids = [] } ] snapshot with
   | Error (Registry.Empty_lane _) -> ()
   | _ -> Alcotest.fail "a lane with neither transport must remain invalid");
  match
    Registry.publish
      ~lanes:
        [ { id = "cli-only"; slot_ids = [ "not-in-frozen-catalog" ]; cli_slot_ids = cli } ]
      snapshot
  with
  | Error error ->
    Alcotest.failf
      "cli-only lane must publish: %s"
      (Registry.publication_error_to_string error)
  | Ok registry ->
    (match Registry.resolve_lane registry ~lane_id:"cli-only" with
     | Ok { selected_slots = []; cli_slots } ->
       Alcotest.(check (list string))
         "every catalog slot dropped, the cli suffix keeps the lane alive"
         cli
         cli_slots
     | Ok _ -> Alcotest.fail "no catalog slot may admit in the cli-only lane"
     | Error error ->
       Alcotest.failf
         "cli-only lane must resolve, not degrade: %s"
         (Registry.lane_resolution_error_to_string error))
;;

let test_unknown_slots_degrade_locally_and_preserve_required_lane_atomicity () =
  let snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = "unknown-slot-local-degradation"
         ; contents = replacement_catalog
         })
  in
  let optional_lane = "optional-exact" in
  let unknown_target = "not-in-frozen-catalog" in
  let optional_registry =
    match
      Registry.publish
        ~lanes:[ { id = optional_lane; slot_ids = [ unknown_target ]; cli_slot_ids = [] } ]
        snapshot
    with
    | Ok registry -> registry
    | Error error ->
      Alcotest.failf
        "unknown optional slot must not block publication: %s"
        (Registry.publication_error_to_string error)
  in
  (match Registry.resolve_lane optional_registry ~lane_id:optional_lane with
   | Error (Registry.No_admitted_lane_slots { lane_id }) ->
     Alcotest.(check string) "degraded optional lane" optional_lane lane_id
   | Error error ->
     Alcotest.failf
       "unknown optional slot returned the wrong typed result: %s"
       (Registry.lane_resolution_error_to_string error)
   | Ok _ -> Alcotest.fail "unknown optional lane must have no selected slots");
  (match Registry.rejected_slots optional_registry with
   | [ rejected ] ->
     Alcotest.(check string) "rejected optional slot" unknown_target rejected.slot_id
   | rejected ->
     Alcotest.failf
       "expected one rejected optional slot, got %d"
       (List.length rejected));
  let required_lane = "required-exact" in
  let stable_registry =
    match
      Registry.publish
        ~required_lane_ids:[ required_lane ]
        ~lanes:[ { id = required_lane; slot_ids = [ replacement_target ]; cli_slot_ids = [] } ]
        snapshot
    with
    | Ok registry -> registry
    | Error error ->
      Alcotest.failf
        "required lane fixture failed to publish: %s"
        (Registry.publication_error_to_string error)
  in
  let stable_registry_snapshot = stable_registry in
  (match
     Registry.publish
       ~required_lane_ids:[ required_lane ]
       ~lanes:[ { id = required_lane; slot_ids = [ unknown_target ]; cli_slot_ids = [] } ]
       snapshot
   with
   | Error (Registry.Required_lane_unavailable { lane_id }) ->
     Alcotest.(check string) "unavailable required lane" required_lane lane_id
   | Error error ->
     Alcotest.failf
       "unknown required slot returned the wrong typed error: %s"
       (Registry.publication_error_to_string error)
   | Ok _ -> Alcotest.fail "unknown required slot must block publication");
  match Registry.current () with
  | Ok current ->
    Alcotest.(check bool)
      "failed required publication preserves the prior generation"
      true
      (current == stable_registry_snapshot)
  | Error error ->
    Alcotest.failf
      "failed required publication lost the prior registry: %s"
      (Registry.publication_error_to_string error)
;;

let test_hitl_auto_judge_lane_bootstrap ~clock ~mono_clock ~net ~proc_mgr ~fs () =
  with_temp_dir "exact-output-hitl-lane-bootstrap" @@ fun root ->
  let config_root = Filename.concat root "config" in
  let base_path = Filename.concat root "workspace" in
  mkdir_p config_root;
  mkdir_p base_path;
  List.iter
    (fun name -> mkdir_p (Filename.concat config_root name))
    [ "keepers"; "prompts" ];
  let replacement_path = Filename.concat root "replacement-models.toml" in
  let runtime_path = Filename.concat config_root "runtime.toml" in
  write_file replacement_path replacement_catalog;
  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Unix.putenv "AGENT_CORE_MODEL_CATALOG" replacement_path;
  let create_server_state () =
    Eio.Switch.run @@ fun sw ->
    ignore
      (Server_runtime_bootstrap.create_server_state
         ~sw
         ~base_path
         ~clock
         ~mono_clock
         ~net
         ~proc_mgr
         ~fs
         ());
    (match Runtime.init_default ~config_path:runtime_path with
     | Ok () -> ()
     | Error detail -> Alcotest.failf "runtime initialization failed: %s" detail);
    Server_runtime_bootstrap.For_testing.configure_exact_output_registry
      ~config_root
      ()
  in
  write_file
    runtime_path
    (runtime_toml ~include_hitl_auto_judge:false replacement_target);
  let explicit_lanes =
    match Runtime_toml.parse_file runtime_path with
    | Error errors ->
      Alcotest.failf
        "missing-HITL runtime fixture failed to parse: %d error(s)"
        (List.length errors)
    | Ok (config : Runtime_schema.config) -> config.exact_output_lane_decls
  in
  let missing_registry =
    let snapshot =
      load_control_snapshot
        (Exact_output.Full_replacement
           { source = replacement_path; contents = replacement_catalog })
    in
    match Registry.publish ~lanes:explicit_lanes snapshot with
    | Ok registry -> registry
    | Error error ->
      Alcotest.failf
        "explicit lanes without HITL failed to publish: %s"
        (Registry.publication_error_to_string error)
  in
  (match Registry.resolve_lane missing_registry ~lane_id:"hitl_auto_judge" with
   | Error (Registry.Exact_lane_unconfigured { lane_id }) ->
     Alcotest.(check string)
       "missing HITL remains typed unconfigured"
       "hitl_auto_judge"
       lane_id
   | Error error ->
     Alcotest.failf
       "missing HITL returned the wrong typed error: %s"
       (Registry.lane_resolution_error_to_string error)
   | Ok _ -> Alcotest.fail "missing HITL exact lane was synthesized");
  write_file runtime_path (runtime_toml replacement_target);
  create_server_state ();
  let default_registry = current_registry "default HITL lane bootstrap" in
  require_lane_slots
    "explicit default HITL lane keeps its configured slot"
    ~lane_id:"hitl_auto_judge"
    ~expected:[ replacement_target ]
    default_registry;
  write_file
    runtime_path
    (runtime_toml
       ~auxiliary_slots:[ deployment_target; replacement_target ]
       replacement_target);
  create_server_state ();
  let degraded_optional_registry =
    current_registry "unknown optional exact-output slot bootstrap"
  in
  require_lane_slots
    "unknown optional slot is excluded while admitted fallback remains"
    ~lane_id:"auxiliary_exact"
    ~expected:[ replacement_target ]
    degraded_optional_registry;
  (match Registry.rejected_slots degraded_optional_registry with
   | [ rejected ] ->
     Alcotest.(check string)
       "rejected lane"
       "auxiliary_exact"
       rejected.lane_id;
     Alcotest.(check int) "rejected position" 1 rejected.position;
     Alcotest.(check string) "rejected slot" deployment_target rejected.slot_id
   | rejected ->
     Alcotest.failf
       "expected one typed rejected slot, got %d"
       (List.length rejected));
  write_file replacement_path replacement_catalog_with_unbound_target;
  write_file
    runtime_path
    (runtime_toml
       ~auxiliary_slots:[ unbound_target; replacement_target ]
       replacement_target);
  create_server_state ();
  let unbound_optional_registry =
    current_registry "unbound optional exact-output target bootstrap"
  in
  require_lane_slots
    "unbound optional target is excluded while admitted fallback remains"
    ~lane_id:"auxiliary_exact"
    ~expected:[ replacement_target ]
    unbound_optional_registry;
  (match Registry.rejected_slots unbound_optional_registry with
   | [ rejected ] ->
     Alcotest.(check string) "unbound rejected slot" unbound_target rejected.slot_id
   | rejected ->
     Alcotest.failf
       "expected one unbound rejected slot, got %d"
       (List.length rejected));
  let stable_registry_snapshot = unbound_optional_registry in
  write_file
    runtime_path
    (runtime_toml
       ~hitl_slots:[ unbound_target ]
       replacement_target);
  (match create_server_state () with
   | exception Env_config_core.Config_error _ -> ()
   | () -> Alcotest.fail "an entirely unbound mandatory lane must block startup"
   | exception exn ->
     Alcotest.failf
       "unbound mandatory lane returned the wrong exception: %s"
       (Printexc.to_string exn));
  (match Registry.current () with
   | Ok registry ->
     Alcotest.(check bool)
       "failed mandatory admission preserves the published registry"
       true
       (registry == stable_registry_snapshot)
   | Error error ->
     Alcotest.failf
       "failed mandatory admission lost the published registry: %s"
       (Registry.publication_error_to_string error));
  write_file replacement_path replacement_catalog;
  let runtime_lane_candidates =
    [ replacement_runtime_target
    ; replacement_secondary_runtime_target
    ]
  in
  write_file
    runtime_path
    (runtime_toml
       ~runtime_lane_candidates
       replacement_target);
  create_server_state ();
require_lane_slots
  "runtime lane does not rewrite the explicit exact lane"
    ~lane_id:"hitl_auto_judge"
~expected:[ replacement_target ]
    (current_registry "runtime-lane HITL bootstrap");
  let explicit_slots = [ replacement_secondary_target; replacement_target ] in
  write_file
    runtime_path
    (runtime_toml
       ~hitl_slots:explicit_slots
       ~runtime_lane_candidates
       replacement_target);
  create_server_state ();
  require_lane_slots
    "explicit HITL lane preserves configured slot order"
    ~lane_id:"hitl_auto_judge"
    ~expected:explicit_slots
    (current_registry "explicit HITL lane bootstrap");
  (* Exercise the first-install writer followed by the actual server admission
     path, not only the lower-level registry. Neither CLI needs credentials to
     prove configuration admission; authentication is a separate setup check. *)
  List.iter
    (fun (protocol, command) ->
       write_file runtime_path
         (runtime_toml replacement_target
          ^ Printf.sprintf
              "\n[providers.first_cli]\nprotocol = %S\ncommand = %S\nis-non-interactive = true\n[models.verifier]\napi-name = \"verifier-fixture\"\nmax-context = 400000\ntools-support = true\n[first_cli.verifier]\n"
              protocol command);
       create_server_state ();
       let runtime_id = "first_cli.verifier" in
       (match Runtime.set_first_run_runtime ~runtime_config_path:runtime_path
                ~runtime_id () with
        | Ok _ -> ()
        | Error detail -> Alcotest.failf "first-run CLI selection failed: %s" detail);
       create_server_state ();
       let registry = current_registry "CLI-only server bootstrap" in
       List.iter
         (fun lane_id ->
            match Registry.resolve_lane registry ~lane_id with
            | Ok { selected_slots = []; cli_slots } ->
              Alcotest.(check (list string)) (protocol ^ " " ^ lane_id)
                [ runtime_id ] cli_slots
            | Ok _ -> Alcotest.fail "CLI bootstrap fabricated an HTTP slot"
            | Error error -> Alcotest.failf "CLI bootstrap lane failed: %s"
                (Registry.lane_resolution_error_to_string error))
         [ "hitl_auto_judge"; "board_attention_exact"; "librarian_exact"; "verifier_exact" ];
       (match protocol, Runtime.verifier_exact_lane_slot_ids () with
        | "codex-app-server", Error detail ->
          Alcotest.(check string) "Codex still requires native-tool suppression"
            (runtime_id ^ ": completion verifier requires native-tool suppression, which this client does not support") detail
        | "codex-app-server", Ok _ -> Alcotest.fail "unsafe Codex verifier was admitted"
        | _, Error detail -> Alcotest.fail detail
        | _, Ok slots -> Alcotest.(check (list string))
            "configured Claude direct binding supplies completion authority" [runtime_id] slots))
    [ "codex-app-server", "codex"; "claude-code", "claude" ]
;;

let test_published_registry_value_is_generation_stable () =
  let lane_id = "generation-swap" in
  let resolver_snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = "immutable-generation-swap"; contents = replacement_catalog })
  in
  let publish slot_ids =
    match
      Runtime.publish_exact_output_registry
        ~lanes:[ Runtime_schema.{ id = lane_id; slot_ids; cli_slot_ids = [] } ]
        resolver_snapshot
    with
    | Ok registry -> registry
    | Error detail ->
      Alcotest.failf "failed to publish immutable generation fixture: %s" detail
  in
  let first = publish [ replacement_target ] in
  let second = publish [ replacement_secondary_target ] in
  Alcotest.(check bool)
    "later publication replaces the earlier one"
    true
    (not (first == second));
  (match Runtime_exact_output_registry.resolve_lane first ~lane_id with
   | Ok _ -> ()
   | Error _ ->
     Alcotest.fail
       "captured publication must remain resolvable after the global swap");
  (match Runtime_exact_output_registry.resolve_lane second ~lane_id with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "latest publication must remain resolvable");
  match Runtime_exact_output_registry.current () with
  | Ok current ->
    Alcotest.(check bool)
      "global registry points at the latest publication"
      true
      (current == second)
  | Error _ -> Alcotest.fail "latest publication must be globally installed"
;;

let test_repo_seed_board_attention_lane_admits () =
  with_saved_model_catalog @@ fun () ->
  with_temp_dir "exact-output-repo-seed-admission" @@ fun root ->
  let config_root = Filename.concat root "config" in
  mkdir_p config_root;
  let repo_root = Masc_test_deps.find_project_root () in
  let source_config = Filename.concat repo_root "config" in
  let runtime_path = Filename.concat config_root "runtime.toml" in
  write_file
    runtime_path
    (Fs_compat.load_file (Filename.concat source_config "runtime.toml"));
  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Unix.putenv "AGENT_CORE_MODEL_CATALOG" "";
  (* This case represents a fresh process. Earlier bootstrap cases install
     explicit global replacements, which unsetting the environment does not
     clear. Follow production startup: embedded catalog, then runtime
     loading. *)
  Llm_provider.Model_catalog.clear_global ();
  ignore (Server_runtime_bootstrap.configure_agent_core_model_catalog_env ());
  (match Runtime.init_default ~config_path:runtime_path with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "repo runtime seed failed to load: %s" detail);
  let lanes =
    match Runtime_toml.parse_file runtime_path with
    | Error errors ->
      Alcotest.failf
        "repo runtime seed failed to parse for exact lanes: %d error(s)"
        (List.length errors)
    | Ok (config : Runtime_schema.config) -> config.exact_output_lane_decls
  in
  let board_lane =
    List.find_opt
      (fun (lane : Runtime_schema.exact_output_lane_decl) ->
         String.equal lane.id Masc.Keeper_board_attention_exact_flow.lane_id)
      lanes
  in
  (match board_lane with
   | None -> Alcotest.fail "repo runtime seed is missing the Board attention lane"
   | Some lane ->
     Alcotest.(check bool)
       "repo Board attention lane has configured slots"
       true
       (lane.slot_ids <> []));
  let credential_envs = [ "ZAI_API_KEY"; "DEEPSEEK_API_KEY" ] in
  let previous_credentials =
    List.map
      (fun credential_env -> credential_env, Sys.getenv_opt credential_env)
      credential_envs
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (credential_env, previous_credential) ->
           Unix.putenv
             credential_env
             (Option.value ~default:"" previous_credential))
        previous_credentials)
    (fun () ->
       let require_published_seed label =
         Server_runtime_bootstrap.For_testing.configure_exact_output_registry
           ~config_root
           ();
         let registry = current_registry label in
         List.iter
           (fun (lane : Runtime_schema.exact_output_lane_decl) ->
              require_lane_slots
                (label ^ " " ^ lane.id)
                ~lane_id:lane.id
                ~expected:lane.slot_ids
                registry)
           lanes
       in
       List.iter (fun credential_env -> Unix.putenv credential_env "") credential_envs;
       require_published_seed "credential-free repo config";
       List.iter
         (fun credential_env ->
            Unix.putenv credential_env "exact-output-seed-test")
         credential_envs;
       require_published_seed "credential-populated repo config")
;;

(* An assignment whose target left the frozen catalog does not fail a lane
   or a boot — the keeper silently falls back to the default runtime. On
   2026-08-28 three keepers ran that way for days with no log line naming
   them. The classifier must name exactly those, and only those. *)
let test_catalog_absent_assignments_names_only_retired_targets () =
  with_temp_dir "catalog-absent-assignments" @@ fun root ->
  let deployment_path = Filename.concat root "deployment-models.toml" in
  write_file deployment_path deployment_catalog;
  let snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = deployment_path; contents = deployment_catalog })
  in
  require_admitted snapshot deployment_target;
  Alcotest.(check (list (pair string string)))
    "only the catalog-absent assignment is named"
    [ ("keeper-ghost", "ghost_provider.retired-model") ]
    (Registry.catalog_absent_assignments snapshot
       ~assignments:
         [ ("keeper-live", deployment_target)
         ; ("keeper-ghost", "ghost_provider.retired-model")
         ])
;;

(* The Lanes view lists only the slots the registry admitted. An append reads
   the slots the file declares, so a slot the registry dropped is still
   declared after it, and the replaced registry still drops it rather than
   losing it from the file. *)
let test_an_append_keeps_a_slot_the_registry_dropped () =
  with_temp_dir "exact-append-dropped" @@ fun root ->
  let saved = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore saved;
      ignore (Registry.unpublish ()))
  @@ fun () ->
  let path = Filename.concat root "runtime.toml" in
  let dropped = "not-in-frozen-catalog" in
  write_file path
    (runtime_toml ~include_board_attention:false replacement_target
     ^ Printf.sprintf
         "\n[runtime.exact_output_lanes.board_attention_exact]\nslots = [%S, %S]\n"
         dropped
         replacement_target);
  (match Runtime.init_default ~config_path:path with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "runtime initialization failed: %s" detail);
  let declared () =
    match Runtime_toml.parse_string (Fs_compat.load_file path) with
    | Error _ -> Alcotest.fail "the written runtime.toml does not parse"
    | Ok config -> config.Runtime_schema.exact_output_lane_decls
  in
  let snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = "append-dropped"; contents = replacement_catalog })
  in
  let dropped_on_board registry =
    Registry.rejected_slots registry
    |> List.filter_map (fun (slot : Registry.rejected_slot) ->
      if String.equal slot.lane_id "board_attention_exact" then Some slot.slot_id else None)
  in
  (match Runtime.publish_exact_output_registry ~lanes:(declared ()) snapshot with
   | Ok registry ->
     Alcotest.(check (list string)) "the registry drops the unknown slot" [ dropped ]
       (dropped_on_board registry)
   | Error detail -> Alcotest.failf "publication failed: %s" detail);
  (match
     Runtime.append_exact_output_lane_slot ~runtime_config_path:path
       ~lane:Runtime.Board_attention ~slot:replacement_secondary_target ()
   with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "append failed: %s" detail);
  (match
     List.find_opt
       (fun (lane : Runtime_schema.exact_output_lane_decl) ->
          String.equal lane.id "board_attention_exact")
       (declared ())
   with
   | Some lane ->
     Alcotest.(check (list string)) "the dropped slot is still declared, in front"
       [ dropped; replacement_target; replacement_secondary_target ] lane.slot_ids
   | None -> Alcotest.fail "the append lost the lane");
  match Registry.current () with
  | Error error -> Alcotest.failf "no registry after the append: %s"
                     (Registry.publication_error_to_string error)
  | Ok registry ->
    Alcotest.(check (list string)) "the replaced registry still drops it" [ dropped ]
      (dropped_on_board registry);
    (match Registry.resolve_lane registry ~lane_id:"board_attention_exact" with
     | Ok { selected_slots; _ } ->
       Alcotest.(check (list string)) "the appended slot is admitted after the kept one"
         [ replacement_target; replacement_secondary_target ]
         (List.map (fun (slot : Registry.selected_slot) -> slot.slot_id) selected_slots)
     | Error error -> Alcotest.failf "the lane does not resolve: %s"
                        (Registry.lane_resolution_error_to_string error))
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
    Server_runtime_bootstrap.init_runtime_context env
  in
  Alcotest.run
    "Exact_output_catalog_precedence"
    [ ( "bootstrap",
        [
          Alcotest.test_case
            "catalog_absent_assignments names only retired targets"
            `Quick
            test_catalog_absent_assignments_names_only_retired_targets
        ; Alcotest.test_case
            "offline saves converge cache without publishing registry"
            `Quick
            test_offline_runtime_save_converges_by_write_stage
        ; Alcotest.test_case
            "full replacement suppresses deployment targets"
            `Quick
            (test_full_replacement_precedence
               ~clock
               ~mono_clock
               ~net
               ~proc_mgr
               ~fs)
        ; Alcotest.test_case
"HITL lane is explicit, typed when missing, and preserves configured order"
            `Quick
            (test_hitl_auto_judge_lane_bootstrap
               ~clock
               ~mono_clock
               ~net
               ~proc_mgr
               ~fs)
        ; Alcotest.test_case
            "registry preserves admitted slots without resolving credentials"
            `Quick
            test_registry_preserves_admitted_slots_without_resolving_credentials
        ; Alcotest.test_case
            "unknown slots degrade locally while required lanes stay atomic"
            `Quick
            test_unknown_slots_degrade_locally_and_preserve_required_lane_atomicity
        ; Alcotest.test_case
            "closed registry transaction publishes final generation and lane"
            `Quick
            test_closed_registry_transaction
; Alcotest.test_case
    "captured publication remains stable across global generation swap"
    `Quick
    test_published_registry_value_is_generation_stable

        ; Alcotest.test_case
            "after-rename runtime save converges file, registry, and cache"
            `Quick
            test_runtime_after_rename_converges_state
        ; Alcotest.test_case
            "repo config admits the Board attention seed lane"
            `Quick
            test_repo_seed_board_attention_lane_admits
        ; Alcotest.test_case
            "cli slots survive resolution and keep a lane alive"
            `Quick
            test_cli_slots_survive_resolution_and_keep_a_lane_alive
        ; Alcotest.test_case
            "an append keeps a slot the registry dropped"
            `Quick
            test_an_append_keeps_a_slot_the_registry_dropped
        ] ) ]
;;
