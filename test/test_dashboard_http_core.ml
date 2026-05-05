module Types = Masc_domain

module Lib = Masc_mcp
module Auth = Masc_mcp.Auth

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_http_core" "" in
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

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target

let request_with_headers target headers =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET target

let with_test_env f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_env "MASC_STORAGE_TYPE" "filesystem" @@ fun () ->
      with_env "MASC_POSTGRES_URL" "" @@ fun () ->
      with_env "DATABASE_URL" "" @@ fun () ->
      with_env "SUPABASE_DB_URL" "" @@ fun () ->
      with_env "SB_PG_URL" "" @@ fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Coord_utils.default_config dir in
      Eio.Switch.run @@ fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () -> f ~env ~sw ~config))

let test_run_dashboard_compute_without_pool_stays_in_current_domain () =
  with_test_env @@ fun ~env ~sw ~config ->
  let caller_domain = Domain.self () in
  let result_domain =
    Lib.Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~config
      (fun ~config:_ ~sw:_ -> Domain.self ())
  in
  check bool "no pool keeps compute on caller domain" true
    (result_domain = caller_domain)

let test_run_dashboard_compute_with_pool_uses_executor_domain () =
  (* All backends offload to the executor pool when available.
     FileSystem key_index is domain-safe via Stdlib.Mutex; Eio.Mutex
     is domain-safe via Stdlib.Mutex internally.  Offloading isolates
     dashboard compute from keeper turns on the main domain. *)
  with_test_env @@ fun ~env ~sw ~config ->
  let exec_pool =
    Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
  in
  Lib.Server_dashboard_http_core.set_executor_pool exec_pool;
  let caller_domain = Domain.self () in
  let result_domain =
    Lib.Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~config
      (fun ~config:_ ~sw:_ -> Domain.self ())
  in
  check bool "non-PG backend offloads to executor pool domain" true
    (result_domain <> caller_domain)

let test_dashboard_shell_http_json_includes_paths () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let json = Lib.Server_dashboard_http_core.dashboard_shell_http_json config in
  let open Yojson.Safe.Util in
  let fields =
    match json with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "dashboard shell payload must be an object"
  in
  let paths =
    match List.assoc_opt "paths" fields with
    | Some value -> value
    | None -> Alcotest.fail "paths key missing from dashboard shell payload"
  in
  let config_resolution =
    List.assoc_opt "config_resolution" fields
    |> Option.value ~default:`Null
  in
  let runtime_resolution =
    List.assoc_opt "runtime_resolution" fields
    |> Option.value ~default:`Null
  in
  let effective_base_path = paths |> member "effective_base_path" |> to_string in
  let effective_masc_root = paths |> member "effective_masc_root" |> to_string in
  let expected_masc_root = Unix.realpath (Filename.concat config.base_path Common.masc_dirname) in
  check bool "paths present" true
    (match paths with `Assoc _ -> true | _ -> false);
  check bool "paths key present" true
    (List.mem_assoc "paths" fields);
  check bool "config_resolution key present" true
    (List.mem_assoc "config_resolution" fields);
  check bool "runtime_resolution key present" true
    (List.mem_assoc "runtime_resolution" fields);
  check string "effective_base_path matches config" (Unix.realpath config.base_path)
    effective_base_path;
  check string "effective_masc_root matches config" expected_masc_root
    effective_masc_root;
  check bool "paths include cwd" true
    (match paths |> member "cwd" with
     | `String value -> String.length value > 0
     | _ -> false);
  check bool "paths include strict_mode_requested bool" true
    (match paths |> member "strict_mode_requested" with
     | `Bool _ -> true
     | _ -> false);
  check bool "paths include startup_rejected bool" true
    (match paths |> member "startup_rejected" with
     | `Bool _ -> true
     | _ -> false);
  check bool "shell config resolution is object or null" true
    (match config_resolution with
     | `Assoc _ | `Null -> true
     | _ -> false);
  check bool "shell config root path surfaced when available" true
    (match config_resolution with
     | `Null -> true
     | _ -> (
         match config_resolution |> member "config_root" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false));
  check bool "shell cascade authoring path surfaced when available" true
    (match config_resolution with
     | `Null -> true
     | _ -> (
         match config_resolution |> member "cascade_authoring" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false));
  check bool "shell runtime resolution is object or null" true
    (match runtime_resolution with
     | `Assoc _ | `Null -> true
     | _ -> false);
  check bool "shell runtime data root path surfaced when available" true
    (match runtime_resolution with
     | `Null -> true
     | _ -> (
         match runtime_resolution |> member "data_root" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false));
  check bool "shell runtime warnings surfaced as list when available" true
    (match runtime_resolution with
     | `Null -> true
     | _ -> (
         match runtime_resolution |> member "warnings" with
         | `List _ -> true
         | _ -> false))

let test_dashboard_shell_http_json_prefers_preserved_base_path_input () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let raw_input = Filename.concat config.base_path Common.masc_dirname in
  with_env "MASC_BASE_PATH_INPUT" raw_input @@ fun () ->
  with_env "MASC_BASE_PATH" config.base_path @@ fun () ->
  let json = Lib.Server_dashboard_http_core.dashboard_shell_http_json config in
  let open Yojson.Safe.Util in
  check string "runtime base_path preserves raw input" raw_input
    (json |> member "runtime_resolution" |> member "base_path" |> member "path"
   |> to_string)

let test_dashboard_shell_http_json_uses_bootstrap_payload_while_prewarming () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Lib.Server_dashboard_http._shell_warmed in
  let original_warming = Atomic.get Lib.Server_dashboard_http._shell_warming in
  let original_last_good = Atomic.get Lib.Server_dashboard_http._last_good_shell in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Lib.Server_dashboard_http._shell_warmed original_warmed;
      Atomic.set Lib.Server_dashboard_http._shell_warming original_warming;
      Atomic.set Lib.Server_dashboard_http._last_good_shell original_last_good)
    (fun () ->
      Atomic.set Lib.Server_dashboard_http._shell_warmed false;
      Atomic.set Lib.Server_dashboard_http._shell_warming true;
      Atomic.set Lib.Server_dashboard_http._last_good_shell (`Assoc []);
      let json =
        Lib.Server_dashboard_http_core.dashboard_shell_http_json
          ~request:(request "/api/v1/dashboard/shell")
          config
      in
      let open Yojson.Safe.Util in
      check string "bootstrap status project" "initializing"
        (json |> member "status" |> member "project" |> to_string);
      check int "bootstrap zero agents" 0
        (json |> member "counts" |> member "agents" |> to_int);
      check string "bootstrap cache state" "initializing"
        (json |> member "projection_diagnostics" |> member "cache_state"
        |> to_string))

let test_dashboard_shell_http_json_prefers_last_good_while_prewarming () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Lib.Server_dashboard_http._shell_warmed in
  let original_warming = Atomic.get Lib.Server_dashboard_http._shell_warming in
  let original_last_good = Atomic.get Lib.Server_dashboard_http._last_good_shell in
  let last_good =
    `Assoc
      [
        ("generated_at", `String "2026-04-17T00:00:00Z");
        ("status", `Assoc [("project", `String "warm-room")]);
        ("counts", `Assoc [("agents", `Int 7); ("tasks", `Int 11); ("keepers", `Int 3)]);
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Lib.Server_dashboard_http._shell_warmed original_warmed;
      Atomic.set Lib.Server_dashboard_http._shell_warming original_warming;
      Atomic.set Lib.Server_dashboard_http._last_good_shell original_last_good)
    (fun () ->
      Atomic.set Lib.Server_dashboard_http._shell_warmed false;
      Atomic.set Lib.Server_dashboard_http._shell_warming true;
      Atomic.set Lib.Server_dashboard_http._last_good_shell last_good;
      let json =
        Lib.Server_dashboard_http_core.dashboard_shell_http_json
          ~request:(request "/api/v1/dashboard/shell")
          config
      in
      let open Yojson.Safe.Util in
      check string "last-good project reused" "warm-room"
        (json |> member "status" |> member "project" |> to_string);
      check int "last-good counts reused" 7
        (json |> member "counts" |> member "agents" |> to_int))

let test_dashboard_planning_http_json_includes_coordination_fsm () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
  let json = Lib.Server_dashboard_http.dashboard_planning_http_json ~config in
  let open Yojson.Safe.Util in
  let coordination = json |> member "coordination_fsm" in
  check string "mode" "advisory" (coordination |> member "mode" |> to_string);
  check bool "summary present" true
    (match coordination |> member "summary" with
     | `Assoc _ -> true
     | _ -> false);
  check bool "summary evidence present" true
    (match coordination |> member "summary" |> member "evidence" with
     | `Int _ -> true
     | _ -> false);
  check bool "violations present" true
    (match coordination |> member "violations" with
     | `List _ -> true
     | _ -> false);
  check bool "evidence present" true
    (match coordination |> member "evidence" with
     | `List _ -> true
     | _ -> false)

let credential_archived_starvation_total () =
  int_of_float
    (Lib.Prometheus.metric_total
       Lib.Prometheus.metric_config_credential_archived_starvation)

let record_test_credential_archive () =
  let keeper_name =
    Printf.sprintf "goal-loop-monitor-%d-%d"
      (Unix.getpid ())
      (Random.bits ())
  in
  Lib.Prometheus.inc_counter
    Lib.Prometheus.metric_config_credential_archived_starvation
    ~labels:[("keeper_name", keeper_name)]
    ()

let test_credential_monitoring_json_surfaces_archive_counter () =
  let before = credential_archived_starvation_total () in
  record_test_credential_archive ();
  let json = Lib.Dashboard_http_monitoring.credential_monitoring_json () in
  let open Yojson.Safe.Util in
  check int "credential archive total"
    (before + 1)
    (json |> member "credential_archived_starvation_total" |> to_int);
  check string "metric name"
    Lib.Prometheus.metric_config_credential_archived_starvation
    (json |> member "metric_name" |> to_string);
  check string "alert level" "bad"
    (json |> member "alert_level" |> to_string);
  check bool "needs attention" true
    (json |> member "needs_attention" |> to_bool)

let test_dashboard_batch_json_includes_credential_monitoring () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
  let before = credential_archived_starvation_total () in
  record_test_credential_archive ();
  let json = Lib.Server_dashboard_http_core.dashboard_batch_json config in
  let open Yojson.Safe.Util in
  let credentials =
    json |> member "status" |> member "monitoring" |> member "credentials"
  in
  check int "batch credential archive total"
    (before + 1)
    (credentials |> member "credential_archived_starvation_total" |> to_int);
  check string "batch credential alert" "bad"
    (credentials |> member "alert_level" |> to_string)

let test_dashboard_shell_auth_json_canonicalizes_token_owner () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  match Auth.create_token config.base_path ~agent_name:"codex" ~role:Masc_domain.Worker with
  | Error e -> fail (Masc_domain.masc_error_to_string e)
  | Ok (raw_token, _) ->
      let json =
        Lib.Server_dashboard_http_core.dashboard_shell_http_json
          ~request:
            (request_with_headers "/api/v1/dashboard/shell"
               [
                 ("authorization", "Bearer " ^ raw_token);
                 ("x-masc-agent", "dashboard");
               ])
          config
      in
      let open Yojson.Safe.Util in
      let auth = json |> member "auth" in
      check bool "token_valid true" true (auth |> member "token_valid" |> to_bool);
      check string "requested actor surfaced" "dashboard"
        (auth |> member "requested_agent" |> to_string);
      check string "token owner surfaced" "codex"
        (auth |> member "token_agent" |> to_string);
      check string "effective actor canonicalized to token owner" "codex"
        (auth |> member "effective_agent" |> to_string);
      check bool "auth error cleared after canonicalization" true
        (match auth |> member "auth_error_code" with `Null -> true | _ -> false);
      check bool "keeper message allowed for canonicalized worker" true
        (auth |> member "can_keeper_msg" |> to_bool)

let test_dashboard_shell_auth_json_reports_missing_token () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  let json =
    Lib.Server_dashboard_http_core.dashboard_shell_http_json
      ~request:
        (request_with_headers "/api/v1/dashboard/shell"
           [
             ("origin", "http://localhost:5173");
             ("host", "localhost:5173");
           ])
      config
  in
  let open Yojson.Safe.Util in
  let auth = json |> member "auth" in
  check bool "token_valid false" false (auth |> member "token_valid" |> to_bool);
  check string "missing token code surfaced" "missing_token"
    (auth |> member "auth_error_code" |> to_string)

let test_execution_actor_for_request_canonicalizes_token_owner () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  match Auth.create_token config.base_path ~agent_name:"codex" ~role:Masc_domain.Worker with
  | Error e -> fail (Masc_domain.masc_error_to_string e)
  | Ok (raw_token, _) ->
      let actor =
        Lib.Server_dashboard_http_execution_surfaces.execution_actor_for_request
          ~base_path:config.base_path
          (request_with_headers "/api/v1/dashboard/execution"
             [
               ("authorization", "Bearer " ^ raw_token);
               ("x-masc-agent", "dashboard");
             ])
      in
      check (option string) "execution actor canonicalized to token owner"
        (Some "codex") actor

let test_verifier_of_request_canonicalizes_token_owner () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  match Auth.create_token config.base_path ~agent_name:"codex" ~role:Masc_domain.Worker with
  | Error e -> fail (Masc_domain.masc_error_to_string e)
  | Ok (raw_token, _) ->
      let verifier =
        Lib.Server_routes_http_routes_verification.verifier_of_request
          ~base_path:config.base_path
          (request_with_headers "/api/v1/verification/resolve"
             [
               ("authorization", "Bearer " ^ raw_token);
               ("x-masc-agent", "dashboard");
             ])
      in
      check string "verification verifier canonicalized to token owner"
        "operator:codex" verifier

let () =
  run "dashboard_http_core"
    [
      ( "executor_pool",
        [
          test_case "no pool stays on caller domain" `Quick
            test_run_dashboard_compute_without_pool_stays_in_current_domain;
          test_case "pool uses executor domain" `Quick
            test_run_dashboard_compute_with_pool_uses_executor_domain;
          test_case "shell payload includes paths diagnostics" `Quick
            test_dashboard_shell_http_json_includes_paths;
          test_case "shell runtime base_path prefers preserved input" `Quick
            test_dashboard_shell_http_json_prefers_preserved_base_path_input;
          test_case "shell bootstrap payload while prewarming" `Quick
            test_dashboard_shell_http_json_uses_bootstrap_payload_while_prewarming;
          test_case "shell reuses last good payload while prewarming" `Quick
            test_dashboard_shell_http_json_prefers_last_good_while_prewarming;
          test_case "planning payload includes coordination FSM" `Quick
            test_dashboard_planning_http_json_includes_coordination_fsm;
          test_case "credential monitoring surfaces archive counter" `Quick
            test_credential_monitoring_json_surfaces_archive_counter;
          test_case "batch payload includes credential monitoring" `Quick
            test_dashboard_batch_json_includes_credential_monitoring;
          test_case "shell auth canonicalizes token owner" `Quick
            test_dashboard_shell_auth_json_canonicalizes_token_owner;
          test_case "shell auth reports missing token" `Quick
            test_dashboard_shell_auth_json_reports_missing_token;
          test_case "execution actor canonicalizes token owner" `Quick
            test_execution_actor_for_request_canonicalizes_token_owner;
          test_case "verification verifier canonicalizes token owner" `Quick
            test_verifier_of_request_canonicalizes_token_owner;
        ] );
    ]
