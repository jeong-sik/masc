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

let capture_stderr f =
  let pipe_read, pipe_write = Unix.pipe () in
  let saved_stderr = Unix.dup Unix.stderr in
  Unix.dup2 pipe_write Unix.stderr;
  Unix.close pipe_write;
  let result =
    try
      f ();
      Ok ()
    with exn ->
      Error (exn, Printexc.get_raw_backtrace ())
  in
  flush stderr;
  Unix.dup2 saved_stderr Unix.stderr;
  Unix.close saved_stderr;
  Unix.set_nonblock pipe_read;
  let buf = Buffer.create 256 in
  let tmp = Bytes.create 256 in
  let rec read_all () =
    match Unix.read pipe_read tmp 0 (Bytes.length tmp) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf tmp 0 n;
        read_all ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
  in
  read_all ();
  Unix.close pipe_read;
  let output = Buffer.contents buf in
  match result with
  | Ok () -> output
  | Error (exn, bt) -> Printexc.raise_with_backtrace exn bt

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
  let caps = Oas_worker_exec.provider_caps_of_config cfg in
  caps.supports_tools && caps.supports_tool_choice

let provider_supports_callable_tool_use (cfg : Llm_provider.Provider_config.t) =
  let caps = Oas_worker_exec.provider_caps_of_config cfg in
  caps.supports_tools
  || (caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events)

let runtime_mcp_policy_with_headers =
  {
    Llm_provider.Llm_transport.empty_runtime_mcp_policy with
    servers =
      [
        Llm_provider.Llm_transport.Http_server
          {
            name = "masc";
            url = "http://127.0.0.1:8935/mcp";
            headers = [ ("x-masc-agent-name", "keeper-sangsu-agent") ];
          };
      ];
    allowed_server_names = [ "masc" ];
    allowed_tool_names = [ "masc_status" ];
    strict = true;
    disable_builtin_tools = true;
  }

let test_route_validation_rejects_unknown_route_key () =
  with_temp_dir "cascade-routes-unknown-key" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let model = Printf.sprintf "custom:stable@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "routes": {
    "keeper_turn": "big_three",
    "governance_jduge": "big_three"
  },
  "big_three_models": ["%s"]
}|}
          model));
  match Cascade_catalog_runtime.inspect_active () with
  | Error rejection ->
      let detail =
        Cascade_catalog_runtime.rejection_to_yojson rejection
        |> Yojson.Safe.to_string
      in
      check bool "unknown route key is surfaced" true
        (contains_substring detail "unknown cascade route key")
  | Ok state ->
      failf "expected route key rejection, got %s"
        (Yojson.Safe.to_string (Cascade_catalog_runtime.state_to_yojson state))

let test_route_validation_rejects_missing_route_target () =
  with_temp_dir "cascade-routes-missing-target" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let model = Printf.sprintf "custom:stable@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "routes": {
    "keeper_turn": "big_three",
    "governance_judge": "missing_profile"
  },
  "big_three_models": ["%s"]
}|}
          model));
  match Cascade_catalog_runtime.inspect_active () with
  | Error rejection ->
      let detail =
        Cascade_catalog_runtime.rejection_to_yojson rejection
        |> Yojson.Safe.to_string
      in
      check bool "missing route target is surfaced" true
        (contains_substring detail
           "cascade route targets missing profile")
  | Ok state ->
      failf "expected route target rejection, got %s"
        (Yojson.Safe.to_string (Cascade_catalog_runtime.state_to_yojson state))

let test_keeper_turn_route_is_required_default_profile () =
  with_temp_dir "cascade-routes-default-profile" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let model = Printf.sprintf "custom:stable@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "routes": {
    "keeper_turn": "custom_default"
  },
  "custom_default_models": ["%s"]
}|}
          model));
  let snapshot =
    match Cascade_catalog_runtime.inspect_active () with
    | Ok (Cascade_catalog_runtime.Validated snapshot) -> snapshot
    | Ok state ->
        failf "expected fully validated custom default, got %s"
          (Yojson.Safe.to_string (Cascade_catalog_runtime.state_to_yojson state))
    | Error rejection ->
        failf "unexpected route-default rejection: %s"
          (Yojson.Safe.to_string
             (Cascade_catalog_runtime.rejection_to_yojson rejection))
  in
  let snapshot_json = Cascade_catalog_runtime.snapshot_to_yojson snapshot in
  check int "profile_count" 1 (json_int_field "profile_count" snapshot_json);
  check string "blank name follows routes.keeper_turn"
    "custom_default"
    (require_ok
       (Cascade_catalog_runtime.resolve_declared_name ~raw_name:"" ()))

let test_valid_catalog_skips_live_probes_at_bootstrap () =
  with_temp_dir "cascade-catalog-runtime" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let shared_model = Printf.sprintf "custom:mock@%s/v1" dummy_base_url in
  let keeper_unified_model =
    Printf.sprintf "custom:keeper-unified@%s/v1" dummy_base_url
  in
  let strict_model =
    Printf.sprintf "custom:tool-use-strict@%s/v1" dummy_base_url
  in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": ["%s"],
  "keeper_unified_models": ["%s"],
  "tool_rerank_models": ["%s"],
  "tool_use_strict_models": ["%s"]
}|}
          shared_model keeper_unified_model shared_model strict_model));
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
  check int "profile_count" 4 (json_int_field "profile_count" snapshot_json);
  check bool "bootstrap probe status is skipped" true
    (contains_substring (Yojson.Safe.to_string snapshot_json) "\"status\":\"skipped\"");
  let blank_name =
    require_ok
      (Cascade_catalog_runtime.resolve_declared_name ~raw_name:"" ())
  in
  check string "blank name defaults to big_three"
    Keeper_config.default_cascade_name blank_name;
  let keeper_unified_name =
    require_ok
      (Cascade_catalog_runtime.resolve_declared_name
         ~raw_name:"keeper_unified" ())
  in
  check string "keeper_unified resolves to catalog profile"
    "keeper_unified" keeper_unified_name;
  check (list string) "keeper_unified models use exact catalog profile"
    [ keeper_unified_model ]
    (require_ok
       (Cascade_catalog_runtime.models_of_cascade_name "keeper_unified"));
  let strict_name =
    require_ok
      (Cascade_catalog_runtime.resolve_declared_name
         ~raw_name:"tool_use_strict" ())
  in
  check string "tool_use_strict resolves to catalog profile"
    "tool_use_strict" strict_name;
  check (list string) "tool_use_strict models use exact catalog profile"
    [ strict_model ]
    (require_ok
       (Cascade_catalog_runtime.models_of_cascade_name "tool_use_strict"));
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
  "big_three_models": ["%s"]
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
  "big_three_models": ["__nonexistent_provider_sentinel__:fake"]
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
          (Cascade_catalog_runtime.models_of_cascade_name "big_three")
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
  "big_three_models": ["%s"]
}|}
          valid_model));
  ignore (Cascade_catalog_runtime.inspect_active ());
  check (list string) "legacy wrapper still resolves known profile"
    [ valid_model ]
    (Cascade_runtime.models_of_cascade_name
       (Keeper_cascade_profile.Runtime_name Keeper_config.default_cascade_name));
  check (list string) "unknown profile no longer falls back to defaults"
    []
    (Cascade_runtime.models_of_cascade_name
       (Keeper_cascade_profile.Runtime_name "missing_profile"))

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
  "big_three_models": [
    {"model": "%s", "weight": 2},
    {"model": "%s", "weight": 2},
    {"model": "%s", "weight": 2}
  ]
}|}
          alpha_model beta_model gamma_model));
  ignore (Cascade_catalog_runtime.inspect_active ~sw ~net ~clock ());
  let observed_orders =
    List.init 8 (fun _ ->
        Cascade_runtime.models_of_cascade_name
          (Keeper_cascade_profile.Runtime_name
             Keeper_config.default_cascade_name))
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
  "big_three_models": ["%s"],
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
  let invalid_profiles =
    Masc_mcp.Server_routes_http_routes_dashboard.invalid_cascade_profiles ()
  in
  check (list string) "invalid profiles use runtime rejected subset"
    [ "broken_profile" ]
    (List.map fst invalid_profiles);
  check bool "invalid profile reason is actionable" true
    (match List.assoc_opt "broken_profile" invalid_profiles with
     | Some reasons ->
         List.exists
           (fun reason ->
              contains_substring reason
                "uses unregistered provider scheme")
           reasons
     | None -> false);
  let config_json =
    with_eio @@ fun ~sw:_ ~net:_ ~clock:_ ~fs:_ ~proc_mgr:_ ->
    Masc_mcp.Dashboard_cascade.config_json ()
  in
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
  "big_three_models": ["__nonexistent_provider_sentinel__:fake"],
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
                   "required default profile \"big_three\" failed validation"
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
  "big_three_models": [
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
  "big_three_models": [
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

let test_resolve_named_providers_runtime_mcp_headers_drop_unsupported_providers () =
  with_temp_dir "cascade-catalog-runtime-mcp-headers" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  ignore
    (write_cascade_json config_dir
       {|{
  "big_three_models": [
    "custom:remote-model@http://127.0.0.1:18080/v1",
    "claude_code:auto",
    "codex_cli:auto",
    "kimi_cli:auto",
    "gemini_cli:auto",
    "ollama:local-model"
  ]
}|});
  let providers =
    require_ok
      (Cascade_catalog_runtime.resolve_named_providers
         ~require_tool_support:true
         ~runtime_mcp_policy:runtime_mcp_policy_with_headers
         ~cascade_name:Keeper_config.default_cascade_name
         ())
  in
  check bool "drops codex_cli when runtime MCP headers are required" false
    (List.mem "codex_cli" (provider_kinds providers));
  check bool "keeps kimi_cli with runtime MCP header support" true
    (List.mem "kimi_cli" (provider_kinds providers));
  check bool "keeps claude_code with runtime MCP header support" true
    (List.mem "claude_code" (provider_kinds providers))

let test_resolve_named_providers_canonical_labels_are_not_leaks () =
  with_temp_dir "cascade-catalog-canonical-labels" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let model = Printf.sprintf "custom:judge@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": ["%s", "codex_cli:auto", "gemini_cli:auto"],
  "governance_judge_models": ["%s", "codex_cli:auto", "gemini_cli:auto"]
}|}
          model model));
  Log.set_level Log.Info;
  let stderr_output =
    capture_stderr (fun () ->
        let providers =
          require_ok
            (Cascade_catalog_runtime.resolve_named_providers
               ~cascade_name:"governance_judge" ())
        in
        let kinds = provider_kinds providers in
        check bool "keeps canonical custom provider" true
          (List.mem "openai_compat" kinds);
        check bool "expands codex_cli:auto" true (List.mem "codex_cli" kinds);
        check bool "expands gemini_cli:auto" true (List.mem "gemini_cli" kinds))
  in
  check bool "canonicalized provider labels are not false leaks" false
    (contains_substring stderr_output "NOT in")

(* #10087 regression: the live big_three cascade declares
   [claude_code:auto, codex_cli:auto, gemini_cli:auto] — three
   CLI providers all using [:auto].  The user-reported symptom is
   "11 providers NOT in declared profile" warnings; #10004
   already replaced the comparison baseline with the post-expansion
   list, but the existing test only covers the case where the
   first declared entry is a [custom:...@url] alias.  This test
   pins the case where ALL three entries are bare CLI [:auto]
   shorthands so that any future change to the expansion or
   filter pipeline that breaks symmetry is caught immediately. *)
let test_resolve_named_providers_three_cli_auto_not_leaks_10087 () =
  with_temp_dir "cascade-catalog-three-cli-auto-10087" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  ignore
    (write_cascade_json config_dir
       {|{
  "big_three_models": ["claude_code:auto", "codex_cli:auto", "gemini_cli:auto"],
  "governance_judge_models": ["kimi_cli:kimi-for-coding", "codex_cli:auto", "gemini_cli:auto"]
}|});
  Log.set_level Log.Info;
  let big_three_stderr =
    capture_stderr (fun () ->
        let providers =
          require_ok
            (Cascade_catalog_runtime.resolve_named_providers
               ~cascade_name:"big_three" ())
        in
        let kinds = provider_kinds providers in
        check bool "big_three: claude_code present" true
          (List.mem "claude_code" kinds);
        check bool "big_three: codex_cli present" true
          (List.mem "codex_cli" kinds);
        check bool "big_three: gemini_cli present" true
          (List.mem "gemini_cli" kinds))
  in
  check bool
    "#10087 big_three: NO 'NOT in' leak warning fires for 3 CLI :auto"
    false
    (contains_substring big_three_stderr "NOT in");
  (* The governance_judge case from the issue uses kimi_cli +
     codex_cli + gemini_cli.  Don't require kimi to resolve in
     this test (it needs an API key the test env does not
     provide); just assert that the expanded codex/gemini path
     does NOT emit a leak warning regardless of kimi's
     resolution outcome. *)
  let gov_stderr =
    capture_stderr (fun () ->
        match
          Cascade_catalog_runtime.resolve_named_providers
            ~cascade_name:"governance_judge" ()
        with
        | Ok providers ->
          let kinds = provider_kinds providers in
          check bool "governance_judge: codex_cli expanded" true
            (List.mem "codex_cli" kinds);
          check bool "governance_judge: gemini_cli expanded" true
            (List.mem "gemini_cli" kinds)
        | Error _ ->
          (* If the cascade fails to resolve at all, the leak
             warning code path is unreachable, so the invariant
             is vacuously satisfied. *)
          ())
  in
  check bool
    "#10087 governance_judge: NO 'NOT in' leak warning fires"
    false
    (contains_substring gov_stderr "NOT in")

let test_config_doctor_live_reports_catalog_validation () =
  with_temp_dir "cascade-doctor-live" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_dir = Filename.concat base_path ".masc/config" in
  init_config_root config_dir;
  ignore
    (write_cascade_json config_dir
       {|{
  "big_three_models": ["__nonexistent_provider_sentinel__:fake"]
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
  "big_three_models": ["%s"],
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
            "route validation rejects unknown route key"
            `Quick
            test_route_validation_rejects_unknown_route_key;
          test_case
            "route validation rejects missing route target"
            `Quick
            test_route_validation_rejects_missing_route_target;
          test_case
            "routes.keeper_turn is the required default profile"
            `Quick
            test_keeper_turn_route_is_required_default_profile;
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
            "resolve_named_providers runtime MCP headers drop unsupported providers"
            `Quick
            test_resolve_named_providers_runtime_mcp_headers_drop_unsupported_providers;
          test_case
            "resolve_named_providers canonical labels are not leak warnings"
            `Quick
            test_resolve_named_providers_canonical_labels_are_not_leaks;
          test_case
            "resolve_named_providers 3 CLI :auto are not leak warnings (#10087)"
            `Quick
            test_resolve_named_providers_three_cli_auto_not_leaks_10087;
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
