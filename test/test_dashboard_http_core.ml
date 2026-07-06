module Types = Masc_domain

let () = Mirage_crypto_rng_unix.use_default ()

module Lib = Masc
module Auth = Masc.Auth
module Workspace = Masc.Workspace

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

let nested_path_string_present_or_null json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Null -> true
  | value -> (
      match value |> member "path" with
      | `String path -> String.length path > 0
      | _ -> false)

let read_file path =
  let path =
    if Filename.is_relative path then
      match Sys.getenv_opt "DUNE_SOURCEROOT" with
      | Some root -> Filename.concat root path
      | None -> path
    else path
  in
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let replace_path_with_file path content =
  if Sys.file_exists path then cleanup_dir path;
  write_file path content

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755
  end

let test_runtime_trace_receipt_reader_surfaces_parse_errors () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let path = Filename.concat dir "receipts.jsonl" in
      write_file
        path
        (String.concat
           "\n"
           [ {|{"keeper_name":"alpha","trace_id":"trace-1","outcome":"receipt_done"}|}
           ; "{not-json"
           ; {|["not-object"]|}
           ]
         ^ "\n");
      let rows, read_errors =
        Server_dashboard_http_keeper_api_scan_summary.read_receipt_rows_with_read_errors
          ~keeper_name:"alpha"
          ~trace_id:"trace-1"
          [ path ]
      in
      check int "matching receipt rows" 1 (List.length rows);
      check int "receipt read errors" 2 (List.length read_errors);
      let open Yojson.Safe.Util in
      match read_errors with
      | [ json_error; row_error ] ->
        check string "json error source" "runtime_trace_execution_receipt_jsonl"
          (json_error |> member "source" |> to_string);
        check string "json error path" path (json_error |> member "path" |> to_string);
        check int "json error line" 2 (json_error |> member "line_index" |> to_int);
        check string "json error kind" "json_error"
          (json_error |> member "kind" |> to_string);
        check int "row error line" 3 (row_error |> member "line_index" |> to_int);
        check string "row error kind" "row_not_object"
          (row_error |> member "kind" |> to_string)
      | _ -> Alcotest.fail "expected two receipt read errors")

let test_bulk_wakeup_result_surfaces_meta_read_error () =
  let row =
    Server_dashboard_http_keeper_api_post.For_testing
    .bulk_directive_meta_read_error_result_json
      ~name:"sangsu"
      ~ok:true
      ~meta_read_error:"malformed keeper meta"
      ()
  in
  let open Yojson.Safe.Util in
  check string "keeper name" "sangsu" (row |> member "name" |> to_string);
  check bool "wakeup still succeeds" true (row |> member "ok" |> to_bool);
  check string "meta read status" "read_error"
    (row |> member "meta_read_status" |> to_string);
  check string "meta read error" "malformed keeper meta"
    (row |> member "meta_read_error" |> to_string);
  check bool "best-effort wakeup has no terminal error field" true
    (row |> member "error" = `Null)

let with_cached_surface_success
      (surface : Server_dashboard_http_cache.cached_surface)
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
      Server_dashboard_http_cache.mark_cached_surface_success surface json;
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

let test_keeper_post_route_classifies_catchup_judge () =
  let path = "/api/v1/keepers/idealist/catchup-judge" in
  check bool "catchup judge route kind" true
    (Server_dashboard_http_keeper_api.classify_keeper_post_route path
     = Server_dashboard_http_keeper_api.Keeper_post_catchup_judge);
  check string "keeper name extracted" "idealist"
    (Server_dashboard_http_keeper_api.extract_keeper_name_for_suffix path
       Server_dashboard_http_keeper_api.keeper_suffix_catchup_judge)

let with_test_env f =
  let dir = test_dir () in
	Fun.protect
	  ~finally:(fun () -> cleanup_dir dir)
	  (fun () ->
	    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace_utils.default_config dir in
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
    Server_dashboard_http_core.run_dashboard_compute
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
  Server_dashboard_http_core.set_executor_pool exec_pool;
  let caller_domain = Domain.self () in
  let result_domain =
    Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~config
      (fun ~config:_ ~sw:_ -> Domain.self ())
  in
  check bool "non-PG backend offloads to executor pool domain" true
    (result_domain <> caller_domain)

let test_meta_cognition_cold_cache_worker_domain_skips_root_switch () =
  with_test_env @@ fun ~env ~sw ~config ->
  let exec_pool =
    Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
  in
  let key =
    Server_dashboard_http_core_meta_cognition.meta_cognition_summary_key config
  in
  Dashboard_cache.invalidate key;
  Server_dashboard_http_core_meta_cognition.clear_meta_cognition_warm_flag key;
  let json =
    Eio.Executor_pool.submit_exn exec_pool ~weight:1.0 (fun () ->
      Server_dashboard_http_core_meta_cognition.meta_cognition_summary_cached
        config)
  in
  check bool "cold worker call returns placeholder" true (json = `Null);
  check bool "worker fork failure clears warm slot" true
    (Server_dashboard_http_core_meta_cognition.Mc_cache.try_acquire_warm_slot
       key);
  Server_dashboard_http_core_meta_cognition.clear_meta_cognition_warm_flag key

let test_dashboard_shell_http_json_includes_paths () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let json = Server_dashboard_http_core.dashboard_shell_http_json config in
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
     | _ -> nested_path_string_present_or_null config_resolution "config_root");
  check bool "shell runtime authoring path surfaced when available" true
    (match config_resolution with
     | `Null -> true
     | _ ->
       nested_path_string_present_or_null config_resolution "runtime_authoring");
  check bool "shell runtime resolution is object or null" true
    (match runtime_resolution with
     | `Assoc _ | `Null -> true
     | _ -> false);
  check bool "shell runtime data root path surfaced when available" true
    (match runtime_resolution with
     | `Null -> true
     | _ -> nested_path_string_present_or_null runtime_resolution "data_root");
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
  let json = Server_dashboard_http_core.dashboard_shell_http_json config in
  let open Yojson.Safe.Util in
  check string "runtime base_path preserves raw input" raw_input
    (json |> member "runtime_resolution" |> member "base_path" |> member "path"
   |> to_string)

let test_runtime_resolution_accepts_server_repo_inside_base_path () =
  match Lib.Build_identity.repo_root () with
  | None -> fail "Build_identity.repo_root unavailable; cannot test server/base path relation"
  | Some repo_root ->
    let repo_root =
      try Unix.realpath repo_root with
      | Unix.Unix_error _ -> repo_root
    in
    let config = Workspace.default_config (Filename.dirname repo_root) in
    check bool "runtime accepts nested server repo" false
      (Server_dashboard_http_runtime_info.server_workspace_mismatch_for_tests
         ~server_repo_path:repo_root
         config)

let test_dashboard_shell_http_json_uses_bootstrap_payload_while_prewarming () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Atomic.set Server_dashboard_http.shell_warmed false;
      Atomic.set Server_dashboard_http.shell_warming true;
      Atomic.set Server_dashboard_http.last_good_shell (`Assoc []);
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json
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
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  let last_good =
    `Assoc
      [
        ("generated_at", `String "2026-04-17T00:00:00Z");
        ("status", `Assoc [("project", `String "warm-workspace")]);
        ("counts", `Assoc [("agents", `Int 7); ("tasks", `Int 11); ("keepers", `Int 3)]);
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Atomic.set Server_dashboard_http.shell_warmed false;
      Atomic.set Server_dashboard_http.shell_warming true;
      Atomic.set Server_dashboard_http.last_good_shell last_good;
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json
          ~request:(request "/api/v1/dashboard/shell")
          config
      in
      let open Yojson.Safe.Util in
      check string "last-good project reused" "warm-workspace"
        (json |> member "status" |> member "project" |> to_string);
      check int "last-good counts reused" 7
        (json |> member "counts" |> member "agents" |> to_int))

let test_dashboard_shell_http_json_records_light_last_good () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_light_last_good =
    Atomic.get Server_dashboard_http.last_good_shell_light
  in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set
        Server_dashboard_http.last_good_shell_light
        original_light_last_good)
    (fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set Server_dashboard_http.last_good_shell_light (`Assoc []);
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
      in
      let cached = Atomic.get Server_dashboard_http.last_good_shell_light in
      let open Yojson.Safe.Util in
      check bool "light last-good populated" true (cached = json);
      check bool "cached payload is light shell" true
        (cached
         |> member "projection_diagnostics"
         |> member "light"
         |> to_bool))

let test_dashboard_shell_http_json_prefers_light_last_good_while_prewarming () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  let original_light_last_good =
    Atomic.get Server_dashboard_http.last_good_shell_light
  in
  let full_last_good =
    `Assoc
      [
        ("status", `Assoc [("project", `String "full-workspace")]);
        ("counts", `Assoc [("agents", `Int 9)]);
      ]
  in
  let light_last_good =
    `Assoc
      [
        ("status", `Assoc [("project", `String "light-workspace")]);
        ("counts", `Assoc [("agents", `Int 2)]);
        ("projection_diagnostics", `Assoc [("light", `Bool true)]);
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good;
      Atomic.set
        Server_dashboard_http.last_good_shell_light
        original_light_last_good)
    (fun () ->
      Atomic.set Server_dashboard_http.shell_warmed false;
      Atomic.set Server_dashboard_http.shell_warming true;
      Atomic.set Server_dashboard_http.last_good_shell full_last_good;
      Atomic.set Server_dashboard_http.last_good_shell_light light_last_good;
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json
          ~request:(request "/api/v1/dashboard/shell?light=1")
          ~light:true
          config
      in
      let open Yojson.Safe.Util in
      check string "light last-good project reused" "light-workspace"
        (json |> member "status" |> member "project" |> to_string);
      check int "light last-good counts reused" 2
        (json |> member "counts" |> member "agents" |> to_int);
      check bool "light diagnostics preserved" true
        (json
         |> member "projection_diagnostics"
         |> member "light"
         |> to_bool))

let test_operator_snapshot_default_route_hydrates_first_success () =
  let source =
    read_file "lib/server/server_dashboard_http_core_operator_snapshot_http.ml"
  in
  check bool "operator snapshot uses first-success cache helper" true
    (contains_substring source "cached_surface_or_first_success_json"
     && contains_substring source "operator_snapshot_cache"
     && contains_substring source
          "dashboard_cache_key config \"operator_snapshot\" \"default-summary\"");
  check bool "operator snapshot no longer serves raw initializing cache" true
    (not
       (contains_substring source
          "then cached_surface_json operator_snapshot_cache"))

let test_dashboard_query_cache_segment_normalizes_missing_values () =
  check string "missing none" "missing"
    (Server_dashboard_http_core_cache.dashboard_query_cache_segment None);
  check string "missing blank" "missing"
    (Server_dashboard_http_core_cache.dashboard_query_cache_segment (Some "  "));
  check string "trimmed value" "keeper-a"
    (Server_dashboard_http_core_cache.dashboard_query_cache_segment (Some " keeper-a "))

let test_dashboard_query_cache_key_partitions_route_params () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let session_a =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "session-a") ]
      in
      let session_b =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "session-b") ]
      in
      let actor_b =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "keeper-b"); ("session", Some "session-a") ]
      in
      check bool "session_id partitions route cache" true
        (not (String.equal session_a session_b));
      check bool "actor partitions route cache" true
        (not (String.equal session_a actor_b));
      check string "deterministic key shape"
        (Printf.sprintf
           "session:%s:default:[[\"actor\",\"default\"],[\"session\",\"session-a\"]]"
           config.base_path)
        session_a)

let test_dashboard_query_cache_key_encodes_delimiter_values () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let actor_delimiter =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default:session=session-a")
          ; ("session", Some "session-b")
          ]
      in
      let session_delimiter =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default")
          ; ("session", Some "session-a:session=session-b")
          ]
      in
      let missing_session =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", None) ]
      in
      let literal_missing_session =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "missing") ]
      in
      let missing_actor =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", None); ("session", Some "session-a") ]
      in
      let explicit_default_actor =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "session-a") ]
      in
      check bool "delimiter-bearing values do not collide" true
        (not (String.equal actor_delimiter session_delimiter));
      check bool "literal missing does not collide with absent value" true
        (not (String.equal missing_session literal_missing_session));
      check bool "missing actor does not collide with explicit default actor" true
        (not (String.equal missing_actor explicit_default_actor)))

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
    Server_dashboard_http_core_operator.operator_snapshot_cache
    seed
  @@ fun () ->
  let json =
    Server_dashboard_http_core.operator_snapshot_http_json
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
  with_cached_surface_success Server_dashboard_http_core_operator.operator_digest_cache seed
  @@ fun () ->
  match
    Server_dashboard_http_core.operator_digest_http_json
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
    check string "query effective target" "workspace"
      (json |> member "query" |> member "effective_target_type" |> to_string);
    check bool "query default namespace" true
      (json |> member "query" |> member "default_namespace_request" |> to_bool);
    check string "cache state" "fresh"
      (json |> member "cache" |> member "cache_state" |> to_string)

let test_dashboard_shell_timeout_fallback_reports_timing_context () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set Server_dashboard_http.shell_warmed true;
      Atomic.set Server_dashboard_http.shell_warming false;
      Atomic.set Server_dashboard_http.last_good_shell (`Assoc []);
      let cache_key =
        Server_dashboard_http_core.dashboard_shell_cache_key config
      in
      ignore
        (Dashboard_cache.get_or_compute cache_key ~ttl:15.0 (fun () ->
             `Assoc
               [
                 ("error", `String "computation_timeout");
                 ("key", `String cache_key);
               ]));
      let json = Server_dashboard_http_core.dashboard_shell_http_json config in
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
    Server_dashboard_http.dashboard_proof_http_json
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

let test_dashboard_ide_snapshot_json_surfaces_legacy_partition_metadata () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Fun.protect
    (* [Client_registry_eio] lives in the wrapped [masc] library; this file does
       not [open Masc] (it uses qualified [Masc.X] access), so the module must be
       qualified. [Server_dashboard_http]/[Ide_paths] resolve bare because they
       come from the unwrapped [masc.server] library. *)
    ~finally:Masc.Client_registry_eio.reset_for_testing
    (fun () ->
      Masc.Client_registry_eio.reset_for_testing ();
      let json = Server_dashboard_http.dashboard_ide_snapshot_json ~config in
      let partition = Ide_paths.Legacy_default in
      let open Yojson.Safe.Util in
      check string "partition kind" (Ide_paths.partition_kind partition)
        (json |> member "partition_kind" |> to_string);
      check bool "partition is orphan" (Ide_paths.partition_is_orphan partition)
        (json |> member "partition_orphan" |> to_bool);
      check int "events count metadata" 0
        (json |> member "events_count" |> to_int);
      check int "cursors count metadata" 0
        (json |> member "cursors_count" |> to_int);
      check int "annotations count metadata" 0
        (json |> member "annotations_count" |> to_int);
      check int "regions count metadata" 0
        (json |> member "regions_count" |> to_int);
      check int "active keepers count metadata" 0
        (json |> member "active_keepers_count" |> to_int);
      check int "events nested count remains" 0
        (json |> member "events" |> member "count" |> to_int);
      check int "presence nested count remains" 0
        (json |> member "presence" |> member "count" |> to_int))

let test_dashboard_planning_http_json_keeps_utf8_valid_after_truncation () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
  let hangul_ga = "\234\176\128" in
  let title = String.concat "" (List.init 40 (fun _ -> hangul_ga)) in
  (match Goal_store.upsert_goal config ~title () with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let json = Server_dashboard_http.dashboard_planning_http_json ~config in
  let serialized = Yojson.Safe.to_string json in
  check int "planning json remains valid utf8" 0 (invalid_utf8_byte_count serialized)

let test_dashboard_planning_http_json_reports_goal_store_read_failure () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
  ignore
    (Workspace.add_task config ~title:"Planning task" ~priority:3 ~description:"");
  write_file (Goal_store.goals_path config) "{not-json";
  write_file (Goal_store.goals_path config ^ ".last-good") "{not-json";
  let json = Server_dashboard_http.dashboard_planning_http_json ~config in
  let open Yojson.Safe.Util in
  check bool "goal store marked unknown" false
    (json |> member "goal_store_known" |> to_bool);
  check bool "goal store read error names goals.json" true
    (contains_substring
       (json |> member "goal_store_read_error" |> to_string)
       "goals.json");
  check int "goals hidden while store unreadable" 0
    (json |> member "goals" |> to_list |> List.length);
  check int "task backlog remains observable" 1
    (json |> member "task_backlog" |> member "todo" |> to_int)

let dashboard_keeper_meta ?(active_goal_ids = []) name trace_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String name
        ; "trace_id", `String trace_id
        ; "goal", `String "dashboard keeper goal"
        ; ( "active_goal_ids"
          , `List (List.map (fun goal_id -> `String goal_id) active_goal_ids)
          )
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta fixture failed: " ^ err)

let corrupt_goal_store config =
  write_file (Goal_store.goals_path config) "{not-json";
  write_file (Goal_store.goals_path config ^ ".last-good") "{not-json"

let test_keeper_config_json_reports_goal_store_read_failure () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let meta =
    dashboard_keeper_meta
      ~active_goal_ids:[ "goal-unreadable" ]
      "keeper-config-goal-store-error"
      "trace-keeper-config-goal-store-error"
  in
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  corrupt_goal_store config;
  let status, json = Dashboard_http_keeper.keeper_config_json config meta.name in
  check bool "keeper config is present" true (status = `OK);
  let open Yojson.Safe.Util in
  let workspace = json |> member "workspace" in
  check bool "active goals marked unknown" false
    (workspace |> member "active_goals_known" |> to_bool);
  check bool "active goals read error names goals.json" true
    (contains_substring
       (workspace |> member "active_goals_read_error" |> to_string)
       "goals.json");
  check int "configured active goal count is retained" 1
    (workspace |> member "active_goal_count" |> to_int);
  check int "active goals are not forged from unreadable store" 0
    (workspace |> member "active_goals" |> to_list |> List.length);
  check int "missing active goals are unknown, not inferred" 0
    (workspace |> member "missing_active_goal_ids" |> to_list |> List.length)

let test_keeper_dashboard_json_reports_active_goal_store_read_failure () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let meta =
    dashboard_keeper_meta
      ~active_goal_ids:[ "goal-unreadable" ]
      "keeper-dashboard-goal-store-error"
      "trace-keeper-dashboard-goal-store-error"
  in
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  corrupt_goal_store config;
  let json = Dashboard_http_keeper.keepers_dashboard_json config in
  let open Yojson.Safe.Util in
  let keeper =
    match json |> member "keepers" |> to_list with
    | [ row ] -> row
    | rows -> failf "expected one keeper row, got %d" (List.length rows)
  in
  let tree = keeper |> member "active_goals_tree" in
  check bool "goal store marked unknown" false
    (tree |> member "goal_store_known" |> to_bool);
  check bool "goal store read error names goals.json" true
    (contains_substring
       (tree |> member "goal_store_read_error" |> to_string)
       "goals.json");
  check bool "goal-task links not evaluated without goals" false
    (tree |> member "goal_task_links_known" |> to_bool);
  check bool "goal-task link error is not forged" true
    (tree |> member "goal_task_links_read_error" = `Null);
  check int "nodes hidden while goal store unreadable" 0
    (tree |> member "nodes" |> to_list |> List.length)

let test_dashboard_execution_running_keeper_scan_reports_keeper_name_failure () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  replace_path_with_file
    (Keeper_types_profile.keeper_dir config)
    "not a keeper directory";
  let json =
    Server_dashboard_http_execution_surfaces.patch_surface_json_for_running_keepers
      config
      (`Assoc [ "keepers", `List [] ])
  in
  let open Yojson.Safe.Util in
  check bool "running keeper names marked unknown" false
    (json |> member "running_keeper_names_known" |> to_bool);
  check int "one running keeper read error" 1
    (json |> member "running_keeper_read_error_count" |> to_int);
  let read_errors = json |> member "running_keeper_read_errors" |> to_list in
  check int "running keeper read error length" 1 (List.length read_errors);
  (match read_errors with
   | [ error ] ->
     check string "read error source" "keeper_names_result"
       (error |> member "source" |> to_string);
     check bool "read error mentions keepers path" true
       (contains_substring (error |> member "message" |> to_string) "keepers")
   | _ -> fail "expected one running keeper read error");
  check int "keeper rows still empty" 0
    (json |> member "keepers" |> to_list |> List.length)

let test_dashboard_execution_running_keeper_scan_reports_meta_read_failure () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let keepers_dir = Keeper_types_profile.keeper_dir config in
  mkdir_p keepers_dir;
  write_file (Filename.concat keepers_dir "broken.json") "{not-json";
  let json =
    Server_dashboard_http_execution_surfaces.patch_surface_json_for_running_keepers
      config
      (`Assoc [ "keepers", `List [] ])
  in
  let open Yojson.Safe.Util in
  check bool "running keeper names remain known" true
    (json |> member "running_keeper_names_known" |> to_bool);
  check int "one running keeper meta read error" 1
    (json |> member "running_keeper_read_error_count" |> to_int);
  let read_errors = json |> member "running_keeper_read_errors" |> to_list in
  match read_errors with
  | [ error ] ->
    check string "read error source" "read_meta"
      (error |> member "source" |> to_string);
    check string "read error keeper" "broken"
      (error |> member "keeper" |> to_string);
    check bool "read error message present" true
      (String.length (error |> member "message" |> to_string) > 0)
  | _ -> fail "expected one running keeper meta read error"

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
        Server_dashboard_http_core.dashboard_shell_http_json
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
    Server_dashboard_http_core.dashboard_shell_http_json
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
    (auth |> member "auth_error_code" |> to_string);
  check string "missing token effective role error code surfaced" "missing_token"
    (auth |> member "effective_role_error_code" |> to_string)

let test_dashboard_shell_auth_json_rejects_stale_token_actor_hint () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  let json =
    Server_dashboard_http_core.dashboard_shell_http_json
      ~request:
        (request_with_headers "/api/v1/dashboard/shell"
           [
             ("authorization", "Bearer stale-dashboard-token");
             ("x-masc-agent", "dashboard");
           ])
      config
  in
  let open Yojson.Safe.Util in
  let auth = json |> member "auth" in
  check bool "token_valid false" false (auth |> member "token_valid" |> to_bool);
  check string "requested actor surfaced for diagnosis" "dashboard"
    (auth |> member "requested_agent" |> to_string);
  check bool "effective actor not recovered from request hint" true
    (match auth |> member "effective_agent" with `Null -> true | _ -> false);
  check bool "effective role unavailable" true
    (match auth |> member "effective_role" with `Null -> true | _ -> false);
  check string "effective actor failure code surfaced" "invalid_token"
    (auth |> member "effective_agent_error_code" |> to_string);
  check string "effective role failure code surfaced" "invalid_token"
    (auth |> member "effective_role_error_code" |> to_string);
  check string "invalid token code surfaced" "invalid_token"
    (auth |> member "auth_error_code" |> to_string);
  check bool "keeper message blocked" false
    (auth |> member "can_keeper_msg" |> to_bool)

let test_dashboard_shell_snapshot_selector_injects_auth () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  Fun.protect
    ~finally:Dashboard_snapshot.reset_for_test
    (fun () ->
       let snapshot =
         Dashboard_snapshot.make_for_test
           ~shell:
             (`Assoc
                [
                  ("status", `Assoc [ ("project", `String "snapshot") ]);
                  ("paths", `Assoc []);
                ])
           ~tools:`Null
           ~namespace_truth:`Null
           ~telemetry_summary:`Null ()
       in
       Dashboard_snapshot.publish_for_test snapshot;
       let json =
         Server_dashboard_snapshot_select.select_shell_json
           ~request:(request "/api/v1/dashboard/shell")
           config
       in
       let open Yojson.Safe.Util in
       check string "snapshot payload preserved" "snapshot"
         (json |> member "status" |> member "project" |> to_string);
       check bool "snapshot selector injects auth" true
         (match json |> member "auth" with
          | `Assoc _ -> true
          | _ -> false))

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
        Server_dashboard_http_execution_surfaces.execution_actor_for_request
          ~base_path:config.base_path
          (request_with_headers "/api/v1/dashboard/execution"
             [
               ("authorization", "Bearer " ^ raw_token);
               ("x-masc-agent", "dashboard");
             ])
      in
      check (option string) "execution actor canonicalized to token owner"
        (Some "codex") actor

let test_dashboard_execution_force_refresh_bypasses_default_cache () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "force_marker", `String "cached"
      ; "generated_at", `String "2026-05-15T00:00:02Z"
      ]
  in
  with_cached_surface_success
    Server_dashboard_http_execution_surfaces.execution_cache
    seed
  @@ fun () ->
  let json =
    Server_dashboard_http_execution_surfaces.dashboard_execution_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (request "/api/v1/dashboard/execution?force=1")
  in
  let open Yojson.Safe.Util in
  check bool "force query surfaced" true
    (json |> member "query" |> member "force" |> to_bool);
  check bool "force is not the default cached light request" false
    (json |> member "query" |> member "default_light_request" |> to_bool);
  check bool "seed marker bypassed" true
    (match json |> member "force_marker" with
     | `Null -> true
     | _ -> false);
  check string "cache key" "execution:default:light"
    (json |> member "cache" |> member "request_cache_key" |> to_string);
  check string "cache state" "fresh"
    (json |> member "cache" |> member "cache_state" |> to_string)

let test_dashboard_execution_trust_default_route_uses_cached_surface () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "source", `String "execution_receipt"
      ; "producer", `String "keeper_agent_run.execution_receipt"
      ; "dashboard_surface", `String "/api/v1/dashboard/execution-trust"
      ; "generated_at", `String "2026-05-15T00:00:03Z"
      ; "freshness_slo_s", `Float 900.0
      ; "entry_count", `Int 2
      ; "exists", `Bool true
      ; "keepers", `List []
      ; "total", `Int 1
      ; "coverage_gaps", `List []
      ; "coverage_gap_count", `Int 0
      ; "health", `String "ok"
      ]
  in
  with_cached_surface_success
    Server_dashboard_http_execution_surfaces.execution_trust_cache
    seed
  @@ fun () ->
  let json =
    Server_dashboard_http_execution_surfaces.dashboard_execution_trust_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (request "/api/v1/dashboard/execution-trust")
  in
  let open Yojson.Safe.Util in
  check int "cached entry count" 2 (json |> member "entry_count" |> to_int);
  check string "surface" "/api/v1/dashboard/execution-trust"
    (json |> member "dashboard_surface" |> to_string);
  check string "projection cache state" "fresh"
    (json |> member "projection_diagnostics" |> member "cache_state" |> to_string);
  check string "envelope cache state" "fresh"
    (json |> member "dashboard_surface_envelope" |> member "cache" |> member "state"
     |> to_string);
  check string "envelope cache key" "execution-trust:default"
    (json |> member "dashboard_surface_envelope" |> member "cache" |> member "key"
     |> to_string)

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
        Server_routes_http_routes_verification.verifier_of_request
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
  let json = Server_dashboard_http_core.dashboard_message_json message in
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
   3. snapshot published + light=true   -> return [snap.shell_light]
                                           (RFC-0204 section 8.3 "A") *)

let test_shell_snapshot_wire_returns_snapshot_when_published () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let marker = `Assoc [ "wire_marker", `String "snapshot-path" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:marker ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:`Null ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_shell_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "snapshot path returns published marker"
    "snapshot-path"
    (json |> member "wire_marker" |> to_string);
  let header = Server_timing.to_header_value timing in
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

let test_shell_snapshot_wire_falls_back_when_empty () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let timing = Server_timing.create () in
  let snapshot_json =
    Server_dashboard_snapshot_select.select_shell_json
      ~timing config
  in
  let direct_json =
    Server_dashboard_http_core.dashboard_shell_http_json
      ~light:false config
  in
  let open Yojson.Safe.Util in
  let paths_of j = j |> member "paths" in
  Alcotest.(check bool)
    "fallback path produces compute-equivalent paths key"
    true
    (paths_of snapshot_json <> `Null
     && paths_of snapshot_json = paths_of direct_json)

let test_shell_snapshot_wire_light_reads_shell_light () =
  (* RFC-0204 section 8.3 ("A"): light=true now serves the published light
     projection [snap.shell_light], not the full [snap.shell] and not a
     recompute. *)
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let full = `Assoc [ "wire_marker", `String "full-shell" ] in
  let light = `Assoc [ "wire_marker", `String "light-shell" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:full ~shell_light:light ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:`Null ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_shell_json
      ~timing ~light:true config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "light=true returns the published shell_light projection"
    "light-shell"
    (json |> member "wire_marker" |> to_string);
  let header = Server_timing.to_header_value timing in
  Alcotest.(check bool)
    "Server-Timing records snapshot_read on light hit"
    true
    (let re = Re.compile (Re.Perl.re "snapshot_read") in Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

let test_dashboard_shell_light_includes_runtime_health_ssot () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let json =
    Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
  in
  let open Yojson.Safe.Util in
  let runtime_resolution = json |> member "runtime_resolution" in
  let keeper_fibers = runtime_resolution |> member "keeper_fibers" |> to_int in
  Alcotest.(check bool)
    "light shell exposes runtime_resolution object"
    true
    (match runtime_resolution with
     | `Assoc _ -> true
     | _ -> false);
  Alcotest.(check int)
    "light shell keeper count follows runtime health keeper_fibers"
    keeper_fibers
    (json |> member "counts" |> member "keepers" |> to_int);
  Alcotest.(check bool)
    "light shell exposes fleet safety"
    true
    (match runtime_resolution |> member "keeper_fleet_safety" with
     | `Assoc _ -> true
     | _ -> false);
  Alcotest.(check bool)
    "light shell exposes fd accountant"
    true
    (match runtime_resolution |> member "fd_accountant" with
     | `Assoc _ -> true
     | _ -> false)

let test_dashboard_fleet_composite_envelope_is_cached () =
  (* [dashboard_fleet_composite_json] caches the fleet envelope so a second poll
     inside the TTL returns the cached compute (identical generated_at) rather
     than re-running the sequential N-keeper read path. Each keeper reaches
     [Keeper_secret_projection.dashboard_status_json] (a synchronous disk
     read), so an uncached poll costs N reads. This guards that regression. *)
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let json1 = Server_dashboard_http.dashboard_fleet_composite_json ~config () in
  let json2 = Server_dashboard_http.dashboard_fleet_composite_json ~config () in
  let open Yojson.Safe.Util in
  let gen1 = json1 |> member "generated_at" |> to_float in
  let gen2 = json2 |> member "generated_at" |> to_float in
  Alcotest.(check bool)
    "second fleet-composite poll hits cache (identical generated_at)"
    true (gen1 = gen2)

let test_composite_tool_call_output_parse_failure_is_typed () =
  let malformed_call = `Assoc [ ("output", `String "{not-json") ] in
  (match
     Server_dashboard_http_composite_claims.parse_tool_call_output malformed_call
   with
   | Server_dashboard_http_composite_claims.Tool_call_output_parse_error detail ->
       check bool "parse error detail is preserved" true (String.length detail > 0)
   | Server_dashboard_http_composite_claims.Tool_call_output_missing ->
       fail "malformed output must not be reported as missing"
   | Server_dashboard_http_composite_claims.Tool_call_output_json _ ->
       fail "malformed output must not be reported as parsed JSON");
  match Server_dashboard_http_composite_claims.parse_tool_call_output (`Assoc []) with
  | Server_dashboard_http_composite_claims.Tool_call_output_missing -> ()
  | Server_dashboard_http_composite_claims.Tool_call_output_parse_error _ ->
      fail "missing output must not be parse_error"
  | Server_dashboard_http_composite_claims.Tool_call_output_json _ ->
      fail "missing output must not be parsed JSON"

let test_offline_keeper_composite_exposes_secret_projection () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let keeper_name = "offline-secret-keeper" in
  let sentinel = "ghs_offline_secret_projection_regression" in
  (match
     Masc.Keeper_secret_projection.set_env_entry
       ~base_path:config.base_path
       ~keeper_name
       ~scope:Masc.Keeper_secret_projection.Shared_secret
       ~name:"GH_TOKEN"
       ~value:sentinel
   with
   | Ok () -> ()
   | Error err -> Alcotest.failf "set shared secret failed: %s" err);
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String keeper_name
           ; "agent_name", `String keeper_name
           ; "trace_id", `String "offline-secret-trace"
           ])
    with
    | Ok meta -> { meta with Masc.Keeper_meta_contract.paused = true }
    | Error err -> Alcotest.failf "meta fixture failed: %s" err
  in
  let json =
    Server_dashboard_http_keeper_api.offline_keeper_composite_json
      ~config
      keeper_name
      meta
  in
  let open Yojson.Safe.Util in
  let projection = json |> member "secret_projection" in
  Alcotest.(check string)
    "offline composite includes ready secret projection"
    "ready"
    (projection |> member "status" |> to_string);
  Alcotest.(check (list string))
    "offline composite reports projected env names"
    [ "GH_TOKEN" ]
    (projection |> member "env_names" |> to_list |> List.map to_string);
  Alcotest.(check bool)
    "offline composite redacts secret values"
    false
    (contains_substring (Yojson.Safe.to_string json) sentinel)

let keeper_state_diagram_meta ?last_runtime_attempt_provider name =
  let runtime_attempt_fields =
    match last_runtime_attempt_provider with
    | None -> []
    | Some provider_id ->
      [ ( "last_runtime_attempt"
        , `Assoc
            [ "provider_id", `String provider_id
            ; "http_status", `Int 200
            ; "outcome", `Assoc [ "kind", `String "success" ]
            ; "timestamp", `Float 1_720_000_000.0
            ] )
      ]
  in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         ([ "name", `String name
          ; "agent_name", `String (name ^ "-agent")
          ; "trace_id", `String ("trace-" ^ name)
          ]
          @ runtime_attempt_fields))
  with
  | Ok meta -> meta
  | Error err -> Alcotest.failf "state diagram meta fixture failed: %s" err

let test_state_diagram_runtime_projection_redacts_live_runtime_evidence () =
  let raw_provider = "openai:gpt-5-secret" in
  let projection =
    Server_dashboard_http_keeper_api.state_diagram_runtime_projection
      (Some
         (keeper_state_diagram_meta
            ~last_runtime_attempt_provider:raw_provider
            "state-diagram-runtime"))
  in
  Alcotest.(check (list string))
    "runtime model labels are public redaction labels"
    [ "runtime" ]
    projection.runtime_models;
  Alcotest.(check (option string))
    "last provider result is redacted to the public runtime label"
    (Some "runtime")
    projection.last_provider_result;
  Alcotest.(check string)
    "runtime model source records keeper meta provenance"
    "keeper_meta.runtime.last_runtime_attempt"
    projection.runtime_models_source;
  Alcotest.(check string)
    "last provider source records keeper meta provenance"
    "keeper_meta.runtime.last_runtime_attempt"
    projection.last_provider_result_source;
  let json =
    Server_dashboard_http_keeper_api.state_diagram_runtime_projection_json
      projection
    |> Yojson.Safe.to_string
  in
  Alcotest.(check bool)
    "projection JSON does not leak raw provider id"
    false
    (contains_substring json raw_provider);
  let mermaid =
    Server_dashboard_http_keeper_api.state_diagram_runtime_fsm_mermaid
      projection
  in
  Alcotest.(check bool)
    "runtime FSM contains the redacted runtime node"
    true
    (contains_substring mermaid {|state "runtime" as P0|});
  Alcotest.(check bool)
    "runtime FSM no longer renders fake candidate node"
    false
    (contains_substring mermaid "candidate");
  Alcotest.(check bool)
    "runtime FSM does not leak raw provider id"
    false
    (contains_substring mermaid raw_provider)

let test_state_diagram_runtime_projection_missing_meta_stays_empty () =
  let projection =
    Server_dashboard_http_keeper_api.state_diagram_runtime_projection None
  in
  Alcotest.(check (list string))
    "missing meta exposes no runtime model labels"
    []
    projection.runtime_models;
  Alcotest.(check (option string))
    "missing meta has no last provider result"
    None
    projection.last_provider_result;
  Alcotest.(check string)
    "missing meta source is explicit"
    "missing_keeper_meta"
    projection.runtime_models_source;
  let mermaid =
    Server_dashboard_http_keeper_api.state_diagram_runtime_fsm_mermaid
      projection
  in
  Alcotest.(check bool)
    "missing meta FSM reports zero models"
    true
    (contains_substring mermaid "Models: 0");
  Alcotest.(check bool)
    "missing meta FSM has no fake candidate node"
    false
    (contains_substring mermaid "candidate")

let test_dashboard_shell_separates_configured_and_persisted_keeper_counts () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let config_root =
    Filename.concat
      (Filename.concat config.base_path Common.masc_dirname)
      "config"
  in
  let keepers_dir = Filename.concat config_root "keepers" in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir "base.toml")
    "[keeper]\nautoboot_enabled = false\n";
  write_file
    (Filename.concat keepers_dir "alpha.toml")
    "[keeper]\nautoboot_enabled = true\npersona_name = \"alpha\"\n";
  write_file
    (Filename.concat keepers_dir "beta.toml")
    "[keeper]\nautoboot_enabled = true\npersona_name = \"beta\"\n";
  with_env "MASC_CONFIG_DIR" config_root @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () -> Config_dir_resolver.reset ())
    (fun () ->
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
      in
      let open Yojson.Safe.Util in
      Alcotest.(check int)
        "configured_keepers follows declarative runtime keeper TOML"
        2
        (json |> member "configured_keepers" |> to_int);
      Alcotest.(check int)
        "persisted_keepers exposes durable meta count separately"
        0
        (json |> member "persisted_keepers" |> to_int);
      Alcotest.(check int)
        "counts.persisted_keepers mirrors top-level persisted_keepers"
        0
        (json |> member "counts" |> member "persisted_keepers" |> to_int);
      write_file
        (Filename.concat keepers_dir "base.toml")
        "[keeper]\nautoboot_enabled = true\n";
      Config_dir_resolver.reset ();
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
      in
      Alcotest.(check int)
        "configured_keepers includes explicit autoboot base keeper"
        3
        (json |> member "configured_keepers" |> to_int))

let test_dashboard_shell_surfaces_persisted_keeper_discovery_failure () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  replace_path_with_file
    (Keeper_types_profile.keeper_dir config)
    "not a keeper directory";
  let json = Server_dashboard_http_core.dashboard_shell_http_json ~light:true config in
  let open Yojson.Safe.Util in
  Alcotest.(check int)
    "persisted keeper count remains zero lower bound"
    0
    (json |> member "persisted_keepers" |> to_int);
  Alcotest.(check bool)
    "persisted keeper count marked unknown"
    false
    (json |> member "persisted_keepers_known" |> to_bool);
  Alcotest.(check bool)
    "counts persisted keeper count marked unknown"
    false
    (json |> member "counts" |> member "persisted_keepers_known" |> to_bool);
  Alcotest.(check int)
    "one keeper count read error"
    1
    (json |> member "keeper_count_read_error_count" |> to_int);
  let read_errors = json |> member "keeper_count_read_errors" |> to_list in
  Alcotest.(check int) "read error length" 1 (List.length read_errors);
  match read_errors with
  | [ error ] ->
    Alcotest.(check string)
      "read error source"
      "keeper_names_result"
      (error |> member "source" |> to_string);
    Alcotest.(check bool)
      "read error mentions keepers path"
      true
      (contains_substring (error |> member "message" |> to_string) "keepers")
  | _ -> Alcotest.fail "expected one keeper count read error"

let test_running_keeper_count_scan_surfaces_meta_read_failure () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let keepers_dir = Keeper_types_profile.keeper_dir config in
  mkdir_p keepers_dir;
  write_file (Filename.concat keepers_dir "broken.json") "{not-json";
  let scan = Dashboard_http_keeper.running_keeper_count_scan config in
  Alcotest.(check int)
    "running count remains zero lower bound"
    0
    scan.running_keeper_count;
  Alcotest.(check bool)
    "running count marked unknown"
    false
    scan.running_keeper_count_known;
  Alcotest.(check int)
    "one running count read error"
    1
    (List.length scan.running_keeper_count_read_errors);
  let open Yojson.Safe.Util in
  match scan.running_keeper_count_read_errors with
  | [ error ] ->
    Alcotest.(check string)
      "read error source"
      "read_meta"
      (error |> member "source" |> to_string);
    Alcotest.(check string)
      "read error keeper"
      "broken"
      (error |> member "keeper" |> to_string);
    Alcotest.(check bool)
      "read error message present"
      true
      (String.length (error |> member "message" |> to_string) > 0)
  | _ -> Alcotest.fail "expected one running count read error"

let test_dashboard_shell_light_counts_agents_from_summary_fields () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let write_agent ~name ~agent_type ~status =
    let path =
      Filename.concat (Workspace.agents_dir config) (Workspace.safe_filename name ^ ".json")
    in
    Workspace.write_json
      config
      path
      (`Assoc
        [ "name", `String name
        ; "agent_type", `String agent_type
        ; "status", `String status
        ; "capabilities", `List []
        ; "session_bound_at", `String "2026-05-20T00:00:00Z"
        ; "last_seen", `String "2026-05-20T00:00:00Z"
        ])
  in
  write_agent ~name:"codex-active" ~agent_type:"codex" ~status:"active";
  write_agent ~name:"keeper-active" ~agent_type:"keeper" ~status:"busy";
  write_agent ~name:"codex-inactive" ~agent_type:"codex" ~status:"inactive";
  let json =
    Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int)
    "light shell counts active non-keeper agents from summary fields"
    1
    (json |> member "counts" |> member "agents" |> to_int)

let checkpoint_inventory_meta name trace_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "agent_name", `String name
         ; "trace_id", `String trace_id
         ; "goal", `String "checkpoint inventory test"
         ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta fixture failed: " ^ err)

let test_keeper_checkpoint_inventory_reports_current_read_error () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let keeper_name = "checkpoint-read-error" in
  let trace_id = "trace-checkpoint-read-error" in
  let meta = checkpoint_inventory_meta keeper_name trace_id in
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  mkdir_p session_dir;
  let checkpoint_path =
    Keeper_checkpoint_store.oas_checkpoint_path ~session_dir ~session_id:trace_id
  in
  write_file checkpoint_path "{";
  let status, json =
    Server_dashboard_http_keeper_api_checkpoints.inventory_json config keeper_name
  in
  let open Yojson.Safe.Util in
  check bool "keeper exists" true (status = `OK);
  check string "current status" "read_error" (json |> member "current_status" |> to_string);
  check bool "current is null on read error" true (json |> member "current" = `Null);
  check int "one read error" 1 (json |> member "read_error_count" |> to_int);
  let read_error =
    match json |> member "read_errors" |> to_list with
    | [ row ] -> row
    | rows -> fail (Printf.sprintf "expected one read error, got %d" (List.length rows))
  in
  check string
    "read error source"
    "oas_current"
    (read_error |> member "source_kind" |> to_string);
  check string
    "read error snapshot"
    (Filename.basename checkpoint_path)
    (read_error |> member "snapshot_id" |> to_string);
  check string
    "read error path"
    checkpoint_path
    (read_error |> member "path" |> to_string)

(* RFC-0138 Phase 3 Step 2 — /tools and /telemetry/summary wire tests.

   Cover the new selector matrix on
   [Server_dashboard_snapshot_select.select_tools_json] and
   [..._telemetry_summary_json]. *)

let test_tools_snapshot_wire_returns_snapshot_when_actor_omitted () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let marker = `Assoc [ "tools_marker", `String "from-snapshot" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:marker
       ~namespace_truth:`Null ~telemetry_summary:`Null ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_tools_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "actor-less snapshot path returns published marker"
    "from-snapshot"
    (json |> member "tools_marker" |> to_string);
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let header = Server_timing.to_header_value timing in
     let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

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
  Dashboard_snapshot.reset_for_test ();
  let marker = `Assoc [ "tele_marker", `String "from-snapshot" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:marker ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_telemetry_summary_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "telemetry_summary snapshot path returns published marker"
    "from-snapshot"
    (json |> member "tele_marker" |> to_string);
  Dashboard_snapshot.reset_for_test ()

let test_telemetry_summary_snapshot_wire_falls_back_when_empty () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_telemetry_summary_json
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
  Dashboard_snapshot.reset_for_test ();
  let marker =
    `Assoc [ "namespace_truth_marker", `String "from-snapshot" ]
  in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:`Null
       ~namespace_truth:marker ~telemetry_summary:`Null ());
  let clock = Eio.Stdenv.clock env in
  let state = Lib.Mcp_server.create_state ~base_path:"/tmp/rfc-0138-step3" in
  let req = request "/api/v1/dashboard/project-snapshot" in
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_project_snapshot_json
      ~state ~sw ~clock ~timing req
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "populated snapshot path returns published marker"
    "from-snapshot"
    (json |> member "namespace_truth_marker" |> to_string);
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let header = Server_timing.to_header_value timing in
     let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

let assoc_has key = function
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false

let test_dashboard_bootstrap_omits_eager_goal_tree () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state = Lib.Mcp_server.create_state ~base_path:config.base_path in
  let clock = Eio.Stdenv.clock env in
  let req = request "/api/v1/dashboard/bootstrap" in
  let json = Server_dashboard_http.dashboard_bootstrap_http_json ~state ~sw ~clock req in
  Alcotest.(check bool) "bootstrap includes shell" true (assoc_has "shell" json);
  Alcotest.(check bool) "bootstrap includes execution" true
    (assoc_has "execution" json);
  Alcotest.(check bool) "bootstrap includes planning" true
    (assoc_has "planning" json);
  Alcotest.(check bool) "bootstrap includes namespace truth" true
    (assoc_has "namespace_truth" json);
  Alcotest.(check bool) "bootstrap includes goal-loop status" true
    (assoc_has "goal_loop_status" json);
  Alcotest.(check bool) "bootstrap omits eager goal tree" false
    (assoc_has "goals" json)

(* Freeze guard: /api/v1/dashboard/telemetry must never default to an
   unbounded read. Observatory polls with since_ms/until_ms and no [n];
   before this fix the windowed default was n=0 (unbounded), letting one
   poll Yojson-parse up to the read clamp (#20659: 50k) per source across
   all sources and peg the single Eio domain -> keeper-fleet freeze. *)
let test_telemetry_n_default_is_bounded () =
  let resolve = Server_routes_http_routes_dashboard_setup.resolve_telemetry_n in
  Alcotest.(check int)
    "windowed + no n -> bounded default, never 0"
    2000 (resolve ~has_time_window:true ~n_param:None);
  Alcotest.(check int)
    "no window + no n -> small default"
    100 (resolve ~has_time_window:false ~n_param:None);
  Alcotest.(check int)
    "unparseable n -> bounded default, never 0"
    2000 (resolve ~has_time_window:true ~n_param:(Some "garbage"));
  (* #20659 all-in-window contract: explicit n=0 is honoured (clamped
     downstream), so an operator can still request the full window. *)
  Alcotest.(check int)
    "explicit n=0 preserved"
    0 (resolve ~has_time_window:true ~n_param:(Some "0"));
  Alcotest.(check int)
    "explicit positive n honoured"
    500 (resolve ~has_time_window:true ~n_param:(Some "500"))

(* Issue #22071: lifecycle event classification was reverse-mapped by a raw
   string whitelist that bypassed compiler exhaustiveness, and the module
   docstrings cited coverage tests ([lifecycle_events_ssot] /
   [lifecycle_event_cache_patcher_coverage]) in a test/test_types.ml that does
   not exist. These are the real guards. *)
let test_lifecycle_event_of_string_roundtrip () =
  List.iter
    (fun verb ->
      let s = Keeper_lifecycle_events.to_string verb in
      check bool
        ("event_of_string round-trips " ^ s)
        true
        (match Keeper_lifecycle_events.event_of_string s with
         | Some v -> String.equal (Keeper_lifecycle_events.to_string v) s
         | None -> false))
    Keeper_lifecycle_events.all_custom_events;
  check bool "unknown lifecycle event string is None" true
    (Option.is_none
       (Keeper_lifecycle_events.event_of_string "no_such_lifecycle_event"));
  List.iter
    (fun verb ->
      check bool
        ("legacy phase/operator event is not a custom verb: " ^ verb)
        true
        (Option.is_none (Keeper_lifecycle_events.event_of_string verb)))
    [ "running"; "stopped"; "crashed"; "dead"; "paused"; "resumed" ]

let test_lifecycle_event_cache_patcher_coverage () =
  (* Every name in the SSOT vocabulary must be classified ([Some]) by all four
     dashboard cache patchers — the coverage the phantom test only promised. The
     custom-event subset is also compiler-enforced via [display_of_custom_event]. *)
  List.iter
    (fun name ->
      check bool
        ("keepalive_running classifies " ^ name)
        true
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.keepalive_running_of_lifecycle_event
              name));
      check bool
        ("phase classifies " ^ name)
        true
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.phase_of_lifecycle_event name));
      check bool
        ("pipeline_stage classifies " ^ name)
        true
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.pipeline_stage_of_lifecycle_event
              name));
      check bool
        ("paused classifies " ^ name)
        true
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.paused_of_lifecycle_event name)))
    Keeper_lifecycle_events.all_event_names

let test_lifecycle_event_display_values () =
  (* Pin the exact (keepalive_running, phase, pipeline_stage, paused) projection
     for every lifecycle event string — including the legacy operator strings
     [paused] / [resumed] that are outside [all_event_names]. This locks the
     byte-identity the refactor preserves: a value drift in
     [display_of_custom_event] or [display_of_phase_or_legacy_string] now fails
     here instead of silently changing a dashboard row (the coverage test above
     only asserts [Some], not the value). *)
  let cases =
    [ ("started", true, "running", "idle", false);
      ("restarted", true, "running", "idle", false);
      ("reconciled", true, "running", "idle", false);
      ("self_preservation", true, "running", "idle", false);
      ("auto_resumed", true, "running", "idle", false);
      ("running", true, "running", "idle", false);
      ("resumed", true, "running", "idle", false);
      ("paused", true, "paused", "paused", true);
      ("paused_pruned", false, "stopped", "offline", true);
      ("admission_denied", false, "offline", "offline", false);
      ("dead_cleaned", false, "dead", "offline", false);
      ("stopped", false, "stopped", "offline", true);
      ("crashed", false, "crashed", "crashed", false);
      ("dead", false, "dead", "offline", false);
    ]
  in
  List.iter
    (fun (name, keepalive, phase, pipeline, paused) ->
      check (option bool)
        ("keepalive_running value for " ^ name)
        (Some keepalive)
        (Server_dashboard_http_execution_surfaces.keepalive_running_of_lifecycle_event
           name);
      check (option string)
        ("phase value for " ^ name)
        (Some phase)
        (Server_dashboard_http_execution_surfaces.phase_of_lifecycle_event name);
      check (option string)
        ("pipeline_stage value for " ^ name)
        (Some pipeline)
        (Server_dashboard_http_execution_surfaces.pipeline_stage_of_lifecycle_event
           name);
      check (option bool)
        ("paused value for " ^ name)
        (Some paused)
        (Server_dashboard_http_execution_surfaces.paused_of_lifecycle_event name))
    cases

let () =
  run "dashboard_http_core"
    [
      ( "executor_pool",
        [
          test_case "no pool stays on caller domain" `Quick
            test_run_dashboard_compute_without_pool_stays_in_current_domain;
          test_case "pool uses executor domain" `Quick
            test_run_dashboard_compute_with_pool_uses_executor_domain;
          test_case "meta-cognition cold worker skips root switch" `Quick
            test_meta_cognition_cold_cache_worker_domain_skips_root_switch;
          test_case "shell payload includes paths diagnostics" `Quick
            test_dashboard_shell_http_json_includes_paths;
          test_case "shell runtime base_path prefers preserved input" `Quick
            test_dashboard_shell_http_json_prefers_preserved_base_path_input;
          test_case "runtime resolution accepts server repo under base path" `Quick
            test_runtime_resolution_accepts_server_repo_inside_base_path;
          test_case "shell bootstrap payload while prewarming" `Quick
            test_dashboard_shell_http_json_uses_bootstrap_payload_while_prewarming;
          test_case "shell reuses last good payload while prewarming" `Quick
            test_dashboard_shell_http_json_prefers_last_good_while_prewarming;
          test_case "shell records light last good payload" `Quick
            test_dashboard_shell_http_json_records_light_last_good;
          test_case "shell reuses light last good payload while prewarming" `Quick
            test_dashboard_shell_http_json_prefers_light_last_good_while_prewarming;
          test_case "operator snapshot hydrates on first default request" `Quick
            test_operator_snapshot_default_route_hydrates_first_success;
          test_case "dashboard query cache segment normalizes missing values" `Quick
            test_dashboard_query_cache_segment_normalizes_missing_values;
          test_case "dashboard query cache key partitions route params" `Quick
            test_dashboard_query_cache_key_partitions_route_params;
          test_case "dashboard query cache key encodes delimiter values" `Quick
            test_dashboard_query_cache_key_encodes_delimiter_values;
          test_case "operator snapshot default route exposes provenance" `Quick
            test_operator_snapshot_default_route_exposes_provenance;
          test_case "operator digest default route exposes provenance" `Quick
            test_operator_digest_default_route_exposes_provenance;
          test_case "shell timeout fallback reports timing context" `Quick
            test_dashboard_shell_timeout_fallback_reports_timing_context;
          test_case "proof payload exposes verification index" `Quick
            test_dashboard_proof_http_json_surfaces_verification_index;
          test_case "proof route registered in HTTP routers" `Quick
            test_dashboard_proof_route_registered_in_http_routers;
          test_case "IDE snapshot exposes legacy partition metadata" `Quick
            test_dashboard_ide_snapshot_json_surfaces_legacy_partition_metadata;
          test_case "bootstrap omits eager goal tree" `Quick
            test_dashboard_bootstrap_omits_eager_goal_tree;
          test_case "planning payload keeps UTF-8 valid after truncation" `Quick
            test_dashboard_planning_http_json_keeps_utf8_valid_after_truncation;
          test_case "planning payload reports goal store read failure" `Quick
            test_dashboard_planning_http_json_reports_goal_store_read_failure;
          test_case "keeper config reports goal store read failure" `Quick
            test_keeper_config_json_reports_goal_store_read_failure;
          test_case "keeper dashboard reports active goal store read failure" `Quick
            test_keeper_dashboard_json_reports_active_goal_store_read_failure;
          test_case "execution patch reports keeper-name discovery failure" `Quick
            test_dashboard_execution_running_keeper_scan_reports_keeper_name_failure;
          test_case "execution patch reports keeper meta read failure" `Quick
            test_dashboard_execution_running_keeper_scan_reports_meta_read_failure;
          test_case "shell auth canonicalizes token owner" `Quick
            test_dashboard_shell_auth_json_canonicalizes_token_owner;
          test_case "shell auth reports missing token" `Quick
            test_dashboard_shell_auth_json_reports_missing_token;
          test_case "shell auth rejects stale token actor hint" `Quick
            test_dashboard_shell_auth_json_rejects_stale_token_actor_hint;
          test_case "shell snapshot selector injects auth" `Quick
            test_dashboard_shell_snapshot_selector_injects_auth;
          test_case "execution actor canonicalizes token owner" `Quick
            test_execution_actor_for_request_canonicalizes_token_owner;
          test_case "execution force refresh bypasses default cache" `Quick
            test_dashboard_execution_force_refresh_bypasses_default_cache;
          test_case "execution trust default route uses cached surface" `Quick
            test_dashboard_execution_trust_default_route_uses_cached_surface;
          test_case "verification verifier canonicalizes token owner" `Quick
            test_verifier_of_request_canonicalizes_token_owner;
          test_case "message JSON exposes temporal decay fields" `Quick
            test_dashboard_message_json_surfaces_temporal_decay_fields;
          test_case "RFC-0138 shell wire returns snapshot when published" `Quick
            test_shell_snapshot_wire_returns_snapshot_when_published;
          test_case "RFC-0138 shell wire falls back when snapshot empty" `Quick
            test_shell_snapshot_wire_falls_back_when_empty;
          test_case "RFC-0204 shell wire light reads shell_light" `Quick
            test_shell_snapshot_wire_light_reads_shell_light;
          test_case "light shell carries runtime health SSOT" `Quick
            test_dashboard_shell_light_includes_runtime_health_ssot;
          test_case "shell separates configured and persisted keeper counts" `Quick
            test_dashboard_shell_separates_configured_and_persisted_keeper_counts;
          test_case "shell surfaces persisted keeper discovery failure" `Quick
            test_dashboard_shell_surfaces_persisted_keeper_discovery_failure;
          test_case "running keeper count scan surfaces meta read failure" `Quick
            test_running_keeper_count_scan_surfaces_meta_read_failure;
          test_case "light shell counts agents from summary fields" `Quick
            test_dashboard_shell_light_counts_agents_from_summary_fields;
          test_case "checkpoint inventory reports current read error" `Quick
            test_keeper_checkpoint_inventory_reports_current_read_error;
          test_case "runtime trace receipt reader surfaces parse errors" `Quick
            test_runtime_trace_receipt_reader_surfaces_parse_errors;
          test_case "bulk wakeup result surfaces meta read errors" `Quick
            test_bulk_wakeup_result_surfaces_meta_read_error;
          test_case "RFC-0138 tools wire returns snapshot when actor omitted" `Quick
            test_tools_snapshot_wire_returns_snapshot_when_actor_omitted;
          test_case "RFC-0138 telemetry_summary wire returns snapshot" `Quick
            test_telemetry_summary_snapshot_wire_returns_snapshot;
          test_case "RFC-0138 telemetry_summary wire falls back when empty" `Quick
            test_telemetry_summary_snapshot_wire_falls_back_when_empty;
          test_case "RFC-0138 project-snapshot wire returns snapshot when populated" `Quick
            test_project_snapshot_wire_returns_snapshot_when_populated;
          test_case "telemetry n default is bounded (freeze guard)" `Quick
            test_telemetry_n_default_is_bounded;
          test_case "fleet-composite envelope is cached across polls" `Quick
            test_dashboard_fleet_composite_envelope_is_cached;
          test_case "composite claim output parse failure is typed" `Quick
            test_composite_tool_call_output_parse_failure_is_typed;
          test_case "offline keeper composite exposes secret projection" `Quick
            test_offline_keeper_composite_exposes_secret_projection;
          test_case "state diagram runtime projection redacts live evidence" `Quick
            test_state_diagram_runtime_projection_redacts_live_runtime_evidence;
          test_case "state diagram runtime projection stays empty without meta" `Quick
            test_state_diagram_runtime_projection_missing_meta_stays_empty;
          test_case "keeper catch-up judge route is classified" `Quick
            test_keeper_post_route_classifies_catchup_judge;
        ] );
      ( "lifecycle event classification (#22071)",
        [ test_case "event_of_string round-trips to_string" `Quick
            test_lifecycle_event_of_string_roundtrip;
          test_case "cache patchers cover the SSOT vocabulary" `Quick
            test_lifecycle_event_cache_patcher_coverage;
          test_case "cache patchers pin byte-identical values" `Quick
            test_lifecycle_event_display_values;
        ] );
    ]
