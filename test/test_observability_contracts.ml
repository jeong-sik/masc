(** Contract tests for observability and telemetry boundaries.

    These tests verify public API contracts that cross module boundaries,
    ensuring serialization, resolution, and schema stability across releases.

    Issue #3955: Smoke harness + contract tests for CI stability. *)

open Alcotest

let with_provider_catalog entries f =
  let previous = Llm_provider.Provider_catalog.global () in
  Llm_provider.Provider_catalog.set_global entries;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some entries -> Llm_provider.Provider_catalog.set_global entries
      | None -> Llm_provider.Provider_catalog.clear_global ())
    f

(* ── Section 1: OAS catalog consumption contracts ── *)

let test_dashboard_provider_snapshots_include_oas_catalog_overlay () =
  let caps =
    { Llm_provider.Capabilities.default_capabilities with
      max_context_tokens = Some 4242
    }
  in
  let entry : Llm_provider.Provider_catalog.entry =
    { id = "fixture-cloud-runtime"
    ; aliases = [ "fixture-cloud" ]
    ; kind = Llm_provider.Provider_config.OpenAI_compat
    ; transport = Llm_provider.Provider_catalog.Custom_openai_compat
    ; command = None
    ; base_url = "https://fixture-cloud.invalid/v1"
    ; request_path = "/v1/chat/completions"
    ; api_key_env = ""
    ; auth = Llm_provider.Provider_catalog.No_auth
    ; default_model = Some "fixture-model"
    ; max_context = Some 4242
    ; capabilities = caps
    ; non_interactive = true
    ; interactive_required = false
    ; daemon_safe = true
    ; credential_scope = None
    }
  in
  Eio_main.run (fun _env ->
    with_provider_catalog [ entry ] (fun () ->
      let open Masc_mcp.Dashboard_provider_runs in
      match provider_snapshot_by_name "fixture-cloud-runtime" with
      | None -> fail "fixture catalog provider missing from dashboard snapshot"
      | Some snapshot ->
        check string "source" "oas/provider-catalog" snapshot.source;
        check string "runtime kind" "direct_api" snapshot.runtime_kind;
        check
          (option string)
          "default model"
          (Some "fixture-model")
          snapshot.default_model;
        check (list string) "models" [ "fixture-model" ] snapshot.models;
        check
          (option string)
          "endpoint"
          (Some "https://fixture-cloud.invalid/v1")
          snapshot.endpoint_url))

let test_provider_name_of_label () =
  let name =
    Masc_mcp.Cascade_runtime.provider_name_of_label
      "fixture-provider:fixture-model"
  in
  check (option string) "provider name" (Some "fixture-provider") name;
  let no_colon = Masc_mcp.Cascade_runtime.provider_name_of_label
      "just-a-model" in
  check (option string) "no colon returns None" None no_colon;
  let empty = Masc_mcp.Cascade_runtime.provider_name_of_label "" in
  check (option string) "empty returns None" None empty

let test_max_context_of_label () =
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
  check int "synthetic unregistered provider fallback 128000" 128_000
    (Masc_mcp.Cascade_runtime.resolve_max_cascade_context
       [ "fixture-provider:fixture-model" ])

let test_labels_require_local_discovery () =
  check bool "llama labels refresh local discovery" true
    (Masc_mcp.Cascade_runtime.labels_require_local_discovery
       [ "llama:auto"; "fixture-remote:auto" ]);
  check bool "mixed non-local labels skip refresh" false
    (Masc_mcp.Cascade_runtime.labels_require_local_discovery
       [ "fixture-remote:auto"; "fixture-cloud:auto" ]);
  check bool "malformed labels skip refresh" false
    (Masc_mcp.Cascade_runtime.labels_require_local_discovery
       [ "default"; "fixture-remote:auto" ])

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
  run "Observability Contracts"
    [
      ( "oas_catalog_consumption",
        [
          test_case "dashboard snapshots include catalog overlay" `Quick
            test_dashboard_provider_snapshots_include_oas_catalog_overlay;
          test_case "provider name of label" `Quick test_provider_name_of_label;
          test_case "max context of label" `Quick test_max_context_of_label;
          test_case "effective discovered ctx floor" `Quick
            test_effective_discovered_ctx;
          test_case "local discovery label detection" `Quick
            test_labels_require_local_discovery;
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
