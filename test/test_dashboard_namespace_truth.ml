(** Dashboard namespace-truth read-model regression tests. *)

let () =
  Masc.Server_startup_state.mark_state_ready
    ~backend:Masc.Server_startup_state.Filesystem_backend
  |> Result.get_ok

module Lib = Masc

open Alcotest

(* Bypass the proactive execution cache warm-up guard so tests get the full
   namespace-truth response instead of the "initializing" short-circuit. *)
let () = Server_dashboard_http.seed_execution_cache_for_test ()

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_namespace_truth" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let with_config_dir dir f =
  let config_dir = Filename.concat (Filename.concat dir ".masc") "config" in
  let keepers_dir = Filename.concat config_dir "keepers" in
  mkdir_p keepers_dir;
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f ~config_dir ~keepers_dir)

let write_keeper_toml ~keepers_dir ~name =
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
sandbox_profile = "local"
instructions = "Dashboard keeper fixture"
|}

let test_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_runtime_default_for_tests dir =
  let path = Filename.concat dir "runtime.toml" in
  write_file path test_runtime_toml;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> failf "Runtime.init_default failed: %s" e

let with_runtime_default_for_tests dir f =
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
      init_runtime_default_for_tests dir;
      f ())

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target

(** Warm the execution cache so namespace-truth skips the "initializing" early
    return. Without this, proactive_first_cycle_pending is true and the handler
    returns a minimal {"status":"initializing"} JSON without namespace/execution/command data. *)
let warm_execution_cache () =
  Server_dashboard_http_cache.mark_cached_surface_success
    Server_dashboard_http.execution_cache
    (`Assoc [("status", `String "ok")])

let expire_execution_warmup () =
  let surface = Server_dashboard_http.execution_cache in
  Server_dashboard_http_cache.invalidate_cached_surface surface;
  let stale_attempt_ts = Unix.gettimeofday () -. 120.0 in
  surface.last_attempt_unix <- Some stale_attempt_ts;
  surface.last_attempt_at <- Some "stale_attempt_for_test"

let create_keeper env sw state name =
  let workspace_scope = Lib.Mcp_server.workspace_scope state in
  let ctx : _ Lib.Keeper_tool_surface.context =
    {
      config = workspace_scope.config;
      agent_name = "tester";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env); net = None;
      publication_recovery_registry =
        (Lib.Mcp_server.workspace_scope_publication_recovery_registry workspace_scope);
    }
  in
  match
    Lib.Keeper_tool_surface.dispatch ctx ~name:"masc_keeper_up"
      ~args:
        (`Assoc
          [
            ("name", `String name);
            ("goal", `String "Dashboard keeper fixture");
            ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
          ])
  with
  | Some result when Tool_result.is_success result -> ()
  | Some result -> fail (Tool_result.message result)
  | None -> fail "missing masc_keeper_up dispatch"

let test_dashboard_namespace_truth_empty_workspace () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      Eio.Switch.run (fun sw ->
        warm_execution_cache ();
        let json =
          Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        check string "cluster default"
          "default"
          (json |> member "workspace" |> member "status" |> member "cluster" |> to_string);
        check int "pending confirms zero"
          0
          (json |> member "operator" |> member "pending_confirm_summary" |> member "total_count" |> to_int);
        check int "configured keepers default to zero"
          0
          (json |> member "workspace" |> member "configured_keepers" |> to_int);
        check int "namespace counts expose total runtimes"
          0
          (json |> member "workspace" |> member "counts" |> member "total_runtimes" |> to_int);
        check string "runtime count authority is namespace truth"
          "namespace_truth_read_model"
          (json |> member "workspace" |> member "runtime_count_authority" |> member "source" |> to_string);
        check bool "runtime counts do not arbitrate through shell"
          false
          (json |> member "workspace" |> member "runtime_count_authority"
           |> member "shell_arbitration_allowed" |> to_bool);
        check string "canonical dashboard surface"
          "/api/v1/dashboard/namespace-truth"
          (json |> member "dashboard_surface" |> to_string);
        check string "read model source"
          "namespace_truth_read_model"
          (json |> member "source" |> to_string);
        check string "retention scope"
          "dashboard_namespace_truth"
          (json |> member "retention" |> member "scope" |> to_string);
        check bool "generated_at_iso present"
          true
          (match json |> member "generated_at_iso" with
          | `String value -> String.length value > 0
          | _ -> false);
        check bool "workspace-truth alias retired"
          false
          (json |> member "dashboard_aliases" |> to_list
           |> List.map to_string
           |> List.mem "/api/v1/dashboard/workspace-truth");
        check bool "readiness status exposed"
          true
          (String.length (json |> member "readiness" |> member "status" |> to_string) > 0);
        check int "readiness exposes four pillars"
          4
          (json |> member "readiness" |> member "pillars" |> to_list |> List.length);
        ignore (json |> member "attention_events" |> to_list);
        check string "focus source"
          "namespace"
          (json |> member "focus" |> member "source" |> to_string);
      ))

let test_dashboard_namespace_truth_execution_fixture () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth?fixture=execution_smoke")
        in
        let open Yojson.Safe.Util in
        check int "fixture blocked operations"
          0
          (json |> member "execution" |> member "summary" |> member "blocked_operations" |> to_int);
        (* top_queue is null when cache has no execution_queue entries *)
        check bool "fixture top queue absent when no blockers"
          true
          (json |> member "execution" |> member "top_queue" = `Null);
      ))

let test_dashboard_namespace_truth_empty_workspace_focus_label () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        let focus_label = json |> member "focus" |> member "label" |> to_string in
        check bool "empty workspace focus mentions no agents"
          true
          (String.length focus_label > 0
           && focus_label <> "지금은 namespace 전체가 비교적 안정적입니다");
      ))

let test_dashboard_namespace_truth_keeper_only_workspace_not_reported_empty () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_config_dir dir @@ fun ~config_dir:_ ~keepers_dir ->
      write_keeper_toml ~keepers_dir ~name:"sangsu";
      with_runtime_default_for_tests dir @@ fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let module Mcp_server = Lib.Mcp_server in
      Eio.Switch.run (fun sw ->
        Lib.Auth.disable_auth dir;
        let state =
          Lib.Mcp_server_eio.create_state_eio
            ~sw
            ~proc_mgr:(Eio.Stdenv.process_mgr env)
            ~fs:(Eio.Stdenv.fs env)
            ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~net:(Eio.Stdenv.net env)
            ~base_path:dir
        in
        let config = Mcp_server.workspace_config state in
        ignore (Lib.Workspace.init config ~agent_name:None);
        ignore
          (Lib.Workspace.bind_session config
             ~agent_name:"keeper-sangsu-agent"
             ~agent_type_override:(Some "keeper")
             ~capabilities:["keeper"]
             ());
        Fun.protect
          ~finally:(fun () ->
            Lib.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw state "sangsu";
            warm_execution_cache ();
            let json =
              Server_dashboard_http.dashboard_namespace_truth_http_json
                ~state ~sw ~clock:(Eio.Stdenv.clock env)
                (request "/api/v1/dashboard/namespace-truth")
            in
            let open Yojson.Safe.Util in
            let focus_label = json |> member "focus" |> member "label" |> to_string in
            check int "keeper-only workspace counts general agents as zero"
              0
              (json |> member "workspace" |> member "counts" |> member "agents" |> to_int);
            check int "keeper-only workspace still counts keeper meta"
              1
              (json |> member "workspace" |> member "counts" |> member "keepers" |> to_int);
            check bool "keeper-only workspace does not report empty workspace focus"
              false
              (String.equal focus_label
                 "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다."))))

let test_dashboard_namespace_truth_mixed_runtime_counts () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_config_dir dir @@ fun ~config_dir:_ ~keepers_dir ->
      write_keeper_toml ~keepers_dir ~name:"sangsu";
      with_runtime_default_for_tests dir @@ fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let module Mcp_server = Lib.Mcp_server in
      Eio.Switch.run (fun sw ->
        Lib.Auth.disable_auth dir;
        let state =
          Lib.Mcp_server_eio.create_state_eio
            ~sw
            ~proc_mgr:(Eio.Stdenv.process_mgr env)
            ~fs:(Eio.Stdenv.fs env)
            ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~net:(Eio.Stdenv.net env)
            ~base_path:dir
        in
        let config = Mcp_server.workspace_config state in
        ignore (Lib.Workspace.init config ~agent_name:None);
        ignore
          (Lib.Workspace.bind_session config
             ~agent_name:"codex-test-agent"
             ~agent_type_override:(Some "codex")
             ~capabilities:["typescript"]
             ());
        ignore
          (Lib.Workspace.bind_session config
             ~agent_name:"keeper-sangsu-agent"
             ~agent_type_override:(Some "keeper")
             ~capabilities:["keeper"]
             ());
        Fun.protect
          ~finally:(fun () ->
            Lib.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw state "sangsu";
            warm_execution_cache ();
            let json =
              Server_dashboard_http.dashboard_namespace_truth_http_json
                ~state ~sw ~clock:(Eio.Stdenv.clock env)
                (request "/api/v1/dashboard/namespace-truth")
            in
            let open Yojson.Safe.Util in
            let focus_label = json |> member "focus" |> member "label" |> to_string in
            check int "mixed workspace counts one general agent"
              1
              (json |> member "workspace" |> member "counts" |> member "agents" |> to_int);
            check int "mixed workspace counts one keeper"
              1
              (json |> member "workspace" |> member "counts" |> member "keepers" |> to_int);
            check bool "mixed workspace avoids empty runtime fallback"
              false
              (String.equal focus_label
                 "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다."))))

let test_operator_pending_confirm_shape_matches_namespace_truth () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        let operator = json |> member "operator" in
        let expected_keys = ["pending_confirm_summary"; "provenance"] in
        List.iter (fun key ->
          let value = operator |> member key in
          check bool (Printf.sprintf "operator.%s present" key)
            true
            (value <> `Null)
        ) expected_keys;
      ))

let test_namespace_truth_cached_snapshot_matches_http_projection_blocks () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      warm_execution_cache ();
      Server_dashboard_http.warm_shell_cache state;
      Eio.Switch.run (fun sw ->
        let http_json =
          Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let cached_snapshot =
          match Server_dashboard_http.namespace_truth_snapshot_from_caches state with
          | Some json -> json
          | None -> fail "expected cached namespace-truth snapshot"
        in
        let open Yojson.Safe.Util in
        let compare_block key =
          check string (Printf.sprintf "%s block matches cached snapshot" key)
            (Yojson.Safe.to_string (http_json |> member key))
            (Yojson.Safe.to_string (cached_snapshot |> member key))
        in
        List.iter compare_block
          [ "namespace"; "execution"; "command"; "operator"; "focus" ];
      ))

let test_dashboard_namespace_truth_warm_request_uses_stale_shell () =
  let dir = test_dir () in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Server_dashboard_http.last_good_shell original_last_good;
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      let config = Lib.Mcp_server.workspace_config state in
      warm_execution_cache ();
      let cached_shell =
        `Assoc
          [
            ( "status",
              `Assoc
                [
                  ("project", `String "ready");
                  ("generated_at", `String "2026-05-18T00:00:00Z");
                ] );
            ( "counts",
              `Assoc
                [
                  ("agents", `Int 7);
                  ("tasks", `Int 0);
                  ("keepers", `Int 2);
                  ("total_runtimes", `Int 9);
                ] );
            ( "paths",
              `Assoc [ ("effective_base_path", `String config.base_path) ] );
            ("configured_keepers", `Int 2);
          ]
      in
      Atomic.set Server_dashboard_http.last_good_shell cached_shell;
      Atomic.set Server_dashboard_http.shell_warmed true;
      Eio.Switch.run (fun sw ->
        let json =
          Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        check int "warm request uses cached shell counts"
          7
          (json |> member "workspace" |> member "counts" |> member "agents" |> to_int);
        check string "warm request reports stale-while-revalidate"
          "stale_while_revalidate"
          (json |> member "projection_diagnostics" |> member "cache_mode" |> to_string);
        check string "warm request shell source is last-good"
          "last_good_shell"
          (json |> member "projection_diagnostics" |> member "shell_source" |> to_string);
        check string "runtime authority documents stale shell as fallback"
          "shell_last_good_only_when_namespace_unavailable"
          (json |> member "workspace" |> member "runtime_count_authority"
           |> member "fallback_policy" |> to_string);
        check int "authority reports configured/live keeper delta"
          0
          (json |> member "workspace" |> member "runtime_count_authority"
           |> member "configured_minus_live_keepers" |> to_int)
      ))

let test_dashboard_namespace_truth_cold_cache_falls_back_to_partial_truth () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      warm_execution_cache ();
      cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      expire_execution_warmup ();
      Eio.Switch.run (fun sw ->
        let json =
          Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        check bool "expired warmup skips top-level initializing payload"
          true
          (json |> member "status" = `Null);
        check bool "namespace block present"
          true
          (json |> member "workspace" <> `Null);
        check int "execution summary falls back to zero operations"
          0
          (json |> member "execution" |> member "summary" |> member "active_operations" |> to_int);
        check string "namespace truth diagnostics keep execution cache state"
          "initializing"
          (json |> member "projection_diagnostics" |> member "execution_cache_state" |> to_string);
      ))

let test_last_good_shell_fallback_preserves_counts () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      ignore (Lib.Workspace.init (Lib.Mcp_server.workspace_config state) ~agent_name:None);
      warm_execution_cache ();
      (* Warm the shell cache so last_good_shell gets populated. *)
      Server_dashboard_http.warm_shell_cache state;
      let last_good = Atomic.get Server_dashboard_http.last_good_shell in
      check bool "last good shell is non-empty after warm"
        true
        (last_good <> `Assoc []);
      (* Now verify that last_good_shell has namespace counts. *)
      let open Yojson.Safe.Util in
      let counts = last_good |> member "counts" in
      check bool "last good shell contains counts block"
        true
        (counts <> `Null);
      (* Verify namespace-truth snapshot_from_caches uses the stale shell data
         even when the warmed flag is false (cold path, simulating timeout). *)
      Atomic.set Server_dashboard_http.shell_warmed false;
      let snapshot =
        match Server_dashboard_http.namespace_truth_snapshot_from_caches state with
        | Some json -> json
        | None -> fail "expected cached namespace-truth snapshot"
      in
      let ns_counts = snapshot |> member "workspace" |> member "counts" in
      (* Shell was warmed once then reset; snapshot_from_caches should still
         produce a valid namespace block via the last_good_shell fallback. *)
      check bool "namespace counts block present in fallback snapshot"
        true
        (ns_counts <> `Null);
      (* Restore warmed state for subsequent tests. *)
      Atomic.set Server_dashboard_http.shell_warmed true)

let test_namespace_truth_snapshot_hash_ignores_generated_at () =
  Fun.protect
    ~finally:(fun () ->
      Server_dashboard_http.last_namespace_truth_snapshot_hash := None)
    (fun () ->
      Server_dashboard_http.last_namespace_truth_snapshot_hash := None;
      Eio_main.run @@ fun _env ->
      let snapshot ~generated_at ~active_sessions =
        `Assoc
          [
            ("generated_at", `String generated_at);
            ("generated_at_iso", `String generated_at);
            ( "namespace",
              `Assoc [ ("status", `String "ready"); ("counts", `Assoc [("agents", `Int 1)]) ]
            );
            ( "execution",
              `Assoc
                [
                  ( "summary",
                    `Assoc [("active_sessions", `Int active_sessions)] );
                ] );
          ]
      in
      check bool "first snapshot broadcasts"
        true
        (Server_dashboard_http.should_broadcast_namespace_truth_snapshot
           (snapshot ~generated_at:"2026-04-09T00:00:00Z" ~active_sessions:1));
      check bool "generated_at-only changes stay deduped"
        false
        (Server_dashboard_http.should_broadcast_namespace_truth_snapshot
           (snapshot ~generated_at:"2026-04-09T00:00:05Z" ~active_sessions:1));
      check bool "semantic changes still broadcast"
        true
        (Server_dashboard_http.should_broadcast_namespace_truth_snapshot
           (snapshot ~generated_at:"2026-04-09T00:00:10Z" ~active_sessions:2)))

let test_namespace_truth_snapshot_hash_avoids_string_collision () =
  (* Length-prefixing string fields must keep distinct payloads distinct.
     The pre-fix hash would collide on these two list-of-string shapes. *)
  Fun.protect
    ~finally:(fun () ->
      Server_dashboard_http.last_namespace_truth_snapshot_hash := None)
    (fun () ->
      Server_dashboard_http.last_namespace_truth_snapshot_hash := None;
      Eio_main.run @@ fun _env ->
      let payload fields = `Assoc [("items", `List fields)] in
      let a = payload [ `String "aS"; `String "b" ] in
      let b = payload [ `String "a"; `String "Sb" ] in
      check bool "first payload broadcasts" true
        (Server_dashboard_http.should_broadcast_namespace_truth_snapshot a);
      check bool "different string concatenation still broadcasts" true
        (Server_dashboard_http.should_broadcast_namespace_truth_snapshot b))

let () =
  Alcotest.run "Dashboard Namespace Truth"
    [
      ( "read_model",
        [
          test_case "empty workspace shape" `Quick test_dashboard_namespace_truth_empty_workspace;
          test_case "execution fixture surfaces top queue" `Quick test_dashboard_namespace_truth_execution_fixture;
          test_case "empty workspace focus label reflects no agents" `Quick test_dashboard_namespace_truth_empty_workspace_focus_label;
          test_case "keeper-only workspace does not look empty" `Quick
            test_dashboard_namespace_truth_keeper_only_workspace_not_reported_empty;
          test_case "mixed runtimes keep counts aligned" `Quick
            test_dashboard_namespace_truth_mixed_runtime_counts;
          test_case "operator pending-confirm shape matches namespace-truth" `Quick
            test_operator_pending_confirm_shape_matches_namespace_truth;
          test_case "cached snapshot matches HTTP projection blocks" `Quick
            test_namespace_truth_cached_snapshot_matches_http_projection_blocks;
          test_case "warm request uses stale shell while refreshing" `Quick
            test_dashboard_namespace_truth_warm_request_uses_stale_shell;
          test_case "expired execution warmup falls back to partial truth" `Quick
            test_dashboard_namespace_truth_cold_cache_falls_back_to_partial_truth;
          test_case "last-good shell fallback preserves namespace counts" `Quick
            test_last_good_shell_fallback_preserves_counts;
          test_case "snapshot hash ignores generated_at churn" `Quick
            test_namespace_truth_snapshot_hash_ignores_generated_at;
          test_case "snapshot hash avoids string concatenation collisions" `Quick
            test_namespace_truth_snapshot_hash_avoids_string_collision;
        ] );
    ]
