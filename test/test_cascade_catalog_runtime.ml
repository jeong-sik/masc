open Alcotest
open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  loop 0

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_config_dir config_dir f =
  let reset () =
    Config_dir_resolver.reset ();
    Cascade_catalog_runtime.reset_cache_for_tests ()
  in
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  reset ();
  Fun.protect ~finally:reset f

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.clear_fs ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  f
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~fs:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)

let init_config_root config_dir =
  mkdir_p (Filename.concat config_dir "prompts");
  mkdir_p (Filename.concat config_dir "keepers");
  mkdir_p (Filename.concat config_dir "personas")

let last_touch = ref 0.0

let bump_mtime path =
  let now = Unix.gettimeofday () +. 1.0 in
  let stamp = Float.max now (!last_touch +. 1.0) in
  last_touch := stamp;
  Unix.utimes path stamp stamp

let write_cascade_json config_dir content =
  let path = Filename.concat config_dir "cascade.json" in
  write_file path content;
  bump_mtime path;
  path

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | _ -> fail "unexpected socket address")

let openai_text_response ?(id = "chatcmpl-1") text =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}|}
    id text

let start_counting_mock ~sw ~net ~port ~response =
  let request_count = Atomic.make 0 in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    ignore (Atomic.fetch_and_add request_count 1);
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  (Printf.sprintf "http://127.0.0.1:%d" port, request_count)

let dummy_base_url = "http://127.0.0.1:1"

let json_member name json = Yojson.Safe.Util.member name json

let json_string_field name json =
  match json_member name json with
  | `String value -> value
  | other ->
      failf "expected %s to be a string, got %s"
        name (Yojson.Safe.to_string other)

let json_int_field name json =
  match json_member name json with
  | `Int value -> value
  | other ->
      failf "expected %s to be an int, got %s"
        name (Yojson.Safe.to_string other)

let json_list_field name json =
  match json_member name json with
  | `List values -> values
  | other ->
      failf "expected %s to be a list, got %s"
        name (Yojson.Safe.to_string other)

let require_ok = function
  | Ok value -> value
  | Error detail -> failf "expected Ok, got Error: %s" detail

let provider_kinds providers =
  List.map
    (fun (cfg : Llm_provider.Provider_config.t) ->
      Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    providers

let provider_supports_required_tool_use (cfg : Llm_provider.Provider_config.t) =
  let registry = Llm_provider.Provider_registry.default () in
  let provider_name =
    Llm_provider.Provider_registry.provider_name_of_config cfg
  in
  let caps =
    match Llm_provider.Provider_registry.find registry provider_name with
    | Some entry -> entry.capabilities
    | None -> Llm_provider.Capabilities.default_capabilities
  in
  let caps =
    match cfg.supports_tool_choice_override with
    | Some supports_tool_choice -> { caps with supports_tool_choice }
    | None -> caps
  in
  caps.supports_tools && caps.supports_tool_choice

let provider_supports_callable_tool_use (cfg : Llm_provider.Provider_config.t) =
  let registry = Llm_provider.Provider_registry.default () in
  let provider_name =
    Llm_provider.Provider_registry.provider_name_of_config cfg
  in
  let caps =
    match Llm_provider.Provider_registry.find registry provider_name with
    | Some entry -> entry.capabilities
    | None -> Llm_provider.Capabilities.default_capabilities
  in
  caps.supports_tools
  || (caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events)

let test_valid_catalog_skips_live_probes_at_bootstrap () =
  with_temp_dir "cascade-catalog-runtime" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let shared_model = Printf.sprintf "custom:mock@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "keeper_unified_models": ["%s"],
  "tool_rerank_models": ["%s"]
}|}
          shared_model shared_model));
  let snapshot =
    match Cascade_catalog_runtime.inspect_active () with
    | Ok (Cascade_catalog_runtime.Validated snapshot) -> snapshot
    | Ok (Cascade_catalog_runtime.Validated_with_rejections _) ->
        fail "expected fully validated snapshot without rejected profiles"
    | Ok (Cascade_catalog_runtime.Serving_last_known_good _) ->
        fail "expected a freshly validated snapshot"
    | Error rejection ->
        failf "unexpected validation rejection: %s"
          (Yojson.Safe.to_string
             (Cascade_catalog_runtime.rejection_to_yojson rejection))
  in
  let snapshot_json = Cascade_catalog_runtime.snapshot_to_yojson snapshot in
  check int "profile_count" 2 (json_int_field "profile_count" snapshot_json);
  check bool "bootstrap probe status is skipped" true
    (contains_substring (Yojson.Safe.to_string snapshot_json) "\"status\":\"skipped\"");
  let blank_name =
    require_ok
      (Cascade_catalog_runtime.resolve_declared_name ~raw_name:"" ())
  in
  check string "blank name defaults to keeper_unified"
    Keeper_config.default_cascade_name blank_name;
  match
    Cascade_catalog_runtime.resolve_declared_name ~raw_name:"missing_profile" ()
  with
  | Ok resolved ->
      failf "expected missing profile to be rejected, got %s" resolved
  | Error detail ->
      check bool "unknown cascade_name is surfaced" true
        (contains_substring detail "unknown cascade_name");
      check bool "active profile list is included" true
        (contains_substring detail "tool_rerank")

let test_invalid_hot_reload_preserves_last_known_good () =
  with_temp_dir "cascade-catalog-lkg" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let valid_model = Printf.sprintf "custom:stable@%s/v1" dummy_base_url in
  let config_path =
    write_cascade_json config_dir
      (Printf.sprintf
         {|{
  "keeper_unified_models": ["%s"]
}|}
         valid_model)
  in
  (match Cascade_catalog_runtime.inspect_active () with
   | Ok (Cascade_catalog_runtime.Validated _) -> ()
   | Ok (Cascade_catalog_runtime.Validated_with_rejections _) ->
       fail "expected the initial snapshot to validate cleanly"
   | Ok (Cascade_catalog_runtime.Serving_last_known_good _) ->
       fail "expected the initial snapshot to validate cleanly"
   | Error rejection ->
       failf "initial validation failed: %s"
         (Yojson.Safe.to_string
            (Cascade_catalog_runtime.rejection_to_yojson rejection)));
  ignore
    (write_cascade_json config_dir
       {|{
  "keeper_unified_models": ["__nonexistent_provider_sentinel__:fake"]
}|});
  match Cascade_catalog_runtime.inspect_active () with
  | Ok
      (Cascade_catalog_runtime.Serving_last_known_good
         { snapshot; rejected_update }) ->
      let served_json = Cascade_catalog_runtime.snapshot_to_yojson snapshot in
      check string "last-known-good source path"
        config_path (json_string_field "source_path" served_json);
      let labels =
        require_ok
          (Cascade_catalog_runtime.models_of_cascade_name "keeper_unified")
      in
      check (list string) "served snapshot keeps prior model" [ valid_model ] labels;
      let rejection_json =
        Cascade_catalog_runtime.rejection_to_yojson rejected_update
        |> Yojson.Safe.to_string
      in
      check bool "rejection mentions invalid candidate" true
        (contains_substring rejection_json "__nonexistent_provider_sentinel__")
  | Ok (Cascade_catalog_runtime.Validated _) ->
      fail "expected invalid hot reload to be rejected"
  | Ok (Cascade_catalog_runtime.Validated_with_rejections _) ->
      fail "expected invalid hot reload to use last-known-good"
  | Error rejection ->
      failf "expected last-known-good fallback, got hard error: %s"
        (Yojson.Safe.to_string
           (Cascade_catalog_runtime.rejection_to_yojson rejection))

let test_legacy_runtime_wrapper_does_not_fallback_to_defaults () =
  with_temp_dir "cascade-runtime-wrapper" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let valid_model = Printf.sprintf "custom:stable@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "keeper_unified_models": ["%s"]
}|}
          valid_model));
  ignore (Cascade_catalog_runtime.inspect_active ());
  check (list string) "legacy wrapper still resolves known profile"
    [ valid_model ]
    (Cascade_runtime.models_of_cascade_name Keeper_config.default_cascade_name);
  check (list string) "unknown profile no longer falls back to defaults"
    []
    (Cascade_runtime.models_of_cascade_name "missing_profile")

let test_legacy_runtime_wrapper_preserves_configured_label_order () =
  with_temp_dir "cascade-runtime-order" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  with_eio @@ fun ~sw ~net ~clock ~fs:_ ~proc_mgr:_ ->
  let port = find_free_port () in
  let base_url, _request_count =
    start_counting_mock ~sw ~net ~port
      ~response:(openai_text_response "pong")
  in
  let alpha_model = Printf.sprintf "custom:alpha@%s/v1" base_url in
  let beta_model = Printf.sprintf "custom:beta@%s/v1" base_url in
  let gamma_model = Printf.sprintf "custom:gamma@%s/v1" base_url in
  let expected = [ alpha_model; beta_model; gamma_model ] in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "keeper_unified_models": [
    {"model": "%s", "weight": 2},
    {"model": "%s", "weight": 2},
    {"model": "%s", "weight": 2}
  ]
}|}
          alpha_model beta_model gamma_model));
  ignore (Cascade_catalog_runtime.inspect_active ~sw ~net ~clock ());
  let observed_orders =
    List.init 8 (fun _ ->
        Cascade_runtime.models_of_cascade_name Keeper_config.default_cascade_name)
  in
  check (list string) "legacy wrapper keeps configured order" expected
    (List.hd observed_orders);
  check int "legacy wrapper order is stable across calls" 1
    (observed_orders
    |> List.map (String.concat "\n")
    |> List.sort_uniq String.compare
    |> List.length)

let test_partial_catalog_keeps_validated_subset_available () =
  with_temp_dir "dashboard-cascade-profiles" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let valid_model = Printf.sprintf "custom:stable@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "keeper_unified_models": ["%s"],
  "tool_rerank_models": ["%s"],
  "broken_profile_models": ["__nonexistent_provider_sentinel__:fake"]
}|}
          valid_model valid_model));
  let rejection_json =
    match Cascade_catalog_runtime.inspect_active () with
    | Ok
        (Cascade_catalog_runtime.Validated_with_rejections
           { rejected_update; _ }) ->
        Cascade_catalog_runtime.rejection_to_yojson rejected_update
        |> Yojson.Safe.to_string
    | Ok (Cascade_catalog_runtime.Validated _) ->
        fail "expected mixed catalog to keep only the validated subset"
    | Ok (Cascade_catalog_runtime.Serving_last_known_good _) ->
        fail "expected direct validation against the current file"
    | Error rejection ->
        failf "expected partial validation, got hard error: %s"
          (Yojson.Safe.to_string
             (Cascade_catalog_runtime.rejection_to_yojson rejection))
  in
  check bool "rejected invalid candidate is surfaced" true
    (contains_substring rejection_json
       "__nonexistent_provider_sentinel__:fake");
  check (list string) "dashboard only advertises validated profiles"
    [ Keeper_config.default_cascade_name; "tool_rerank" ]
    (Masc_mcp.Server_routes_http_routes_dashboard.available_cascade_profiles ());
  let config_json = Masc_mcp.Dashboard_cascade.config_json () in
  let profile_names =
    json_list_field "profiles" config_json
    |> List.map (json_string_field "name")
  in
  check (list string) "dashboard config_json only renders validated profiles"
    [ Keeper_config.default_cascade_name; "tool_rerank" ]
    profile_names;
  check bool "dashboard config_json keeps rejected profile metadata" true
    (contains_substring (Yojson.Safe.to_string config_json) "broken_profile")

let test_partial_catalog_rejects_invalid_default_profile () =
  with_temp_dir "dashboard-cascade-default-gate" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  with_eio @@ fun ~sw ~net ~clock ~fs:_ ~proc_mgr:_ ->
  let port = find_free_port () in
  let base_url, _request_count =
    start_counting_mock ~sw ~net ~port
      ~response:(openai_text_response "pong")
  in
  let valid_model = Printf.sprintf "custom:stable@%s/v1" base_url in
  match
    ignore
      (write_cascade_json config_dir
         (Printf.sprintf
            {|{
  "keeper_unified_models": ["__nonexistent_provider_sentinel__:fake"],
  "tool_rerank_models": ["%s"]
}|}
            valid_model));
    Cascade_catalog_runtime.inspect_active ~sw ~net ~clock ()
  with
  | Error rejection ->
      let rejection_json =
        Cascade_catalog_runtime.rejection_to_yojson rejection
      in
      let errors = json_list_field "errors" rejection_json in
      check bool "default-profile gate is surfaced" true
        (List.exists
           (function
             | `String value ->
                 contains_substring value
                   "required default profile \"keeper_unified\" failed validation"
             | _ -> false)
           errors);
      check bool "rejected default profile invalid candidate is surfaced" true
        (contains_substring (Yojson.Safe.to_string rejection_json)
           "__nonexistent_provider_sentinel__:fake")
  | Ok (Cascade_catalog_runtime.Validated _) ->
      fail "expected invalid default profile to hard-fail validation"
  | Ok (Cascade_catalog_runtime.Validated_with_rejections _) ->
      fail "expected invalid default profile to be rejected, not partially validated"
  | Ok (Cascade_catalog_runtime.Serving_last_known_good _) ->
      fail "expected direct validation against the current file"

let test_resolve_named_providers_tool_choice_filters_runtime_only_providers () =
  with_temp_dir "cascade-catalog-tool-choice" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  ignore
    (write_cascade_json config_dir
       {|{
  "keeper_unified_models": [
    "custom:remote-model@http://127.0.0.1:18080/v1",
    "codex_cli:auto",
    "gemini_cli:auto",
    "ollama:local-model"
  ]
}|});
  let providers =
    require_ok
      (Cascade_catalog_runtime.resolve_named_providers
         ~require_tool_choice_support:true
         ~cascade_name:Keeper_config.default_cascade_name
         ())
  in
  check bool "every surviving provider supports inline tool choice" true
    (List.for_all provider_supports_required_tool_use providers);
  check bool "drops codex_cli without inline tool choice" false
    (List.mem "codex_cli" (provider_kinds providers));
  check bool "drops gemini_cli without inline tool choice" false
    (List.mem "gemini_cli" (provider_kinds providers))

let test_resolve_named_providers_tool_support_keeps_runtime_mcp_providers () =
  with_temp_dir "cascade-catalog-tool-support" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  ignore
    (write_cascade_json config_dir
       {|{
  "keeper_unified_models": [
    "custom:remote-model@http://127.0.0.1:18080/v1",
    "claude_code:auto",
    "codex_cli:auto",
    "gemini_cli:auto",
    "ollama:local-model"
  ]
}|});
  let providers =
    require_ok
      (Cascade_catalog_runtime.resolve_named_providers
         ~require_tool_support:true
         ~cascade_name:Keeper_config.default_cascade_name
         ())
  in
  check bool "tool-support path keeps at least one callable provider" true
    (providers <> []);
  check bool "every surviving provider supports inline or runtime MCP tools" true
    (List.for_all provider_supports_callable_tool_use providers);
  check bool "keeps codex_cli via runtime MCP lane" true
    (List.mem "codex_cli" (provider_kinds providers));
  check bool "drops gemini_cli without runtime MCP lane" false
    (List.mem "gemini_cli" (provider_kinds providers))

let test_config_doctor_live_reports_catalog_validation () =
  with_temp_dir "cascade-doctor-live" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_dir = Filename.concat base_path ".masc/config" in
  init_config_root config_dir;
  ignore
    (write_cascade_json config_dir
       {|{
  "keeper_unified_models": ["__nonexistent_provider_sentinel__:fake"]
}|});
  with_config_dir config_dir @@ fun () ->
  with_eio @@ fun ~sw ~net ~clock ~fs ~proc_mgr ->
  let report =
    Config_doctor.analyze_live
      ~sw ~net ~clock ~fs ~proc_mgr
      ~base_path_input:base_path
      ~default_base_path:base_path
      ()
  in
  check string "live doctor status" "error"
    (Config_doctor.status_to_string report.status);
  match report.catalog_validation with
  | None -> fail "expected catalog_validation output from analyze_live"
  | Some json ->
      check string "catalog validation status" "invalid"
        (json_string_field "status" json);
      check bool "live warning present" true
        (List.exists
           (fun warning ->
             contains_substring warning "Live cascade catalog validation failed")
           report.warnings);
      check bool "invalid provider is surfaced" true
        (contains_substring (Yojson.Safe.to_string json)
           "__nonexistent_provider_sentinel__")

let test_config_doctor_live_warns_on_partial_catalog_validation () =
  with_temp_dir "cascade-doctor-live-partial" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_dir = Filename.concat base_path ".masc/config" in
  init_config_root config_dir;
  with_eio @@ fun ~sw ~net ~clock ~fs ~proc_mgr ->
  let port = find_free_port () in
  let base_url, _request_count =
    start_counting_mock ~sw ~net ~port
      ~response:(openai_text_response "pong")
  in
  let valid_model = Printf.sprintf "custom:stable@%s/v1" base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "keeper_unified_models": ["%s"],
  "broken_profile_models": ["__nonexistent_provider_sentinel__:fake"]
}|}
          valid_model));
  with_config_dir config_dir @@ fun () ->
  let report =
    Config_doctor.analyze_live
      ~sw ~net ~clock ~fs ~proc_mgr
      ~base_path_input:base_path
      ~default_base_path:base_path
      ()
  in
  check string "live doctor partial status" "warn"
    (Config_doctor.status_to_string report.status);
  check bool "live partial warning present" true
    (List.exists
       (fun warning ->
          contains_substring warning
            "kept the usable profile subset and rejected some presets")
       report.warnings);
  match report.catalog_validation with
  | None -> fail "expected catalog_validation output from analyze_live"
  | Some json ->
      check string "partial catalog validation status" "validated"
        (json_string_field "status" json);
      check bool "rejected profile is surfaced in live doctor json" true
        (contains_substring (Yojson.Safe.to_string json)
           "__nonexistent_provider_sentinel__:fake")

let () =
  run "cascade_catalog_runtime"
    [
      ( "runtime",
        [
          test_case
            "valid catalog skips live probes at bootstrap"
            `Quick
            test_valid_catalog_skips_live_probes_at_bootstrap;
          test_case
            "invalid hot reload preserves last-known-good"
            `Quick
            test_invalid_hot_reload_preserves_last_known_good;
          test_case
            "legacy runtime wrapper does not fallback to defaults"
            `Quick
            test_legacy_runtime_wrapper_does_not_fallback_to_defaults;
          test_case
            "legacy runtime wrapper preserves configured label order"
            `Quick
            test_legacy_runtime_wrapper_preserves_configured_label_order;
          test_case
            "partial catalog keeps validated subset available"
            `Quick
            test_partial_catalog_keeps_validated_subset_available;
          test_case
            "partial catalog rejects invalid default profile"
            `Quick
            test_partial_catalog_rejects_invalid_default_profile;
          test_case
            "resolve_named_providers tool choice drops runtime-only providers"
            `Quick
            test_resolve_named_providers_tool_choice_filters_runtime_only_providers;
          test_case
            "resolve_named_providers tool support keeps runtime MCP providers"
            `Quick
            test_resolve_named_providers_tool_support_keeps_runtime_mcp_providers;
          test_case
            "config doctor live reports catalog validation"
            `Quick
            test_config_doctor_live_reports_catalog_validation;
          test_case
            "config doctor live warns on partial catalog validation"
            `Quick
            test_config_doctor_live_warns_on_partial_catalog_validation;
        ] );
    ]
