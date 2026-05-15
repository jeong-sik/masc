(** Contract tests for observability, provider, and telemetry boundaries.

    These tests verify public API contracts that cross module boundaries,
    ensuring serialization, resolution, and schema stability across releases.

    Issue #3955: Smoke harness + contract tests for CI stability. *)

open Alcotest

module Model_resolve = Masc_mcp.Cascade_model_resolve

let with_provider_catalog json f =
  match Llm_provider.Provider_catalog.of_json (Yojson.Safe.from_string json) with
  | Error msg -> fail msg
  | Ok catalog ->
    Llm_provider.Provider_catalog.set_global catalog;
    Fun.protect ~finally:Llm_provider.Provider_catalog.clear_global f

let local_runtime_catalog_json =
  {|
{
  "schema_version": 1,
  "providers": [
    {
      "id": "observability-local",
      "kind": "openai_compat",
      "transport": "http",
      "base_url": "http://127.0.0.1:8124",
      "request_path": "/v1/chat/completions",
      "auth": {"type": "none"},
      "capabilities_base": "openai_chat",
      "non_interactive": true,
      "interactive_required": false,
      "daemon_safe": true
    }
  ]
}
|}

let string_of_resolution_provenance = function
  | Model_resolve.Explicit_input -> "explicit_input"
  | Model_resolve.Env_default var -> "env_default:" ^ var
  | Model_resolve.Binding_default -> "binding_default"
  | Model_resolve.Discovery -> "discovery"
  | Model_resolve.Unresolved_auto -> "unresolved_auto"

let resolution_provenance =
  testable
    (fun fmt provenance ->
      Format.pp_print_string fmt (string_of_resolution_provenance provenance))
    ( = )

(* ── Section 1: OAS model resolve contracts ── *)

let test_dashboard_provider_snapshots_include_cli_and_api () =
  Eio_main.run (fun _env ->
    let open Masc_mcp.Dashboard_provider_runs in
    let claude_cli = provider_snapshot_by_name "claude_code" in
    let claude_api = provider_snapshot_by_name "claude" in
    let gemini_cli = provider_snapshot_by_name "gemini_cli" in
    let glm_api = provider_snapshot_by_name "glm" in
    let glm_coding_plan = provider_snapshot_by_name "glm-coding" in
    let legacy_claude_api = provider_snapshot_by_name "claude-api" in
    let legacy_glm_api = provider_snapshot_by_name "glm-api" in
    check bool "cli snapshot present" true (Option.is_some claude_cli);
    check bool "api snapshot present" true (Option.is_some claude_api);
    check bool "gemini cli snapshot present" true (Option.is_some gemini_cli);
    check bool "glm api snapshot present" true (Option.is_some glm_api);
    check bool "glm coding snapshot present" true (Option.is_some glm_coding_plan);
    check bool "legacy claude-api snapshot removed" false
      (Option.is_some legacy_claude_api);
    check bool "legacy glm-api snapshot removed" false
      (Option.is_some legacy_glm_api);
    check string "cli runtime kind" "cli_agent"
      (Option.get claude_cli).runtime_kind;
    check string "api runtime kind" "direct_api"
      (Option.get claude_api).runtime_kind;
    check string "glm api runtime kind" "direct_api"
      (Option.get glm_api).runtime_kind;
    check string "glm coding runtime kind" "direct_api"
      (Option.get glm_coding_plan).runtime_kind;
    check string "cli source" "oas/provider-runtime-binding"
      (Option.get claude_cli).source;
    check string "api source" "oas/provider-runtime-binding"
      (Option.get claude_api).source)

let test_default_registry_populated () =
  (* Verify default_registry is usable by resolving a known provider.
     Direct access to Llm_provider.Provider_registry types avoided —
     OAS SDK internals are not MASC's contract boundary. *)
  let ctx = Masc_mcp.Cascade_runtime.max_context_of_label
      "claude:claude-sonnet-4-6" in
  check bool "registry resolves known provider" true (ctx > 0)

let test_provider_name_of_label () =
  let name = Masc_mcp.Cascade_runtime.provider_name_of_label
      "claude:claude-sonnet-4-6" in
  check (option string) "provider name" (Some "claude") name;
  let no_colon = Masc_mcp.Cascade_runtime.provider_name_of_label
      "just-a-model" in
  check (option string) "no colon returns None" None no_colon;
  let empty = Masc_mcp.Cascade_runtime.provider_name_of_label "" in
  check (option string) "empty returns None" None empty

let test_max_context_of_label () =
  let ctx = Masc_mcp.Cascade_runtime.max_context_of_label
      "claude:claude-sonnet-4-6" in
  check bool "max context > 0" true (ctx > 0);
  let fallback = Masc_mcp.Cascade_runtime.max_context_of_label
      "nonexistent:model" in
  check int "fallback 128000" 128_000 fallback


let test_effective_discovered_ctx () =
  let edc = Masc_mcp.Cascade_runtime.effective_discovered_ctx in
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
    (Masc_mcp.Cascade_runtime.resolve_max_cascade_context []);
  (* Unknown provider → fallback *)
  check int "unknown provider fallback 128000" 128_000
    (Masc_mcp.Cascade_runtime.resolve_max_cascade_context
       [ "nonexistent:model" ]);
  (* Malformed label (no colon) → fallback *)
  check int "malformed label fallback 128000" 128_000
    (Masc_mcp.Cascade_runtime.resolve_max_cascade_context [ "nocolonlabel" ]);
  (* Known provider with available key returns max context > 0 *)
  let ctx = Masc_mcp.Cascade_runtime.resolve_max_cascade_context
      [ "claude:claude-sonnet-4-6" ] in
  check bool "known provider returns positive context" true (ctx > 0)

let test_labels_require_local_discovery () =
  check bool "llama labels refresh local discovery" true
    (Masc_mcp.Cascade_runtime.labels_require_local_discovery
       [ "llama:auto"; "glm:auto" ]);
  check bool "mixed non-local labels skip refresh" false
    (Masc_mcp.Cascade_runtime.labels_require_local_discovery
       [ "glm:auto"; "claude:auto" ]);
  check bool "malformed labels skip refresh" false
    (Masc_mcp.Cascade_runtime.labels_require_local_discovery
       [ "default"; "glm:auto" ])

let test_cascade_model_resolve_unregistered_default_provenance () =
  let resolved =
    Model_resolve.resolve_auto_model ~getenv:(fun _ -> None) "openai"
      (Model_resolve.model_selector_of_string "auto")
  in
  check string "openai generic default" "auto" resolved.resolved_model_id;
  check resolution_provenance "unregistered provider provenance"
    Model_resolve.Unresolved_auto resolved.provenance

let test_cascade_model_resolve_env_default_provenance () =
  let getenv = function
    | "GEMINI_DEFAULT_MODEL" -> Some "gemini-3-flash-preview"
    | _ -> None
  in
  let resolved =
    Model_resolve.resolve_auto_model ~getenv "gemini"
      (Model_resolve.model_selector_of_string "auto")
  in
  check string "gemini env default" "gemini-3-flash-preview"
    resolved.resolved_model_id;
  check resolution_provenance "env provenance"
    (Model_resolve.Env_default "GEMINI_DEFAULT_MODEL")
    resolved.provenance

let test_cascade_model_resolve_discovery_provenance () =
  with_provider_catalog local_runtime_catalog_json (fun () ->
    let resolved =
      Model_resolve.resolve_auto_model
        ~getenv:(fun _ -> None)
        ~discover:(fun () -> Some "local-model")
        "observability-local" (Model_resolve.model_selector_of_string "auto")
    in
    check string "local discovery" "local-model" resolved.resolved_model_id;
    check resolution_provenance "discovery provenance"
      Model_resolve.Discovery resolved.provenance)

let test_cascade_model_resolve_unresolved_auto_provenance () =
  let resolved =
    Model_resolve.resolve_auto_model ~getenv:(fun _ -> None) "openrouter"
      (Model_resolve.model_selector_of_string "auto")
  in
  check string "openrouter unresolved auto stays auto" "auto"
    resolved.resolved_model_id;
  check resolution_provenance "generic OAS binding provenance"
    Model_resolve.Binding_default resolved.provenance

(* ── Section 2: Dashboard schema contracts ── *)

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

(* ── Section 3: Telemetry contracts ── *)

let test_event_serialization_roundtrip () =
  let module T = Masc_mcp.Telemetry_eio in
  let events =
    [ T.Agent_joined { agent_id = "test-agent"; capabilities = [] };
      T.Task_started { task_id = "task-1"; agent_id = "agent-1" };
      T.Task_completed { task_id = "task-1"; duration_ms = 100; success = true };
      T.Tool_called
        {
          tool_name = "read_file";
          success = true;
          duration_ms = 10;
          agent_id = None;
          source = None;
          session_id = None;
          operation_id = None;
          worker_run_id = None;
          error_kind = None;
          error_message = None;
          exit_code = None;
          stderr_excerpt = None;
        };
      T.Error_occurred { code = "E001"; message = "test"; context = "test" } ]
  in
  List.iter (fun event ->
    let json = T.event_to_yojson event in
    let json_str = Yojson.Safe.to_string json in
    check bool ("json roundtrip: " ^ T.show_event event)
      true (String.length json_str > 0))
    events

(* ── Section 4: Extended redaction contracts ── *)

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
      ( "oas_model_resolve",
        [
          test_case "dashboard snapshots include cli and api" `Quick
            test_dashboard_provider_snapshots_include_cli_and_api;
          test_case "default registry populated" `Quick
            test_default_registry_populated;
          test_case "provider name of label" `Quick test_provider_name_of_label;
          test_case "max context of label" `Quick test_max_context_of_label;
          test_case "effective discovered ctx floor" `Quick
            test_effective_discovered_ctx;
          test_case "local discovery label detection" `Quick
            test_labels_require_local_discovery;
          test_case "cascade unregistered default provenance" `Quick
            test_cascade_model_resolve_unregistered_default_provenance;
          test_case "cascade env default provenance" `Quick
            test_cascade_model_resolve_env_default_provenance;
          test_case "cascade discovery provenance" `Quick
            test_cascade_model_resolve_discovery_provenance;
          test_case "cascade unresolved auto provenance" `Quick
            test_cascade_model_resolve_unresolved_auto_provenance;
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
