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

let invalid_utf8_byte_count s =
  let len = String.length s in
  let rec loop i count =
    if i >= len
    then count
    else (
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec
      then loop (i + dlen) count
      else loop (i + 1) (count + 1))
  in
  loop 0 0

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.equal (String.sub haystack i needle_len) needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let with_cached_surface_success
      (surface : Lib.Server_dashboard_http_cache.cached_surface)
      json
      f
  =
  let saved =
    ( surface.json
    , surface.last_success_at
    , surface.last_success_unix
    , surface.last_attempt_at
    , surface.last_attempt_unix
    , surface.last_error
    , surface.last_error_at
    , surface.last_error_unix )
  in
  Fun.protect
    ~finally:(fun () ->
      let ( json
          , last_success_at
          , last_success_unix
          , last_attempt_at
          , last_attempt_unix
          , last_error
          , last_error_at
          , last_error_unix )
        =
        saved
      in
      surface.json <- json;
      surface.last_success_at <- last_success_at;
      surface.last_success_unix <- last_success_unix;
      surface.last_attempt_at <- last_attempt_at;
      surface.last_attempt_unix <- last_attempt_unix;
      surface.last_error <- last_error;
      surface.last_error_at <- last_error_at;
      surface.last_error_unix <- last_error_unix)
    (fun () ->
      Lib.Server_dashboard_http_cache.mark_cached_surface_success surface json;
      f ())

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
         | _ -> false));
  let diagnostics = json |> member "projection_diagnostics" in
  check string "shell timing trace finished" "finished"
    (diagnostics |> member "projection_timing_status" |> to_string);
  check bool "shell timing top populated" true
    ((diagnostics |> member "projection_timing_top" |> to_list |> List.length)
     > 0)

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
  let original_warmed = Atomic.get Lib.Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Lib.Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Lib.Server_dashboard_http.last_good_shell in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Lib.Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Lib.Server_dashboard_http.shell_warming original_warming;
      Atomic.set Lib.Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Atomic.set Lib.Server_dashboard_http.shell_warmed false;
      Atomic.set Lib.Server_dashboard_http.shell_warming true;
      Atomic.set Lib.Server_dashboard_http.last_good_shell (`Assoc []);
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
  let original_warmed = Atomic.get Lib.Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Lib.Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Lib.Server_dashboard_http.last_good_shell in
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
      Atomic.set Lib.Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Lib.Server_dashboard_http.shell_warming original_warming;
      Atomic.set Lib.Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Atomic.set Lib.Server_dashboard_http.shell_warmed false;
      Atomic.set Lib.Server_dashboard_http.shell_warming true;
      Atomic.set Lib.Server_dashboard_http.last_good_shell last_good;
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

let test_operator_snapshot_default_route_hydrates_first_success () =
  let source = read_file "lib/server/server_dashboard_http_core.ml" in
  check bool "operator snapshot uses first-success cache helper" true
    (contains_substring source "cached_surface_or_first_success_json"
     && contains_substring source "operator_snapshot_cache"
     && contains_substring source
          "dashboard_cache_key config \"operator_snapshot\" \"default-summary\"");
  check bool "operator snapshot no longer serves raw initializing cache" true
    (not
       (contains_substring source
          "then cached_surface_json operator_snapshot_cache"))

let test_operator_snapshot_default_route_exposes_provenance () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "available_actions", `List []
      ; "keepers", `List []
      ; "generated_at", `String "2026-05-15T00:00:00Z"
      ]
  in
  with_cached_surface_success
    Lib.Server_dashboard_http_core.operator_snapshot_cache
    seed
  @@ fun () ->
  let json =
    Lib.Server_dashboard_http_core.operator_snapshot_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (request "/api/v1/operator")
  in
  let open Yojson.Safe.Util in
  check string "surface" "/api/v1/operator"
    (json |> member "dashboard_surface" |> to_string);
  check string "source" "operator_snapshot_read_model"
    (json |> member "source" |> to_string);
  check string "generated_at_iso" "2026-05-15T00:00:00Z"
    (json |> member "generated_at_iso" |> to_string);
  check string "retention scope" "operator_snapshot"
    (json |> member "retention" |> member "scope" |> to_string);
  check string "retention store" "process_cache"
    (json |> member "retention" |> member "store_kind" |> to_string);
  check string "query effective actor" "dashboard"
    (json |> member "query" |> member "effective_actor" |> to_string);
  check bool "query default summary" true
    (json |> member "query" |> member "default_summary_request" |> to_bool);
  check bool "query includes keepers" true
    (json |> member "query" |> member "include_keepers" |> to_bool);
  check string "cache state" "fresh"
    (json |> member "cache" |> member "cache_state" |> to_string);
  check bool "cache key surfaced" true
    (String.length (json |> member "cache" |> member "request_cache_key" |> to_string)
     > 0)

let test_operator_digest_default_route_exposes_provenance () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "health", `String "ok"
      ; "generated_at", `String "2026-05-15T00:00:01Z"
      ]
  in
  with_cached_surface_success Lib.Server_dashboard_http_core.operator_digest_cache seed
  @@ fun () ->
  match
    Lib.Server_dashboard_http_core.operator_digest_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (request "/api/v1/operator/digest")
  with
  | Error _ -> Alcotest.fail "operator digest default route returned error"
  | Ok json ->
    let open Yojson.Safe.Util in
    check string "surface" "/api/v1/operator/digest"
      (json |> member "dashboard_surface" |> to_string);
    check string "source" "operator_digest_read_model"
      (json |> member "source" |> to_string);
    check string "generated_at_iso" "2026-05-15T00:00:01Z"
      (json |> member "generated_at_iso" |> to_string);
    check string "retention scope" "operator_digest"
      (json |> member "retention" |> member "scope" |> to_string);
    check string "retention store" "process_cache"
      (json |> member "retention" |> member "store_kind" |> to_string);
    check string "query effective target" "root"
      (json |> member "query" |> member "effective_target_type" |> to_string);
    check bool "query default namespace" true
      (json |> member "query" |> member "default_namespace_request" |> to_bool);
    check string "cache state" "fresh"
      (json |> member "cache" |> member "cache_state" |> to_string)

let test_dashboard_shell_timeout_fallback_reports_timing_context () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Lib.Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Lib.Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Lib.Server_dashboard_http.last_good_shell in
  Fun.protect
    ~finally:(fun () ->
      Lib.Dashboard_cache.invalidate_all ();
      Atomic.set Lib.Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Lib.Server_dashboard_http.shell_warming original_warming;
      Atomic.set Lib.Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Lib.Dashboard_cache.invalidate_all ();
      Atomic.set Lib.Server_dashboard_http.shell_warmed true;
      Atomic.set Lib.Server_dashboard_http.shell_warming false;
      Atomic.set Lib.Server_dashboard_http.last_good_shell (`Assoc []);
      let cache_key =
        Lib.Server_dashboard_http_core.dashboard_shell_cache_key config
      in
      ignore
        (Lib.Dashboard_cache.get_or_compute cache_key ~ttl:15.0 (fun () ->
             `Assoc
               [
                 ("error", `String "computation_timeout");
                 ("key", `String cache_key);
               ]));
      let json = Lib.Server_dashboard_http_core.dashboard_shell_http_json config in
      let open Yojson.Safe.Util in
      let diagnostics = json |> member "projection_diagnostics" in
      check string "timeout fallback cache state" "timeout_fallback"
        (diagnostics |> member "cache_state" |> to_string);
      check string "timeout fallback source" "bootstrap"
        (diagnostics |> member "fallback_source" |> to_string);
      check string "timeout cache key surfaced" cache_key
        (diagnostics |> member "timeout_cache_key" |> to_string);
      check (float 0.001) "full shell timeout surfaced" 16.0
        (diagnostics |> member "timeout_sec" |> to_float);
      check string "timing absence is explicit" "none"
        (diagnostics |> member "projection_timing_status" |> to_string);
      check int "timing top is empty without an active trace" 0
        (diagnostics |> member "projection_timing_top" |> to_list |> List.length))

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

let test_dashboard_proof_http_json_surfaces_verification_index () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let module V = Lib.Verification in
  let output =
    `Assoc
      [
        ("evidence_refs", `List [ `String "artifact://proof-route" ]);
        ("task_title", `String "Proof route fixture");
      ]
  in
  (match
     V.create_request
       ~base_path:config.base_path
       ~task_id:"task-proof-route"
       ~output
       ~criteria:[ V.Custom "proof route must expose verification evidence" ]
       ~worker:"keeper-proof"
       ()
   with
   | Ok _ -> ()
   | Error message -> fail message);
  let json =
    Lib.Server_dashboard_http.dashboard_proof_http_json
      ~config
      (request "/api/v1/dashboard/proof?limit=5&recent=2")
  in
  let open Yojson.Safe.Util in
  check int "verification total" 1
    (json |> member "summary" |> member "verification_total" |> to_int);
  check int "pending total" 1
    (json |> member "summary" |> member "verification_pending" |> to_int);
  check bool "verification requests exposed" true
    (match json |> member "verification" |> member "requests" |> member "requests" with
     | `List [ _ ] -> true
     | _ -> false);
  check bool "proof sources include execution trust route" true
    (json
     |> member "proof_sources"
     |> to_list
     |> List.exists (fun source ->
       String.equal
         (source |> member "route" |> to_string)
         "/api/v1/dashboard/execution-trust"))

let test_dashboard_proof_route_registered_in_http_routers () =
  let http1 = read_file "lib/server/server_routes_http_routes_dashboard.ml" in
  let h2 = read_file "lib/server/server_h2_gateway.ml" in
  check bool "HTTP/1 dashboard proof route registered" true
    (contains_substring http1 "\"/api/v1/dashboard/proof\"");
  check bool "HTTP/2 dashboard proof route registered" true
    (contains_substring h2 "\"/api/v1/dashboard/proof\"")

let test_dashboard_planning_http_json_keeps_utf8_valid_after_truncation () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
  let hangul_ga = "\234\176\128" in
  let title = String.concat "" (List.init 40 (fun _ -> hangul_ga)) in
  (match Lib.Goal_store.upsert_goal config ~title () with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let json = Lib.Server_dashboard_http.dashboard_planning_http_json ~config in
  let serialized = Yojson.Safe.to_string json in
  check int "planning json remains valid utf8" 0 (invalid_utf8_byte_count serialized)

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

let test_dashboard_message_json_surfaces_temporal_decay_fields () =
  let message : Types.message =
    {
      seq = 7;
      from_agent = "operator";
      msg_type = "broadcast";
      content = "hello";
      mention = None;
      timestamp = "2026-05-07T00:00:00Z";
      trace_context = Some "traceparent";
      expires_at = Some 1_714_067_200.0;
      relevance = "critical";
    }
  in
  let json = Lib.Server_dashboard_http_core.dashboard_message_json message in
  let open Yojson.Safe.Util in
  check string "type" "broadcast" (json |> member "type" |> to_string);
  check string "trace_context" "traceparent"
    (json |> member "trace_context" |> to_string);
  check (float 0.001) "expires_at" 1_714_067_200.0
    (json |> member "expires_at" |> to_float);
  check string "relevance" "critical"
    (json |> member "relevance" |> to_string)

(* RFC-0138 Phase 3 Step 1 — /shell snapshot wire tests.

   These exercise [Server_dashboard_snapshot_select.select_shell_json]
   directly, which is what the /api/v1/dashboard/shell handler now
   calls.  Three cases cover the full selector matrix:

   1. snapshot published + light=false  -> return [snap.shell]
   2. snapshot empty + light=false      -> fall back to compute path
   3. snapshot published + light=true   -> ignore snapshot, fall back
                                           (one-sprint compatibility) *)

let test_shell_snapshot_wire_returns_snapshot_when_published () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Lib.Dashboard_snapshot.reset_for_test ();
  let sentinel = `Assoc [ "wire_sentinel", `String "snapshot-path" ] in
  Lib.Dashboard_snapshot.publish_for_test
    (Lib.Dashboard_snapshot.make_for_test
       ~shell:sentinel ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:`Null);
  let timing = Lib.Server_timing.create () in
  let json =
    Lib.Server_dashboard_snapshot_select.select_shell_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "snapshot path returns published sentinel"
    "snapshot-path"
    (json |> member "wire_sentinel" |> to_string);
  let header = Lib.Server_timing.to_header_value timing in
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Lib.Dashboard_snapshot.reset_for_test ()

let test_shell_snapshot_wire_falls_back_when_empty () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Lib.Dashboard_snapshot.reset_for_test ();
  let timing = Lib.Server_timing.create () in
  let snapshot_json =
    Lib.Server_dashboard_snapshot_select.select_shell_json
      ~timing config
  in
  let direct_json =
    Lib.Server_dashboard_http_core.dashboard_shell_http_json
      ~light:false config
  in
  let open Yojson.Safe.Util in
  let paths_of j = j |> member "paths" in
  Alcotest.(check bool)
    "fallback path produces compute-equivalent paths key"
    true
    (paths_of snapshot_json <> `Null
     && paths_of snapshot_json = paths_of direct_json)

let test_shell_snapshot_wire_light_variant_bypasses_snapshot () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Lib.Dashboard_snapshot.reset_for_test ();
  let sentinel = `Assoc [ "wire_sentinel", `String "snapshot-path" ] in
  Lib.Dashboard_snapshot.publish_for_test
    (Lib.Dashboard_snapshot.make_for_test
       ~shell:sentinel ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:`Null);
  let timing = Lib.Server_timing.create () in
  let json =
    Lib.Server_dashboard_snapshot_select.select_shell_json
      ~timing ~light:true config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "light=true must NOT return the snapshot sentinel"
    true
    (json |> member "wire_sentinel" = `Null);
  Lib.Dashboard_snapshot.reset_for_test ()

(* RFC-0138 Phase 3 Step 2 — /tools and /telemetry/summary wire tests.

   Cover the new selector matrix on
   [Server_dashboard_snapshot_select.select_tools_json] and
   [..._telemetry_summary_json]. *)

let test_tools_snapshot_wire_returns_snapshot_when_actor_omitted () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Lib.Dashboard_snapshot.reset_for_test ();
  let sentinel = `Assoc [ "tools_sentinel", `String "from-snapshot" ] in
  Lib.Dashboard_snapshot.publish_for_test
    (Lib.Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:sentinel
       ~namespace_truth:`Null ~telemetry_summary:`Null);
  let timing = Lib.Server_timing.create () in
  let json =
    Lib.Server_dashboard_snapshot_select.select_tools_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "actor-less snapshot path returns published sentinel"
    "from-snapshot"
    (json |> member "tools_sentinel" |> to_string);
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let header = Lib.Server_timing.to_header_value timing in
     let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Lib.Dashboard_snapshot.reset_for_test ()

(* [test_tools_snapshot_wire_bypasses_snapshot_when_actor_given]
   intentionally omitted from the unit suite.  The selector's
   actor=Some branch routes to
   [Server_dashboard_http_runtime_info.dashboard_tools_http_json] which
   requires a full Eio scheduler + runtime probe wiring not present
   in [with_test_env].  Integration coverage of the actor-filter
   bypass belongs in [test_dashboard_tools.ml] (which already runs
   inside the live HTTP harness).  See RFC-0138 §3.3 Step 2 retire
   criterion: snapshot grows an [Actor_filter] arm. *)

let test_telemetry_summary_snapshot_wire_returns_snapshot () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Lib.Dashboard_snapshot.reset_for_test ();
  let sentinel = `Assoc [ "tele_sentinel", `String "from-snapshot" ] in
  Lib.Dashboard_snapshot.publish_for_test
    (Lib.Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:sentinel);
  let timing = Lib.Server_timing.create () in
  let json =
    Lib.Server_dashboard_snapshot_select.select_telemetry_summary_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "telemetry_summary snapshot path returns published sentinel"
    "from-snapshot"
    (json |> member "tele_sentinel" |> to_string);
  Lib.Dashboard_snapshot.reset_for_test ()

let test_telemetry_summary_snapshot_wire_falls_back_when_empty () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Lib.Dashboard_snapshot.reset_for_test ();
  let timing = Lib.Server_timing.create () in
  let json =
    Lib.Server_dashboard_snapshot_select.select_telemetry_summary_json
      ~timing config
  in
  Alcotest.(check bool)
    "fallback path produces a non-null JSON object"
    true
    (match json with `Assoc _ -> true | _ -> false)

(* RFC-0138 Phase 3 Step 3 — /project-snapshot wire test.

   We can only unit-test the snapshot-hit branch.  The fallback branch
   calls [dashboard_namespace_truth_http_json] which requires a full
   server_state + Eio scheduler + 6 timeout env knobs ([with_test_env]
   does not synthesise these).  The fallback path lives in
   [test_dashboard_namespace_truth.ml] integration coverage. *)

let test_project_snapshot_wire_returns_snapshot_when_populated () =
  with_test_env @@ fun ~env ~sw ~config:_ ->
  Lib.Dashboard_snapshot.reset_for_test ();
  let sentinel =
    `Assoc [ "namespace_truth_sentinel", `String "from-snapshot" ]
  in
  Lib.Dashboard_snapshot.publish_for_test
    (Lib.Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:`Null
       ~namespace_truth:sentinel ~telemetry_summary:`Null);
  let clock = Eio.Stdenv.clock env in
  let state = Lib.Mcp_server.create_state ~base_path:"/tmp/rfc-0138-step3" in
  let req = request "/api/v1/dashboard/project-snapshot" in
  let timing = Lib.Server_timing.create () in
  let json =
    Lib.Server_dashboard_snapshot_select.select_project_snapshot_json
      ~state ~sw ~clock ~timing req
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "populated snapshot path returns published sentinel"
    "from-snapshot"
    (json |> member "namespace_truth_sentinel" |> to_string);
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let header = Lib.Server_timing.to_header_value timing in
     let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Lib.Dashboard_snapshot.reset_for_test ()

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
          test_case "operator snapshot hydrates on first default request" `Quick
            test_operator_snapshot_default_route_hydrates_first_success;
          test_case "operator snapshot default route exposes provenance" `Quick
            test_operator_snapshot_default_route_exposes_provenance;
          test_case "operator digest default route exposes provenance" `Quick
            test_operator_digest_default_route_exposes_provenance;
          test_case "shell timeout fallback reports timing context" `Quick
            test_dashboard_shell_timeout_fallback_reports_timing_context;
          test_case "planning payload includes coordination FSM" `Quick
            test_dashboard_planning_http_json_includes_coordination_fsm;
          test_case "proof payload exposes verification index" `Quick
            test_dashboard_proof_http_json_surfaces_verification_index;
          test_case "proof route registered in HTTP routers" `Quick
            test_dashboard_proof_route_registered_in_http_routers;
          test_case "planning payload keeps UTF-8 valid after truncation" `Quick
            test_dashboard_planning_http_json_keeps_utf8_valid_after_truncation;
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
          test_case "message JSON exposes temporal decay fields" `Quick
            test_dashboard_message_json_surfaces_temporal_decay_fields;
          test_case "RFC-0138 shell wire returns snapshot when published" `Quick
            test_shell_snapshot_wire_returns_snapshot_when_published;
          test_case "RFC-0138 shell wire falls back when snapshot empty" `Quick
            test_shell_snapshot_wire_falls_back_when_empty;
          test_case "RFC-0138 shell wire light variant bypasses snapshot" `Quick
            test_shell_snapshot_wire_light_variant_bypasses_snapshot;
          test_case "RFC-0138 tools wire returns snapshot when actor omitted" `Quick
            test_tools_snapshot_wire_returns_snapshot_when_actor_omitted;
          test_case "RFC-0138 telemetry_summary wire returns snapshot" `Quick
            test_telemetry_summary_snapshot_wire_returns_snapshot;
          test_case "RFC-0138 telemetry_summary wire falls back when empty" `Quick
            test_telemetry_summary_snapshot_wire_falls_back_when_empty;
          test_case "RFC-0138 project-snapshot wire returns snapshot when populated" `Quick
            test_project_snapshot_wire_returns_snapshot_when_populated;
        ] );
    ]
