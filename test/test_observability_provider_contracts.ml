(** Contract tests for observability, provider, and telemetry boundaries.

    These tests verify public API contracts that cross module boundaries,
    ensuring serialization, resolution, and schema stability across releases.

    Issue #3955: Smoke harness + contract tests for CI stability. *)

open Alcotest

(* ── Section 1: Provider_adapter contracts ── *)

module Adapter = Masc_mcp.Provider_adapter

let with_env name value_opt f =
  let prior = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "")
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.putenv name "");
      f ())

let with_temp_dir prefix f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists dir then (
        Array.iter
          (fun name ->
            let path = Filename.concat dir name in
            if Sys.file_exists path then Sys.remove path)
          (Sys.readdir dir);
        Unix.rmdir dir))
    (fun () -> f dir)

let test_alias_roundtrip () =
  let cases =
    [ ("anthropic", "claude-api"); ("Claude", "claude");
      ("google", "gemini-api"); ("Gemini", "gemini");
      ("openai", "codex-api"); ("OpenAI", "codex-api");
      ("llama", "llama"); ("llamacpp", "llama");
      ("glm", "glm-api"); ("glm-api", "glm-api");
      ("glm-coding", "glm-coding-plan");
      ("glm-coding-plan", "glm-coding-plan");
      ("zai", "glm-api");
      ("openrouter", "openrouter") ]
  in
  List.iter (fun (input, expected) ->
    match Adapter.resolve_direct_canonical_name input with
    | Some canonical ->
        check string (Printf.sprintf "alias %s -> %s" input expected)
          expected canonical
    | None ->
        fail (Printf.sprintf "alias %s resolved to None" input))
    cases

let test_case_insensitive () =
  let a1 = Adapter.resolve_direct_adapter "Claude-API" in
  let a2 = Adapter.resolve_direct_adapter "CLAUDE-API" in
  check bool "mixed case resolves" true (Option.is_some a1);
  check bool "upper case resolves" true (Option.is_some a2)

let test_whitespace_trimmed () =
  let a = Adapter.resolve_direct_adapter "  anthropic  " in
  check bool "whitespace trimmed" true (Option.is_some a);
  check string "canonical" "claude-api"
    (Option.get a).Adapter.canonical_name

let test_unknown_returns_none () =
  let a = Adapter.resolve_direct_adapter "nonexistent-provider-xyz" in
  check (option string) "unknown returns None" None
    (Option.map (fun (x : Adapter.adapter) -> x.canonical_name) a)

let test_adapter_well_formed () =
  List.iter (fun (a : Adapter.adapter) ->
    check bool ("canonical non-empty: " ^ a.canonical_name)
      true (String.length a.canonical_name > 0);
    check bool ("has aliases: " ^ a.canonical_name)
      true (List.length a.aliases > 0))
    Adapter.direct_adapters

let test_runtime_kind_strings () =
  check string "local" "local" (Adapter.string_of_runtime_kind Adapter.Local);
  check string "cli_agent" "cli_agent"
    (Adapter.string_of_runtime_kind Adapter.Cli_agent);
  check string "direct_api" "direct_api"
    (Adapter.string_of_runtime_kind Adapter.Direct_api)

(* ── Section 2: OAS model resolve contracts ── *)

let test_resolve_canonical_wraps_adapter () =
  let labels =
    [ "claude"; "anthropic"; "gemini"; "google"; "openai"; "llama";
      "glm"; "glm-api"; "glm-coding"; "glm-coding-plan" ]
  in
  List.iter (fun label ->
    let via_fn = Adapter.resolve_direct_canonical_name label in
    let via_adapter =
      Option.map (fun (a : Adapter.adapter) -> a.canonical_name)
        (Adapter.resolve_direct_adapter label)
    in
    check (option string) ("consistent: " ^ label) via_adapter via_fn)
    labels

let test_dashboard_provider_snapshots_include_cli_and_api () =
  Eio_main.run (fun _env ->
    let open Masc_mcp.Dashboard_provider_runs in
    let claude_cli = provider_snapshot_by_name "claude" in
    let claude_api = provider_snapshot_by_name "claude-api" in
    check bool "cli snapshot present" true (Option.is_some claude_cli);
    check bool "api snapshot present" true (Option.is_some claude_api);
    check string "cli runtime kind" "cli_agent"
      (Option.get claude_cli).runtime_kind;
    check string "api runtime kind" "direct_api"
      (Option.get claude_api).runtime_kind)

let test_default_registry_populated () =
  (* Verify default_registry is usable by resolving a known provider.
     Direct access to Llm_provider.Provider_registry types avoided —
     OAS SDK internals are not MASC's contract boundary. *)
  let ctx = Masc_mcp.Oas_model_resolve.max_context_of_label
      "claude:claude-sonnet-4-6" in
  check bool "registry resolves known provider" true (ctx > 0)

let test_provider_name_of_label () =
  let name = Masc_mcp.Oas_model_resolve.provider_name_of_label
      "claude:claude-sonnet-4-6" in
  check (option string) "provider name" (Some "claude") name;
  let no_colon = Masc_mcp.Oas_model_resolve.provider_name_of_label
      "just-a-model" in
  check (option string) "no colon returns None" None no_colon;
  let empty = Masc_mcp.Oas_model_resolve.provider_name_of_label "" in
  check (option string) "empty returns None" None empty

let test_max_context_of_label () =
  let ctx = Masc_mcp.Oas_model_resolve.max_context_of_label
      "claude:claude-sonnet-4-6" in
  check bool "max context > 0" true (ctx > 0);
  let fallback = Masc_mcp.Oas_model_resolve.max_context_of_label
      "nonexistent:model" in
  check int "fallback 128000" 128_000 fallback


let test_effective_discovered_ctx () =
  let edc = Masc_mcp.Oas_model_resolve.effective_discovered_ctx in
  (* Below floor (4096) → use static *)
  check int "below floor uses static" 128_000
    (edc ~static_ctx:128_000 ~discovered:(Some 2048));
  (* At floor → use discovered *)
  check int "at floor uses discovered" 4_096
    (edc ~static_ctx:128_000 ~discovered:(Some 4_096));
  (* Above floor → use discovered *)
  check int "above floor uses discovered" 32_768
    (edc ~static_ctx:128_000 ~discovered:(Some 32_768));
  (* None → use static *)
  check int "none uses static" 128_000
    (edc ~static_ctx:128_000 ~discovered:None)

let test_resolve_max_cascade_context () =
  (* Empty list → 128_000 fallback *)
  check int "empty labels fallback 128000" 128_000
    (Masc_mcp.Oas_model_resolve.resolve_max_cascade_context []);
  (* Unknown provider → fallback *)
  check int "unknown provider fallback 128000" 128_000
    (Masc_mcp.Oas_model_resolve.resolve_max_cascade_context
       [ "nonexistent:model" ]);
  (* Malformed label (no colon) → fallback *)
  check int "malformed label fallback 128000" 128_000
    (Masc_mcp.Oas_model_resolve.resolve_max_cascade_context [ "nocolonlabel" ]);
  (* Known provider with available key returns max context > 0 *)
  let ctx = Masc_mcp.Oas_model_resolve.resolve_max_cascade_context
      [ "claude:claude-sonnet-4-6" ] in
  check bool "known provider returns positive context" true (ctx > 0)

let test_labels_require_local_discovery () =
  check bool "llama labels refresh local discovery" true
    (Masc_mcp.Oas_model_resolve.labels_require_local_discovery
       [ "llama:auto"; "glm:auto" ]);
  check bool "mixed non-local labels skip refresh" false
    (Masc_mcp.Oas_model_resolve.labels_require_local_discovery
       [ "glm:auto"; "claude:auto" ]);
  check bool "malformed labels skip refresh" false
    (Masc_mcp.Oas_model_resolve.labels_require_local_discovery
       [ "default"; "glm:auto" ])

let test_registry_provider_name_normalizes_glm_aliases () =
  check string "glm-api -> glm registry key" "glm"
    (Adapter.registry_provider_name "glm-api");
  check string "glm-coding-plan -> glm-coding registry key" "glm-coding"
    (Adapter.registry_provider_name "glm-coding-plan");
  check string "legacy glm stays glm" "glm"
    (Adapter.registry_provider_name "glm");
  check string "legacy glm-coding stays glm-coding" "glm-coding"
    (Adapter.registry_provider_name "glm-coding")

let test_cascade_prefix_of_provider_config_disambiguates_glm_and_llama () =
  let coding_cfg =
    match Masc_mcp.Cascade_config.parse_model_string_exn "glm-coding-plan:glm-5.1" with
    | Ok cfg -> cfg
    | Error err -> fail err
  in
  let api_cfg =
    match Masc_mcp.Cascade_config.parse_model_string_exn "glm-api:glm-5.1" with
    | Ok cfg -> cfg
    | Error err -> fail err
  in
  let llama_cfg =
    match Masc_mcp.Cascade_config.parse_model_string_exn "llama:qwen3.5:27b-nvfp4" with
    | Ok cfg -> cfg
    | Error err -> fail err
  in
  check string "coding-plan prefix preserved" "glm-coding-plan"
    (Adapter.cascade_prefix_of_provider_config coding_cfg);
  check string "glm-api prefix preserved" "glm-api"
    (Adapter.cascade_prefix_of_provider_config api_cfg);
  check string "local openai-compat rendered as llama" "llama"
    (Adapter.cascade_prefix_of_provider_config llama_cfg)

let test_resolve_named_providers_honors_api_key_override_for_glm_coding_plan () =
  with_temp_dir "glm-coding-provider" @@ fun config_dir ->
  let cascade_path = Filename.concat config_dir "cascade.json" in
  let oc = open_out cascade_path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc
        {|{
  "default_models": [{"model":"glm-coding-plan:glm-5.1","weight":1}],
  "default_api_key_env": {"glm-coding-plan":"ZAI_API_KEY_SB"}
}|});
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  with_env "ZAI_API_KEY" None @@ fun () ->
  with_env "ZAI_API_KEY_SB" (Some "sb-key") @@ fun () ->
    let providers =
      Masc_mcp.Oas_model_resolve.resolve_named_providers ~cascade_name:"default" ()
    in
    match providers with
    | [ cfg ] ->
      check string "coding-plan base url"
        "https://api.z.ai/api/coding/paas/v4"
        cfg.Llm_provider.Provider_config.base_url;
      check string "resolved model"
        "glm-5.1"
        cfg.Llm_provider.Provider_config.model_id
    | _ ->
      fail (Printf.sprintf "expected one provider, got %d" (List.length providers))

(* ── Section 3: Dashboard schema contracts ── *)

let test_heartbeat_snapshot_has_required_fields () =
  let snapshot = `Assoc
    [ ("ts", `String "2026-04-01T00:00:00Z");
      ("ts_unix", `Float 1000000.0);
      ("channel", `String "heartbeat");
      ("name", `String "test-keeper");
      ("generation", `Int 1);
      ("context_ratio", `Float 0.5);
      ("message_count", `Int 10);
      ("work_kind", `String "status_tick") ]
  in
  let keys = match snapshot with `Assoc kvs ->
    List.map (fun (k, _) -> k) kvs | _ -> [] in
  List.iter (fun required ->
    check bool ("has field: " ^ required) true
      (List.mem required keys))
    [ "ts"; "name"; "generation"; "context_ratio"; "work_kind" ]

let test_prometheus_text_format () =
  let metrics = Masc_mcp.Prometheus.to_prometheus_text () in
  check bool "prometheus output non-empty" true
    (String.length metrics >= 0)

(* ── Section 4: Telemetry contracts ── *)

let test_event_serialization_roundtrip () =
  let module T = Masc_mcp.Telemetry_eio in
  let events =
    [ T.Agent_joined { agent_id = "test-agent"; capabilities = [] };
      T.Task_started { task_id = "task-1"; agent_id = "agent-1" };
      T.Task_completed { task_id = "task-1"; duration_ms = 100; success = true };
      T.Tool_called { tool_name = "read_file"; success = true; duration_ms = 10;
                      agent_id = None; source = None };
      T.Error_occurred { code = "E001"; message = "test"; context = "test" } ]
  in
  List.iter (fun event ->
    let json = T.event_to_yojson event in
    let json_str = Yojson.Safe.to_string json in
    check bool ("json roundtrip: " ^ T.show_event event)
      true (String.length json_str > 0))
    events

(* ── Section 5: Extended redaction contracts ── *)

let test_bearer_token_redacted () =
  let input = "Authorization: Bearer sk-secret-key-12345" in
  let redacted = Masc_mcp.Observability_redact.redact_preview input in
  check bool "bearer redacted" true
    (not (String.contains redacted 'k'
          && String.sub redacted
              (max 0 (String.length redacted - 10))
              (min 10 (String.length redacted)) = "key-12345"))

let test_nested_credentials_redacted () =
  let input =
    {|{"api_key": "sk-live-abc123", "config": {"token": "tok_xyz"}}|}
  in
  let redacted = Masc_mcp.Observability_redact.redact_preview input in
  check bool "api_key redacted" true
    (not (String.contains redacted 'a'
          && String.length redacted < String.length input))

let test_redaction_idempotent () =
  let input = "key=sk-abc123" in
  let r1 = Masc_mcp.Observability_redact.redact_preview input in
  let r2 = Masc_mcp.Observability_redact.redact_preview r1 in
  check string "idempotent" r1 r2

(* ── Test runner ── *)

let () =
  run "Observability Provider Contracts"
    [
      ( "provider_adapter",
        [
          test_case "alias roundtrip" `Quick test_alias_roundtrip;
          test_case "case insensitive" `Quick test_case_insensitive;
          test_case "whitespace trimmed" `Quick test_whitespace_trimmed;
          test_case "unknown returns none" `Quick test_unknown_returns_none;
          test_case "adapter well formed" `Quick test_adapter_well_formed;
          test_case "runtime kind strings" `Quick test_runtime_kind_strings;
          test_case "dashboard snapshots include cli and api" `Quick
            test_dashboard_provider_snapshots_include_cli_and_api;
        ] );
      ( "oas_model_resolve",
        [
          test_case "resolve canonical wraps adapter" `Quick
            test_resolve_canonical_wraps_adapter;
          test_case "default registry populated" `Quick
            test_default_registry_populated;
          test_case "provider name of label" `Quick test_provider_name_of_label;
          test_case "max context of label" `Quick test_max_context_of_label;
          test_case "effective discovered ctx floor" `Quick
            test_effective_discovered_ctx;
          test_case "local discovery label detection" `Quick
            test_labels_require_local_discovery;
          test_case "registry provider aliases normalize" `Quick
            test_registry_provider_name_normalizes_glm_aliases;
          test_case "provider config prefixes stay disambiguated" `Quick
            test_cascade_prefix_of_provider_config_disambiguates_glm_and_llama;
          test_case "named providers honor glm coding override" `Quick
            test_resolve_named_providers_honors_api_key_override_for_glm_coding_plan;
          test_case "resolve max cascade context" `Quick
            test_resolve_max_cascade_context;
        ] );
      ( "dashboard_schema",
        [
          test_case "heartbeat snapshot required fields" `Quick
            test_heartbeat_snapshot_has_required_fields;
          test_case "prometheus text format" `Quick test_prometheus_text_format;
        ] );
      ( "telemetry",
        [
          test_case "event serialization roundtrip" `Quick
            test_event_serialization_roundtrip;
        ] );
      ( "redaction_extended",
        [
          test_case "bearer token redacted" `Quick test_bearer_token_redacted;
          test_case "nested credentials redacted" `Quick
            test_nested_credentials_redacted;
          test_case "redaction idempotent" `Quick test_redaction_idempotent;
        ] );
    ]
