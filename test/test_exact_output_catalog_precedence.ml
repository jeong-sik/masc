include Test_exact_output_catalog_precedence_fixture

let require_lane_slots label ~lane_id ~expected registry =
  match Registry.resolve_lane registry ~lane_id with
  | Error error ->
    Alcotest.failf
      "%s: %s"
      label
      (Registry.lane_resolution_error_to_string error)
  | Ok { selected_slots; unavailable_slots } ->
    Alcotest.(check int)
      (label ^ " unavailable")
      0
      (List.length unavailable_slots);
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
    [ "keepers"; "personas"; "prompts" ];
  let overlay_path = Filename.concat config_root "oas-models-overlay.toml" in
  let replacement_path = Filename.concat root "replacement-models.toml" in
  let runtime_path = Filename.concat config_root "runtime.toml" in
  write_file overlay_path overlay_catalog;
  write_file replacement_path replacement_catalog;

  let overlay_snapshot =
    load_control_snapshot
      (Exact_output.Embedded_with_overlay
         { source = overlay_path; contents = overlay_catalog })
  in
  require_admitted overlay_snapshot overlay_target;
  let replacement_snapshot =
    load_control_snapshot
      (Exact_output.Full_replacement
         { source = replacement_path; contents = replacement_catalog })
  in
  require_admitted replacement_snapshot replacement_target;
  require_not_admitted replacement_snapshot overlay_target;

  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Unix.putenv "OAS_MODEL_CATALOG" replacement_path;
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
  require_bootstrap_rejected "overlay target is suppressed" overlay_target;

  write_file runtime_path (runtime_toml replacement_target);
  create_server_state ();
  match Registry.current () with
  | Error _ -> Alcotest.fail "replacement-only target must publish the registry"
  | Ok registry ->
    let lanes : Runtime_schema.exact_output_lane_decl list =
      [ { id = "compaction_exact"; slot_ids = [ replacement_target ] } ]
    in
    let require_slots label registry =
      match Registry.resolve_lane registry ~lane_id:"compaction_exact" with
      | Error error ->
        Alcotest.failf
          "%s: %s"
          label
          (Registry.lane_resolution_error_to_string error)
      | Ok { selected_slots; unavailable_slots } ->
        Alcotest.(check int) (label ^ " unavailable") 0
          (List.length unavailable_slots);
        Alcotest.(check (list string))
          label
          [ replacement_target ]
          (List.map
             (fun (slot : Registry.selected_slot) -> slot.slot_id)
             selected_slots)
    in
    require_slots "replacement-only lane" registry;
    let stable_generation = Registry.generation registry in
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
       Alcotest.(check int64)
         "pure preparation does not fence current"
         stable_generation
         (Registry.generation current)
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
    Alcotest.(check int64)
      "same lanes preserve registry generation"
      stable_generation
      (Registry.generation after_noop);
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
    Alcotest.(check int64)
      "stale tokens preserve registry generation"
      stable_generation
      (Registry.generation after_stale_tokens);
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
     | Ok () -> Alcotest.fail "published runtime save unexpectedly replaced a directory");
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
    Alcotest.(check int64)
      "failed published save preserves registry generation"
      stable_generation
      (Registry.generation after_failed_save);
    require_slots "failed published save preserves slots" after_failed_save;
    let stale_prepared =
      match Registry.prepare_replacement ~lanes with
      | Ok prepared -> prepared
      | Error error ->
        Alcotest.failf
          "stale-candidate preparation failed: %s"
          (Registry.publication_error_to_string error)
    in
    let concurrent_registry =
      match Registry.publish ~lanes replacement_snapshot with
      | Ok registry -> registry
      | Error error ->
        Alcotest.failf
          "concurrent publication fixture failed: %s"
          (Registry.publication_error_to_string error)
    in
    let concurrent_generation = Registry.generation concurrent_registry in
    Registry.reserve_replacement stale_prepared
    |> require_replacement_base_changed
         "stale prepared candidate"
         ~expected_generation:(Some stable_generation)
         ~actual_generation:(Some concurrent_generation);
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

let unavailable_signature (slot : Registry.unavailable_slot) =
  let kind, target_ref, environment_variable =
    match slot.cause with
    | Exact_output.Missing_target_credential
        { target_ref; environment_variable } ->
      "missing", target_ref, environment_variable
    | Exact_output.Target_credential_invalid
        { target_ref; environment_variable } ->
      "invalid", target_ref, environment_variable
    | Exact_output.Target_credential_read_failed
        { target_ref; environment_variable } ->
      "read-failed", target_ref, environment_variable
  in
  Printf.sprintf
    "%d:%s:%s:%s:%s"
    slot.position
    slot.slot_id
    kind
    target_ref
    environment_variable
;;

let test_registry_skips_typed_unavailable_credentials () =
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
  let unavailable =
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
      }
    ; { id = "all-unavailable"; slot_ids = unavailable }
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
  let expected_mixed_unavailable =
    [ "1:credential-missing:missing:credential-missing:MISSING_FIXTURE_KEY"
    ; "3:credential-invalid:invalid:credential-invalid:INVALID_FIXTURE_KEY"
    ; "4:credential-read-failed:read-failed:credential-read-failed:READ_FAILED_FIXTURE_KEY"
    ]
  in
  (match Registry.resolve_lane registry ~lane_id:"mixed-credentials" with
   | Error error ->
     Alcotest.failf
       "one usable slot must keep the lane available: %s"
       (Registry.lane_resolution_error_to_string error)
   | Ok { selected_slots; unavailable_slots } ->
     Alcotest.(check (list string))
       "usable slots retain declaration order"
       [ "credential-available" ]
       (List.map
          (fun (slot : Registry.selected_slot) -> slot.slot_id)
          selected_slots);
     Alcotest.(check (list string))
       "unavailable credential diagnostics retain declaration order"
       expected_mixed_unavailable
       (List.map unavailable_signature unavailable_slots));
  match Registry.resolve_lane registry ~lane_id:"all-unavailable" with
  | Error (Registry.No_usable_lane_slots { lane_id; unavailable_slots }) ->
    Alcotest.(check string) "terminal lane id" "all-unavailable" lane_id;
    Alcotest.(check (list string))
      "terminal diagnostics retain declaration order"
      [ "1:credential-missing:missing:credential-missing:MISSING_FIXTURE_KEY"
      ; "2:credential-invalid:invalid:credential-invalid:INVALID_FIXTURE_KEY"
      ; "3:credential-read-failed:read-failed:credential-read-failed:READ_FAILED_FIXTURE_KEY"
      ]
      (List.map unavailable_signature unavailable_slots)
  | Error error ->
    Alcotest.failf
      "all-unavailable lane returned the wrong typed failure: %s"
      (Registry.lane_resolution_error_to_string error)
  | Ok _ -> Alcotest.fail "all-unavailable lane must fail closed"
;;

let test_hitl_auto_judge_lane_bootstrap ~clock ~mono_clock ~net ~proc_mgr ~fs () =
  with_temp_dir "exact-output-hitl-lane-bootstrap" @@ fun root ->
  let config_root = Filename.concat root "config" in
  let base_path = Filename.concat root "workspace" in
  mkdir_p config_root;
  mkdir_p base_path;
  List.iter
    (fun name -> mkdir_p (Filename.concat config_root name))
    [ "keepers"; "personas"; "prompts" ];
  let replacement_path = Filename.concat root "replacement-models.toml" in
  let runtime_path = Filename.concat config_root "runtime.toml" in
  write_file replacement_path replacement_catalog;
  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Unix.putenv "OAS_MODEL_CATALOG" replacement_path;
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
  let structured_judge_candidates =
    [ replacement_structured_judge_target
    ; replacement_secondary_runtime_target
    ]
  in
  write_file
    runtime_path
    (runtime_toml
       ~structured_judge_candidates
       replacement_target);
  create_server_state ();
require_lane_slots
  "structured-judge runtime lane does not rewrite the explicit exact lane"
    ~lane_id:"hitl_auto_judge"
~expected:[ replacement_target ]
    (current_registry "runtime-lane HITL bootstrap");
  let explicit_slots = [ replacement_secondary_target; replacement_target ] in
  write_file
    runtime_path
    (runtime_toml
       ~hitl_slots:explicit_slots
       ~structured_judge_candidates
       replacement_target);
  create_server_state ();
  require_lane_slots
    "explicit HITL lane preserves configured slot order"
    ~lane_id:"hitl_auto_judge"
    ~expected:explicit_slots
    (current_registry "explicit HITL lane bootstrap")
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
        ~lanes:[ Runtime_schema.{ id = lane_id; slot_ids } ]
        resolver_snapshot
    with
    | Ok registry -> registry
    | Error detail ->
      Alcotest.failf "failed to publish immutable generation fixture: %s" detail
  in
  let first = publish [ replacement_target ] in
  let first_generation = Runtime_exact_output_registry.generation first in
  let second = publish [ replacement_secondary_target ] in
  let second_generation = Runtime_exact_output_registry.generation second in
  Alcotest.(check int64)
    "later publication advances generation"
    (Int64.succ first_generation)
    second_generation;
  Alcotest.(check int64)
    "captured publication retains its generation"
    first_generation
    (Runtime_exact_output_registry.generation first);
  (match Runtime_exact_output_registry.resolve_lane first ~lane_id with
   | Ok _ -> ()
   | Error _ ->
     Alcotest.fail
       "captured publication must remain resolvable after the global generation swaps");
  (match Runtime_exact_output_registry.resolve_lane second ~lane_id with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "latest publication must remain resolvable");
  match Runtime_exact_output_registry.current () with
  | Ok current ->
    Alcotest.(check int64)
      "global registry points at the latest publication"
      second_generation
      (Runtime_exact_output_registry.generation current)
  | Error _ -> Alcotest.fail "latest publication must be globally installed"
;;

let test_repo_seed_board_attention_lane_admits () =
  with_temp_dir "exact-output-repo-seed-admission" @@ fun root ->
  let config_root = Filename.concat root "config" in
  mkdir_p config_root;
  let repo_root = Masc_test_deps.find_project_root () in
  let source_config = Filename.concat repo_root "config" in
  let runtime_path = Filename.concat config_root "runtime.toml" in
  let overlay_path = Filename.concat config_root "oas-models-overlay.toml" in
  write_file
    runtime_path
    (Fs_compat.load_file (Filename.concat source_config "runtime.toml"));
  write_file
    overlay_path
    (Fs_compat.load_file
       (Filename.concat source_config "oas-models-overlay.toml"));
  Unix.putenv "MASC_CONFIG_DIR" config_root;
  Unix.putenv "OAS_MODEL_CATALOG" "";
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
         String.equal lane.id Keeper_board_attention_exact_flow.lane_id)
      lanes
  in
  (match board_lane with
   | None -> Alcotest.fail "repo runtime seed is missing the Board attention lane"
   | Some lane ->
     Alcotest.(check bool)
       "repo Board attention lane has configured slots"
       true
       (lane.slot_ids <> []));
  let credential_envs = [ "ZAI_API_KEY_SB"; "DEEPSEEK_API_KEY" ] in
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
       List.iter (fun credential_env -> Unix.putenv credential_env "") credential_envs;
       let unavailable_message =
         try
           Server_runtime_bootstrap.For_testing.configure_exact_output_registry
             ~config_root
             ();
           Alcotest.fail
             "mandatory seed lanes must reject startup without a usable credential"
         with
         | Env_config_core.Config_error message -> message
       in
       Alcotest.(check bool)
         "credential failure names the first mandatory lane"
         true
         (String_util.contains_substring unavailable_message "hitl_auto_judge");
       Alcotest.(check bool)
         "credential failure gives provider-neutral credential guidance"
         true
         (String_util.contains_substring unavailable_message "credential");
       List.iter
         (fun credential_env ->
            Unix.putenv credential_env "exact-output-seed-test")
         credential_envs;
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
       require_published_seed "repo config plus deployment overlay";
       let overlay_without_pricing =
         Fs_compat.load_file
           (Filename.concat source_config "oas-models-overlay.toml")
         |> String.split_on_char '\n'
         |> List.filter (fun line ->
           let line = String.trim line in
           not
             (String.starts_with ~prefix:"input_per_million =" line
              || String.starts_with ~prefix:"output_per_million =" line))
         |> String.concat "\n"
       in
       write_file overlay_path overlay_without_pricing;
       require_published_seed "pricing-free deployment overlay")
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
        [ Alcotest.test_case
            "offline saves converge cache without publishing registry"
            `Quick
            test_offline_runtime_save_converges_by_write_stage
        ; Alcotest.test_case
            "full replacement suppresses overlay targets"
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
            "credential failures skip slots and fail only when none are usable"
            `Quick
            test_registry_skips_typed_unavailable_credentials
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
            "repo config and deployment overlay admit the Board attention seed lane"
            `Quick
            test_repo_seed_board_attention_lane_admits
        ] ) ]
;;
