module Cases = Test_mcp_tool_matrix_cases
module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server

let contains_substring text fragment =
  let text_len = String.length text in
  let fragment_len = String.length fragment in
  let rec loop index =
    if fragment_len = 0 then true
    else if index + fragment_len > text_len then false
    else if String.sub text index fragment_len = fragment then true
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

let require_registry (scope : Mcp_server.workspace_scope) =
  match Mcp_server.workspace_scope_publication_recovery_registry scope with
  | Some registry -> registry
  | None -> Alcotest.fail "Eio workspace scope omitted its recovery registry"
;;

let require_activation_report (scope : Mcp_server.workspace_scope) =
  match Mcp_server.workspace_scope_publication_recovery_report scope with
  | Some report -> report
  | None -> Alcotest.fail "Eio workspace scope omitted its recovery report"
;;

let require_uuid value =
  match Uuidm.of_string value with
  | Some operation_id -> operation_id
  | None -> Alcotest.failf "invalid fixture UUID %S" value
;;

let seed_prepared_recovery
      ~fs
      ~base_path
      ~owner
      ~operation_id
  =
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
      ~registry_root:Eio.Path.(fs / Masc.Workspace.masc_root_dir config)
  with
  | Error error ->
    Alcotest.fail
      (Fs_compat.publication_recovery_registry_error_to_string error)
  | Ok registry ->
    (match
       Fs_compat.Capability_write_for_testing.seed_prepared_publication_recovery
         ~registry
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
       Alcotest.fail
         (Fs_compat.publication_recovery_fixture_error_to_string error))
;;

let test_workspace_switch_reuses_process_recovery_runtime () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let first_base = Cases.temp_dir "mcp-scope-first-" in
  let second_base = Cases.temp_dir "mcp-scope-second-" in
  let nested_workspace = Filename.concat first_base "nested-workspace" in
  Fun.protect
    ~finally:(fun () ->
      Cases.cleanup_dir first_base;
      Cases.cleanup_dir second_base)
    (fun () ->
      Unix.mkdir nested_workspace 0o700;
      let fs = Eio.Stdenv.fs env in
      Fs_compat.set_fs fs;
      let state =
        Mcp_eio.create_state_eio
          ~sw
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~fs
          ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~net:(Eio.Stdenv.net env)
          ~base_path:first_base
      in
      let first_scope = Mcp_server.workspace_scope state in
      let first_registry = require_registry first_scope in
      let first_report = require_activation_report first_scope in
      let same_root_config =
        { first_scope.config with workspace_path = nested_workspace }
      in
      (match Mcp_server.set_workspace_config state same_root_config with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail
           (Mcp_server.workspace_switch_error_to_string error));
      let nested_scope = Mcp_server.workspace_scope state in
      Alcotest.(check string)
        "workspace projection changed"
        nested_workspace
        nested_scope.config.workspace_path;
      Alcotest.(check bool)
        "same MASC root reuses the exact process registry"
        true
        (require_registry nested_scope == first_registry);
      Alcotest.(check bool)
        "same MASC root reuses the exact activation report"
        true
        (require_activation_report nested_scope == first_report);
      let public_health =
        Mcp_server.publication_recovery_activation_report_to_health_yojson
          first_report
      in
      Alcotest.(check string)
        "empty activation is healthy"
        "ok"
        Yojson.Safe.Util.(public_health |> member "status" |> to_string);
      Alcotest.(check bool)
        "empty activation needs no operator"
        false
        Yojson.Safe.Util.
          (public_health |> member "operator_action_required" |> to_bool);
      Alcotest.(check int)
        "empty activation has no rows"
        0
        Yojson.Safe.Util.(public_health |> member "row_count" |> to_int);
      let second_config = Masc.Workspace.default_config second_base in
      (match Mcp_server.set_workspace_config state second_config with
       | Error
           (Mcp_server.Workspace_masc_root_mismatch
              { runtime_root; requested_root }) ->
         Alcotest.(check string)
           "runtime root is exact"
           (Masc.Workspace.masc_root_dir first_scope.config)
           runtime_root;
         Alcotest.(check string)
           "requested root is exact"
           (Masc.Workspace.masc_root_dir second_config)
           requested_root
       | Ok () -> Alcotest.fail "different MASC root was accepted");
      Alcotest.(check bool)
        "root mismatch leaves the prior scope object unchanged"
        true
        (Mcp_server.workspace_scope state == nested_scope))
;;

let test_runtime_start_tracks_async_owner_activation () =
  Eio_main.run
  @@ fun env ->
  let base_path = Cases.temp_dir "mcp-recovery-activation-" in
  Fun.protect
    ~finally:(fun () -> Cases.cleanup_dir base_path)
    (fun () ->
      let fs = Eio.Stdenv.fs env in
      Fs_compat.set_fs fs;
      let valid_owner = "startup-valid-owner" in
      let rejected_owner = "startup owner with spaces" in
      seed_prepared_recovery
        ~fs
        ~base_path
        ~owner:valid_owner
        ~operation_id:
          (require_uuid "66666666-6666-4666-8666-666666666666");
      seed_prepared_recovery
        ~fs
        ~base_path
        ~owner:rejected_owner
        ~operation_id:
          (require_uuid "77777777-7777-4777-8777-777777777777");
      Eio.Switch.run
      @@ fun sw ->
      let state =
        Mcp_eio.create_state_eio
          ~sw
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~fs
          ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~net:(Eio.Stdenv.net env)
          ~base_path
      in
      let scope = Mcp_server.workspace_scope state in
      let report = require_activation_report scope in
      let activation_rows =
        Mcp_server.For_testing.await_publication_recovery_activation report
      in
      let valid_ready, rejected_explicit, unsettled =
        List.fold_left
          (fun (valid_ready, rejected_explicit, unsettled) -> function
             | Mcp_server.Publication_recovery_owner_report owner_report ->
               let is_valid_owner =
                 String.equal
                   valid_owner
                   (Fs_compat.publication_recovery_reconciliation_report_owner
                      owner_report)
               in
               ( valid_ready
                 || is_valid_owner
                    && Fs_compat.publication_recovery_reconciliation_report_is_ready
                         owner_report
               , rejected_explicit
               , unsettled )
             | Mcp_server.Publication_recovery_owner_identity_rejected
                 { owner; _ } ->
               valid_ready,
               rejected_explicit || String.equal rejected_owner owner,
               unsettled
             | Mcp_server.Publication_recovery_owner_pending _
             | Mcp_server.Publication_recovery_owner_running _ ->
               valid_ready, rejected_explicit, true
             | Mcp_server.Publication_recovery_owner_reconciliation_failed _
             | Mcp_server.Publication_recovery_owner_reconciliation_crashed _
             | Mcp_server.Publication_recovery_owner_cancelled _
             | Mcp_server.Publication_recovery_owner_inventory_issue _ ->
               valid_ready, rejected_explicit, unsettled)
          (false, false, false)
          activation_rows
      in
      Alcotest.(check bool) "valid owner reconciled" true valid_ready;
      Alcotest.(check bool)
        "MASC owner rejection retained"
        true
        rejected_explicit;
      Alcotest.(check bool)
        "exact activation await leaves no pending row"
        false
        unsettled;
      let public_health =
        Mcp_server.publication_recovery_activation_report_to_health_yojson
          report
      in
      Alcotest.(check string)
        "rejected activation blocks public health"
        "blocked"
        Yojson.Safe.Util.(public_health |> member "status" |> to_string);
      Alcotest.(check bool)
        "rejected activation requires operator action"
        true
        Yojson.Safe.Util.
          (public_health |> member "operator_action_required" |> to_bool);
      Alcotest.(check int)
        "public health aggregates the rejected owner"
        1
        Yojson.Safe.Util.
          (public_health
           |> member "row_counts"
           |> member "owner_identity_rejected"
           |> to_int);
      Alcotest.(check bool)
        "public health omits exact activation rows"
        true
        Yojson.Safe.Util.(public_health |> member "rows" = `Null);
      let registry = require_registry scope in
      (match
         Fs_compat.with_publication_recovery_lane
           ~registry
           ~owner:valid_owner
           (fun _ -> ())
       with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail
           (Fs_compat.publication_recovery_lane_open_error_to_string error));
      (match
         Fs_compat.with_publication_recovery_lane
           ~registry
           ~owner:rejected_owner
           (fun _ -> ())
       with
       | Error error ->
         (match
            Fs_compat.publication_recovery_lane_reconciliation_error error
          with
          | Some
              (Fs_compat.Publication_recovery_reconciliation_blocked
                (Fs_compat.Publication_recovery_owner_activation_rejected_block
                  owner)) ->
            Alcotest.(check string)
              "rejected owner remains fenced"
              rejected_owner
              (Fs_compat.publication_recovery_owner_to_string owner)
          | Some
              ( Fs_compat.Publication_recovery_reconciliation_required _
              | Fs_compat.Publication_recovery_reconciliation_in_progress _
              | Fs_compat.Publication_recovery_reconciliation_blocked
                  ( Fs_compat.Publication_recovery_owner_inventory_block _
                  | Fs_compat.Publication_recovery_owner_report_block _
                  | Fs_compat.Publication_recovery_owner_crash_block _
                  | Fs_compat.Publication_recovery_owner_cancelled_block _ ) )
          | None ->
            Alcotest.fail
              (Fs_compat.publication_recovery_lane_open_error_to_string error))
       | Ok () -> Alcotest.fail "MASC-rejected owner was admitted");
      match
        Fs_compat.with_publication_recovery_lane
          ~registry
          ~owner:"unrelated-owner"
          (fun _ -> ())
      with
      | Ok () -> ()
      | Error error ->
        Alcotest.fail
          (Fs_compat.publication_recovery_lane_open_error_to_string error))
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
            "reuses one recovery runtime and rejects another MASC root"
            `Quick
            test_workspace_switch_reuses_process_recovery_runtime
        ; Alcotest.test_case
            "tracks async owner activation and fences rejected owners"
            `Quick
            test_runtime_start_tracks_async_owner_activation
        ] )
    ]
;;
