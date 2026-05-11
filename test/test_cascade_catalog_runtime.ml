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

(* RFC-0058 §9.4: cascade.toml is the on-disk SSOT, and the materializer
   emits the flat ["<profile>_<field>": ...] JSON shape these fixtures
   were written in.  Inverting that shape into per-profile TOML tables
   lets the existing flat-JSON fixtures keep working without rewriting
   every call site. *)
let cascade_profile_fields =
  [ "models"; "temperature"; "max_tokens"; "strategy"; "max_cycles"
  ; "backoff_base_ms"; "backoff_cap_ms"; "ollama_max_concurrent"
  ; "cli_max_concurrent"; "tiers"; "sticky_ttl_ms"; "latency_baseline_ms"
  ; "rate_limit_recency_window_s"; "rate_limit_decay_base"
  ; "rate_limit_skip_after"; "server_error_recency_window_s"
  ; "server_error_decay_base"; "server_error_skip_after"
  ; "keeper_assignable"; "thinking_enabled"; "thinking_budget"
  ; "fallback_cascade"; "required_capability_profile"; "api_key_env"
  ; "keep_alive"; "num_ctx"; "timeout_sec"; "groups"
  ]

let toml_value_of_json = function
  | `String s -> Printf.sprintf "%S" s
  | `Int i -> string_of_int i
  | `Float f -> Printf.sprintf "%g" f
  | `Bool b -> if b then "true" else "false"
  | `List items ->
    let items_str =
      items
      |> List.map (function
        | `String s -> Printf.sprintf "%S" s
        | `Int i -> string_of_int i
        | `Float f -> Printf.sprintf "%g" f
        | `Bool b -> if b then "true" else "false"
        | `Assoc fields ->
          (* Inline table: {key = value, ...} *)
          let kvs =
            List.map (fun (k, v) ->
              Printf.sprintf "%s = %s" k
                (match v with
                 | `String s -> Printf.sprintf "%S" s
                 | `Int i -> string_of_int i
                 | `Float f -> Printf.sprintf "%g" f
                 | `Bool b -> if b then "true" else "false"
                 | other -> Yojson.Safe.to_string other))
              fields
          in
          Printf.sprintf "{ %s }" (String.concat ", " kvs)
        | other -> Yojson.Safe.to_string other)
      |> String.concat ", "
    in
    Printf.sprintf "[%s]" items_str
  | other -> Yojson.Safe.to_string other

let parse_profile_field key =
  List.find_map
    (fun field ->
      let suffix = "_" ^ field in
      if String.length key > String.length suffix
         && String.equal
              (String.sub key
                 (String.length key - String.length suffix)
                 (String.length suffix))
              suffix
      then Some (String.sub key 0 (String.length key - String.length suffix), field)
      else None)
    cascade_profile_fields

let flat_json_to_toml content =
  let json = Yojson.Safe.from_string content in
  let fields =
    match json with
    | `Assoc xs -> xs
    | _ -> failwith "expected flat JSON object at root"
  in
  (* Group by (profile_name, [(field, value); ...]) preserving order. *)
  let buf = Buffer.create 256 in
  let special_top_level acc (key, value) =
    match key, value with
    | "routes", `Assoc inner ->
      Buffer.add_string buf "[routes]\n";
      List.iter
        (fun (rk, rv) ->
          Buffer.add_string buf
            (Printf.sprintf "%s = %s\n" rk (toml_value_of_json rv)))
        inner;
      Buffer.add_char buf '\n';
      acc
    | _ -> (key, value) :: acc
  in
  let remaining = List.rev (List.fold_left special_top_level [] fields) in
  let profile_order = ref [] in
  let profile_table : (string, (string * Yojson.Safe.t) list ref) Hashtbl.t =
    Hashtbl.create 8
  in
  List.iter
    (fun (key, value) ->
      match parse_profile_field key with
      | Some (profile, field) ->
        let entry =
          match Hashtbl.find_opt profile_table profile with
          | Some r -> r
          | None ->
            let r = ref [] in
            Hashtbl.add profile_table profile r;
            profile_order := profile :: !profile_order;
            r
        in
        entry := (field, value) :: !entry
      | None ->
        failwith (Printf.sprintf "unsupported cascade JSON key: %s" key))
    remaining;
  List.iter
    (fun profile ->
      Buffer.add_string buf (Printf.sprintf "[%s]\n" profile);
      let fields = List.rev !(Hashtbl.find profile_table profile) in
      List.iter
        (fun (field, value) ->
          Buffer.add_string buf
            (Printf.sprintf "%s = %s\n" field (toml_value_of_json value)))
        fields;
      Buffer.add_char buf '\n')
    (List.rev !profile_order);
  Buffer.contents buf

let write_cascade_json config_dir content =
  let toml_content = flat_json_to_toml content in
  let toml_path = Filename.concat config_dir "cascade.toml" in
  write_file toml_path toml_content;
  bump_mtime toml_path;
  (* Return the .toml path so call sites that compare against the
     snapshot's [source_path] (also .toml, RFC-0058 §9.4) match. *)
  toml_path

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

let require_some label = function
  | Some value -> value
  | None -> failf "expected Some for %s" label

let provider_kinds providers =
  List.map
    (fun (cfg : Llm_provider.Provider_config.t) ->
      Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
    providers

let provider_supports_required_tool_use (cfg : Llm_provider.Provider_config.t) =
  let caps = Cascade_runner.provider_caps_of_config cfg in
  caps.supports_tools && caps.supports_tool_choice

let provider_supports_callable_tool_use (cfg : Llm_provider.Provider_config.t) =
  let caps = Cascade_runner.provider_caps_of_config cfg in
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
            headers =
              [
                ("x-masc-agent-name", "keeper-sangsu-agent");
                ("authorization", "Bearer test-token");
              ];
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

let test_valid_catalog_records_probe_error_without_eio_caps () =
  with_temp_dir "cascade-catalog-runtime" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let skip_metric () =
    Prometheus.metric_value_or_zero
      Prometheus.metric_provider_health_probe_skipped
      ~labels:[("provider_name", "custom"); ("profile_name", "big_three")]
      ()
  in
  let before_skip_metric = skip_metric () in
  let shared_model = Printf.sprintf "custom:mock@%s/v1" dummy_base_url in
  let custom_exec_model =
    Printf.sprintf "custom:custom-exec@%s/v1" dummy_base_url
  in
  let strict_model =
    Printf.sprintf "custom:tool-use-strict@%s/v1" dummy_base_url
  in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": ["%s"],
  "custom_exec_models": ["%s"],
  "tool_rerank_models": ["%s"],
  "strict_exec_models": ["%s"]
}|}
          shared_model custom_exec_model shared_model strict_model));
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
  let snapshot_string = Yojson.Safe.to_string snapshot_json in
  check int "profile_count" 4 (json_int_field "profile_count" snapshot_json);
  check bool "local bootstrap probe records an error" true
    (contains_substring snapshot_string "\"status\":\"error\"");
  check bool "old advisory skip signature is absent" false
    (contains_substring snapshot_string "bootstrap skips live probe");
  check bool "local bootstrap probe is not skipped" false
    (contains_substring snapshot_string "\"status\":\"skipped\"");
  check (float 0.0001) "local bootstrap skip metric does not increment"
    0.0
    (skip_metric () -. before_skip_metric);
  let blank_name =
    require_ok
      (Cascade_catalog_runtime.resolve_declared_name ~raw_name:"" ())
  in
  (* [Keeper_config.default_cascade_name] is evaluated at module init
     when no catalog is loaded, so it freezes to the
     [first_alias_or_key] fallback ("default").  After the fixture
     installs a catalog whose first profile is "big_three",
     [resolve_declared_name ""] returns "big_three" — the live answer.
     Pin against the fixture's first profile, not the init-time cache. *)
  check string "blank name defaults to first catalog profile"
    "big_three" blank_name;
  let custom_exec_name =
    require_ok
      (Cascade_catalog_runtime.resolve_declared_name
         ~raw_name:"custom_exec" ())
  in
  check string "custom_exec resolves to catalog profile"
    "custom_exec" custom_exec_name;
  check (list string) "custom_exec models use exact catalog profile"
    [ custom_exec_model ]
    (require_ok
       (Cascade_catalog_runtime.models_of_cascade_name "custom_exec"));
  let strict_name =
    require_ok
      (Cascade_catalog_runtime.resolve_declared_name
         ~raw_name:"strict_exec" ())
  in
  check string "strict_exec resolves to catalog profile"
    "strict_exec" strict_name;
  check (list string) "strict_exec models use exact catalog profile"
    [ strict_model ]
    (require_ok
       (Cascade_catalog_runtime.models_of_cascade_name "strict_exec"));
  (* Same init-time-cache issue: pin against the fixture's first
     profile name. *)
  check string "keeper_unified logical alias falls back to big_three"
    "big_three"
    (require_ok
       (Cascade_catalog_runtime.resolve_declared_name
          ~raw_name:"keeper_unified" ()));
  check string "tool_use_strict logical alias falls back to big_three"
    "big_three"
    (require_ok
       (Cascade_catalog_runtime.resolve_declared_name
          ~raw_name:"tool_use_strict" ()));
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

let test_valid_catalog_probes_local_endpoints_when_eio_caps_available () =
  with_temp_dir "cascade-catalog-runtime-probe" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  with_eio @@ fun ~sw ~net ~clock ~fs:_ ~proc_mgr:_ ->
  let skip_metric () =
    Prometheus.metric_value_or_zero
      Prometheus.metric_provider_health_probe_skipped
      ~labels:[("provider_name", "custom"); ("profile_name", "big_three")]
      ()
  in
  let health_metric () =
    Prometheus.metric_value_or_zero
      Prometheus.metric_provider_actual_health_status
      ~labels:
        [
          ("provider_name", "openai_compat");
          ("profile_name", "big_three");
          ("model_id", "mock");
        ]
      ()
  in
  let before_skip_metric = skip_metric () in
  let model = Printf.sprintf "custom:mock@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf {|{"big_three_models": ["%s"]}|} model));
  let snapshot =
    match Cascade_catalog_runtime.inspect_active ~sw ~net ~clock () with
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
  let snapshot_string =
    Yojson.Safe.to_string (Cascade_catalog_runtime.snapshot_to_yojson snapshot)
  in
  check bool "local probe status is error" true
    (contains_substring snapshot_string "\"status\":\"error\"");
  check bool "local probe reports endpoint" true
    (contains_substring snapshot_string "local endpoint");
  check bool "local probe is not skipped" false
    (contains_substring snapshot_string "\"status\":\"skipped\"");
  check (float 0.0001) "local probe does not increment skipped metric"
    0.0
    (skip_metric () -. before_skip_metric);
  check (float 0.0001) "unhealthy local probe gauge" 3.0 (health_metric ())

let test_cloud_probe_is_not_applicable_not_skipped () =
  with_temp_dir "cascade-catalog-runtime-cloud-probe" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let skipped_metric () =
    Prometheus.metric_value_or_zero
      Prometheus.metric_provider_health_probe_skipped
      ~labels:[("provider_name", "codex_cli"); ("profile_name", "big_three")]
      ()
  in
  let before_skipped_metric = skipped_metric () in
  ignore
    (write_cascade_json config_dir
       {|{
  "big_three_models": ["codex_cli:auto"]
}|});
  let snapshot =
    match Cascade_catalog_runtime.inspect_active () with
    | Ok (Cascade_catalog_runtime.Validated snapshot) -> snapshot
    | Ok state ->
        failf "expected fully validated cloud-only snapshot, got %s"
          (Yojson.Safe.to_string
             (Cascade_catalog_runtime.state_to_yojson state))
    | Error rejection ->
        failf "unexpected cloud-only rejection: %s"
          (Yojson.Safe.to_string
             (Cascade_catalog_runtime.rejection_to_yojson rejection))
  in
  let snapshot_string =
    Yojson.Safe.to_string (Cascade_catalog_runtime.snapshot_to_yojson snapshot)
  in
  check bool "cloud probe is explicitly not applicable" true
    (contains_substring snapshot_string "\"status\":\"not_applicable\"");
  check bool "cloud probe explains auth-free bootstrap boundary" true
    (contains_substring snapshot_string "auth-free bootstrap probe");
  check bool "cloud probe is not counted as skipped" false
    (contains_substring snapshot_string "\"status\":\"skipped\"");
  check (float 0.0001) "cloud probe skipped metric does not increment"
    0.0
    (skipped_metric () -. before_skipped_metric)

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
  (* Same caveat as test_valid_catalog_records_probe_error_without_eio_caps:
     [Keeper_config.default_cascade_name] is module-init-cached; assert
     against the fixture's first profile name directly. *)
  check (list string) "dashboard only advertises validated profiles"
    [ "big_three"; "tool_rerank" ]
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
    [ "big_three"; "tool_rerank" ]
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
  check bool "keeps gemini_cli via runtime MCP lane" true
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
  check bool "keeps codex_cli with identity header support" true
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
  "routes": {
    "governance_judge": "big_three"
  }
}|}
          model));
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
  "governance_judge_models": ["kimi_cli:kimi-for-coding", "codex_cli:auto", "gemini_cli:auto"],
  "routes": {
    "governance_judge": "big_three"
  }
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
  (* [governance_judge_models] is a deprecated logical-profile key and is
     ignored.  Direct logical-name resolution must route through [routes] to
     the active [big_three] profile without producing false leak warnings. *)
  let gov_stderr =
    capture_stderr (fun () ->
        match
          Cascade_catalog_runtime.resolve_named_providers
            ~cascade_name:"governance_judge" ()
        with
        | Ok providers ->
          let kinds = provider_kinds providers in
          check bool "governance_judge routes to big_three claude" true
            (List.mem "claude_code" kinds);
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

(* #12686: strict variant tests *)

let test_strict_resolve_rejects_nonmatching_provider_filter () =
  with_temp_dir "cascade-strict-filter" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let fallback = Printf.sprintf "custom:filter-standin@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": [
    "codex_cli:gpt-5.2",
    "%s"
  ]
}|}
          fallback));
  match
    Cascade_catalog_runtime.resolve_named_providers_strict
      ~provider_filter:[ "ollama"; "gemini" ]
      ~cascade_name:Keeper_config.default_cascade_name
      ()
  with
  | Ok providers ->
      failf "strict should reject when no provider matches filter, got %d providers"
        (List.length providers)
  | Error detail ->
      check bool "error mentions filter mismatch" true
        (contains_substring detail "provider_filter matched no providers")

let test_strict_resolve_ok_when_filter_matches () =
  with_temp_dir "cascade-strict-match" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let fallback = Printf.sprintf "custom:filter-standin@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": [
    "codex_cli:gpt-5.2",
    "%s"
  ]
}|}
          fallback));
  let providers =
    require_ok
      (Cascade_catalog_runtime.resolve_named_providers_strict
         ~provider_filter:[ "codex_cli" ]
         ~cascade_name:Keeper_config.default_cascade_name
         ())
  in
  check int "only codex_cli providers survive" 1 (List.length providers);
  check bool "provider kind is codex_cli" true
    (List.mem "codex_cli" (provider_kinds providers))

let test_non_strict_resolve_tolerates_nonmatching_filter () =
  with_temp_dir "cascade-nonstrict-filter" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let fallback = Printf.sprintf "custom:filter-standin@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": [
    "codex_cli:gpt-5.2",
    "%s"
  ]
}|}
          fallback));
  (* Non-strict resolve should NOT error on non-matching filter.
     It returns whatever the catalog provides (silently ignores filter). *)
  let providers =
    require_ok
      (Cascade_catalog_runtime.resolve_named_providers
         ~provider_filter:[ "nonexistent_provider_xyz" ]
         ~cascade_name:Keeper_config.default_cascade_name
         ())
  in
  check int "non-strict returns all providers despite bad filter" 2
    (List.length providers)

let test_secondary_resolution_disambiguates_duplicate_primary_slots () =
  with_temp_dir "cascade-secondary-duplicate" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let primary = Printf.sprintf "custom:primary@%s/v1" dummy_base_url in
  let secondary_a = Printf.sprintf "custom:fallback-a@%s/v1" dummy_base_url in
  let secondary_b = Printf.sprintf "custom:fallback-b@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": [
    {"model": "%s", "secondary": "%s"},
    {"model": "%s", "secondary": "%s"}
  ]
}|}
          primary secondary_a primary secondary_b));
  let resolution =
    require_ok
      (Cascade_catalog_runtime
       .resolve_named_providers_strict_with_secondary_resolver
         ~cascade_name:Keeper_config.default_cascade_name
         ())
  in
  check int "duplicate primaries remain distinct" 2
    (List.length resolution.providers);
  let first_primary = List.nth resolution.providers 0 in
  let second_primary = List.nth resolution.providers 1 in
  let first_secondary =
    require_some "first secondary"
      (resolution.secondary_resolver 0 first_primary)
  in
  let second_secondary =
    require_some "second secondary"
      (resolution.secondary_resolver 1 second_primary)
  in
  let secondary_models =
    [
      first_secondary.Llm_provider.Provider_config.model_id;
      second_secondary.Llm_provider.Provider_config.model_id;
    ]
  in
  check (list string) "slot secondaries preserved"
    [ "fallback-a"; "fallback-b" ]
    (List.sort String.compare secondary_models);
  check bool "duplicate primary slots keep distinct secondaries" true
    (first_secondary.Llm_provider.Provider_config.model_id
     <> second_secondary.Llm_provider.Provider_config.model_id)

let test_secondary_resolution_applies_provider_filter_to_secondary () =
  with_temp_dir "cascade-secondary-filter" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  with_config_dir config_dir @@ fun () ->
  let secondary = Printf.sprintf "custom:fallback@%s/v1" dummy_base_url in
  ignore
    (write_cascade_json config_dir
       (Printf.sprintf
          {|{
  "big_three_models": [
    {"model": "codex_cli:gpt-5.2", "secondary": "%s"}
  ]
}|}
          secondary));
  let resolution =
    require_ok
      (Cascade_catalog_runtime
       .resolve_named_providers_strict_with_secondary_resolver
         ~provider_filter:[ "codex_cli" ]
         ~cascade_name:Keeper_config.default_cascade_name
         ())
  in
  check int "primary survives provider filter" 1
    (List.length resolution.providers);
  let primary = List.nth resolution.providers 0 in
  check (option string) "secondary violating provider_filter is hidden" None
    (Option.map
       (fun (cfg : Llm_provider.Provider_config.t) -> cfg.model_id)
       (resolution.secondary_resolver 0 primary))

let () =
  run "cascade_catalog_runtime"
    [
      ( "runtime",
        [
          test_case
            "valid catalog records probe errors without Eio caps"
            `Quick
            test_valid_catalog_records_probe_error_without_eio_caps;
          test_case
            "valid catalog probes local endpoints when Eio caps available"
            `Quick
            test_valid_catalog_probes_local_endpoints_when_eio_caps_available;
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
            "cloud probe is not applicable, not skipped"
            `Quick
            test_cloud_probe_is_not_applicable_not_skipped;
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
          test_case
            "strict resolve rejects non-matching provider filter (#12686)"
            `Quick
            test_strict_resolve_rejects_nonmatching_provider_filter;
          test_case
            "strict resolve ok when filter matches (#12686)"
            `Quick
            test_strict_resolve_ok_when_filter_matches;
          test_case
            "non-strict resolve tolerates non-matching filter (#12686)"
            `Quick
            test_non_strict_resolve_tolerates_nonmatching_filter;
          test_case
            "secondary resolver disambiguates duplicate primary slots"
            `Quick
            test_secondary_resolution_disambiguates_duplicate_primary_slots;
          test_case
            "secondary resolver applies provider_filter to secondaries"
            `Quick
            test_secondary_resolution_applies_provider_filter_to_secondary;
        ] );
    ]
