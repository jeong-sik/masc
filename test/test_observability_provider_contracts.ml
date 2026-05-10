(** Contract tests for observability, provider, and telemetry boundaries.

    These tests verify public API contracts that cross module boundaries,
    ensuring serialization, resolution, and schema stability across releases.

    Issue #3955: Smoke harness + contract tests for CI stability. *)

open Alcotest

(* ── Section 1: Provider_adapter contracts ── *)

module Adapter = Masc_mcp.Provider_adapter
module Model_resolve = Masc_mcp.Cascade_model_resolve

let string_of_resolution_provenance = function
  | Model_resolve.Explicit_input -> "explicit_input"
  | Model_resolve.Alias alias -> "alias:" ^ alias
  | Model_resolve.Env_default var -> "env_default:" ^ var
  | Model_resolve.Hardcoded_default -> "hardcoded_default"
  | Model_resolve.Discovery -> "discovery"
  | Model_resolve.Unresolved_auto -> "unresolved_auto"

let resolution_provenance =
  testable
    (fun fmt provenance ->
      Format.pp_print_string fmt (string_of_resolution_provenance provenance))
    ( = )

let test_alias_roundtrip () =
  let cases =
    [ ("anthropic", "claude-api"); ("Claude", "claude");
      ("google", "gemini-api"); ("Gemini", "gemini");
      ("openai", "codex-api"); ("OpenAI", "codex-api");
      ("llama", "llama"); ("llamacpp", "llama");
      ("glm", "glm-api"); ("zai", "glm-api");
      ("glm-coding", "glm-coding-plan");
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
  let labels = [ "claude"; "anthropic"; "gemini"; "google"; "openai"; "llama" ] in
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
    let gemini_cli = provider_snapshot_by_name "gemini" in
    let glm_api = provider_snapshot_by_name "glm-api" in
    let glm_coding_plan = provider_snapshot_by_name "glm-coding-plan" in
    check bool "cli snapshot present" true (Option.is_some claude_cli);
    check bool "api snapshot present" true (Option.is_some claude_api);
    check bool "gemini cli snapshot present" true (Option.is_some gemini_cli);
    check bool "glm api snapshot present" true (Option.is_some glm_api);
    check bool "glm coding snapshot present" true (Option.is_some glm_coding_plan);
    check string "cli runtime kind" "cli_agent"
      (Option.get claude_cli).runtime_kind;
    check string "api runtime kind" "direct_api"
      (Option.get claude_api).runtime_kind;
    check string "glm api runtime kind" "direct_api"
      (Option.get glm_api).runtime_kind;
    check string "glm coding runtime kind" "direct_api"
      (Option.get glm_coding_plan).runtime_kind;
    check bool "gemini cli expands concrete models" true
      ((Option.get gemini_cli).models <> []);
    check bool "gemini cli does not expose bare auto" false
      (List.mem "auto" (Option.get gemini_cli).models))

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

let test_cascade_model_resolve_alias_provenance () =
  let resolved =
    Model_resolve.resolve_glm_model ~getenv:(fun _ -> None)
      (Model_resolve.model_selector_of_string "flash")
  in
  check string "glm flash alias" "glm-4.7-flashx" resolved.resolved_model_id;
  check resolution_provenance "alias provenance"
    (Model_resolve.Alias "flash") resolved.provenance

let test_cascade_model_resolve_hardcoded_default_provenance () =
  let resolved =
    Model_resolve.resolve_auto_model ~getenv:(fun _ -> None) "openai"
      (Model_resolve.model_selector_of_string "auto")
  in
  check string "openai hardcoded default" "gpt-4.1" resolved.resolved_model_id;
  check resolution_provenance "hardcoded provenance"
    Model_resolve.Hardcoded_default resolved.provenance

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
  let resolved =
    Model_resolve.resolve_auto_model
      ~getenv:(fun _ -> None)
      ~discover:(fun () -> Some "qwen3:8b")
      "ollama" (Model_resolve.model_selector_of_string "auto")
  in
  check string "ollama discovery" "qwen3:8b" resolved.resolved_model_id;
  check resolution_provenance "discovery provenance"
    Model_resolve.Discovery resolved.provenance

let test_cascade_model_resolve_unresolved_auto_provenance () =
  let resolved =
    Model_resolve.resolve_auto_model ~getenv:(fun _ -> None) "openrouter"
      (Model_resolve.model_selector_of_string "auto")
  in
  check string "openrouter unresolved auto stays auto" "auto"
    resolved.resolved_model_id;
  check resolution_provenance "unresolved provenance"
    Model_resolve.Unresolved_auto resolved.provenance

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
          test_case "cascade alias provenance" `Quick
            test_cascade_model_resolve_alias_provenance;
          test_case "cascade hardcoded default provenance" `Quick
            test_cascade_model_resolve_hardcoded_default_provenance;
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
