module Cases = Test_mcp_tool_matrix_cases
module Keeper_publication_recovery_availability =
  Masc.Keeper_publication_recovery_availability

module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server
module Recovery_test = Fs_compat.Publication_recovery_for_testing

let contains_substring text fragment =
  let text_len = String.length text in
  let fragment_len = String.length fragment in
  let rec loop index =
    if fragment_len = 0
    then true
    else if index + fragment_len > text_len
    then false
    else if String.sub text index fragment_len = fragment
    then true
    else loop (index + 1)
  in
  loop 0
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let test_masc_start_tilde_rejects_empty_initial_home () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = Cases.temp_dir "mcp-start-home-empty-" in
  let saved_home = Sys.getenv_opt "HOME" in
  let saved_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      Cases.cleanup_dir base_path;
      restore_env "HOME" saved_home;
      restore_env "MASC_BASE_PATH" saved_base_path)
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base_path;
      let fixture =
        Cases.make_fixture
          sw
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~fs:(Eio.Stdenv.fs env)
          ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          (Eio.Stdenv.clock env)
          ~base_path
          Cases.Fresh
      in
      let result =
        Cases.execute_tool
          fixture
          ~name:"masc_start"
          ~arguments:(`Assoc [ "path", `String "~" ])
      in
      Alcotest.(check bool) "rejected" false (Tool_result.is_success result);
      let message = Tool_result.message result in
      Alcotest.(check bool)
        "reports missing HOME"
        true
        (contains_substring message "HOME is required to expand '~'"))
;;

let test_health_aggregate_sum_rejects_overflow () =
  (match
     Mcp_server.For_testing.publication_recovery_health_count_sum
       [ Int.max_int; 1 ]
   with
   | Mcp_server.For_testing.Health_count_overflow -> ()
   | Mcp_server.For_testing.Health_count_negative ->
     failwith "positive counts were classified negative"
   | Mcp_server.For_testing.Health_count_sum _ ->
     failwith "aggregate count overflow was accepted");
  match
    Mcp_server.For_testing.publication_recovery_health_count_sum [ 2; 3; 5 ]
  with
  | Mcp_server.For_testing.Health_count_sum 10 -> ()
  | Mcp_server.For_testing.Health_count_sum value ->
    failwith (Printf.sprintf "aggregate sum returned %d" value)
  | Mcp_server.For_testing.Health_count_negative ->
    failwith "positive counts were classified negative"
  | Mcp_server.For_testing.Health_count_overflow ->
    failwith "ordinary aggregate sum overflowed"
;;

let test_identity_projection_failure_is_terminal_degraded_health () =
  Eio_main.run
  @@ fun _ ->
  let health =
    Mcp_server.For_testing.publication_recovery_identity_projection_failure_health
      (Failure "deterministic identity projection failure")
  in
  Alcotest.(check string)
    "projection failure is terminal degraded health"
    "degraded"
    Yojson.Safe.Util.(health |> member "status" |> to_string);
  Alcotest.(check bool)
    "projection failure requires operator attention"
    true
    Yojson.Safe.Util.(health |> member "operator_action_required" |> to_bool);
  Alcotest.(check (list string))
    "projection failure reason is explicit"
    [ "owner_identity_projection_failed" ]
    Yojson.Safe.Util.
      (health |> member "status_reasons" |> to_list |> List.map to_string)
;;

let require_registry state =
  match Mcp_server.For_testing.publication_recovery_registry state with
  | Some registry -> registry
  | None -> Alcotest.fail "initialized runtime omitted its recovery registry"
;;

let health state =
  state
  |> Mcp_server.workspace_scope
  |> Mcp_server.workspace_scope_publication_recovery_snapshot
  |> Mcp_server.publication_recovery_snapshot_to_health_yojson
;;

let require_uuid value =
  match Uuidm.of_string value with
  | Some operation_id -> operation_id
  | None -> Alcotest.failf "invalid fixture UUID %S" value
;;

let seed_prepared_recovery ~fs ~base_path ~owner ~operation_id =
  let config = Masc.Workspace.default_config base_path in
  ignore (Masc.Workspace.init config ~agent_name:None);
  let allowed_root_path = Unix.realpath config.base_path in
  let allowed_root =
    Eio.Path.stat ~follow:false Eio.Path.(fs / allowed_root_path)
  in
  Eio.Switch.run
  @@ fun sw ->
  match
    Fs_compat.open_publication_recovery_registry
      ~sw
      ~fs
      ~registry_root:Eio.Path.(fs / Masc.Workspace.masc_root_dir config)
  with
  | Error error ->
    Alcotest.fail
      (Fs_compat.publication_recovery_registry_error_to_string error)
  | Ok registry ->
    (match
       Recovery_test.seed_prepared
         ~registry:(Recovery_test.private_registry registry)
         ~owner
         ~operation_id
         ~allowed_root_path
         ~allowed_root_device:allowed_root.dev
         ~allowed_root_inode:allowed_root.ino
         ~parent_components:[]
         ~parent_device:allowed_root.dev
         ~parent_inode:allowed_root.ino
         ~target_leaf:"target.json"
         ~permissions:0o600
     with
     | Ok () -> ()
     | Error error ->
       Alcotest.fail (Recovery_test.fixture_error_to_string error))
;;

let create_runtime env sw ~base_path =
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Mcp_eio.create_state_eio
    ~sw
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~fs
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~net:(Eio.Stdenv.net env)
    ~base_path
;;

let test_runtime_publishes_before_open_and_discovers_without_owner_fanout () =
  Eio_main.run
  @@ fun env ->
  let base_path = Cases.temp_dir "mcp-recovery-incremental-" in
  Fun.protect
    ~finally:(fun () -> Cases.cleanup_dir base_path)
    (fun () ->
      let fs = Eio.Stdenv.fs env in
      let first_owner = "startup-valid-owner" in
      let second_owner = "startup owner with spaces" in
      seed_prepared_recovery
        ~fs
        ~base_path
        ~owner:first_owner
        ~operation_id:(require_uuid "66666666-6666-4666-8666-666666666666");
      seed_prepared_recovery
        ~fs
        ~base_path
        ~owner:second_owner
        ~operation_id:(require_uuid "77777777-7777-4777-8777-777777777777");
      Eio.Switch.run
      @@ fun sw ->
      let state = create_runtime env sw ~base_path in
      let publication_recovery_provider =
        Mcp_server.publication_recovery_availability_provider state
      in
      (match publication_recovery_provider () with
       | Keeper_publication_recovery_availability.Initializing -> ()
       | Keeper_publication_recovery_availability.Available _
       | Keeper_publication_recovery_availability.Registry_unavailable _
       | Keeper_publication_recovery_availability.Initialization_crashed _
       | Keeper_publication_recovery_availability.Non_runtime ->
         Alcotest.fail "live provider did not expose initial runtime state");
      (match
         Mcp_server.For_testing.publication_recovery_runtime_observation state
       with
       | Mcp_server.For_testing.Runtime_initializing -> ()
       | Mcp_server.For_testing.Runtime_available
       | Mcp_server.For_testing.Runtime_unavailable
       | Mcp_server.For_testing.Runtime_initialization_crashed
       | Mcp_server.For_testing.Runtime_non_runtime ->
         Alcotest.fail "registry open ran before state publication");
      let initial_health = health state in
      Alcotest.(check string)
        "initial health is warming"
        "warming"
        Yojson.Safe.Util.(initial_health |> member "status" |> to_string);
      Alcotest.(check string)
        "initial phase is explicit"
        "initializing"
        Yojson.Safe.Util.
          (initial_health |> member "discovery_phase" |> to_string);
      let initial_scope = Mcp_server.workspace_scope state in
      let nested_workspace = Filename.concat base_path "nested-workspace" in
      Unix.mkdir nested_workspace 0o700;
      let updated_config =
        { initial_scope.config with workspace_path = nested_workspace }
      in
      (match Mcp_server.set_workspace_config state updated_config with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail
           (Mcp_server.workspace_switch_error_to_string error));
      Mcp_server.For_testing.await_publication_recovery_initialization state;
      (match
         Mcp_server.For_testing.publication_recovery_runtime_observation state
       with
       | Mcp_server.For_testing.Runtime_available -> ()
       | Mcp_server.For_testing.Runtime_initializing
       | Mcp_server.For_testing.Runtime_unavailable
       | Mcp_server.For_testing.Runtime_initialization_crashed
       | Mcp_server.For_testing.Runtime_non_runtime ->
         Alcotest.fail "registry initialization did not become available");
      (match publication_recovery_provider () with
       | Keeper_publication_recovery_availability.Available _ -> ()
       | Keeper_publication_recovery_availability.Initializing
       | Keeper_publication_recovery_availability.Registry_unavailable _
       | Keeper_publication_recovery_availability.Initialization_crashed _
       | Keeper_publication_recovery_availability.Non_runtime ->
         Alcotest.fail "same live provider did not observe availability");
      let initialized_scope = Mcp_server.workspace_scope state in
      Alcotest.(check bool)
        "config replacement preserves the live recovery handle"
        true
        (initial_scope.publication_recovery
         == initialized_scope.publication_recovery);
      Alcotest.(check string)
        "async initialization does not overwrite config"
        nested_workspace
        initialized_scope.config.workspace_path;
      let registry = require_registry state in
      let private_registry =
        Fs_compat.Publication_recovery_for_testing.private_registry registry
      in
      Fs_compat.Publication_recovery_for_testing.For_testing.await_discovery_settlement
        private_registry;
      let before_demand =
        Fs_compat.Publication_recovery_for_testing.For_testing.snapshot
          private_registry
      in
      Alcotest.(check int)
        "startup discovery does not prepopulate exact owners"
        0
        (List.length before_demand.owners);
      (match before_demand.discovery with
       | Fs_compat.Publication_recovery_for_testing.Snapshot_discovery_complete rows ->
         Alcotest.(check int) "both names observed" 2 (List.length rows)
       | Fs_compat.Publication_recovery_for_testing.Snapshot_discovery_required
       | Fs_compat.Publication_recovery_for_testing.Snapshot_discovery_running
       | Fs_compat.Publication_recovery_for_testing.Snapshot_discovery_failed _ ->
         Alcotest.fail "discovery settlement did not publish success");
      let settled_health = health state in
      Alcotest.(check bool)
        "owner-local attention never becomes a global gate"
        false
        Yojson.Safe.Util.
          (settled_health |> member "global_blocking" |> to_bool);
      Alcotest.(check int)
        "MASC identity rejection is aggregated"
        1
        Yojson.Safe.Util.
          (settled_health
           |> member "row_counts"
           |> member "owner_identity_rejected"
           |> to_int);
      (match
         Fs_compat.with_publication_recovery_lane
           ~registry
           ~owner:first_owner
           (fun _ -> ())
       with
       | Ok (Fs_compat.Publication_recovery.Lane_released ()) -> ()
       | Ok (Fs_compat.Publication_recovery.Lane_release_failed _) ->
         Alcotest.fail "publication recovery lane release failed"
       | Error error ->
         Alcotest.fail
           (Fs_compat.publication_recovery_lane_open_error_to_string error));
      let after_demand =
        Fs_compat.Publication_recovery_for_testing.For_testing.snapshot
          private_registry
      in
      Alcotest.(check int)
        "one exact demand creates one owner state"
        1
        (List.length after_demand.owners);
      let other_config =
        Masc.Workspace.default_config
          (Cases.temp_dir "mcp-recovery-other-root-")
      in
      Fun.protect
        ~finally:(fun () -> Cases.cleanup_dir other_config.base_path)
        (fun () ->
          match Mcp_server.set_workspace_config state other_config with
          | Error (Mcp_server.Workspace_masc_root_mismatch _) -> ()
          | Ok () -> Alcotest.fail "different MASC root was accepted"))
;;

let write_empty_file path =
  let channel = open_out_bin path in
  close_out channel
;;

let test_registry_unavailable_keeps_server_state_live () =
  Eio_main.run
  @@ fun env ->
  let base_path = Cases.temp_dir "mcp-recovery-unavailable-" in
  Fun.protect
    ~finally:(fun () -> Cases.cleanup_dir base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      ignore (Masc.Workspace.init config ~agent_name:None);
      write_empty_file
        (Filename.concat
           (Masc.Workspace.masc_root_dir config)
           "fs-publication-recovery");
      Eio.Switch.run
      @@ fun sw ->
      let state = create_runtime env sw ~base_path in
      let publication_recovery_provider =
        Mcp_server.publication_recovery_availability_provider state
      in
      Alcotest.(check string)
        "unrelated workspace state is immediately available"
        config.base_path
        (Mcp_server.workspace_config state).base_path;
      Mcp_server.For_testing.await_publication_recovery_initialization state;
      (match
         Mcp_server.For_testing.publication_recovery_runtime_observation state
       with
       | Mcp_server.For_testing.Runtime_unavailable -> ()
       | Mcp_server.For_testing.Runtime_initializing
       | Mcp_server.For_testing.Runtime_available
       | Mcp_server.For_testing.Runtime_initialization_crashed
       | Mcp_server.For_testing.Runtime_non_runtime ->
         Alcotest.fail "invalid registry layout was not typed unavailable");
      (match publication_recovery_provider () with
       | Keeper_publication_recovery_availability.Registry_unavailable _ -> ()
       | Keeper_publication_recovery_availability.Initializing
       | Keeper_publication_recovery_availability.Available _
       | Keeper_publication_recovery_availability.Initialization_crashed _
       | Keeper_publication_recovery_availability.Non_runtime ->
         Alcotest.fail "live provider collapsed registry-unavailable state");
      Alcotest.(check bool)
        "publication registry is fail-closed"
        true
        (state
         |> Mcp_server.For_testing.publication_recovery_registry
         |> Option.is_none);
      let unavailable_health = health state in
      Alcotest.(check string)
        "unavailable registry is degraded"
        "degraded"
        Yojson.Safe.Util.(unavailable_health |> member "status" |> to_string);
      Alcotest.(check bool)
        "unavailable publication tools do not globally block the runtime"
        false
        Yojson.Safe.Util.
          (unavailable_health |> member "global_blocking" |> to_bool);
      let nested_workspace = Filename.concat base_path "still-live" in
      Unix.mkdir nested_workspace 0o700;
      let updated_config =
        { (Mcp_server.workspace_config state) with
          workspace_path = nested_workspace
        }
      in
      (match Mcp_server.set_workspace_config state updated_config with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail
           (Mcp_server.workspace_switch_error_to_string error));
      Alcotest.(check string)
        "non-publication state mutation remains live"
        nested_workspace
        (Mcp_server.workspace_config state).workspace_path)
;;

let test_lane_store_failure_degrades_and_success_recovers_health () =
  Eio_main.run
  @@ fun env ->
  let base_path = Cases.temp_dir "mcp-recovery-lane-store-health-" in
  Fun.protect
    ~finally:(fun () -> Cases.cleanup_dir base_path)
    (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      let state = create_runtime env sw ~base_path in
      Mcp_server.For_testing.await_publication_recovery_initialization state;
      let registry = require_registry state in
      let private_registry =
        Fs_compat.Publication_recovery_for_testing.private_registry registry
      in
      Fs_compat.Publication_recovery_for_testing.For_testing.await_discovery_settlement
        private_registry;
      let owner = "lane-store-health" in
      let exception_ = Failure "deterministic lane store open failure" in
      let backtrace =
        try raise exception_ with
        | observed ->
          Alcotest.(check bool)
            "exact injected store failure"
            true
            (observed == exception_);
          Printexc.get_raw_backtrace ()
      in
      (match
         Fs_compat.Publication_recovery_for_testing.For_testing
         .record_lane_store_open_failure
           ~registry:private_registry
           ~owner
           ~exception_
           ~backtrace
       with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail
           (Fs_compat.Publication_recovery_for_testing.validation_error_to_string
              error));
      let failed = health state in
      Alcotest.(check string)
        "retryable lane-store failure degrades health"
        "degraded"
        Yojson.Safe.Util.(failed |> member "status" |> to_string);
      Alcotest.(check int)
        "one exact failing owner is aggregated"
        1
        Yojson.Safe.Util.
          (failed
           |> member "row_counts"
           |> member "owner_lane_store_failure"
           |> to_int);
      Alcotest.(check (list string))
        "retryable store reason is explicit without owner/path evidence"
        [ "owner_lane_store_failure" ]
        Yojson.Safe.Util.
          (failed
           |> member "status_reasons"
           |> to_list
           |> List.map to_string);
      (match
         Fs_compat.Publication_recovery_for_testing.For_testing
         .record_lane_store_open_success
           ~registry:private_registry
           ~owner
       with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail
           (Fs_compat.Publication_recovery_for_testing.validation_error_to_string
              error));
      let recovered = health state in
      Alcotest.(check string)
        "successful exact lane open clears degraded health"
        "ok"
        Yojson.Safe.Util.(recovered |> member "status" |> to_string);
      Alcotest.(check int)
        "retryable lane-store aggregate clears"
        0
        Yojson.Safe.Util.
          (recovered
           |> member "row_counts"
           |> member "owner_lane_store_failure"
           |> to_int))
;;

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run
    "mcp_tool_runtime_workspace_path"
    [ ( "masc_start"
      , [ Alcotest.test_case
            "rejects tilde expansion when initial HOME is empty"
            `Quick
            test_masc_start_tilde_rejects_empty_initial_home
        ; Alcotest.test_case
            "checks aggregate health count overflow"
            `Quick
            test_health_aggregate_sum_rejects_overflow
        ; Alcotest.test_case
            "terminalizes owner identity projection failure"
            `Quick
            test_identity_projection_failure_is_terminal_degraded_health
        ; Alcotest.test_case
            "publishes before registry open and keeps owner work demand-driven"
            `Quick
            test_runtime_publishes_before_open_and_discovers_without_owner_fanout
        ; Alcotest.test_case
            "keeps server state live when publication registry is unavailable"
            `Quick
            test_registry_unavailable_keeps_server_state_live
        ; Alcotest.test_case
            "degrades and recovers retryable lane-store health"
            `Quick
            test_lane_store_failure_degrades_and_success_recovers_health
        ] )
    ]
;;
